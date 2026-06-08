import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/book_source.dart';
import '../../services/app_logger.dart';
import '../../services/storage_service.dart';

class InternalBrowserPage extends StatefulWidget {
  final String url;
  final String title;
  final String sourceUrl;
  final String sourceName;
  final Map<String, String> headers;

  const InternalBrowserPage({
    super.key,
    required this.url,
    this.title = '',
    this.sourceUrl = '',
    this.sourceName = '',
    this.headers = const {},
  });

  @override
  State<InternalBrowserPage> createState() => _InternalBrowserPageState();
}

class _InternalBrowserPageState extends State<InternalBrowserPage> {
  InAppWebViewController? _controller;
  double _progress = 0;
  bool _isFullScreen = false;
  bool _showWebLog = false;
  String _currentUrl = '';

  bool get _hasSource => widget.sourceUrl.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
  }

  @override
  void dispose() {
    if (_isFullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _handleBack(didPop),
      child: Scaffold(
        appBar: _isFullScreen
            ? null
            : AppBar(
                titleSpacing: 0,
                title: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title.isEmpty ? '网页' : widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.sourceName.isNotEmpty)
                      Text(
                        widget.sourceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                actions: [
                  IconButton(
                    tooltip: '刷新',
                    onPressed: () => _controller?.reload(),
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: '确定',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.check),
                  ),
                  IconButton(
                    tooltip: '页内搜索',
                    onPressed: _showSearchDialog,
                    icon: const Icon(Icons.search),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    offset: const Offset(0, 48),
                    onSelected: _handleMenuAction,
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'browser',
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Text('浏览器打开'),
                      ),
                      const PopupMenuItem(
                        value: 'copy',
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Text('拷贝URL'),
                      ),
                      const PopupMenuItem(
                        value: 'fullscreen',
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Text('全屏'),
                      ),
                      PopupMenuItem(
                        value: 'log',
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            const Expanded(child: Text('输出日志')),
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              alignment: Alignment.center,
                              child: _showWebLog
                                  ? Icon(
                                      Icons.check,
                                      size: 18,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                      if (_hasSource)
                        const PopupMenuItem(
                          value: 'disable',
                          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Text('禁用源'),
                        ),
                      if (_hasSource)
                        const PopupMenuItem(
                          value: 'delete',
                          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Text('删除源'),
                        ),
                    ],
                  ),
                ],
                bottom: _progress < 1
                    ? PreferredSize(
                        preferredSize: const Size.fromHeight(2),
                        child: LinearProgressIndicator(
                          value: _progress,
                          minHeight: 2,
                        ),
                      )
                    : null,
              ),
        body: InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri(widget.url),
            headers: widget.headers,
          ),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
            supportZoom: true,
            useWideViewPort: true,
            loadWithOverviewMode: true,
          ),
          onWebViewCreated: (controller) => _controller = controller,
          onLoadStart: (_, url) {
            if (url != null) _currentUrl = url.toString();
          },
          onLoadStop: (_, url) {
            if (url != null) _currentUrl = url.toString();
          },
          onProgressChanged: (_, progress) {
            if (mounted) setState(() => _progress = progress / 100);
          },
          onConsoleMessage: (_, message) {
            if (_showWebLog) {
              AppLogger.instance.debug(
                LogCategory.js,
                'WebView: ${message.message}',
              );
            }
          },
        ),
      ),
    );
  }

  Future<void> _handleBack(bool didPop) async {
    if (didPop) return;
    if (_isFullScreen) {
      _toggleFullScreen();
    } else if (await _controller?.canGoBack() == true) {
      await _controller?.goBack();
    } else if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _handleMenuAction(String action) async {
    switch (action) {
      case 'browser':
        final uri = Uri.tryParse(_currentUrl);
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: _currentUrl));
        _showMessage('已复制URL');
        break;
      case 'fullscreen':
        _toggleFullScreen();
        break;
      case 'log':
        setState(() => _showWebLog = !_showWebLog);
        _showMessage(_showWebLog ? '已开启网页日志' : '已关闭网页日志');
        break;
      case 'disable':
        await _disableSource();
        break;
      case 'delete':
        await _deleteSource();
        break;
    }
  }

  void _toggleFullScreen() {
    setState(() => _isFullScreen = !_isFullScreen);
    SystemChrome.setEnabledSystemUIMode(
      _isFullScreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  Future<void> _showSearchDialog() async {
    final controller = TextEditingController();
    final query = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('页内搜索'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入搜索内容'),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('搜索'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (query == null || query.isEmpty) return;
    final escaped = query
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
    await _controller?.evaluateJavascript(
      source:
          "window.find('$escaped', false, false, true, false, true, false);",
    );
  }

  Future<void> _disableSource() async {
    final data = StorageService.instance.getBookSource(widget.sourceUrl);
    if (data == null) {
      _showMessage('书源不存在');
      return;
    }
    final source = BookSource.fromJson(data);
    await StorageService.instance.saveBookSource(
      source.copyWith(enabled: false).toJson(),
    );
    if (!mounted) return;
    _showMessage('已禁用源');
    Navigator.pop(context);
  }

  Future<void> _deleteSource() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除源'),
        content: Text('确定删除“${widget.sourceName}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await StorageService.instance.deleteBookSource(widget.sourceUrl);
    if (!mounted) return;
    _showMessage('已删除源');
    Navigator.pop(context);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
