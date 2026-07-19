import 'dart:async' show Timer;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../../models/highlight.dart';
import '../../../providers/reader_provider.dart';
import '../../../utils/chinese_converter.dart';
import 'reader_html_template.dart';
import 'reader_webview_controller.dart';

/// 阅读器 WebView 组件
///
/// 替代原有的 flutter_html 渲染方案，改用 WebView 原生渲染 HTML+CSS。
///
/// 核心优势：
/// - CSS column-width 原生分栏分页，无需 Dart 侧手动测量
/// - text-indent 原生支持，首行缩进准确
/// - 高亮规则用真正的 CSS class，完整支持 text-decoration-thickness 等
/// - 性能更好（浏览器原生渲染）
///
/// 架构：
/// - ReaderWebView: Widget 封装，负责创建 InAppWebView 和加载内容
/// - ReaderWebViewController: 控制器，提供 Dart→JS 调用方法
/// - ReaderHtmlTemplate: HTML/CSS/JS 模板生成
class ReaderWebView extends StatefulWidget {
  /// 章节内容（纯文本，未经简繁转换）
  final String content;

  /// 章节标题
  final String title;

  /// 章节索引（用于 IntersectionObserver 监测当前可见章节）
  ///
  /// 仅用于初始 HTML 生成时给 <h1> 加 data-chapter-index 属性。
  /// 滚动模式中追加章节时由 appendChapter 单独传入 chapterIndex 参数，
  /// 不依赖此字段（因为 ReaderWebView 的 chapterIndex 只反映初始章节）。
  final int chapterIndex;

  /// 阅读器配置
  final ReaderProvider provider;

  /// 是否滚动模式
  final bool isScrollMode;

  /// 控制器
  final ReaderWebViewController controller;

  /// 回调
  final ReaderWebViewCallbacks callbacks;

  const ReaderWebView({
    super.key,
    required this.content,
    required this.title,
    required this.chapterIndex,
    required this.provider,
    required this.isScrollMode,
    required this.controller,
    required this.callbacks,
  });

  @override
  State<ReaderWebView> createState() => _ReaderWebViewState();
}

class _ReaderWebViewState extends State<ReaderWebView> {
  InAppWebViewController? _webviewController;
  bool _isLoaded = false;
  String _currentHtml = '';
  // 样式快照：记录上次生成 HTML 时的所有 CSS 相关字段值
  // ChangeNotifier 是单例，didUpdateWidget 拿到的 oldWidget.provider 和
  // widget.provider 是同一引用，无法直接比较字段（getter 返回最新值）。
  // 用快照在生成 HTML 后保存，下次 didUpdateWidget 时与当前值比较。
  _StyleSnapshot? _lastStyleSnapshot;

