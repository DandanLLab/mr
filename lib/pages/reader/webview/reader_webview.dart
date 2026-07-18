import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
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

  /// 初始页码（用于恢复阅读进度）
  final int initialPage;

  const ReaderWebView({
    super.key,
    required this.content,
    required this.title,
    required this.provider,
    required this.isScrollMode,
    required this.controller,
    required this.callbacks,
    this.initialPage = 0,
  });

  @override
  State<ReaderWebView> createState() => _ReaderWebViewState();
}

class _ReaderWebViewState extends State<ReaderWebView> {
  InAppWebViewController? _webviewController;
  bool _isLoaded = false;
  String _currentHtml = '';

  @override
  void initState() {
    super.initState();
    widget.controller.setCallbacks(widget.callbacks);
    _currentHtml = _generateHtml();
  }

  @override
  void didUpdateWidget(ReaderWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容变化 → 重新生成 HTML 并加载
    if (oldWidget.content != widget.content ||
        oldWidget.title != widget.title ||
        oldWidget.isScrollMode != widget.isScrollMode) {
      _currentHtml = _generateHtml();
      _reloadHtml();
      return;
    }
    // 样式变化（字号/行高/缩进/颜色等）→ 重新生成 HTML 并加载
    if (_styleChanged(oldWidget.provider, widget.provider)) {
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

  /// 检查影响渲染的样式是否变化
  bool _styleChanged(ReaderProvider oldP, ReaderProvider newP) {
    return oldP.fontSize != newP.fontSize ||
        oldP.lineHeight != newP.lineHeight ||
        oldP.letterSpacing != newP.letterSpacing ||
        oldP.paragraphSpacing != newP.paragraphSpacing ||
        oldP.paragraphIndent != newP.paragraphIndent ||
        oldP.textColor != newP.textColor ||
        oldP.backgroundColor != newP.backgroundColor ||
        oldP.fontFamily != newP.fontFamily ||
        oldP.showChapterTitle != newP.showChapterTitle ||
        oldP.titleTopSpacing != newP.titleTopSpacing ||
        oldP.titleBottomSpacing != newP.titleBottomSpacing ||
        oldP.paddingTop != newP.paddingTop ||
        oldP.paddingBottom != newP.paddingBottom ||
        oldP.paddingLeft != newP.paddingLeft ||
        oldP.paddingRight != newP.paddingRight ||
        oldP.chineseConverterType != newP.chineseConverterType ||
        _highlightRulesChanged(oldP, newP);
  }

  bool _highlightRulesChanged(ReaderProvider oldP, ReaderProvider newP) {
    final oldRules = oldP.highlightRules.where((r) => r.enabled).toList();
    final newRules = newP.highlightRules.where((r) => r.enabled).toList();
    if (oldRules.length != newRules.length) return true;
    for (var i = 0; i < oldRules.length; i++) {
      if (oldRules[i].pattern != newRules[i].pattern ||
          oldRules[i].style != newRules[i].style ||
          oldRules[i].color != newRules[i].color) {
        return true;
      }
    }
    return false;
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
      widget.controller.markReady();
      widget.callbacks.onInitialized();
      // 恢复初始页码
      if (widget.initialPage > 0 && !widget.isScrollMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          widget.controller.jumpToPage(widget.initialPage);
        });
      }
    }
  }
}
