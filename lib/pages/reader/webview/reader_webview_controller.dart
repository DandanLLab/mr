import 'dart:convert' show jsonEncode;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../../services/app_logger.dart';

/// WebView 阅读器回调
class ReaderWebViewCallbacks {
  /// 页面初始化完成（HTML 加载 + DOM 渲染完成）
  final void Function() onInitialized;

  /// 总页数计算完成
  final void Function(int totalPages) onPageCountReady;

  /// 页码变更
  final void Function(int pageIndex) onPageChanged;

  /// 普通点击（非图片）
  final void Function(double x, double y) onTap;

  /// 图片点击
  final void Function(String src, Rect rect) onImageTap;

  /// 滚动模式接近底部时触发（用于无缝衔接下一章）
  ///
  /// 触发条件：滚动到距底部 < 1.5 视口高度时通知一次，
  /// Dart 侧加载下一章并调 appendChapter 追加到 DOM，
  /// 追加后 JS 端会重置标志允许下次触发。
  /// 用户主动滚回顶部区域也会重置，允许下次触发。
  /// 仅滚动模式（PageMode.scroll）会触发。
  final void Function()? onScrollNearEnd;

  const ReaderWebViewCallbacks({
    required this.onInitialized,
    required this.onPageCountReady,
    required this.onPageChanged,
    required this.onTap,
    required this.onImageTap,
    this.onScrollNearEnd,
  });
}

/// WebView 阅读器控制器
///
/// 提供 Dart 侧调用 JS API 的方法：
/// - jumpToPage(pageIndex): 翻到指定页
/// - getCurrentPage(): 获取当前页码
/// - getPageCount(): 获取总页数
/// - getScrollProgress(): 获取滚动进度
/// - setScrollProgress(ratio): 设置滚动进度
/// - checkTap(x, y): 检测点击位置
class ReaderWebViewController {
  InAppWebViewController? _webviewController;
  ReaderWebViewCallbacks? _callbacks;
  bool _isReady = false;

  bool get isReady => _isReady;

  void attach(InAppWebViewController controller) {
    _webviewController = controller;
  }

  void detach() {
    _webviewController = null;
    _isReady = false;
  }

  void setCallbacks(ReaderWebViewCallbacks callbacks) {
    _callbacks = callbacks;
  }

  void markReady() {
    _isReady = true;
  }