  /// 样式变化 reload 的防抖 timer
  ///
  /// 滑块类高频变化（fontSize/lineHeight/pageAnimDuration 等）每次 notifyListeners
  /// 都会触发 didUpdateWidget → _reloadHtml。直接 reload 会重置 WebView 状态、丢失
  /// 当前位置，且高频 reload 严重卡顿。
  /// 策略：样式变化时延迟 200ms 执行 reload，期间若有新变化则取消旧 timer 重启。
  /// 内容/模式变化（content/title/isScrollMode）不走防抖，立即 reload。
  Timer? _styleReloadDebounce;
  static const Duration _styleReloadDelay = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    widget.controller.setCallbacks(widget.callbacks);
    // 不在此处生成 HTML：_lastConstraints 此时为 (0,0)，生成的尺寸错误
    // 等 build 方法第一次拿到 LayoutBuilder 的真实 constraints 后再生成
    _lastStyleSnapshot = _StyleSnapshot.fromProvider(widget.provider);
  }

  @override
  void didUpdateWidget(ReaderWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容/模式变化 → 重新生成 HTML 并加载（不走防抖，立即生效）
    // 滚动模式下 title 变化不触发 reload：
    // - 滚动模式中 IntersectionObserver 监测到用户滚到下一章时，Dart 侧
    //   setState 更新 _chapterTitle（让 UI 顶栏跟随显示），但 WebView 内部
    //   已通过 appendChapter 写入了新章节标题，不需要重新生成 HTML
    // - 若 reload 会清空所有 appendChapter 追加的内容，破坏滚动状态
    // - 分页模式下 title 变化 = 章节切换，content 也会变，由前一个条件触发 reload
    if (oldWidget.content != widget.content ||
        oldWidget.isScrollMode != widget.isScrollMode ||
        (!widget.isScrollMode && oldWidget.title != widget.title)) {
      _styleReloadDebounce?.cancel();
      _currentHtml = _generateHtml();
      _lastStyleSnapshot = _StyleSnapshot.fromProvider(widget.provider);
      _reloadHtml();
      return;
    }
    // 样式变化（字号/行高/缩进/颜色/字重/标题模式等）→ 防抖 reload
    // 用快照比较，避免同一 provider 实例导致比较永远 false 的陷阱
    final current = _StyleSnapshot.fromProvider(widget.provider);
    if (_lastStyleSnapshot != current) {
      _lastStyleSnapshot = current;
      _currentHtml = _generateHtml();
      // 防抖：滑块拖动期间高频触发，等 200ms 静止后才真正 reload
      _styleReloadDebounce?.cancel();
      _styleReloadDebounce = Timer(_styleReloadDelay, () {
        if (mounted) _reloadHtml();
      });
    }
  }

  /// 生成 HTML 内容
  ///
  /// viewWidth/viewHeight 必须用 LayoutBuilder 的 constraints（WebView 实际可用尺寸），
  /// 不能用 MediaQuery.sizeOf（屏幕尺寸）——因为 WebView 位于 SafeArea > Column > Expanded
  /// 内，顶部可能有 header、底部可能有 footer，实际可用区域远小于屏幕。
  /// 传入正确尺寸后 JS 的 column-width 才能正确分页，避免翻页错位。
  String _generateHtml() {
    // 简繁转换
    final displayContent = ChineseConverter.convert(
      widget.content,
      widget.provider.chineseConverterType,
    );
    final displayTitle = ChineseConverter.convert(
      widget.title,
      widget.provider.chineseConverterType,
    );

    return ReaderHtmlTemplate.generate(
      content: displayContent,
      title: displayTitle,
      provider: widget.provider,
      viewWidth: _lastConstraints.maxWidth,
      viewHeight: _lastConstraints.maxHeight,
      isScrollMode: widget.isScrollMode,
      pageAnimDurationMs: widget.provider.pageAnimDurationMs,
      pageModeIndex: widget.provider.pageMode.index,
      chapterIndex: widget.chapterIndex,
    );
  }

  /// 最近一次 LayoutBuilder 的 constraints（build 时更新）
  /// 用于 _generateHtml 取 WebView 实际可用尺寸
  BoxConstraints _lastConstraints = const BoxConstraints();

  /// 重新加载 HTML
  Future<void> _reloadHtml() async {
    if (_webviewController == null) return;
    setState(() => _isLoaded = false);
    await _webviewController!.loadData(
      data: _currentHtml,
      mimeType: 'text/html',
      encoding: 'utf-8',
      baseUrl: WebUri('about:blank'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 检测尺寸变化（如键盘弹出、旋转、header/footer 显隐）
        final sizeChanged = _lastConstraints.maxWidth != constraints.maxWidth ||
            _lastConstraints.maxHeight != constraints.maxHeight;
        final isFirstBuild = _currentHtml.isEmpty;

        if (sizeChanged) {
          _lastConstraints = constraints;
          _currentHtml = _generateHtml();
          if (!isFirstBuild) {
            // 非首次：尺寸变化需异步重载 HTML（CSS column-width 依赖 viewWidth）
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _reloadHtml();
            });
          }
          // 首次：_currentHtml 直接传给 initialData，无需手动重载
        }
        return InAppWebView(
          initialData: InAppWebViewInitialData(
            data: _currentHtml,
            mimeType: 'text/html',
            encoding: 'utf-8',
            baseUrl: WebUri('about:blank'),
          ),
          initialSettings: InAppWebViewSettings(
            transparentBackground: true,
            // 必须为 false：Hybrid Composition 模式下 WebView 由 Android
            // 原生绘制到独立 Surface，Flutter 的 RepaintBoundary.toImage()
            // 无法截到该 Surface 内容 → 翻页截图会是空白 → 排版乱。
            // Texture Layer 模式下 WebView 作为 texture 合成到 Flutter 树，
            // 可被 RepaintBoundary 正常截图。
            useHybridComposition: false,
            // 必须为 true：禁用 Android 默认 ActionMode（系统选择菜单），
            // 改由 JS 自定义浮动菜单（reader_html_template.dart 中的
            // #reader-selection-menu）替代，样式更美观统一。
            // 同时长按图片的 onImageTap 通过 JS click 触发，不依赖此菜单。
            disableContextMenu: true,
            disableHorizontalScroll: true,
            disableVerticalScroll: widget.isScrollMode ? false : true,
            supportZoom: false,
            // 必须显式关闭 builtInZoomControls，否则 Android WebView 仍允许
            // 双指缩放手势触发（supportZoom:false 只禁缩放功能，不禁手势识别）
            builtInZoomControls: false,
            displayZoomControls: false,
            javaScriptEnabled: true,
            allowFileAccessFromFileURLs: true,
            allowUniversalAccessFromFileURLs: true,
            verticalScrollBarEnabled: false,
            horizontalScrollBarEnabled: false,
            overScrollMode: OverScrollMode.NEVER,
          ),
          onWebViewCreated: _onWebViewCreated,
          onLoadStop: _onLoadStop,
        );
      },
    );
  }

  void _onWebViewCreated(InAppWebViewController controller) {
    _webviewController = controller;
    widget.controller.attach(controller);
    widget.controller.setupJavaScriptHandlers(controller);
  }

  void _onLoadStop(InAppWebViewController controller, WebUri? uri) {
    if (!_isLoaded) {
      _isLoaded = true;
      // 不在此处 markReady 或 jumpToPage：
      // CSS column 布局需要 JS init() 里的 requestAnimationFrame 两帧后才能
      // 正确计算 scrollWidth / columnWidth，由 JS notifyPageCountReady 回调
      // 触发 onPageCountReady，在那里统一 markReady + jumpToPage
      widget.callbacks.onInitialized();
    }
  }

  @override
  void dispose() {
    // 取消防抖 timer，避免 widget 销毁后还触发 _reloadHtml
    _styleReloadDebounce?.cancel();
    super.dispose();
  }
}

