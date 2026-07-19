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

  /// 文字选区完成（防抖 250ms 稳定后触发）
  ///
  /// 参数：
  /// - text：选中的文字
  /// - rect：选区在 WebView 内的 rect（WebView 坐标系，已与 Flutter 一致）
  ///
  /// 用途：Dart 侧可在此处记录选区位置/内容，用于高亮回填等
  final void Function(String text, Rect rect)? onSelectionReady;

  /// 文字选择菜单项点击
  ///
  /// 参数：
  /// - action：'copy' / 'highlight' / 'lookup' / 'share'
  /// - text：选中的文字
  /// - rect：选区在 WebView 内的 rect
  ///
  /// action='copy' 时 JS 已自行用 Clipboard API 复制，Dart 此处兜底
  /// action='highlight' 时 Dart 应弹颜色选择器，保存 Highlight 并刷新 HTML
  /// action='lookup' 时 Dart 应弹查词对话框
  /// action='share' 时 Dart 应调用 Share.share
  final void Function(String action, String text, Rect rect)? onSelectionAction;

  /// 文字选区菜单隐藏（选区被清除 / 滚动 / 视口变化时触发）
  final void Function()? onHideSelectionMenu;

  /// 滚动模式：当前可见章节变化（用户滚动到另一章时触发）
  ///
  /// 触发条件：JS 端 IntersectionObserver 监测到 [data-chapter-index]
  /// 元素进入屏幕中部 10% 区域时回调一次。
  ///
  /// 参数：
  /// - chapterIndex：当前可见章节在 _chapters 列表中的索引
  ///
  /// 用途：Dart 侧更新 _currentChapterIndex / _chapterTitle / _sliderValue
  /// 让 UI 章节标题、进度条实时跟随用户滚动更新
  final void Function(int chapterIndex)? onChapterVisible;

  /// WebView 即将因尺寸变化（旋转/键盘弹出/header-footer 显隐）触发 reload
  ///
  /// 在 reload 前由 ReaderWebView 调用，父级可在此通过 controller 异步获取
  /// 当前进度（滚动模式 getScrollProgress / 分页模式 getCurrentPage）保存到
  /// _pendingWebviewFraction，避免 reload 后位置丢失跳回顶部（E1 Bug）。
  ///
  /// 注意：回调本身是同步的，但内部可以 fire-and-forget 启动 async 保存。
  /// ReaderWebView 会在下一帧（addPostFrameCallback）才真正 reload，给
  /// async 保存留出执行时间。
  final Future<void> Function()? onBeforeSizeReload;

  const ReaderWebViewCallbacks({
    required this.onInitialized,
    required this.onPageCountReady,
    required this.onPageChanged,
    required this.onTap,
    required this.onImageTap,
    this.onScrollNearEnd,
    this.onSelectionReady,
    this.onSelectionAction,
    this.onHideSelectionMenu,
    this.onChapterVisible,
    this.onBeforeSizeReload,
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
  Future<void> appendChapter(String title, String paragraphsHtml, int chapterIndex) async {
    if (!_isReady) return;
    // 用 jsonEncode 把字符串转为合法 JS 字符串字面量（自动转义 "、\、\n 等）
    final titleJs = jsonEncode(title);
    final htmlJs = jsonEncode(paragraphsHtml);
    await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.appendChapter($titleJs, $htmlJs, $chapterIndex);',
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

  /// 主动隐藏 JS 自定义文字选择菜单
  ///
  /// 触发场景：
  /// - 章节切换、翻页时（避免菜单停留在旧选区位置）
  /// - 用户点击 ReaderControlOverlay 上的按钮（菜单呼出时同时存在选区菜单会很乱）
  /// - 离开页面 / 退出阅读器
  Future<void> hideSelectionMenu() async {
    if (!_isReady) return;
    await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.hideSelectionMenu();',
    );
  }

  /// 给当前选区上色高亮
  ///
  /// 在 JS 端用 surroundContents（单元素选区）或 execCommand('hiliteColor')
  /// （跨元素选区）给当前选区套 `<span class="sel-hl">`，上色后清除选区
  /// 并隐藏菜单。
  ///
  /// 参数：
  /// - [colorIndex]：颜色索引（0=黄/1=绿/2=蓝/3=粉/4=橙/5=紫）
  /// - [styleIndex]：样式索引（0=背景色/1=下划线/2=删除线/3=波浪线）
  ///
  /// 返回 true 表示上色成功（JS 端返回 boolean）。
  /// 失败原因可能：选区已失效（用户已点击别处清除选区）、选区跨段落且
  /// execCommand 兜底也失败。
  Future<bool> highlightSelection(int colorIndex, int styleIndex) async {
    if (!_isReady) return false;
    final result = await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.highlightSelection($colorIndex, $styleIndex);',
    );
    if (result == null) return false;
    if (result is bool) return result;
    if (result is String) return result == 'true';
    if (result is num) return result != 0;
    return false;
  }

  /// Phase 3.2：恢复持久化高亮（章节加载后批量重绘）
  ///
  /// [list] 是从 StorageService 取出的 JSON 列表，每项含
  /// { id, selectedText, color, style, ... }。
  /// JS 端遍历 #reader-content-a 文本节点，按 selectedText 匹配位置
  /// 用 .sel-hl span 包裹。重复恢复会按 data-highlight-id 跳过。
  Future<void> restoreHighlights(List<Map<String, dynamic>> list) async {
    if (!_isReady) return;
    if (list.isEmpty) return;
    final json = jsonEncode(list);
    await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.restoreHighlights($json);',
    );
  }

  /// Phase 3.2：按 selectedText 删除视觉高亮（持久化由 Dart 侧处理）
  ///
  /// 用于持久化高亮的视觉移除：Dart 侧删除 StorageService 记录后调用此方法
  /// 让 JS 端把对应 .sel-hl span 的内容提到父级，移除 span。
  Future<void> removeHighlightByText(String text) async {
    if (!_isReady) return;
    final textJs = jsonEncode(text);
    await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.removeHighlightByText($textJs);',
    );
  }

  /// Phase 3.4：全文搜索
  ///
  /// 返回匹配位置 JSON 数组字符串：
  /// `[{ idx, chapterIndex, offset, length, snippet, top }]`
  /// Dart 侧用 jsonDecode 解析后展示在 BottomSheet 列表中。
  Future<String> searchText(String query) async {
    if (!_isReady) return '[]';
    final queryJs = jsonEncode(query);
    final result = await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.searchText($queryJs);',
    );
    if (result is String) return result;
    if (result == null) return '[]';
    return result.toString();
  }

  /// Phase 3.4：滚动到第 idx 个搜索结果并高亮
  ///
  /// JS 端会清除上次搜索高亮，重新包裹 .sel-hl-search，并 smooth 滚动到该位置。
  Future<bool> scrollToSearchResult(int idx) async {
    if (!_isReady) return false;
    final result = await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.scrollToSearchResult($idx);',
    );
    if (result is bool) return result;
    if (result is String) return result == 'true';
    if (result is num) return result != 0;
    return false;
  }

  /// 重置 nearEndNotified 标志（_appendNextChapter 失败/空内容时调用）
  ///
  /// 避免空章节或网络失败时 nearEndNotified=true 死锁，导致用户必须滚回上方
  /// 才能再次触发 onScrollNearEnd（A3 Bug）。
  Future<void> resetNearEndNotify() async {
    if (!_isReady) return;
    await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.resetNearEndNotify();',
    );
  }

  /// 重新计算页数（样式更新后调用）
  Future<int> recalcPageCount() async {
    if (!_isReady) return 1;
    final result = await _webviewController?.evaluateJavascript(
      source: 'window.readerApi.getPageCount();',
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

    // 滚动模式：当前可见章节变化
    // - JS 端 IntersectionObserver 监测 [data-chapter-index] 元素进入屏幕中部
    // - 触发时 Dart 侧更新 _currentChapterIndex / _chapterTitle / _sliderValue
    // - 让 UI 章节标题实时跟随滚动更新（修复用户反馈的 bug）
    controller.addJavaScriptHandler(
      handlerName: 'onChapterVisible',
      callback: (args) {
        if (args.isEmpty) return;
        final idx = args[0];
        if (idx is int) {
          _callbacks?.onChapterVisible?.call(idx);
        } else if (idx is num) {
          _callbacks?.onChapterVisible?.call(idx.toInt());
        }
      },
    );

    // ============ 文字选择菜单 ============
    // 选区稳定 250ms 后触发，Dart 侧可记录选区内容/位置
    controller.addJavaScriptHandler(
      handlerName: 'onSelectionReady',
      callback: (args) {
        if (args.length < 5) return;
        final text = args[0]?.toString() ?? '';
        final left = _toDouble(args[1]);
        final top = _toDouble(args[2]);
        final width = _toDouble(args[3]);
        final height = _toDouble(args[4]);
        _callbacks?.onSelectionReady?.call(text, Rect.fromLTWH(left, top, width, height));
      },
    );

    // 菜单项点击：action ∈ {copy, highlight, lookup, share}
    // action=copy 时 JS 已自行用 Clipboard API 复制，Dart 此处兜底
    controller.addJavaScriptHandler(
      handlerName: 'onSelectionAction',
      callback: (args) {
        if (args.length < 6) return;
        final action = args[0]?.toString() ?? '';
        final text = args[1]?.toString() ?? '';
        final left = _toDouble(args[2]);
        final top = _toDouble(args[3]);
        final width = _toDouble(args[4]);
        final height = _toDouble(args[5]);
        _callbacks?.onSelectionAction?.call(
          action, text, Rect.fromLTWH(left, top, width, height));
      },
    );

    // 选区菜单隐藏（选区被清除 / 滚动 / 视口变化）
    controller.addJavaScriptHandler(
      handlerName: 'onHideSelectionMenu',
      callback: (args) {
        _callbacks?.onHideSelectionMenu?.call();
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