  /// 翻到指定页
  /// [animate]: true=带翻页动画（用户主动翻页）, false=无动画（进度恢复/初始化）
  Future<void> jumpToPage(int pageIndex, {bool animate = true}) async {
    if (!_isReady) return;
    await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.jumpToPage($pageIndex, ${animate ? 'true' : 'false'});',
    );
  }

  /// 获取当前页码
  Future<int> getCurrentPage() async {
    if (!_isReady) return 0;
    final result = await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.getCurrentPage();',
    );
    return _toInt(result);
  }

  /// 获取总页数
  Future<int> getPageCount() async {
    if (!_isReady) return 1;
    final result = await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.getPageCount();',
    );
    return _toInt(result);
  }

  /// 获取滚动进度（0-1）
  Future<double> getScrollProgress() async {
    if (!_isReady) return 0;
    final result = await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.getScrollProgress();',
    );
    return _toDouble(result);
  }

  /// 设置滚动进度（0-1）
  Future<void> setScrollProgress(double ratio) async {
    if (!_isReady) return;
    await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.setScrollProgress($ratio);',
    );
  }

  /// 获取滚动像素偏移（滚动模式进度保存用）
  Future<int> getScrollOffset() async {
    if (!_isReady) return 0;
    final result = await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.getScrollOffset();',
    );
    return _toInt(result);
  }

  /// 滚动到指定像素偏移（滚动模式进度恢复用）
  Future<void> scrollToOffset(int px) async {
    if (!_isReady) return;
    await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.scrollToOffset($px);',
    );
  }

  /// 按视口高度滚动（direction: -1 上翻 / +1 下翻）
  /// 返回滚动后的进度（0-1），若已到顶/底返回 -1 表示触发章节切换
  Future<double> scrollByViewport(int direction) async {
    if (!_isReady) return -1;
    final result = await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.scrollByViewport($direction);',
    );
    return _toDouble(result);
  }

  /// 检测点击位置（让 JS 决定是普通点击还是图片点击）
  Future<void> checkTap(double x, double y) async {
    if (!_isReady) return;
    await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.checkTap($x, $y);',
    );
  }

  /// 追加章节内容到 DOM（滚动模式无缝衔接）
  ///
  /// 在不触发整页 reload 的前提下，把下一章标题 + 段落 HTML 追加到
  /// #reader-content-a 末尾，保留用户当前滚动位置。
  ///
  /// - [title]：章节标题（纯文本，已做简繁转换）。JS 端用 textContent
  ///   创建 h1，避免 XSS。
  /// - [paragraphsHtml]：段落 HTML（由 ReaderHtmlTemplate.buildParagraphsHtml
  ///   生成，包含 `<p class="reader-p">...</p>`），可信内容。
  ///
  /// 追加后 JS 端会重置 nearEndNotified，允许下次接近底部时再次触发。
  /// 仅滚动模式有效；分页模式调用此方法无意义（column 布局不会重排）。
  Future<void> appendChapter(String title, String paragraphsHtml) async {
    if (!_isReady) return;
    // 用 jsonEncode 把字符串转为合法 JS 字符串字面量（自动转义 "、\、\n 等）
    final titleJs = jsonEncode(title);
    final htmlJs = jsonEncode(paragraphsHtml);
    await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.appendChapter($titleJs, $htmlJs);',
    );
  }

  /// 获取已追加的章节数（用于 Dart 侧查询当前已加载到第几章）
  Future<int> getAppendedChapterCount() async {
    if (!_isReady) return 0;
    final result = await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.getAppendedChapterCount();',
    );
    return _toInt(result);
  }

  /// 重新计算页数（样式更新后调用）
  Future<int> recalcPageCount() async {
    if (!_isReady) return 1;
    final result = await _webviewController?.evaluateJavascript(
      source: '''
window.readerApi.getPageCount();
''',
    );
    return _toInt(result);
  }

  /// 设置 JS Handler（在 WebView 创建时调用）
  void setupJavaScriptHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'onPageCountReady',
      callback: (args) {
        if (args.isNotEmpty && args[0] is int) {
          _callbacks?.onPageCountReady(args[0] as int);
        } else if (args.isNotEmpty && args[0] is num) {
          _callbacks?.onPageCountReady((args[0] as num).toInt());
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'onPageChanged',
      callback: (args) {
        if (args.isNotEmpty && args[0] is int) {
          _callbacks?.onPageChanged(args[0] as int);
        } else if (args.isNotEmpty && args[0] is num) {
          _callbacks?.onPageChanged((args[0] as num).toInt());
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'onTap',
      callback: (args) {
        if (args.length >= 2) {
          _callbacks?.onTap(
            (args[0] as num).toDouble(),
            (args[1] as num).toDouble(),
          );
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'onImageTap',
      callback: (args) {
        if (args.length >= 5) {
          _callbacks?.onImageTap(
            args[0] as String,
            Rect.fromLTWH(
              (args[1] as num).toDouble(),
              (args[2] as num).toDouble(),
              (args[3] as num).toDouble(),
              (args[4] as num).toDouble(),
            ),
          );
        }
      },
    );

    // JS 日志桥：JS 端调用 callHandler('onReaderLog', msg) 回传到 Flutter
    // 直接写入 AppLogger（与搜索页一致），阅读器页面通过日志对话框查看
    controller.addJavaScriptHandler(
      handlerName: 'onReaderLog',
      callback: (args) {
        if (args.isEmpty) return;
        final msg = args[0]?.toString() ?? '';
        if (msg.isEmpty) return;
        // 级别判定：[error]/[warn] 走对应级别，其余走 debug
        if (msg.startsWith('[error]') || msg.contains(' uncaught:')) {
          AppLogger.instance.error(LogCategory.js, msg);
        } else if (msg.startsWith('[warn]')) {
          AppLogger.instance.warn(LogCategory.js, msg);
        } else {
          AppLogger.instance.debug(LogCategory.js, msg);
        }
      },
    );

    // 滚动模式无缝衔接：滚动接近底部时通知 Dart 侧加载下一章
    // - 仅滚动模式（isScrollMode=true）会触发，分页模式不会
    // - JS 端已做去重（nearEndNotified），appendChapter 后会重置
    controller.addJavaScriptHandler(
      handlerName: 'onScrollNearEnd',
      callback: (args) {
        _callbacks?.onScrollNearEnd?.call();
      },
    );
  }

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  double _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }
}