/// 阅读器样式快照
///
/// 用于 ReaderWebView.didUpdateWidget 中检测样式是否变化。
/// ReaderProvider 是 ChangeNotifier 单例，didUpdateWidget 拿到的
/// oldWidget.provider 和 widget.provider 是同一引用，直接比较字段
/// 永远相等（getter 返回最新值）。所以需要在生成 HTML 后保存快照，
/// 下次 didUpdateWidget 时用当前值构造新快照，与上次快照比较。
///
/// 覆盖所有影响 WebView HTML/CSS 渲染的字段：
/// - 基础排版：字号/行距/字距/段距/缩进/字重/字体
/// - 颜色：文字色/背景色
/// - 边距：正文上下左右边距
/// - 标题：显示开关/模式/字号增量/上下间距
/// - 简繁转换类型
/// - 高亮规则（pattern/style/color）
class _StyleSnapshot {
  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final double paragraphSpacing;
  final String paragraphIndent;
  final Color textColor;
  final Color backgroundColor;
  final String fontFamily;
  final int fontWeightIndex;
  final bool fontWeightFine;
  final int textBoldFine;
  final int titleBoldFine;
  final double paddingTop;
  final double paddingBottom;
  final double paddingLeft;
  final double paddingRight;
  final bool showChapterTitle;
  final int titleMode;
  final int titleSize;
  final int titleTopSpacing;
  final int titleBottomSpacing;
  final int chineseConverterType;
  final int pageAnimDurationMs;
  final int pageModeIndex;
  final List<Object?> highlightRulesSnapshot;

