import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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

  const ReaderWebViewCallbacks({
    required this.onInitialized,
    required this.onPageCountReady,
    required this.onPageChanged,
    required this.onTap,
    required this.onImageTap,
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

  /// 截图（用于翻页动画）
  Future<ui.Image?> takeScreenshot() async {
    // 翻页动画暂时不实现截图，返回 null 走简化路径
    return null;
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
