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

  @override
  void initState() {
    super.initState();
    widget.controller.setCallbacks(widget.callbacks);
    _currentHtml = _generateHtml();
    _lastStyleSnapshot = _StyleSnapshot.fromProvider(widget.provider);
  }

  @override
  void didUpdateWidget(ReaderWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容/模式变化 → 重新生成 HTML 并加载
    if (oldWidget.content != widget.content ||
        oldWidget.title != widget.title ||
        oldWidget.isScrollMode != widget.isScrollMode) {
      _currentHtml = _generateHtml();
      _lastStyleSnapshot = _StyleSnapshot.fromProvider(widget.provider);
      _reloadHtml();
      return;
    }
    // 样式变化（字号/行高/缩进/颜色/字重/标题模式等）→ 重新生成 HTML 并加载
    // 用快照比较，避免同一 provider 实例导致比较永远 false 的陷阱
    final current = _StyleSnapshot.fromProvider(widget.provider);
    if (_lastStyleSnapshot != current) {
      _lastStyleSnapshot = current;
      _currentHtml = _generateHtml();
      _reloadHtml();
    }
  }

  /// 生成 HTML 内容
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
      viewWidth: _viewWidth,
      viewHeight: _viewHeight,
      isScrollMode: widget.isScrollMode,
      pageAnimDurationMs: widget.provider.pageAnimDurationMs,
      pageModeIndex: widget.provider.pageMode.index,
    );
  }

  double get _viewWidth {
    final size = MediaQuery.sizeOf(context);
    return size.width - widget.provider.paddingLeft - widget.provider.paddingRight;
  }

  double get _viewHeight {
    final size = MediaQuery.sizeOf(context);
    return size.height - widget.provider.paddingTop - widget.provider.paddingBottom;
  }

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
        return InAppWebView(
          initialData: InAppWebViewInitialData(
            data: _currentHtml,
            mimeType: 'text/html',
            encoding: 'utf-8',
            baseUrl: WebUri('about:blank'),
          ),
          initialSettings: InAppWebViewSettings(
            transparentBackground: true,
            useHybridComposition: true,
            disableContextMenu: false,
            disableHorizontalScroll: true,
            disableVerticalScroll: widget.isScrollMode ? false : true,
            supportZoom: false,
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