  _StyleSnapshot({
    required this.fontSize,
    required this.lineHeight,
    required this.letterSpacing,
    required this.paragraphSpacing,
    required this.paragraphIndent,
    required this.textColor,
    required this.backgroundColor,
    required this.fontFamily,
    required this.fontWeightIndex,
    required this.fontWeightFine,
    required this.textBoldFine,
    required this.titleBoldFine,
    required this.paddingTop,
    required this.paddingBottom,
    required this.paddingLeft,
    required this.paddingRight,
    required this.showChapterTitle,
    required this.titleMode,
    required this.titleSize,
    required this.titleTopSpacing,
    required this.titleBottomSpacing,
    required this.chineseConverterType,
    required this.pageAnimDurationMs,
    required this.pageModeIndex,
    required this.highlightRulesSnapshot,
  });

  factory _StyleSnapshot.fromProvider(ReaderProvider p) {
    final rules = p.highlightRules.where((r) => r.enabled).map((r) {
      return <Object?>[r.pattern, r.style.index, r.color.color.toARGB32()];
    }).toList();
    return _StyleSnapshot(
      fontSize: p.fontSize,
      lineHeight: p.lineHeight,
      letterSpacing: p.letterSpacing,
      paragraphSpacing: p.paragraphSpacing,
      paragraphIndent: p.paragraphIndent,
      textColor: p.textColor,
      backgroundColor: p.backgroundColor,
      fontFamily: p.fontFamily,
      fontWeightIndex: p.fontWeightIndex,
      fontWeightFine: p.fontWeightFine,
      textBoldFine: p.textBoldFine,
      titleBoldFine: p.titleBoldFine,
      paddingTop: p.paddingTop,
      paddingBottom: p.paddingBottom,
      paddingLeft: p.paddingLeft,
      paddingRight: p.paddingRight,
      showChapterTitle: p.showChapterTitle,
      titleMode: p.titleMode,
      titleSize: p.titleSize,
      titleTopSpacing: p.titleTopSpacing,
      titleBottomSpacing: p.titleBottomSpacing,
      chineseConverterType: p.chineseConverterType,
      pageAnimDurationMs: p.pageAnimDurationMs,
      pageModeIndex: p.pageMode.index,
      highlightRulesSnapshot: rules,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _StyleSnapshot) return false;
    if (fontSize != other.fontSize ||
        lineHeight != other.lineHeight ||
        letterSpacing != other.letterSpacing ||
        paragraphSpacing != other.paragraphSpacing ||
        paragraphIndent != other.paragraphIndent ||
        textColor.toARGB32() != other.textColor.toARGB32() ||
        backgroundColor.toARGB32() != other.backgroundColor.toARGB32() ||
        fontFamily != other.fontFamily ||
        fontWeightIndex != other.fontWeightIndex ||
        fontWeightFine != other.fontWeightFine ||
        textBoldFine != other.textBoldFine ||
        titleBoldFine != other.titleBoldFine ||
        paddingTop != other.paddingTop ||
        paddingBottom != other.paddingBottom ||
        paddingLeft != other.paddingLeft ||
        paddingRight != other.paddingRight ||
        showChapterTitle != other.showChapterTitle ||
        titleMode != other.titleMode ||
        titleSize != other.titleSize ||
        titleTopSpacing != other.titleTopSpacing ||
        titleBottomSpacing != other.titleBottomSpacing ||
        chineseConverterType != other.chineseConverterType ||
        pageAnimDurationMs != other.pageAnimDurationMs ||
        pageModeIndex != other.pageModeIndex) {
      return false;
    }
    // 高亮规则比较
    final a = highlightRulesSnapshot;
    final b = other.highlightRulesSnapshot;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final ra = a[i] as List<Object?>;
      final rb = b[i] as List<Object?>;
      if (ra.length != rb.length) return false;
      for (var j = 0; j < ra.length; j++) {
        if (ra[j] != rb[j]) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll([
        fontSize,
        lineHeight,
        letterSpacing,
        paragraphSpacing,
        paragraphIndent,
        textColor.toARGB32(),
        backgroundColor.toARGB32(),
        fontFamily,
        fontWeightIndex,
        fontWeightFine,
        textBoldFine,
        titleBoldFine,
        paddingTop,
        paddingBottom,
        paddingLeft,
        paddingRight,
        showChapterTitle,
        titleMode,
        titleSize,
        titleTopSpacing,
        titleBottomSpacing,
        chineseConverterType,
        pageAnimDurationMs,
        pageModeIndex,
        ...highlightRulesSnapshot,
      ]);
}
