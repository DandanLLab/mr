import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/chapter.dart';
import '../../models/highlight.dart';
import '../../models/replace_rule.dart';
import '../../providers/reader_provider.dart';
import '../../providers/bookshelf_provider.dart';
import '../../services/book_data_provider.dart';
import '../../services/chapter_cache_service.dart';
import '../../services/chapter_prefetch_service.dart';
import '../../services/local_book/local_book_service.dart';
import '../../services/native/platform_channel.dart';
import '../../services/reader_bookmark_service.dart';
import '../../services/storage_service.dart';
import '../../services/read_record_service.dart';
import '../../widgets/reader/reader_control_overlay.dart';
import '../../widgets/reader/reader_settings_sheet.dart';
import '../../widgets/reader/reader_tts_bar.dart';
import '../../widgets/change_source_sheet.dart';
import '../../routes/app_routes.dart';
import '../../utils/design_tokens.dart';
import '../../utils/chinese_converter.dart';
import '../../utils/share_helper.dart';
import 'webview/reader_webview.dart';
import 'webview/reader_webview_controller.dart';
import 'webview/reader_html_template.dart';
import 'page_turn/reader_page_view.dart';
import 'page_turn/page_delegate.dart';

class NovelReaderPage extends StatefulWidget {
  final String bookUrl;
  final int chapterIndex;
  final bool resumeProgress;
  final Book? initialBook;

  const NovelReaderPage({
    super.key,
    required this.bookUrl,
    this.chapterIndex = 0,
    this.resumeProgress = false,
    this.initialBook,
  });

  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage>
    with TickerProviderStateMixin {
  bool _showMenu = false;
  /// 翻页动画进行中标记，用于阻止动画期间 JS click 误触发菜单
  /// 由 _onPageTurnCompleted / _onPageTurnCancelled 复位
  bool _isPageTurning = false;
  /// 翻页时等 onPageChanged 回调作为「JS 已设 transform」确认信号
  /// 由 _onWebviewPageChanged complete，由 _waitForWebViewFrame 等待
  Completer<void>? _pageRenderedCompleter;
  String _content = '';
  String _chapterTitle = '';
  String? _chapterUrl;
  int _currentChapterIndex = 0;
  int _totalChapters = 0;
  bool _isLoading = true;
  bool _restoreInitialPosition = false;
  int _initialChapterPos = 0;
  bool _pendingInitialPageToEnd = false;
  bool _isChangingChapterByPageView = false;
  Book? _book;
  BookSource? _bookSource;
  List<Chapter> _chapters = [];
  BookDataProvider? _dataProvider;
  double _sliderValue = 0; // 滑动进度条的实时值
  int _chapterLoadToken = 0;

  // Animation
  late AnimationController _menuAnimController;

  // 增强版控制
  bool _hasBookmark = false;
  // TTS 速度，必须与 _initTts 中传给 provider 的 rate 一致，否则 UI 显示与实际播放不符
  double _ttsSpeed = 0.5;
  bool _isAutoScroll = false;
  bool _useReplaceRules = true;
  List<ReplaceRule> _replaceRules = const [];
  Timer? _autoScrollTimer;
  // _processedContent 缓存：仅在 content/规则/useReplaceRules 变化时重算，
  // 避免每次 build 都对全文跑正则替换（滚动模式下一次 build 会调 3 次）
  String _processedCacheInput = '';
  bool _processedCacheUseRules = false;
  List<ReplaceRule> _processedCacheRules = const [];
  String _processedCacheOutput = '';

  // 阅读记录
  int _readStartTime = 0;
  Timer? _progressSaveTimer;
  Timer? _clockTimer;
  final ValueNotifier<double> _scrollProgressNotifier = ValueNotifier(0);
  double get _scrollProgress => _scrollProgressNotifier.value;

  // ==================== WebView 渲染层 ====================
  // 替代 flutter_html，使用 WebView 原生渲染 HTML+CSS+JS
  // - CSS column-width 原生分栏分页（无需 Dart 侧 TextPainter 测量）
  // - text-indent 原生支持（首行缩进准确）
  // - 高亮规则用真正的 CSS class（支持 text-decoration-thickness 等）
  final ReaderWebViewController _readerWebViewController =
      ReaderWebViewController();
  // WebView 总页数（每次内容或样式变化后由 onPageCountReady 回调更新）
  int _webviewPageCount = 1;
  // WebView 当前页码（由 onPageChanged 回调更新）
  int _webviewCurrentPage = 0;
  // WebView 是否已就绪（HTML 加载完成，可调用 JS API）
  bool _webviewReady = false;
  // 滚动模式无缝衔接：当前已加载到第几章（最大 index）
  //
  // - 章节切换（_loadChapterContent）时重置为 _currentChapterIndex
  // - 滚动到接近底部触发 _onScrollNearEnd 时，加载下一章并 _scrollChapterMax=nextIndex
  // - 用户主动翻到下一章 / 跳转章节时，_content 变化触发 WebView reload，
  //   _scrollChapterMax 同步重置为新章节 index，旧追加内容随 reload 清空
  int _scrollChapterMax = -1;
  // _appendNextChapter 防重入标志：避免 onScrollNearEnd 高频触发时重复加载
  bool _isAppendingChapter = false;
  // 待恢复的初始页码（章节加载时设置，WebView 就绪后调用 jumpToPage）
  // 约定：>= (1 << 30) 表示「跳到最后一页」
  int _pendingWebviewInitialPage = 0;
  // 待恢复的页码比例（样式变化后保留位置用，0.0-1.0）
  // 与 _pendingWebviewInitialPage 互斥使用：fraction >= 0 时优先用 fraction
  double _pendingWebviewFraction = -1.0;
  // WebView 是否正在重新加载内容（避免回调串扰）
  bool _webviewReloading = false;
  // 问题 9 修复：_webviewReloading 超时保护
  //
  // 背景：JS 端 notifyPageCountReady 因异常或图片/字体加载失败未触发时，
  // _webviewReloading 永远 true → _onWebviewPageChanged 永远早 return →
  // 翻页流程的 _pageRenderedCompleter 永远 complete 不了 → 用户卡死。
  //
  // 策略：设置 _webviewReloading=true 时同步启动 5s 超时，
  // _onWebviewPageCountReady 正常触发时取消；超时强制释放并日志告警。
  Timer? _webviewReloadTimeoutTimer;
  static const Duration _webviewReloadTimeout = Duration(seconds: 5);

  // ==================== 系统交互：屏幕常亮 / 亮度 / 音量键 ====================
  // 焦点节点：用于接收硬件按键（音量键翻页）
  late final FocusNode _focusNode;
  // 进入阅读器时的系统亮度（用于退出时恢复）
  double _systemBrightnessOnEnter = -1.0;
  // 上次应用到系统的亮度（避免重复调用 setScreenBrightness）
  double _lastAppliedBrightness = -2.0;
  // 上次记录的 keepScreenOn 配置（用于检测变化触发 wakelock）
  bool? _lastKeepScreenOn;
  // 上次记录的 screenBrightness 配置（用于检测变化触发亮度调节）
  double? _lastScreenBrightness;
  // 滑动翻页：pointerDown 时间，用于 _onPointerUp 判断是 tap 还是 swipe
  DateTime? _swipeStartTime;
  // 滑动翻页阈值：水平滑动 > 40px 且垂直偏移 < 60px 判为左右滑翻页
  // 垂直滑动 > 40px 且水平偏移 < 60px 判为上下滑翻页
  static const double _swipeThreshold = 40;
  static const double _swipeOrthogonalMax = 60;
  // 滑动超时：> 500ms 不算 swipe（可能是长按选文字）
  static const int _swipeTimeoutMs = 500;

  @override
  void initState() {
    super.initState();
    _currentChapterIndex = widget.resumeProgress ? 0 : widget.chapterIndex;
    _sliderValue = _currentChapterIndex.toDouble();
    _readStartTime = ReadRecordService.instance.startReading();

    _menuAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _focusNode = FocusNode(debugLabel: 'NovelReaderPage');

    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _loadBookAndChapters();
    _loadReaderContentOptions();
    _initTts();
    _checkBookmark();
    // 延迟到首帧后初始化系统交互（provider 此时已可用）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initSystemInteractions();
    });
  }

  /// 初始化系统交互：屏幕常亮 + 亮度调节 + 监听配置变化
  Future<void> _initSystemInteractions() async {
    final provider = context.read<ReaderProvider>();
    // 读取并保存进入时的系统亮度
    _systemBrightnessOnEnter = await NativeChannel.instance.getScreenBrightness();
    // await 后必须检查 mounted：dispose() 可能在 await 期间被调用，
    // 此时若继续 addListener 会导致 provider（单例 ChangeNotifier）持有
    // 已销毁 State 的 _onProviderChanged 引用，造成内存泄漏 + 反复进出累积
    if (!mounted) return;
    // 应用配置中的亮度和常亮
    _applyBrightness(provider.screenBrightness);
    _applyKeepScreenOn(provider.keepScreenOn);
    _lastKeepScreenOn = provider.keepScreenOn;
    _lastScreenBrightness = provider.screenBrightness;
    // 注册 provider 监听（配置变化时立即生效）
    provider.addListener(_onProviderChanged);
  }

  /// Provider 变化监听：检测到 keepScreenOn / screenBrightness 变化时触发副作用
  void _onProviderChanged() {
    if (!mounted) return;
    final provider = context.read<ReaderProvider>();
    if (_lastKeepScreenOn != provider.keepScreenOn) {
      _lastKeepScreenOn = provider.keepScreenOn;
      _applyKeepScreenOn(provider.keepScreenOn);
    }
    if (_lastScreenBrightness != provider.screenBrightness) {
      _lastScreenBrightness = provider.screenBrightness;
      _applyBrightness(provider.screenBrightness);
    }
  }

  /// 应用屏幕常亮配置
  Future<void> _applyKeepScreenOn(bool enabled) async {
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (error) {
      debugPrint('[NovelReader] wakelock 切换失败: $error');
    }
  }

  /// 应用亮度配置
  /// [value] -1 表示跟随系统（恢复进入时的亮度）；0.0-1.0 表示应用层亮度
  Future<void> _applyBrightness(double value) async {
    if (value == _lastAppliedBrightness) return;
    _lastAppliedBrightness = value;
    try {
      if (value < 0) {
        // 跟随系统：恢复进入时记录的系统亮度
        await NativeChannel.instance.setScreenBrightness(_systemBrightnessOnEnter);
      } else {
        await NativeChannel.instance.setScreenBrightness(value.clamp(0.0, 1.0));
      }
    } catch (error) {
      debugPrint('[NovelReader] 设置屏幕亮度失败: $error');
    }
  }

  /// 处理硬件按键：音量键翻页
  /// 仅在 enableVolumeKeyPage 启用时生效；TTS 播放时受 volumeKeyPageOnTts 控制
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final provider = context.read<ReaderProvider>();
    if (!provider.enableVolumeKeyPage) return KeyEventResult.ignored;
    // TTS 播放时若未启用 volumeKeyPageOnTts 则不响应
    if (provider.isTtsPlaying && !provider.volumeKeyPageOnTts) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.audioVolumeUp) {
      _previousPage();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.audioVolumeDown) {
      _nextPage();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }


  @override
  void dispose() {
    // 翻页中退出：唤醒等待的 completer，避免 _waitForWebViewFrame 等超时
    // （问题 10：dispose 中未处理 _pageRenderedCompleter 会有 ~150ms 悬挂）
    final c = _pageRenderedCompleter;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
    _pageRenderedCompleter = null;

    final provider = context.read<ReaderProvider>();
    provider.removeListener(_onProviderChanged);
    _progressSaveTimer?.cancel();
    _webviewReloadTimeoutTimer?.cancel(); // 问题 9 修复
    _clockTimer?.cancel();
    _autoScrollTimer?.cancel();
    _scrollProgressNotifier.dispose();
    _menuAnimController.dispose();
    _focusNode.dispose();
    _readerWebViewController.detach();
    provider.disposeTts();
    // 恢复系统亮度（应用层亮度是全局的，退出阅读器必须还原）
    // 不等待 Future，dispose 中无法 await
    NativeChannel.instance.setScreenBrightness(_systemBrightnessOnEnter);
    // 禁用屏幕常亮
    WakelockPlus.disable();
    super.dispose();
  }

  /// 保存阅读记录
  void _saveReadRecord() {
    if (_book != null && _readStartTime > 0) {
      debugPrint('[NovelReader] Saving read record: ${_book!.name}');
      ReadRecordService.instance.endReading(
        bookUrl: _book!.bookUrl,
        bookName: _book!.name,
        bookAuthor: _book!.author,
        coverUrl: _book!.coverUrl,
        startTime: _readStartTime,
        chapterIndex: _currentChapterIndex,
        chapterTitle: _chapterTitle,
      );
    }
  }

  Future<void> _initTts() async {
    final provider = context.read<ReaderProvider>();
    await provider.initTts(
      rate: 0.5,
      onStateChanged: () {
        if (mounted) setState(() {});
      },
      onParagraphChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _checkBookmark() async {
    if (_book == null) return;
    final provider = context.read<ReaderProvider>();
    await provider.loadBookmarks(_book!.bookUrl);
    _hasBookmark = await provider.hasBookmarkForChapter(
      _book!.bookUrl,
      _currentChapterIndex,
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggleBookmark() async {
    if (_book == null) return;
    final provider = context.read<ReaderProvider>();
    if (_hasBookmark) {
      // 移除书签
      final bookmarks = provider.bookmarks
          .where(
            (b) =>
                b.bookUrl == _book!.bookUrl &&
                b.chapterIndex == _currentChapterIndex,
          )
          .toList();
      for (final b in bookmarks) {
        await provider.removeBookmark(_book!.bookUrl, b.id);
      }
    } else {
      // 添加书签
      await provider.addBookmark(
        bookUrl: _book!.bookUrl,
        chapterIndex: _currentChapterIndex,
        chapterTitle: _chapterTitle,
        content: _content.length > 100 ? _content.substring(0, 100) : _content,
      );
    }
    _hasBookmark = !_hasBookmark;
    if (mounted) setState(() {});
  }

  void _showEnhancedSettings() {
    final provider = context.read<ReaderProvider>();
    _hideMenu();
    _showInterfaceSettingsDialog(provider);
  }

  void _startTts() {
    final provider = context.read<ReaderProvider>();
    provider.setTtsChapterContent(
      ChineseConverter.convert(
        _processedContent(_content),
        provider.chineseConverterType,
      ),
    );
    provider.startTts();
  }

  Future<void> _loadReaderContentOptions() async {
    final preferences = await SharedPreferences.getInstance();
    final enabled = preferences.getBool('reader_replace_rules_enabled') ?? true;
    final rules = <ReplaceRule>[];
    final data = StorageService.instance.getCachedData('replace_rules');
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              rules.add(ReplaceRule.fromJson(Map<String, dynamic>.from(item)));
            }
          }
        }
      } catch (error) {
        debugPrint('[NovelReader] 读取替换规则失败: $error');
      }
    }
    if (!mounted) return;
    setState(() {
      _useReplaceRules = enabled;
      _replaceRules = rules;
    });
    _refreshProcessedContent();
  }

  String _processedContent(String content) {
    // 缓存命中检查：内容相同且规则配置相同则直接返回缓存结果
    if (content == _processedCacheInput &&
        _useReplaceRules == _processedCacheUseRules &&
        _replaceRules.length == _processedCacheRules.length &&
        _rulesEqual(_replaceRules, _processedCacheRules)) {
      return _processedCacheOutput;
    }
    var result = content;
    if (_useReplaceRules) {
      for (final rule in _replaceRules.where((item) => item.isEnabled)) {
        if (rule.pattern.isEmpty) continue;
        try {
          if (rule.isRegex) {
            final expression = RegExp(rule.pattern, multiLine: true);
            result = result.replaceAllMapped(
              expression,
              (match) => _expandReplacement(rule.replacement, match),
            );
          } else {
            result = result.replaceAll(rule.pattern, rule.replacement);
          }
        } catch (error) {
          debugPrint('[NovelReader] 跳过无效替换规则 ${rule.name}: $error');
        }
      }
    }
    // 更新缓存
    _processedCacheInput = content;
    _processedCacheUseRules = _useReplaceRules;
    _processedCacheRules = List.unmodifiable(_replaceRules);
    _processedCacheOutput = result;
    return result;
  }

  static bool _rulesEqual(List<ReplaceRule> a, List<ReplaceRule> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].pattern != b[i].pattern ||
          a[i].replacement != b[i].replacement ||
          a[i].isRegex != b[i].isRegex ||
          a[i].isEnabled != b[i].isEnabled) {
        return false;
      }
    }
    return true;
  }

  String _expandReplacement(String replacement, Match match) {
    return replacement.replaceAllMapped(RegExp(r'\$(\d+)|\\(\d+)'), (token) {
      final index = int.tryParse(token.group(1) ?? token.group(2) ?? '');
      if (index == null || index > match.groupCount) return token.group(0)!;
      return match.group(index) ?? '';
    });
  }

  void _refreshProcessedContent() {
    if (!mounted || _content.isEmpty) return;
    final provider = context.read<ReaderProvider>();
    provider.setTtsChapterContent(
      ChineseConverter.convert(
        _processedContent(_content),
        provider.chineseConverterType,
      ),
    );
    _repaginatePreservingPosition();
    setState(() {});
  }

  Future<void> _setUseReplaceRules(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('reader_replace_rules_enabled', enabled);
    if (!mounted) return;
    setState(() => _useReplaceRules = enabled);
    _refreshProcessedContent();
  }

  Future<void> _openReplaceRules() async {
    _hideMenu();
    await Navigator.pushNamed(context, AppRoutes.replaceRule);
    if (mounted) await _loadReaderContentOptions();
  }

  void _toggleAutoScroll() {
    if (_isAutoScroll) {
      _stopAutoScroll();
      return;
    }
    setState(() => _isAutoScroll = true);
    _hideMenu();
    _startAutoScrollTimer();
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    if (mounted && _isAutoScroll) setState(() => _isAutoScroll = false);
  }

  void _startAutoScrollTimer() {
    _autoScrollTimer?.cancel();
    final provider = context.read<ReaderProvider>();
    final configured = provider.autoPageIntervalSeconds;
    final seconds = configured > 0
        ? configured
        : (12 - provider.autoScrollSpeed ~/ 10).clamp(2, 11);
    _autoScrollTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (!mounted || !_isAutoScroll || _isLoading) return;
      final atBookEnd =
          _webviewCurrentPage >= _webviewPageCount - 1 &&
          _nextReadableChapterIndex(_currentChapterIndex) == null;
      if (atBookEnd) {
        _stopAutoScroll();
      } else {
        _nextPage();
      }
    });
  }

  Future<void> _showChapterSearch() async {
    _hideMenu();
    final controller = TextEditingController();
    var query = '';
    var offsets = <int>[];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final provider = context.read<ReaderProvider>();
          final displayContent = ChineseConverter.convert(
            _processedContent(_content),
            provider.chineseConverterType,
          );
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                top: 12,
                right: 16,
                bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
              ),
              child: SizedBox(
                height: min(MediaQuery.sizeOf(context).height * 0.7, 560),
                child: Column(
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: '搜索本章内容',
                        prefixIcon: const Icon(Icons.search),
                        suffixText: query.isEmpty
                            ? null
                            : '${offsets.length} 处',
                      ),
                      onChanged: (value) {
                        query = value;
                        offsets = [];
                        if (query.isNotEmpty) {
                          var start = 0;
                          while (start < displayContent.length) {
                            final offset = displayContent.indexOf(query, start);
                            if (offset < 0) break;
                            offsets.add(offset);
                            start = offset + max(query.length, 1);
                          }
                        }
                        setSheetState(() {});
                      },
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: query.isEmpty
                          ? const Center(child: Text('输入关键词搜索当前章节'))
                          : offsets.isEmpty
                          ? const Center(child: Text('未找到匹配内容'))
                          : ListView.builder(
                              itemCount: offsets.length,
                              itemBuilder: (context, index) {
                                final offset = offsets[index];
                                final start = max(0, offset - 24);
                                final end = min(
                                  displayContent.length,
                                  offset + query.length + 36,
                                );
                                final snippet = displayContent
                                    .substring(start, end)
                                    .replaceAll(RegExp(r'\s+'), ' ');
                                return ListTile(
                                  leading: CircleAvatar(
                                    child: Text('${index + 1}'),
                                  ),
                                  title: Text(
                                    snippet,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    Navigator.pop(sheetContext);
                                    _jumpToSearchMatch(
                                      query,
                                      index,
                                      offset,
                                      displayContent.length,
                                    );
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    controller.dispose();
  }

  void _jumpToSearchMatch(
    String query,
    int occurrence,
    int offset,
    int contentLength,
  ) {
    // WebView 渲染：用进度比例跳转
    // 滚动模式：setScrollProgress
    // 分页模式：按比例计算目标页码后 jumpToPage
    final provider = context.read<ReaderProvider>();
    final fraction = contentLength == 0 ? 0.0 : (offset / contentLength).clamp(0.0, 1.0);
    if (_isScrollLikeMode(provider)) {
      _readerWebViewController.setScrollProgress(fraction);
      return;
    }
    final targetPage = (fraction * (_webviewPageCount - 1))
        .round()
        .clamp(0, max(_webviewPageCount - 1, 0)).toInt();
    _readerWebViewController.jumpToPage(targetPage, animate: false);
  }

  Future<void> _editChapterContent() async {
    _hideMenu();
    final controller = TextEditingController(text: _content);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑正文'),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 12,
            maxLines: 20,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '编辑当前章节正文',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) {
      controller.dispose();
      return;
    }
    final edited = controller.text;
    controller.dispose();
    setState(() => _content = edited);
    _refreshProcessedContent();

    final book = _book;
    final chapter = _currentChapterIndex < _chapters.length
        ? _chapters[_currentChapterIndex]
        : null;
    if (book != null &&
        chapter != null &&
        book.originType == BookOriginType.online) {
      ChapterPrefetchService.instance.clearBook(book.bookUrl);
      await ChapterCacheService.instance.saveChapterContent(
        book,
        chapter,
        edited,
      );
      if (mounted) _showMessage('正文已保存到章节缓存');
    } else {
      _showMessage('正文已在本次阅读中更新');
    }
  }

  Future<void> _refreshChapterContent() async {
    final book = _book;
    final chapter = _currentChapterIndex < _chapters.length
        ? _chapters[_currentChapterIndex]
        : null;
    if (book != null &&
        chapter != null &&
        book.originType == BookOriginType.online) {
      ChapterPrefetchService.instance.clearBook(book.bookUrl);
      await ChapterCacheService.instance.deleteChapterCache(book, chapter);
    }
    if (mounted) await _loadChapterContent();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }

  void _stopTts() {
    context.read<ReaderProvider>().stopTts();
  }

  void _pauseTts() {
    context.read<ReaderProvider>().pauseTts();
  }

  Future<void> _resumeTts() async {
    await context.read<ReaderProvider>().resumeTts();
  }

  void _nextTtsParagraph() {
    context.read<ReaderProvider>().nextTtsParagraph();
  }

  void _prevTtsParagraph() {
    context.read<ReaderProvider>().prevTtsParagraph();
  }

  void _cycleTtsSpeed() {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final currentIndex = speeds.indexOf(_ttsSpeed);
    final nextIndex = (currentIndex + 1) % speeds.length;
    _ttsSpeed = speeds[nextIndex];
    context.read<ReaderProvider>().setTtsRate(_ttsSpeed);
    setState(() {});
  }

  Future<void> _loadBookAndChapters() async {
    try {
      final bookData = StorageService.instance.getBook(widget.bookUrl);
      _book = bookData != null ? Book.fromJson(bookData) : widget.initialBook;
      if (_book != null) {
        _dataProvider = createBookDataProvider(_book!);
        _chapters = await _dataProvider!.getChapterList(_book!);
        _totalChapters = _chapters.length;
        if (_totalChapters > 0) {
          final initialIndex = widget.resumeProgress
              ? _book!.durChapterIndex
              : widget.chapterIndex;
          _currentChapterIndex = _readableChapterIndex(initialIndex);
          _initialChapterPos = widget.resumeProgress ? _book!.durChapterPos : 0;
          _restoreInitialPosition =
              widget.resumeProgress && _initialChapterPos > 0;
          _sliderValue = _currentChapterIndex.toDouble();
        }
        // 加载书源信息
        if (_book!.originType == BookOriginType.online &&
            _book!.sourceUrl != null) {
          final sourceData = StorageService.instance.getBookSource(
            _book!.sourceUrl!,
          );
          if (sourceData != null) {
            _bookSource = BookSource.fromJson(sourceData);
          }
        }
      }
      await _loadChapterContent();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _content = '加载失败：$e';
      });
    }
  }

  Future<void> _loadChapterContent() async {
    if (_book == null || _dataProvider == null || _chapters.isEmpty) {
      _isChangingChapterByPageView = false;
      setState(() {
        _isLoading = false;
        _content = '无法加载内容';
      });
      return;
    }

    // 章节切换时主动隐藏文字选区菜单（选区会随 WebView reload 失效，
    // 不主动隐藏菜单会停留在旧选区位置上看起来很怪）
    _readerWebViewController.hideSelectionMenu();

    final loadToken = ++_chapterLoadToken;
    final chapterIndex = _currentChapterIndex;
    // 同步捕获位置标志位并清空成员字段，防止被新 load 抢占后串到下一章
    final pendingToLast = _pendingInitialPageToEnd;
    final restoreInitial = _restoreInitialPosition;
    _pendingInitialPageToEnd = false;
    _restoreInitialPosition = false;
    // 滚动模式无缝衔接：章节切换时重置已加载到第几章
    // WebView 会因 _content 变化 reload，旧追加内容随 reload 清空
    _scrollChapterMax = chapterIndex;
    _isAppendingChapter = false;
    setState(() {
      _isLoading = true;
      _sliderValue = _currentChapterIndex.toDouble();
    });

    final chapter = chapterIndex < _chapters.length
        ? _chapters[chapterIndex]
        : null;

    if (chapter == null || chapter.isVolume) {
      _isChangingChapterByPageView = false;
      setState(() {
        _isLoading = false;
        _content = '章节不存在';
      });
      return;
    }

    try {
      // 1. 优先从预取内存缓存读取（瞬时返回，跳过文件 I/O）
      String? content;
      if (_book!.originType == BookOriginType.online && chapter.url != null) {
        final url = chapter.url!;
        content = ChapterPrefetchService.instance.getCachedContent(
          _book!.bookUrl,
          url,
        );
      }

      // 2. 内存未命中则从文件缓存读取
      if ((content == null || content.isEmpty) &&
          _book!.originType == BookOriginType.online) {
        content = await ChapterCacheService.instance.readChapterContent(
          _book!,
          chapter,
        );
      }

      // 3. 缓存没有则从网络获取
      if (content == null || content.isEmpty) {
        content = await _dataProvider!.getContent(
          _book!,
          chapter,
          allChapters: _chapters,
        );
        // 保存到缓存
        if (content != null &&
            content.isNotEmpty &&
            _book!.originType == BookOriginType.online) {
          unawaited(
            ChapterCacheService.instance.saveChapterContent(
              _book!,
              chapter,
              content,
            ),
          );
        }
      }

      if (mounted &&
          loadToken == _chapterLoadToken &&
          chapterIndex == _currentChapterIndex) {
        setState(() {
          _chapterTitle = chapter.title;
          _chapterUrl = chapter.url?.split(',{').first.trim();
          _content = content ?? '内容加载失败';
          _isLoading = false;
        });

        // 章节切换时若 TTS 正在播放，先停止再替换内容，避免 paragraphIndex 越界
        final readerProvider = context.read<ReaderProvider>();
        if (readerProvider.isTtsPlaying) {
          readerProvider.stopTts();
        }
        readerProvider.setTtsChapterContent(
          ChineseConverter.convert(
            _processedContent(_content),
            readerProvider.chineseConverterType,
          ),
        );

        // 检查书签
        _checkBookmark();

        final restorePos = pendingToLast
            ? 1 << 30
            : (restoreInitial ? _initialChapterPos : 0);

        // WebView 渲染：不再调用 _repaginate（CSS column 原生分页）
        // 设置待恢复页码，等 WebView 加载完成 + onPageCountReady 后 jumpToPage
        _webviewReloading = true;
        _startWebviewReloadTimeout(); // 问题 9 修复
        _webviewReady = false;
        _webviewCurrentPage = 0;
        _webviewPageCount = 1;
        _pendingWebviewFraction = -1.0; // 章节切换时清除 fraction
        if (restorePos > 0) {
          // 用大数表示「跳到最后一页」，onPageCountReady 时会 clamp
          _pendingWebviewInitialPage =
              pendingToLast ? (1 << 30) : restorePos;
        } else {
          _pendingWebviewInitialPage = 0;
        }
        // 触发 WebView 重新加载（didUpdateWidget 检测 content 变化）
        if (mounted) setState(() {});

        // 用 clamp 后的真实位置保存到数据库
        // （_onWebviewPageCountReady 会再次保存校正后的位置）
        final actualPos = restorePos > 0 ? restorePos.clamp(0, 1 << 30) : 0;
        unawaited(_saveCurrentProgress(chapter: chapter, pos: actualPos));

        // 后台预取后续 N 章（Phase 3 流水线化：用户翻页时瞬时返回）
        if (_book!.originType == BookOriginType.online &&
            chapterIndex + 1 < _chapters.length) {
          final prefetchIndices = ChapterPrefetchService.computePrefetchIndices(
            chapterIndex,
            _chapters.length,
            5,
            isReadable: (i) =>
                !_chapters[i].isVolume && _chapters[i].url != null,
          );
          if (prefetchIndices.isNotEmpty) {
            final prefetchChs = prefetchIndices
                .map((i) => _chapters[i])
                .toList();
            unawaited(
              ChapterPrefetchService.instance.prefetchChapters(
                book: _book!,
                chapters: prefetchChs,
                provider: _dataProvider!,
                allChapters: _chapters,
              ),
            );
          }
        }
      }
    } catch (e) {
      // 旧 load 的异常必须丢弃，不能覆盖新 load 的成功结果
      if (loadToken != _chapterLoadToken) return;
      if (mounted) {
        setState(() {
          _content = '加载失败：$e';
          _chapterTitle = '加载失败';
          _isLoading = false;
          // WebView 模式：重置状态，触发 WebView 重新加载错误信息
          _webviewReady = false;
          _webviewCurrentPage = 0;
          _webviewPageCount = 1;
          _pendingWebviewInitialPage = 0;
          _pendingWebviewFraction = -1.0;
        });
      }
    } finally {
      // 仅当前 load 是最新时才释放翻页导航锁，避免被旧 load 提前释放
      if (loadToken == _chapterLoadToken) {
        _isChangingChapterByPageView = false;
      }
    }
  }

  int _readableChapterIndex(int index) {
    if (_chapters.isEmpty) return 0;
    final target = index.clamp(0, _chapters.length - 1);
    if (!_chapters[target].isVolume) return target;

    for (var i = target + 1; i < _chapters.length; i++) {
      if (!_chapters[i].isVolume) return i;
    }
    for (var i = target - 1; i >= 0; i--) {
      if (!_chapters[i].isVolume) return i;
    }
    return target;
  }

  int? _nextReadableChapterIndex(int fromIndex) {
    for (var i = fromIndex + 1; i < _chapters.length; i++) {
      if (!_chapters[i].isVolume) return i;
    }
    return null;
  }

  int? _previousReadableChapterIndex(int fromIndex) {
    for (var i = fromIndex - 1; i >= 0; i--) {
      if (!_chapters[i].isVolume) return i;
    }
    return null;
  }

  Future<void> _saveCurrentProgress({Chapter? chapter, int? pos}) async {
    if (!mounted) return;
    final book = _book;
    if (book == null) return;
    final chapterTitle = chapter?.title ?? _chapterTitle;
    final provider = context.read<ReaderProvider>();
    int chapterPos;
    if (pos != null) {
      chapterPos = pos;
    } else if (_isScrollLikeMode(provider)) {
      // 滚动模式：从 WebView 获取真实像素偏移
      chapterPos = await _readerWebViewController.getScrollOffset();
    } else {
      chapterPos = _currentChapterPos();
    }

    _book = book.copyWith(
      durChapterIndex: _currentChapterIndex,
      durChapterTitle: chapterTitle,
      durChapterPos: chapterPos,
      durChapterTime: DateTime.now(),
    );

    if (!mounted) return;
    final bookshelfProvider = context.read<BookshelfProvider>();
    await bookshelfProvider.updateBookProgress(
      book.bookUrl,
      durChapterIndex: _currentChapterIndex,
      durChapterTitle: chapterTitle,
      durChapterPos: chapterPos,
    );
  }

  int _currentChapterPos() {
    // WebView 渲染：用 WebView 当前页码（滚动模式也用进度近似页码）
    return _webviewCurrentPage;
  }

  // ==================== Pagination ====================
  //
  // WebView 渲染模式下，分页由 CSS column-width 原生完成，无需 Dart 侧测量。
  // _repaginatePreservingPosition 作为样式变化后的触发点，
  // 通过 setState 通知 ReaderWebView.didUpdateWidget 检测样式变化并重新加载 HTML。

  void _repaginatePreservingPosition() {
    // 唤醒正在等待 onPageChanged 的翻页流程：
    // 样式变化会触发 WebView reload，reload 期间 _webviewReloading=true 让
    // _onWebviewPageChanged 早 return，永远不会 complete 旧 completer。
    // 不唤醒会导致 _waitForWebViewFrame 等 120ms 超时（白白阻塞翻页时序）。
    final c = _pageRenderedCompleter;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
    _pageRenderedCompleter = null;

    // WebView 模式下：记录当前页码比例，等 WebView 重新加载后按比例恢复
    _pendingWebviewFraction = _webviewPageCount > 1
        ? _webviewCurrentPage / (_webviewPageCount - 1)
        : 0.0;
    _pendingWebviewInitialPage = 0;
    _webviewReloading = true;
    _startWebviewReloadTimeout(); // 问题 9 修复
    _webviewReady = false;
    if (mounted) setState(() {});
  }

  // ==================== Tap Zone ====================

  void _handleTap(TapUpDetails details) {
    // 菜单显示时点击任意区域（含 overlay 外部）都关闭菜单，符合「点击外部关闭」的交互预期
    if (_showMenu) {
      _hideMenu();
      return;
    }
    if (_isLoading) return;
    final provider = context.read<ReaderProvider>();
    final size = MediaQuery.of(context).size;
    final x = details.globalPosition.dx;
    final y = details.globalPosition.dy;

    final col = (x / (size.width / 3)).clamp(0, 2).toInt();
    final row = (y / (size.height / 3)).clamp(0, 2).toInt();

    final actions = provider.tapZoneActions;
    if (row >= actions.length || col >= actions[row].length) return;

    final action = actions[row][col];
    _executeTapAction(action);
  }

  /// 用 Listener 在 hit-test 阶段拦截 pointerUp，转成 tap 事件。
  ///
  /// 关键修复：原来用 GestureDetector(onTapUp) 包裹 SelectionArea，
  /// 但 SelectionArea 内部的 Text.rich 会消费 tap 事件用于光标定位/选中，
  /// 导致外层 GestureDetector 收不到 onTapUp —— 点击屏幕中央无法召唤菜单。
  /// 改用 Listener + _lastDownEvent 自己判定 tap，不依赖手势系统，
  /// 这样既能触发菜单，又不影响 SelectionArea 的长按文字选中（长按是独立手势）。
  PointerDownEvent? _lastDownEvent;

  void _onPointerUp(PointerUpEvent event) {
    final down = _lastDownEvent;
    _lastDownEvent = null;
    if (down == null) return;
    if (event.buttons != kPrimaryButton && event.buttons != 0) return;

    // 分页模式（slide/cover/simulation/none）：翻页和 tap 完全交给 ReaderPageView 处理
    // 外层 Listener 只保留菜单显示时的「点击外部关闭」逻辑
    final provider = context.read<ReaderProvider>();
    final isPagedMode = !_isScrollLikeMode(provider);
    if (isPagedMode && !_showMenu) {
      return;
    }

    final dx = event.position.dx - down.position.dx;
    final dy = event.position.dy - down.position.dy;
    final absDx = dx.abs();
    final absDy = dy.abs();
    // 用 DateTime.now() 记录的按下时间，避免 PointerEvent.timeStamp 语义混淆
    final elapsed = _swipeStartTime != null
        ? DateTime.now().difference(_swipeStartTime!).inMilliseconds
        : 0;

    // 滑动翻页判定（仅滚动模式生效，分页模式由 ReaderPageView 处理）：
    // - 时长 < 500ms（长按选文字不算）
    // - 主轴位移 > 40px
    // - 副轴位移 < 60px（避免误识别对角线滑动）
    if (!isPagedMode && elapsed < _swipeTimeoutMs) {
      if (absDx >= _swipeThreshold && absDy < _swipeOrthogonalMax) {
        // 水平滑动：右滑=上一页，左滑=下一页
        if (dx > 0) {
          _previousPage();
        } else {
          _nextPage();
        }
        return;
      }
      if (absDy >= _swipeThreshold && absDx < _swipeOrthogonalMax) {
        // 垂直滑动：下滑=上一页，上滑=下一页
        if (dy > 0) {
          _previousPage();
        } else {
          _nextPage();
        }
        return;
      }
    }

    // 简单 tap 判定：移动距离 < kTouchSlop
    if (dx * dx + dy * dy > 18 * 18) return;
    _handleTap(TapUpDetails(
      kind: event.kind,
      globalPosition: event.position,
      localPosition: event.localPosition,
    ));
  }

  void _onPointerDown(PointerDownEvent event) {
    _lastDownEvent = event;
    _swipeStartTime = DateTime.now();
  }

  void _executeTapAction(TapZoneAction action) {
    switch (action) {
      case TapZoneAction.showMenu:
        _toggleMenu();
        break;
      case TapZoneAction.previousPage:
        _previousPage();
        break;
      case TapZoneAction.nextPage:
        _nextPage();
        break;
      case TapZoneAction.previousChapter:
        _previousChapter();
        break;
      case TapZoneAction.nextChapter:
        _nextChapter();
        break;
      case TapZoneAction.none:
        break;
    }
  }

  void _previousPage() {
    final provider = context.read<ReaderProvider>();
    if (_isScrollLikeMode(provider)) {
      // 滚动模式：按视口高度向上翻
      if (!_webviewReady) return;
      _readerWebViewController.scrollByViewport(-1).then((progress) {
        if (progress < 0) {
          // 已到顶，切换上一章（从末页开始）
          _previousChapter(toLastPage: true);
        }
      });
    } else {
      // 分页模式：通过 JS jumpToPage 翻页
      if (!_webviewReady) return;
      if (_webviewCurrentPage > 0) {
        _readerWebViewController.jumpToPage(_webviewCurrentPage - 1);
      } else {
        _previousChapter(toLastPage: true);
      }
    }
  }

  void _nextPage() {
    final provider = context.read<ReaderProvider>();
    if (_isScrollLikeMode(provider)) {
      // 滚动模式：按视口高度向下翻
      if (!_webviewReady) return;
      _readerWebViewController.scrollByViewport(1).then((progress) {
        if (progress < 0) {
          // 已到底，切换下一章
          _nextChapter();
        }
      });
    } else {
      // 分页模式
      if (!_webviewReady) return;
      if (_webviewCurrentPage < _webviewPageCount - 1) {
        _readerWebViewController.jumpToPage(_webviewCurrentPage + 1);
      } else {
        _nextChapter();
      }
    }
  }

  void _previousChapter({bool toLastPage = false}) {
    final previousIndex = _previousReadableChapterIndex(_currentChapterIndex);
    if (previousIndex != null) {
      _pendingInitialPageToEnd = toLastPage;
      setState(() {
        _currentChapterIndex = previousIndex;
      });
      _loadChapterContent();
    } else {
      // 没有上一章时还原所有翻页锁状态（含 _isLoading），
      // 否则 _onPageChanged 设置的 _isLoading=true 永远不会被清空，UI 卡在 loading
      if (_isChangingChapterByPageView) {
        _isChangingChapterByPageView = false;
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _nextChapter() {
    final nextIndex = _nextReadableChapterIndex(_currentChapterIndex);
    if (nextIndex != null) {
      setState(() {
        _currentChapterIndex = nextIndex;
      });
      _loadChapterContent();
    } else {
      // 没有下一章时还原所有翻页锁状态（含 _isLoading）
      if (_isChangingChapterByPageView) {
        _isChangingChapterByPageView = false;
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // ==================== 滚动模式无缝衔接 ====================
  // 滚动模式（PageMode.scroll）下，滚动到接近底部时自动加载下一章并追加到
  // WebView DOM，保留用户当前滚动位置，无需点击翻页按钮即可连续阅读。
  //
  // 数据流：
  // 1. JS 端 scroll listener 检测距底 < 1.5 视口高度 → callHandler('onScrollNearEnd')
  // 2. ReaderWebViewController 转发到 callbacks.onScrollNearEnd
  // 3. _onScrollNearEnd 检查是否有下一章 → _appendNextChapter 异步加载
  // 4. _appendNextChapter 拉取章节内容 → 简繁转换 + 替换规则 + 生成段落 HTML
  //    → controller.appendChapter 追加到 DOM（不触发整页 reload）
  // 5. _scrollChapterMax 更新为 nextIndex，下次接近底部时继续加载下一章
  //
  // 章节切换（_loadChapterContent）会重置 _scrollChapterMax = _currentChapterIndex，
  // 同时 _content 变化触发 WebView reload，旧追加内容随 reload 清空。

  /// 滚动接近底部时触发：加载下一章并追加到 WebView DOM
  void _onScrollNearEnd() {
    if (!mounted) return;
    if (_isAppendingChapter) return; // 防重入：避免高频触发重复加载
    if (_book == null || _dataProvider == null || _chapters.isEmpty) return;

    final nextIndex = _nextReadableChapterIndex(_scrollChapterMax);
    if (nextIndex == null) return; // 没有下一章，JS 端 nearEndNotified 会保持 true 避免重复

    _isAppendingChapter = true;
    _appendNextChapter(nextIndex);
  }

  /// 滚动模式：当前可见章节变化（IntersectionObserver 触发）
  ///
  /// JS 端监听 [data-chapter-index] 元素，进入屏幕中部 10% 区域时回调。
  /// Dart 侧更新 _currentChapterIndex / _chapterTitle / _sliderValue，
  /// 让 UI 章节标题、进度条实时跟随用户滚动更新。
  ///
  /// 注意：
  /// - ReaderWebView.didUpdateWidget 已特判滚动模式下 title 变化不触发 reload，
  ///   所以这里 setState 更新 _chapterTitle 不会让 WebView 重新加载
  /// - _saveCurrentProgress 用 _currentChapterIndex 保存章节，自动联动
  /// - 不主动调 _scheduleProgressSave，由 _onWebviewPageChanged 的 200ms 防抖处理
  ///   （IntersectionObserver 触发频率低，但 _onWebviewPageChanged 高频触发）
  void _onChapterVisible(int chapterIndex) {
    if (!mounted) return;
    if (_book == null) return;
    if (chapterIndex == _currentChapterIndex) return;
    if (chapterIndex < 0 || chapterIndex >= _chapters.length) return;

    final chapter = _chapters[chapterIndex];
    setState(() {
      _currentChapterIndex = chapterIndex;
      _chapterTitle = chapter.title;
      _sliderValue = chapterIndex.toDouble();
    });
  }

  /// 异步加载下一章内容并追加到 WebView DOM
  ///
  /// 不走 _loadChapterContent（会 setState(_isLoading=true) + 触发 _content 变化
  /// 导致 WebView reload 丢失滚动位置）。而是直接拉取内容、生成段落 HTML、
  /// 调用 controller.appendChapter 追加到现有 DOM 末尾。
  Future<void> _appendNextChapter(int chapterIndex) async {
    final chapter =
        chapterIndex < _chapters.length ? _chapters[chapterIndex] : null;
    if (chapter == null || chapter.isVolume) {
      _isAppendingChapter = false;
      return;
    }

    // 在 await 之前先取 provider，避免异步间隙后访问 BuildContext（info 警告）
    final provider = context.read<ReaderProvider>();
    final book = _book!;
    final dataProvider = _dataProvider!;

    try {
      // 1. 优先从预取内存缓存读取（瞬时返回，跳过文件 I/O）
      String? content;
      if (book.originType == BookOriginType.online && chapter.url != null) {
        content = ChapterPrefetchService.instance.getCachedContent(
          book.bookUrl,
          chapter.url!,
        );
      }
      // 2. 内存未命中则从文件缓存读取
      if ((content == null || content.isEmpty) &&
          book.originType == BookOriginType.online) {
        content = await ChapterCacheService.instance.readChapterContent(
          book,
          chapter,
        );
      }
      // 3. 缓存没有则从网络获取
      if (content == null || content.isEmpty) {
        content = await dataProvider.getContent(
          book,
          chapter,
          allChapters: _chapters,
        );
        // 保存到缓存
        if (content != null &&
            content.isNotEmpty &&
            book.originType == BookOriginType.online) {
          unawaited(
            ChapterCacheService.instance.saveChapterContent(
              book,
              chapter,
              content,
            ),
          );
        }
      }
      if (content == null || content.isEmpty) {
        debugPrint(
          '[NovelReader] _appendNextChapter 内容为空: index=$chapterIndex',
        );
        return;
      }

      // 4. 简繁转换 + 替换规则
      final displayContent = ChineseConverter.convert(
        content,
        provider.chineseConverterType,
      );
      final displayTitle = ChineseConverter.convert(
        chapter.title,
        provider.chineseConverterType,
      );
      final processedContent = _processedContent(displayContent);

      // 5. 生成段落 HTML（用 ReaderHtmlTemplate 的 public 方法）
      final paragraphsHtml = ReaderHtmlTemplate.buildParagraphsHtml(
        processedContent,
        provider,
      );

      // 6. 调用 JS 追加到 DOM（不触发 reload）
      //    传入 chapterIndex 让 JS 端给 <h1> 加 data-chapter-index 属性，
      //    供 IntersectionObserver 监测当前可见章节
      if (!mounted) return;
      await _readerWebViewController.appendChapter(
        displayTitle,
        paragraphsHtml,
        chapterIndex,
      );

      // Phase 3.2：追加后恢复该章节的持久化高亮
      // - 章节内容已写入 DOM，此时调用 restoreHighlights 让 JS 端按 selectedText
      //   匹配位置并包裹 .sel-hl，使重启后高亮自动恢复
      await _restoreHighlights(chapterIndex);

      // 7. 更新已加载章节索引
      _scrollChapterMax = chapterIndex;
    } catch (e) {
      debugPrint('[NovelReader] _appendNextChapter 失败: $e');
    } finally {
      _isAppendingChapter = false;
    }
  }

  /// Phase 3.2：恢复某章节的所有持久化高亮
  ///
  /// 章节加载完成后调用：从 StorageService 取该章节的高亮列表，
  /// 通过 JS 端 restoreHighlights 重新绘制 .sel-hl 视觉标记。
  /// - 跨进程重启后高亮自动恢复
  /// - JS 端按 data-highlight-id 跳过已恢复的，避免重复
  Future<void> _restoreHighlights(int chapterIndex) async {
    final book = _book;
    if (book == null) return;
    try {
      final list = StorageService.instance.getChapterHighlights(
        book.bookUrl,
        chapterIndex,
      );
      if (list.isEmpty) return;
      await _readerWebViewController.restoreHighlights(list);
    } catch (e) {
      debugPrint('[NovelReader] 恢复高亮失败: $e');
    }
  }

  /// Phase 3.2：把当前选区高亮持久化到 StorageService
  ///
  /// 简化方案：用 selectedText 作为唯一标识（重复文本可能误匹配，实际场景可接受）。
  /// - startIndex/endIndex 暂用 0/length（不依赖偏移，JS 端用文本匹配）
  /// - id 用 bookUrl + 时间戳保证唯一
  Future<void> _persistHighlight({
    required String text,
    required int colorIndex,
    required int styleIndex,
    String? note,
  }) async {
    final book = _book;
    if (book == null) return;
    final highlight = Highlight(
      id: '${book.bookUrl}_${DateTime.now().millisecondsSinceEpoch}',
      bookUrl: book.bookUrl,
      chapterIndex: _currentChapterIndex,
      startIndex: 0,
      endIndex: text.length,
      selectedText: text,
      style: HighlightStyle.values[styleIndex],
      color: HighlightColor.values[colorIndex],
      note: note,
      createdAt: DateTime.now(),
    );
    try {
      await StorageService.instance.saveHighlight(highlight.toJson());
    } catch (e) {
      debugPrint('[NovelReader] 保存高亮失败: $e');
    }
  }

  /// Phase 3.2：删除当前章节内匹配 text 的所有持久化高亮
  ///
  /// JS 端已通过 removeHighlightInSelection 移除视觉标记，
  /// Dart 侧同步删除 StorageService 中的记录。
  Future<void> _removeHighlightByText(String text) async {
    final book = _book;
    if (book == null) return;
    try {
      final highlights = StorageService.instance.getChapterHighlights(
        book.bookUrl,
        _currentChapterIndex,
      );
      int removedCount = 0;
      for (final h in highlights) {
        if (h['selectedText'] == text) {
          final id = h['id'] as String?;
          if (id != null) {
            await StorageService.instance.deleteHighlight(id);
            removedCount++;
          }
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(removedCount > 0 ? '已删除 $removedCount 处高亮' : '未找到匹配高亮'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      debugPrint('[NovelReader] 删除高亮失败: $e');
    }
  }

  // ==================== 文字选择菜单回调 ====================
  //
  // 配套：reader_html_template.dart 中的 #reader-selection-menu（JS 自定义
  // 浮动菜单，替代 Android 默认 ActionMode 样式不统一问题）；
  // reader_webview.dart 中 disableContextMenu:true 禁用系统菜单。
  //
  // 调用流：
  // 1. 用户长按选文字 → selectionchange → 防抖 250ms 后 showSelectionMenu
  // 2. JS 通过 callHandler('onSelectionReady', text, l, t, w, h) 通知 Dart
  // 3. 用户点击菜单项 → callHandler('onSelectionAction', action, text, l, t, w, h)
  // 4. Dart 根据 action 分发：copy / highlight / lookup / share
  // 5. 选区被清除 / 滚动 / 视口变化 → callHandler('onHideSelectionMenu')

  /// 选区稳定 250ms 后触发（菜单已由 JS 自行显示）
  ///
  /// Dart 不需要主动响应；保留此回调供未来「按选区位置/内容自动建议操作」
  /// 等智能菜单扩展用。
  void _onSelectionReady(String text, Rect rect) {
    // 预留：未来可用于联动 Dart 侧 UI（如自动建议菜单）
  }

  /// 菜单项点击分发
  ///
  /// action 取值：
  /// - 'copy' / 'highlight' / 'lookup' / 'share'（原有 4 项）
  /// - 'removeHighlight' / 'search'（Phase 3.1 新增 2 项，select 由 JS 自处理）
  void _onSelectionAction(String action, String text, Rect rect) {
    if (!mounted) return;
    switch (action) {
      case 'copy':
        _onSelectionCopy(text);
        break;
      case 'highlight':
        _showHighlightColorPicker(text, rect);
        break;
      case 'lookup':
        _onSelectionLookup(text);
        break;
      case 'share':
        _onSelectionShare(text);
        break;
      case 'removeHighlight':
        _removeHighlightByText(text);
        break;
      case 'search':
        _showSearchSheet(text);
        break;
      default:
        debugPrint('[NovelReader] unknown selection action: $action');
    }
  }

  /// 选区菜单隐藏（选区被清除 / 滚动 / 视口变化时触发）
  ///
  /// Dart 不需要主动响应；JS 已自行移除 visible class。
  void _onHideSelectionMenu() {
    // 预留：未来可用于联动关闭 Dart 侧弹出的子菜单（如颜色选择器）
  }

  // ---- copy ----
  // JS 端 onSelectionMenuItemClick('copy') 已自行用 Clipboard API 复制，
  // Dart 此处兜底（部分 WebView 可能拦截 Clipboard API）+ SnackBar 提示。
  void _onSelectionCopy(String text) {
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    final preview = text.length > 16 ? '${text.substring(0, 16)}…' : text;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制: $preview'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  // ---- lookup ----
  // 用内置浏览器（AppRoutes.internalBrowser）打开百度百科词条页，
  // 最适合中文小说查词场景；不用 url_launcher 是为了在 App 内浏览。
  void _onSelectionLookup(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final uri = Uri.parse(
      'https://baike.baidu.com/item/${Uri.encodeComponent(trimmed)}',
    );
    _hideMenu();
    Navigator.pushNamed(
      context,
      AppRoutes.internalBrowser,
      arguments: <String, dynamic>{
        'url': uri.toString(),
        'title': '查词: $trimmed',
        'sourceUrl': '',
        'sourceName': '',
      },
    );
  }

  // ---- share ----
  // 走 ShareHelper 封装，自动处理 iPad sharePositionOrigin
  void _onSelectionShare(String text) {
    if (text.isEmpty) return;
    _hideMenu();
    ShareHelper.shareText(context, text);
  }

  /// 高亮颜色 + 样式选择 BottomSheet
  ///
  /// 用户选完颜色和样式后，调 _readerWebViewController.highlightSelection
  /// 给当前选区上色。选区在 BottomSheet 弹出期间可能失效（WebView 失焦 /
  /// 用户已点击别处），失效时 SnackBar 提示重试。
  void _showHighlightColorPicker(String text, Rect rect) {
    var selectedColorIndex = 0; // 默认黄色
    var selectedStyleIndex = 0; // 默认背景色

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            const colors = <HighlightColor>[
              HighlightColor.yellow,
              HighlightColor.green,
              HighlightColor.blue,
              HighlightColor.pink,
              HighlightColor.orange,
              HighlightColor.purple,
            ];
            const styleLabels = <String>['背景色', '下划线', '删除线', '波浪线'];
            final preview = text.length > 24
                ? '${text.substring(0, 24)}…'
                : text;
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '预览: $preview',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.black54,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '颜色',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: List.generate(colors.length, (idx) {
                      final c = colors[idx];
                      final selected = selectedColorIndex == idx;
                      return GestureDetector(
                        onTap: () {
                          setSheetState(() {
                            selectedColorIndex = idx;
                          });
                        },
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: c.color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected
                                  ? Colors.black87
                                  : Colors.black12,
                              width: selected ? 2.5 : 1,
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '样式',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: List.generate(styleLabels.length, (idx) {
                      return ChoiceChip(
                        label: Text(styleLabels[idx]),
                        selected: selectedStyleIndex == idx,
                        onSelected: (_) {
                          setSheetState(() {
                            selectedStyleIndex = idx;
                          });
                        },
                      );
                    }),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: const Text('取消'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () async {
                            Navigator.pop(sheetContext);
                            final success = await _readerWebViewController
                                .highlightSelection(
                              selectedColorIndex,
                              selectedStyleIndex,
                            );
                            if (success) {
                              // Phase 3.2：持久化到 StorageService（重启后可恢复）
                              await _persistHighlight(
                                text: text,
                                colorIndex: selectedColorIndex,
                                styleIndex: selectedStyleIndex,
                              );
                            }
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  success ? '已高亮' : '选区已失效，请重试',
                                ),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          },
                          child: const Text('高亮'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Phase 3.4：全文搜索 BottomSheet
  ///
  /// - 顶部 TextField + 搜索按钮
  /// - 下方结果列表（snippet + 章节标题）
  /// - 点击结果项调用 scrollToSearchResult 跳转并高亮
  void _showSearchSheet(String initialQuery) {
    final queryController = TextEditingController(text: initialQuery);
    List<Map<String, dynamic>> results = [];
    var isSearching = false;

    Future<void> doSearch(StateSetter setSheetState) async {
      final q = queryController.text.trim();
      if (q.isEmpty) return;
      setSheetState(() => isSearching = true);
      try {
        final json = await _readerWebViewController.searchText(q);
        final list = jsonDecode(json) as List<dynamic>;
        setSheetState(() {
          results = list.cast<Map<String, dynamic>>();
          isSearching = false;
        });
      } catch (e) {
        debugPrint('[NovelReader] 搜索失败: $e');
        setSheetState(() => isSearching = false);
      }
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16, 4, 16, 16 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: queryController,
                          autofocus: true,
                          decoration: const InputDecoration(
                            hintText: '搜索内容...',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          onSubmitted: (_) => doSearch(setSheetState),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: isSearching ? null : () => doSearch(setSheetState),
                        icon: const Icon(Icons.search),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (isSearching)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else if (results.isNotEmpty)
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '找到 ${results.length} 处结果',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Flexible(
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: results.length,
                              itemBuilder: (ctx, idx) {
                                final r = results[idx];
                                final snippet = r['snippet']?.toString() ?? '';
                                final chapterIdx =
                                    r['chapterIndex'] as int? ?? -1;
                                final chapterTitle =
                                    (chapterIdx >= 0 && chapterIdx < _chapters.length)
                                        ? _chapters[chapterIdx].title
                                        : '当前章节';
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    snippet,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    chapterTitle,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  onTap: () async {
                                    await _readerWebViewController
                                        .scrollToSearchResult(idx);
                                    if (sheetContext.mounted) {
                                      Navigator.pop(sheetContext);
                                    }
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (initialQuery.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        '点击搜索按钮开始查找',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _toggleMenu() {
    setState(() {
      _showMenu = !_showMenu;
    });
    if (_showMenu) {
      _menuAnimController.forward();
      // 菜单呼出时主动隐藏文字选区菜单，避免两层菜单同时显示混乱
      _readerWebViewController.hideSelectionMenu();
    } else {
      _menuAnimController.reverse();
    }
  }

  void _hideMenu() {
    if (_showMenu) {
      setState(() {
        _showMenu = false;
      });
      _menuAnimController.reverse();
    }
  }

  /// 是否走「按视口滚动」渲染路径。
  ///
  /// PageMode.scroll：原生 body.overflow-y:auto 滚动。
  /// PageMode.none：在渲染上仍是 CSS column 分页（reader-paged），仅禁用翻页动画
  ///   （JS 端 pageModeIndex=4 → animEnabled=false → jumpToPage 同步切页）。
  ///   这样 none 与 lumina 的 ReaderPageAnimation.none 语义一致：分页 + 无动画。
  bool _isScrollLikeMode(ReaderProvider provider) =>
      provider.pageMode == PageMode.scroll;

  // ==================== Build ====================

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ReaderProvider>();

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _saveReadRecord();
        }
      },
      child: Scaffold(
        backgroundColor: provider.backgroundColor,
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerUp: _onPointerUp,
            behavior: HitTestBehavior.translucent,
            child: Stack(
              children: [
                if (_hasBackgroundImage(provider))
                  Positioned.fill(
                    child: Image.file(
                      File(provider.backgroundImagePath!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                  // WebView 渲染层：文字选择由 WebView 内部 CSS user-select 控制
                  // 旧的 SelectionArea 仅对 flutter_html 生效，对 PlatformView 无效
                  _buildContent(provider),
              // TTS 播放控制条
              if (provider.isTtsPlaying)
                ReaderTtsBar(
                  isSpeaking: provider.isTtsPlaying,
                  isPaused: provider.isTtsPaused,
                  paragraphIndex: provider.ttsParagraphIndex,
                  paragraphTotal: provider.ttsParagraphTotal,
                  fontSize: provider.fontSize,
                  textColor: provider.textColor,
                  backgroundColor: provider.backgroundColor,
                  onPrev: _prevTtsParagraph,
                  onNext: _nextTtsParagraph,
                  onPause: _pauseTts,
                  onResume: _resumeTts,
                  onStop: _stopTts,
                  onCycleSpeed: _cycleTtsSpeed,
                  onSpeedChanged: (speed) {
                    _ttsSpeed = speed;
                    provider.setTtsRate(speed);
                  },
                  speed: _ttsSpeed,
                ),
              // 增强版控制面板
              //
              // 之前直接 if (_showMenu) ReaderControlOverlay(...) 导致菜单瞬间显示/消失
              // 没有任何过渡动画——_menuAnimController 只 forward/reverse 但没 widget 用
              // 它的值。改为 ListenableBuilder 监听 _menuAnimController，配合 IgnorePointer
              // 在动画值 < 0.5 时屏蔽点击，让菜单有滑入/淡入的过渡动画。
              //
              // 注意 child 必须在 builder 内构造（不能用 ListenableBuilder 的 child 参数
              // 因为 ReaderControlOverlay 依赖大量 _NovelReaderPageState 字段，父级 setState
              // 时这些参数需要刷新）。性能上 ReaderControlOverlay 实例化很轻，可接受。
              if (_showMenu || _menuAnimController.value > 0.0)
                ListenableBuilder(
                  listenable: _menuAnimController,
                  builder: (context, _) {
                    // 动画反向完成且 _showMenu=false 时彻底移除 widget（避免空 widget 占空间）
                    if (!_showMenu && _menuAnimController.value == 0.0) {
                      return const SizedBox.shrink();
                    }
                    return IgnorePointer(
                      // 动画值 < 0.5 时屏蔽点击：菜单半隐藏时不响应按钮
                      // 但 GestureDetector（onClose）在 value >= 0.5 时可点击关闭
                      ignoring: _menuAnimController.value < 0.5,
                      child: ReaderControlOverlay(
                        animation: _menuAnimController,
                        bookName: _book?.name ?? '',
                        chapterTitle: _chapterTitle,
                        chapterUrl: _chapterUrl,
                        sourceName: _book?.sourceName ??
                            (_book?.originType == BookOriginType.local
                                ? '本地书籍'
                                : ''),
                        hasBookSource: _bookSource != null,
                        currentChapter: _currentChapterIndex,
                        totalChapters: _totalChapters,
                        hasBookmark: _hasBookmark,
                        hasPrev: _previousReadableChapterIndex(
                                _currentChapterIndex) !=
                            null,
                        hasNext: _nextReadableChapterIndex(_currentChapterIndex) !=
                            null,
                        isAutoScroll: _isAutoScroll,
                        useReplaceRules: _useReplaceRules,
                        isNightMode: provider.isNightMode,
                        sliderValue: _sliderValue,
                        onBack: () => Navigator.pop(context),
                        onChangeSource: _showChangeSourceDialog,
                        onOpenDetail: _openBookDetail,
                        onOpenChapterUrl: _openChapterUrl,
                        onEditSource: () => _handleSourceAction('edit'),
                        onDisableSource: () => _handleSourceAction('disable'),
                        onRefresh: _refreshChapterContent,
                        onDownload: _showCacheOptions,
                        onToggleBookmark: _toggleBookmark,
                        onClose: _hideMenu,
                        onPrevChapter: () {
                          if (_previousReadableChapterIndex(
                                  _currentChapterIndex) !=
                              null) {
                            _previousChapter();
                          }
                        },
                        onNextChapter: () {
                          if (_nextReadableChapterIndex(_currentChapterIndex) !=
                              null) {
                            _nextChapter();
                          }
                        },
                        onStartSearch: _showChapterSearch,
                        onToggleAutoScroll: _toggleAutoScroll,
                        onToggleNightMode: () {
                          provider.toggleNightMode();
                          _repaginatePreservingPosition();
                        },
                        onOpenReplaceRules: _openReplaceRules,
                        onUseReplaceRulesChanged: _setUseReplaceRules,
                        onEditChapter: _editChapterContent,
                        onShowDirectory: () {
                          _hideMenu();
                          _showChapterList();
                        },
                        onStartTts: _startTts,
                        onShowInterface: _showEnhancedSettings,
                        onShowSettings: () {
                          _hideMenu();
                          _showMoreSettingsDialog(provider);
                        },
                        onSliderChanged: (value) {
                          setState(() {
                            _sliderValue = value;
                          });
                        },
                        onSliderChangeEnd: (value) {
                          _currentChapterIndex = _readableChapterIndex(value);
                          _loadChapterContent();
                        },
                      ),
                    );
                  },
                )
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==================== Content Area ====================

  Widget _buildContent(ReaderProvider provider) {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(color: provider.textColor),
      );
    }

    // 统一走 WebView 渲染：
    // - 滚动模式（scroll/none）：WebView 内部 body.reader-scroll + overflow-y:auto
    // - 分页模式（slide/cover/simulation）：WebView 内部 body.reader-paged + CSS column 分栏
    // 翻页交互由 _onPointerUp/_onPointerDown + _executeTapAction 处理，
    // 通过 _readerWebViewController.jumpToPage() 调用 JS 翻页
    return _buildWebViewContent(provider);
  }

  // ==================== WebView Content ====================

  /// 构建 WebView 阅读内容
  ///
  /// 替代旧的 _buildScrollContent / _buildSlideContent / _buildCoverContent
  /// / _buildSimulationContent，统一由 WebView 渲染 HTML+CSS+JS。
  ///
  /// 章节内容 / 样式变化由 ReaderWebView.didUpdateWidget 自动检测并重新加载。
  /// 翻页进度通过 onPageCountReady / onPageChanged 回调同步到本 State。
  Widget _buildWebViewContent(ReaderProvider provider) {
    final isScrollMode = _isScrollLikeMode(provider);
    final pageModeIndex = provider.pageMode.index;

    return SafeArea(
      child: Column(
        children: [
          if (_headerVisible(provider))
            _buildScrollPageTip(provider, isHeader: true),
          Expanded(
            child: ReaderPageView(
              isScrollMode: isScrollMode,
              pageModeIndex: pageModeIndex,
              onPerformPageTurn: _onPerformPageTurn,
              onPageTurnCompleted: _onPageTurnCompleted,
              onPageTurnCancelled: _onPageTurnCancelled,
              child: ReaderWebView(
                content: _processedContent(_content),
                title: _chapterTitle,
                chapterIndex: _currentChapterIndex,
                provider: provider,
                isScrollMode: isScrollMode,
                controller: _readerWebViewController,
                callbacks: ReaderWebViewCallbacks(
                  onInitialized: _onWebviewInitialized,
                  onPageCountReady: _onWebviewPageCountReady,
                  onPageChanged: _onWebviewPageChanged,
                  // tap 由 JS click 事件触发（InAppWebView 是 PlatformView，
                  // Flutter Listener 收不到 pointerUp，必须靠 JS 回调）
                  onTap: _onWebviewJsTap,
                  onImageTap: _onWebviewImageTap,
                  // 滚动模式无缝衔接：接近底部时加载下一章
                  onScrollNearEnd: _onScrollNearEnd,
                  // 滚动模式：当前可见章节变化时更新 UI 章节标题/进度
                  onChapterVisible: _onChapterVisible,
                  // 文字选择菜单（JS 自定义浮动菜单，替代 Android ActionMode）
                  onSelectionReady: _onSelectionReady,
                  onSelectionAction: _onSelectionAction,
                  onHideSelectionMenu: _onHideSelectionMenu,
                ),
              ),
            ),
          ),
          if (_footerVisible(provider))
            _buildScrollPageTip(provider, isHeader: false),
        ],
      ),
    );
  }

  /// ReaderPageView 回调：执行翻页（让 WebView 切换到目标页）
  ///
  /// 返回 true：正常翻页（章节内），ReaderPageView 继续截图 + 动画
  /// 返回 false：章节边界，外部已触发章节切换，ReaderPageView 取消动画
  Future<bool> _onPerformPageTurn(PageDirection direction) async {
    if (!_readerWebViewController.isReady) return false;
    _isPageTurning = true; // 翻页流程开始，阻止 JS click 误触发菜单

    final provider = context.read<ReaderProvider>();
    final isScrollMode = _isScrollLikeMode(provider);
    if (isScrollMode) return false;

    final targetPage = direction == PageDirection.next
        ? _webviewCurrentPage + 1
        : _webviewCurrentPage - 1;

    // 章节边界：触发上一章/下一章切换，取消翻页动画
    if (targetPage < 0) {
      _previousChapter();
      return false;
    }
    if (targetPage >= _webviewPageCount) {
      _nextChapter();
      return false;
    }

    // 章节内翻页：调用 WebView 切换（无动画，因为我们的 ReaderPageView 自己做动画）
    await _readerWebViewController.jumpToPage(targetPage, animate: false);

    // 等待 WebView 内部 CSS column 重排 + PlatformView 合成到 Flutter Surface
    // jumpToPage 同步设 transform，但 WebView 渲染需要 1-2 帧才能更新到 Surface
    // 必须等帧完成，否则 RepaintBoundary.toImage 截到的是旧内容（第 2 页排版乱的根因）
    await _waitForWebViewFrame(targetPage);
    return true;
  }

  /// 等待 WebView 完成渲染并合成到 Flutter Surface
  ///
  /// 关键时序问题：
  /// 1. `evaluateJavascript` await 完成仅保证 JS 函数已返回，
  ///    但 JS 端 `jumpToPage(animate:false)` 内部已同步设 `contentA.style.transform`
  ///    并通过 `void offsetHeight` 强制 reflow。
  /// 2. 浏览器渲染管线把 transform 提交到 Surface 需要 1 个 vsync。
  /// 3. flutter_inappwebview 的 PlatformView 把 Surface 合成到 Flutter 的图层，
  ///    需要 1-2 个 Flutter vsync 才能反映到 RepaintBoundary.toImage() 截图。
  ///
  /// 策略：
  /// - 用 onPageChanged 回调作为「JS 端已设 transform」的确认信号（避免空等）；
  /// - 再等 2 个 Flutter 帧 + 1 个 vsync 给 SurfaceFlinger。
  Future<void> _waitForWebViewFrame([int? expectedPage]) async {
    // 1. 等 onPageChanged 回调确认 JS 端 currentPage = expectedPage
    //    （兜底超时 120ms，防止回调丢失时永远阻塞）
    //
    // 每次强制新建 completer 覆盖旧值：
    // 快速连续翻页时若复用旧 completer（已 complete），第二次 await 立即返回，
    // 但等的是上一次的回调，时序错乱（问题 5）
    final completer = expectedPage != null ? Completer<void>() : null;
    if (completer != null) {
      _pageRenderedCompleter = completer;
    }
    if (completer != null) {
      await completer.future.timeout(
        const Duration(milliseconds: 120),
        onTimeout: () {
          debugPrint('[NovelReader] _waitForWebViewFrame: onPageChanged 超时');
        },
      );
      if (identical(_pageRenderedCompleter, completer)) {
        _pageRenderedCompleter = null;
      }
    }
    // 2. 第一帧：浏览器提交渲染
    await _nextFrame();
    // 3. 第二帧：PlatformView 合成到 Flutter Surface
    await _nextFrame();
    // 4. SurfaceFlinger 最后一次 vsync 保险
    await Future.delayed(const Duration(milliseconds: 16));
  }

  Future<void> _nextFrame() {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => completer.complete());
    return completer.future;
  }

  /// 翻页完成（动画结束后）：保存进度
  void _onPageTurnCompleted(PageDirection direction) {
    if (!mounted) return;
    _isPageTurning = false;
    // 进度保存由 _onWebviewPageChanged 处理（jumpToPage 会触发它）
    // 这里只做必要的 UI 状态更新
    setState(() {});
  }

  /// 翻页取消：恢复状态
  void _onPageTurnCancelled() {
    if (!mounted) return;
    _isPageTurning = false;
    setState(() {});
  }

  void _onWebviewInitialized() {
    // WebView HTML 加载完成，但 CSS column 布局尚未完成
    // 不在此处设置 _webviewReady，等 onPageCountReady 回调后再标记就绪
    // （_onWebviewPageCountReady 会在 JS init() 的 requestAnimationFrame 两帧后触发）
  }

  /// 问题 9 修复：启动 _webviewReloading 超时保护
  ///
  /// 与 _webviewReloading = true 配对调用。
  /// 若 5s 内 _onWebviewPageCountReady 未触发，强制释放 _webviewReloading
  /// 并唤醒等待中的 _pageRenderedCompleter（避免翻页流程卡死）。
  void _startWebviewReloadTimeout() {
    _webviewReloadTimeoutTimer?.cancel();
    _webviewReloadTimeoutTimer = Timer(_webviewReloadTimeout, () {
      if (!mounted) return;
      if (!_webviewReloading) return;
      debugPrint('[novel_reader] WebView reload 超时 5s，强制释放 _webviewReloading');
      _webviewReloading = false;
      // 唤醒可能正在等待 _onWebviewPageChanged 的翻页流程
      // （reload 期间 _onWebviewPageChanged 早 return，completer 永不 complete）
      final c = _pageRenderedCompleter;
      if (c != null && !c.isCompleted) {
        c.complete();
      }
      _pageRenderedCompleter = null;
      setState(() {});
    });
  }

  void _onWebviewPageCountReady(int totalPages) {
    if (!mounted) return;
    final newPageCount = max(1, totalPages);

    // M1 修复：区分「首次 pageCount ready」与「后续更新」
    //
    // 背景：reader_html_template.dart 的 notifyPageCountReadyWhenStable
    // 会在图片/字体加载完成后二次通知 pageCount。二次通知时
    // _pendingWebviewFraction/InitialPage 已被首次通知消费完，
    // 若走原 else 分支会 _webviewCurrentPage=0 重置到第 0 页。
    //
    // 修复：isUpdate=true 时只更新 _webviewPageCount + clamp 当前页 +
    // 存库（问题 6），不重新恢复进度。
    final isUpdate = _webviewReady;

    setState(() {
      _webviewPageCount = newPageCount;
      _webviewReady = true;
      _webviewReloading = false;
    });
    // 问题 9 修复：pageCount ready 正常触发，取消 reload 超时 timer
    _webviewReloadTimeoutTimer?.cancel();
    _webviewReloadTimeoutTimer = null;

    // 关键：标记 controller 就绪，否则 jumpToPage 第一行 if (!_isReady) return
    // 直接返回，翻页完全失效（之前 markReady() 方法定义了但从未被调用）
    _readerWebViewController.markReady();
    // Phase 3.2 补丁：首次 pageCount ready 时恢复初始章节的持久化高亮
    // - 滚动模式后续追加章节由 _appendNextChapter 单独处理
    // - 章节切换（_loadChapterContent）触发 WebView reload 后走首次分支，
    //   同样需要恢复该章节的高亮
    // - isUpdate=true 时 DOM 没变、高亮已在内存中，跳过避免重复
    if (!isUpdate) {
      unawaited(_restoreHighlights(_currentChapterIndex));
    }
    final provider = context.read<ReaderProvider>();
    final isScrollMode = _isScrollLikeMode(provider);

    // M1 + 问题 6 修复：更新型通知不重新恢复进度
    // 只 clamp 当前页（pageCount 变小后可能越界）+ 存库（pageCount 变化后进度比例也变）
    if (isUpdate) {
      if (!isScrollMode) {
        if (_webviewCurrentPage >= newPageCount) {
          // 当前页越界，clamp 到末页并跳转
          final clampedPage = newPageCount - 1;
          _webviewCurrentPage = clampedPage;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _readerWebViewController.jumpToPage(clampedPage, animate: false);
            }
          });
          _scheduleProgressSave(pos: clampedPage);
        } else {
          // 当前页在范围内，但 pageCount 变化后进度比例也变，存库新位置
          _scheduleProgressSave(pos: _webviewCurrentPage);
        }
      }
      // 滚动模式：pageCount 恒为 1，无需 clamp/存库
      return;
    }

    // 以下为首次 pageCount ready 的进度恢复逻辑（原逻辑）

    // 滚动模式：pageCount 恒为 1，进度恢复用 scrollToOffset（像素）
    if (isScrollMode) {
      if (_pendingWebviewFraction >= 0) {
        // 样式变化后保留位置（fraction 是 0-1 的滚动比例）
        final ratio = _pendingWebviewFraction.clamp(0.0, 1.0);
        _pendingWebviewFraction = -1.0;
        _pendingWebviewInitialPage = 0;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _readerWebViewController.setScrollProgress(ratio);
        });
      } else if (_pendingWebviewInitialPage > 0) {
        // 章节切换/进度恢复：_pendingWebviewInitialPage 是像素偏移
        final offset = _pendingWebviewInitialPage >= (1 << 30)
            ? 1 << 30 // 末页：scrollToOffset 会自动 clamp 到底部
            : _pendingWebviewInitialPage;
        _pendingWebviewInitialPage = 0;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _readerWebViewController.scrollToOffset(offset);
        });
      }
      return;
    }

    // 分页模式：用 jumpToPage 恢复（无动画，避免初始化时滑动）
    if (_pendingWebviewFraction >= 0) {
      final target = (_pendingWebviewFraction * (_webviewPageCount - 1))
          .round()
          .clamp(0, _webviewPageCount - 1);
      _pendingWebviewFraction = -1.0;
      _pendingWebviewInitialPage = 0;
      _webviewCurrentPage = target;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _readerWebViewController.jumpToPage(target, animate: false);
      });
    } else if (_pendingWebviewInitialPage > 0) {
      // 章节切换/进度恢复：跳到指定页
      // 1 << 30 表示「跳到最后一页」
      final target = _pendingWebviewInitialPage >= (1 << 30)
          ? _webviewPageCount - 1
          : _pendingWebviewInitialPage.clamp(0, _webviewPageCount - 1);
      _pendingWebviewInitialPage = 0;
      _webviewCurrentPage = target;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _readerWebViewController.jumpToPage(target, animate: false);
      });
    } else {
      _webviewCurrentPage = 0;
    }
  }

  void _onWebviewPageChanged(int pageIndex) {
    if (!mounted) return;
    if (_webviewReloading) return;
    final provider = context.read<ReaderProvider>();
    final isScrollMode = _isScrollLikeMode(provider);

    // 唤醒翻页时序等待：_waitForWebViewFrame(expectedPage) 在调 jumpToPage 后等此回调
    final c = _pageRenderedCompleter;
    if (c != null && !c.isCompleted) {
      c.complete();
    }

    if (isScrollMode) {
      // 滚动模式：pageIndex 是 progress * 1000（虚拟页码）
      _webviewCurrentPage = pageIndex;
      _scrollProgressNotifier.value = pageIndex / 1000.0;
      // 滚动模式高频触发（每滚几像素一次），用防抖避免高频 Hive 写入 IO 压力
      // （问题 2：滚动模式无防抖，每滚几像素写一次数据库）
      _scheduleProgressSave(pos: null);
    } else {
      setState(() {
        _webviewCurrentPage = pageIndex;
      });
      _scrollProgressNotifier.value =
          _webviewPageCount > 1 ? pageIndex / (_webviewPageCount - 1) : 0;
      // 分页模式每次翻页才触发，频率低，但仍走防抖以合并连续翻页
      _scheduleProgressSave(pos: pageIndex);
    }
  }

  /// 防抖保存进度
  ///
  /// 滚动模式 _onWebviewPageChanged 高频触发（每滚几像素一次），直接
  /// _saveCurrentProgress 会造成 Hive 频繁 put，IO 压力大，且并发保存存在
  /// 回退竞态（问题 3）。延迟 300ms，期间新触发则取消旧 timer 重启。
  /// 分页模式也走防抖，合并连续翻页的多次保存。
  void _scheduleProgressSave({int? pos}) {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) unawaited(_saveCurrentProgress(pos: pos));
    });
  }

  void _onWebviewImageTap(String src, Rect rect) {
    // 图片点击：打开图片预览（暂未实现，与旧 flutter_html 行为一致）
    debugPrint('[NovelReader] Image tap: $src');
  }

  /// WebView 内部 JS click 事件回调（x, y 是 clientX/clientY，相对 WebView 视口）
  ///
  /// 关键修复：InAppWebView 是 PlatformView，外层 Flutter Listener 收不到
  /// pointerUp 事件，必须靠 JS 端的 click 事件回传才能召唤菜单。
  /// JS 端在 reader_html_template.dart 的 document.addEventListener('click')
  /// 中调用 notifyTap(x, y)，通过 flutter_inappwebview 桥回传到此处。
  ///
  /// 注意：JS click 事件在 Android WebView 上有 ~300ms 延迟（防止双击缩放），
  /// 所以菜单召唤会比纯 Flutter 略慢一点，但这是 PlatformView 的固有代价。
  void _onWebviewJsTap(double x, double y) {
    // 翻页动画进行中：忽略 click（防止滑动时手抖触发菜单）
    if (_isPageTurning) return;
    // 复用 _handleTap 的 tap zone 分区逻辑，避免重复代码导致不一致
    // x, y 是相对 WebView 视口的坐标，需补上 SafeArea padding 和 header 高度
    // 才能得到屏幕全局坐标（_handleTap 期望的是 globalPosition）
    final provider = context.read<ReaderProvider>();
    final mq = MediaQuery.of(context);
    final headerExtent = _headerVisible(provider) ? _headerExtent(provider) : 0.0;
    final globalX = x + mq.padding.left;
    final globalY = y + mq.padding.top + headerExtent;
    _handleTap(TapUpDetails(
      kind: PointerDeviceKind.touch,
      globalPosition: Offset(globalX, globalY),
      localPosition: Offset(globalX, globalY),
    ));
  }

  bool _hasBackgroundImage(ReaderProvider provider) {
    final path = provider.backgroundImagePath;
    return !kIsWeb && path != null && path.isNotEmpty;
  }

  // ==================== Rich Content with Highlights ====================

  String _displayChapterTitle(ReaderProvider provider) =>
      ChineseConverter.convert(_chapterTitle, provider.chineseConverterType);

  bool _headerVisible(ReaderProvider provider) {
    if (!provider.showReadingInfo) return false;
    // headerMode: 0=自动（分页显示/滚动隐藏）, 1=显示, 2=隐藏
    if (provider.headerMode == 1) return true;
    if (provider.headerMode == 2) return false;
    return !_isScrollLikeMode(provider);
  }

  bool _footerVisible(ReaderProvider provider) {
    return provider.showReadingInfo && provider.footerMode == 0;
  }

  double _headerExtent(ReaderProvider provider) {
    if (!_headerVisible(provider)) return 0;
    return max(16.0, provider.headerFontSize * 1.35) +
        provider.headerPaddingTop +
        provider.headerPaddingBottom +
        (provider.showHeaderLine ? 1 : 0);
  }

  double _footerExtent(ReaderProvider provider) {
    if (!_footerVisible(provider)) return 0;
    return max(16.0, provider.footerFontSize * 1.35) +
        provider.footerPaddingTop +
        provider.footerPaddingBottom +
        (provider.showFooterLine ? 1 : 0);
  }

  Widget _buildScrollPageTip(
    ReaderProvider provider, {
    required bool isHeader,
  }) {
    return ValueListenableBuilder<double>(
      valueListenable: _scrollProgressNotifier,
      builder: (context, progress, child) {
        return _buildPageTip(
          provider,
          isHeader: isHeader,
          pageIndex: _webviewCurrentPage,
        );
      },
    );
  }

  Widget _buildPageTip(
    ReaderProvider provider, {
    required bool isHeader,
    required int pageIndex,
  }) {
    final values = isHeader
        ? [
            provider.tipHeaderLeft,
            provider.tipHeaderMiddle,
            provider.tipHeaderRight,
          ]
        : [
            provider.tipFooterLeft,
            provider.tipFooterMiddle,
            provider.tipFooterRight,
          ];
    final alignments = [TextAlign.left, TextAlign.center, TextAlign.right];
    final color = provider.tipColor == 0
        ? provider.textColor.withValues(alpha: 0.58)
        : Color(provider.tipColor);
    final dividerColor = provider.tipDividerColor < 0
        ? color.withValues(alpha: 0.28)
        : provider.tipDividerColor == 0
        ? provider.textColor.withValues(alpha: 0.16)
        : Color(provider.tipDividerColor);
    final fontSize = isHeader
        ? provider.headerFontSize.toDouble()
        : provider.footerFontSize.toDouble();
    final extent = isHeader ? _headerExtent(provider) : _footerExtent(provider);
    final padding = isHeader
        ? EdgeInsets.fromLTRB(
            provider.headerPaddingLeft,
            provider.headerPaddingTop,
            provider.headerPaddingRight,
            provider.headerPaddingBottom,
          )
        : EdgeInsets.fromLTRB(
            provider.footerPaddingLeft,
            provider.footerPaddingTop,
            provider.footerPaddingRight,
            provider.footerPaddingBottom,
          );

    return SizedBox(
      height: extent,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          border: Border(
            top: !isHeader && provider.showFooterLine
                ? BorderSide(color: dividerColor)
                : BorderSide.none,
            bottom: isHeader && provider.showHeaderLine
                ? BorderSide(color: dividerColor)
                : BorderSide.none,
          ),
        ),
        child: Row(
          children: List.generate(values.length, (index) {
            return Expanded(
              child: Text(
                _tipText(values[index], pageIndex, provider),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: alignments[index],
                style: TextStyle(color: color, fontSize: fontSize, height: 1.2),
              ),
            );
          }),
        ),
      ),
    );
  }

  String _tipText(int type, int pageIndex, ReaderProvider provider) {
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final pageCount = max(_webviewPageCount, 1);
    final withinChapter = _isScrollLikeMode(provider)
        ? _scrollProgress
        : pageIndex / max(pageCount - 1, 1);
    final totalProgress = _totalChapters <= 0
        ? 0.0
        : ((_currentChapterIndex + withinChapter) / _totalChapters).clamp(
            0.0,
            1.0,
          );
    return switch (type) {
      1 => _displayChapterTitle(provider),
      2 => time,
      4 =>
        _isScrollLikeMode(provider)
            ? '${(_scrollProgress * 100).round()}%'
            : '${pageIndex + 1}',
      5 => '${(totalProgress * 100).toStringAsFixed(1)}%',
      6 =>
        _isScrollLikeMode(provider)
            ? '${_currentChapterIndex + 1}/${max(_totalChapters, 1)}'
            : '${pageIndex + 1}/$pageCount',
      7 => ChineseConverter.convert(
        _book?.displayName ?? '',
        provider.chineseConverterType,
      ),
      _ => '',
    };
  }

  // ==================== Menu ====================

  // ==================== Dialogs ====================

  void _showChangeSourceDialog() {
    _hideMenu();
    if (_book == null || _book!.originType != BookOriginType.online) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本地书籍不支持换源')));
      return;
    }

    ChangeSourceSheet.show(
      context: context,
      bookName: _book!.displayName,
      bookAuthor: _book!.displayAuthor,
      currentSourceUrl: _book!.sourceUrl,
      currentSourceName: _book!.sourceName,
      onSourceSelected: (sourceUrl, sourceName, bookData) async {
        if (_book == null) return;

        try {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('正在切换书源...')));

          // 创建新的书籍对象
          final newBook = _book!.copyWith(
            sourceUrl: sourceUrl,
            sourceName: sourceName,
            bookUrl: bookData['bookUrl'] ?? _book!.bookUrl,
            name: bookData['name'] ?? _book!.name,
            author: bookData['author'] ?? _book!.author,
            coverUrl: bookData['coverUrl'] ?? _book!.coverUrl,
            intro: bookData['intro'] ?? _book!.intro,
            lastChapter: bookData['lastChapter'] ?? _book!.lastChapter,
          );

          // 获取新书源的目录
          _dataProvider = createBookDataProvider(newBook);
          final chapters = await _dataProvider!.getChapterList(newBook);

          // 更新书籍
          final updatedBook = newBook.copyWith(
            totalChapterNum: chapters.length,
          );

          // 保存到书架
          StorageService.instance.addToBookshelf(updatedBook.toJson());
          context.read<BookshelfProvider>().loadBooks();

          // 更新状态并重新加载内容
          setState(() {
            _book = updatedBook;
            _chapters = chapters;
            _totalChapters = chapters.length;
            _currentChapterIndex = 0; // 切换书源后从第一章开始
          });

          // await 加载完成后再提示成功，避免「已切换」与加载中状态并存
          await _loadChapterContent();

          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('已切换到 $sourceName')));
            // 换源后当前章节的书签状态可能与旧源不同，需重新检查
            _checkBookmark();
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('换源失败: $e')));
          }
        }
      },
    );
  }

  void _openBookDetail() {
    if (_book == null) return;
    _hideMenu();
    Navigator.pushNamed(
      context,
      AppRoutes.detail,
      arguments: {'bookUrl': _book!.bookUrl, 'bookData': _book},
    );
  }

  Future<void> _openChapterUrl() async {
    final rawUrl = _chapterUrl ?? '';
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前章节没有可打开的网页链接')));
      return;
    }
    _hideMenu();
    await Navigator.pushNamed(
      context,
      AppRoutes.internalBrowser,
      arguments: {
        'url': uri.toString(),
        'title': _chapterTitle,
        'sourceUrl': _book?.sourceUrl ?? '',
        'sourceName': _book?.sourceName ?? '',
      },
    );
  }

  void _handleSourceAction(String action) {
    switch (action) {
      case 'edit':
        final sourceUrl = _bookSource?.bookSourceUrl;
        if (sourceUrl == null || sourceUrl.isEmpty) return;
        _hideMenu();
        Navigator.pushNamed(
          context,
          AppRoutes.bookSourceEdit,
          arguments: {'sourceUrl': sourceUrl},
        ).then((_) => _reloadBookSource());
        break;
      case 'disable':
        _disableBookSource();
        break;
    }
  }

  Future<void> _reloadBookSource() async {
    final sourceUrl = _book?.sourceUrl;
    if (!mounted || sourceUrl == null || sourceUrl.isEmpty) return;
    final sourceData = StorageService.instance.getBookSource(sourceUrl);
    if (sourceData == null) return;
    final source = BookSource.fromJson(sourceData);
    setState(() {
      _bookSource = source;
    });
  }

  Future<void> _disableBookSource() async {
    final source = _bookSource;
    if (source == null || !source.enabled) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该书源已禁用')));
      return;
    }
    await StorageService.instance.saveBookSource(
      source.copyWith(enabled: false).toJson(),
    );
    if (!mounted) return;
    setState(() => _bookSource = source.copyWith(enabled: false));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已禁用书源')));
  }

  void _showChapterList() {
    _hideMenu();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      showDragHandle: true,
      builder: (context) => _NovelChapterListPanel(
        book: _book,
        chapters: _chapters,
        totalChapters: _totalChapters,
        currentChapterIndex: _currentChapterIndex,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        onChapterSelected: (index) {
          setState(() => _currentChapterIndex = _readableChapterIndex(index));
          _loadChapterContent();
          Navigator.pop(context);
        },
        // 子面板书签增删后重新检查当前章节书签状态，同步顶栏图标
        onBookmarksChanged: () {
          if (mounted) _checkBookmark();
        },
      ),
    );
  }

  void _showSpacingDialog(ReaderProvider provider) {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('间距设置'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Line height
                    Row(
                      children: [
                        const Text('行距'),
                        Expanded(
                          child: Slider(
                            value: provider.lineHeight,
                            min: 1.0,
                            max: 3.0,
                            divisions: 20,
                            onChanged: (value) {
                              provider.setLineHeight(value);
                              setDialogState(() {});
                            },
                            onChangeEnd: (_) {
                              _repaginatePreservingPosition();
                            },
                          ),
                        ),
                        Text(provider.lineHeight.toStringAsFixed(1)),
                      ],
                    ),
                    // Paragraph spacing
                    Row(
                      children: [
                        const Text('段距'),
                        Expanded(
                          child: Slider(
                            value: provider.paragraphSpacing,
                            min: 0,
                            max: 24,
                            divisions: 24,
                            onChanged: (value) {
                              provider.setParagraphSpacing(value);
                              setDialogState(() {});
                            },
                            onChangeEnd: (_) {
                              _repaginatePreservingPosition();
                            },
                          ),
                        ),
                        Text(provider.paragraphSpacing.toInt().toString()),
                      ],
                    ),
                    // Text indent
                    Row(
                      children: [
                        const Text('缩进'),
                        Expanded(
                          child: Slider(
                            value: provider.textIndent,
                            min: 0,
                            max: 4,
                            divisions: 4,
                            onChanged: (value) {
                              provider.setTextIndent(value);
                              setDialogState(() {});
                            },
                            onChangeEnd: (_) {
                              _repaginatePreservingPosition();
                            },
                          ),
                        ),
                        Text(provider.textIndent.toInt().toString()),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showBrightnessDialog(ReaderProvider provider) {
    // screenBrightness 为 -1 表示跟随系统，clamp 到滑块范围
    var brightness = provider.screenBrightness < 0
        ? 0.5
        : provider.screenBrightness.clamp(0.1, 1.0);
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('亮度'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Slider(
                    value: brightness,
                    min: 0.1,
                    max: 1.0,
                    onChanged: (value) {
                      provider.setScreenBrightness(value);
                      brightness = value;
                      setDialogState(() {});
                    },
                  ),
                  Text('${(brightness * 100).toInt()}%'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showCacheOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('缓存当前章节'),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_cacheCurrentChapter());
                },
              ),
              if (_book?.originType == BookOriginType.online) ...[
                ListTile(
                  leading: const Icon(Icons.download_for_offline),
                  title: const Text('缓存后续50章'),
                  onTap: () {
                    Navigator.pop(context);
                    unawaited(_cacheFollowingChapters(50));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.cloud_download),
                  title: const Text('缓存全本'),
                  onTap: () {
                    Navigator.pop(context);
                    unawaited(_cacheFollowingChapters(null));
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _cacheCurrentChapter() async {
    final book = _book;
    final chapter = _currentChapterIndex < _chapters.length
        ? _chapters[_currentChapterIndex]
        : null;
    if (book == null || chapter == null || _content.isEmpty) return;
    if (book.originType != BookOriginType.online) {
      _showMessage('本地书籍无需缓存');
      return;
    }
    await ChapterCacheService.instance.saveChapterContent(
      book,
      chapter,
      _content,
    );
    _showMessage('当前章节已缓存');
  }

  Future<void> _cacheFollowingChapters(int? limit) async {
    final book = _book;
    final dataProvider = _dataProvider;
    if (book == null || dataProvider == null) return;
    final chapters = _chapters
        .skip(_currentChapterIndex + 1)
        .where((chapter) => !chapter.isVolume && chapter.url != null)
        .take(limit ?? _chapters.length)
        .toList();
    if (chapters.isEmpty) {
      _showMessage('没有可缓存的后续章节');
      return;
    }
    _showMessage('开始缓存 ${chapters.length} 章');
    try {
      await _cacheCurrentChapter();
      await ChapterPrefetchService.instance.prefetchChapters(
        book: book,
        chapters: chapters,
        provider: dataProvider,
        allChapters: _chapters,
      );
      _showMessage('已完成 ${chapters.length} 章缓存');
    } catch (error) {
      if (mounted) _showMessage('缓存失败：$error');
    }
  }

  void _showInterfaceSettingsDialog(ReaderProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.43,
          minChildSize: 0.24,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              child: _buildInterfaceSettingsSheet(
                provider,
                onClose: () => Navigator.pop(sheetContext),
              ),
            );
          },
        );
      },
    );
  }

  ReaderSettingsSheet _buildInterfaceSettingsSheet(
    ReaderProvider provider, {
    required VoidCallback onClose,
  }) {
    void updateLayout(VoidCallback update) {
      update();
      _repaginatePreservingPosition();
    }

    return ReaderSettingsSheet(
      fontSize: provider.fontSize,
      lineHeight: provider.lineHeight,
      letterSpacing: provider.letterSpacing,
      paragraphSpacing: provider.paragraphSpacing,
      paragraphIndent: provider.paragraphIndent,
      fontWeightIndex: provider.fontWeightIndex,
      fontFamily: provider.fontFamily,
      backgroundColor: provider.backgroundColor,
      backgroundImagePath: provider.backgroundImagePath,
      showReadingInfo: provider.showReadingInfo,
      pageAnim: provider.pageMode.index,
      pageAnimDurationMs: provider.pageAnimDurationMs,
      screenBrightness: provider.screenBrightness,
      keepScreenOn: provider.keepScreenOn,
      enableVolumeKeyPage: provider.enableVolumeKeyPage,
      volumeKeyPageOnTts: provider.volumeKeyPageOnTts,
      enableLongPressMenu: provider.enableLongPressMenu,
      autoScrollSpeed: provider.autoScrollSpeed,
      autoPageIntervalSeconds: provider.autoPageIntervalSeconds,
      isNightMode: provider.isNightMode,
      chineseConverterType: provider.chineseConverterType,
      fontWeightFine: provider.fontWeightFine,
      textBoldFine: provider.textBoldFine,
      titleBoldFine: provider.titleBoldFine,
      titleMode: provider.titleMode,
      titleSize: provider.titleSize,
      titleTopSpacing: provider.titleTopSpacing,
      titleBottomSpacing: provider.titleBottomSpacing,
      paddingTop: provider.paddingTop,
      paddingBottom: provider.paddingBottom,
      paddingLeft: provider.paddingLeft,
      paddingRight: provider.paddingRight,
      headerPaddingTop: provider.headerPaddingTop,
      headerPaddingBottom: provider.headerPaddingBottom,
      headerPaddingLeft: provider.headerPaddingLeft,
      headerPaddingRight: provider.headerPaddingRight,
      footerPaddingTop: provider.footerPaddingTop,
      footerPaddingBottom: provider.footerPaddingBottom,
      footerPaddingLeft: provider.footerPaddingLeft,
      footerPaddingRight: provider.footerPaddingRight,
      showHeaderLine: provider.showHeaderLine,
      showFooterLine: provider.showFooterLine,
      headerMode: provider.headerMode,
      footerMode: provider.footerMode,
      tipHeaderLeft: provider.tipHeaderLeft,
      tipHeaderMiddle: provider.tipHeaderMiddle,
      tipHeaderRight: provider.tipHeaderRight,
      tipFooterLeft: provider.tipFooterLeft,
      tipFooterMiddle: provider.tipFooterMiddle,
      tipFooterRight: provider.tipFooterRight,
      headerFontSize: provider.headerFontSize,
      footerFontSize: provider.footerFontSize,
      onFontSizeChanged: (value) {
        provider.setFontSize(value);
        _repaginatePreservingPosition();
      },
      onLineHeightChanged: (value) {
        provider.setLineHeight(value);
        _repaginatePreservingPosition();
      },
      onLetterSpacingChanged: (value) {
        provider.setLetterSpacing(value);
        _repaginatePreservingPosition();
      },
      onParagraphSpacingChanged: (value) {
        provider.setParagraphSpacing(value);
        _repaginatePreservingPosition();
      },
      onParagraphIndentChanged: (value) {
        provider.setParagraphIndent(value);
        _repaginatePreservingPosition();
      },
      onFontWeightChanged: (value) {
        provider.setFontWeightIndex(value);
        _repaginatePreservingPosition();
      },
      onFontFamilyChanged: (value) =>
          updateLayout(() => provider.setFontFamily(value)),
      onBackgroundColorChanged: (value) =>
          updateLayout(() => provider.setBackgroundColor(value)),
      onBackgroundImageChanged: (value) =>
          provider.setBackgroundImagePath(value),
      onShowReadingInfoChanged: (value) =>
          updateLayout(() => provider.setShowReadingInfo(value)),
      onPageAnimChanged: (value) {
        if (value < PageMode.values.length) {
          provider.setPageMode(PageMode.values[value]);
          _repaginatePreservingPosition();
        }
      },
      onPageAnimDurationChanged: (value) {
        // pageAnimDurationMs 在 _StyleSnapshot 中，setter 会触发 ReaderWebView 重载 HTML，
        // 必须保留当前进度比例，否则会跳回第 0 页
        provider.setPageAnimDurationMs(value);
        _repaginatePreservingPosition();
      },
      onScreenBrightnessChanged: (value) => provider.setScreenBrightness(value),
      onKeepScreenOnChanged: (value) => provider.setKeepScreenOn(value),
      onEnableVolumeKeyPageChanged: (value) =>
          provider.setEnableVolumeKeyPage(value),
      onVolumeKeyPageOnTtsChanged: (value) =>
          provider.setVolumeKeyPageOnTts(value),
      onEnableLongPressMenuChanged: (value) =>
          provider.setEnableLongPressMenu(value),
      onAutoScrollSpeedChanged: (value) => provider.setAutoScrollSpeed(value),
      onAutoPageIntervalChanged: (value) =>
          provider.setAutoPageIntervalSeconds(value),
      onNightModeChanged: (value) {
        if (provider.isNightMode != value) {
          provider.toggleNightMode();
          // 夜间模式切换会改变背景色和文字色，触发 WebView 重新加载，保留位置
          _repaginatePreservingPosition();
        }
      },
      onChineseConverterTypeChanged: (value) {
        updateLayout(() => provider.setChineseConverterType(value));
        provider.setTtsChapterContent(
          ChineseConverter.convert(_processedContent(_content), value),
        );
      },
      onFontWeightFineChanged: (value) =>
          updateLayout(() => provider.setFontWeightFine(value)),
      onTextBoldFineChanged: (value) =>
          updateLayout(() => provider.setTextBoldFine(value)),
      onTitleBoldFineChanged: (value) =>
          updateLayout(() => provider.setTitleBoldFine(value)),
      onTitleModeChanged: (value) =>
          updateLayout(() => provider.setTitleMode(value)),
      onTitleSizeChanged: (value) =>
          updateLayout(() => provider.setTitleSize(value)),
      onTitleTopSpacingChanged: (value) =>
          updateLayout(() => provider.setTitleTopSpacing(value)),
      onTitleBottomSpacingChanged: (value) =>
          updateLayout(() => provider.setTitleBottomSpacing(value)),
      onPaddingTopChanged: (value) =>
          updateLayout(() => provider.setPaddingTop(value)),
      onPaddingBottomChanged: (value) =>
          updateLayout(() => provider.setPaddingBottom(value)),
      onPaddingLeftChanged: (value) =>
          updateLayout(() => provider.setPaddingLeft(value)),
      onPaddingRightChanged: (value) =>
          updateLayout(() => provider.setPaddingRight(value)),
      onHeaderPaddingTopChanged: (value) =>
          updateLayout(() => provider.setHeaderPaddingTop(value)),
      onHeaderPaddingBottomChanged: (value) =>
          updateLayout(() => provider.setHeaderPaddingBottom(value)),
      onHeaderPaddingLeftChanged: provider.setHeaderPaddingLeft,
      onHeaderPaddingRightChanged: provider.setHeaderPaddingRight,
      onFooterPaddingTopChanged: (value) =>
          updateLayout(() => provider.setFooterPaddingTop(value)),
      onFooterPaddingBottomChanged: (value) =>
          updateLayout(() => provider.setFooterPaddingBottom(value)),
      onFooterPaddingLeftChanged: provider.setFooterPaddingLeft,
      onFooterPaddingRightChanged: provider.setFooterPaddingRight,
      onShowHeaderLineChanged: (value) =>
          updateLayout(() => provider.setShowHeaderLine(value)),
      onShowFooterLineChanged: (value) =>
          updateLayout(() => provider.setShowFooterLine(value)),
      onHeaderModeChanged: (value) =>
          updateLayout(() => provider.setHeaderMode(value)),
      onFooterModeChanged: (value) =>
          updateLayout(() => provider.setFooterMode(value)),
      onTipHeaderLeftChanged: provider.setTipHeaderLeft,
      onTipHeaderMiddleChanged: provider.setTipHeaderMiddle,
      onTipHeaderRightChanged: provider.setTipHeaderRight,
      onTipFooterLeftChanged: provider.setTipFooterLeft,
      onTipFooterMiddleChanged: provider.setTipFooterMiddle,
      onTipFooterRightChanged: provider.setTipFooterRight,
      onHeaderFontSizeChanged: (value) =>
          updateLayout(() => provider.setHeaderFontSize(value)),
      onFooterFontSizeChanged: (value) =>
          updateLayout(() => provider.setFooterFontSize(value)),
      onClose: onClose,
    );
  }

  void _showMoreSettingsDialog(ReaderProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return SafeArea(
              child: ListView(
                controller: scrollController,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(DesignTokens.spacingLg),
                    child: Text(
                      '更多设置',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  // 行距设置
                  ListTile(
                    leading: const Icon(Icons.format_line_spacing),
                    title: const Text('行距设置'),
                    subtitle: const Text('调整行高和段间距'),
                    onTap: () {
                      Navigator.pop(context);
                      _showSpacingDialog(provider);
                    },
                  ),
                  // 亮度设置
                  ListTile(
                    leading: const Icon(Icons.brightness_6),
                    title: const Text('亮度设置'),
                    subtitle: const Text('调整屏幕亮度'),
                    onTap: () {
                      Navigator.pop(context);
                      _showBrightnessDialog(provider);
                    },
                  ),
                  // 缓存管理
                  ListTile(
                    leading: const Icon(Icons.download),
                    title: const Text('缓存管理'),
                    subtitle: const Text('下载和清理章节缓存'),
                    onTap: () {
                      Navigator.pop(context);
                      _showCacheOptions();
                    },
                  ),
                  // Tap zone configuration
                  ListTile(
                    leading: const Icon(Icons.touch_app),
                    title: const Text('点击区域设置'),
                    subtitle: const Text('自定义九宫格点击动作'),
                    onTap: () {
                      Navigator.pop(context);
                      _showTapZoneConfigDialog(provider);
                    },
                  ),
                  // Highlight rules
                  ListTile(
                    leading: const Icon(Icons.highlight),
                    title: const Text('高亮规则'),
                    subtitle: const Text('管理正则高亮规则'),
                    onTap: () {
                      Navigator.pop(context);
                      _showHighlightRulesDialog(provider);
                    },
                  ),
                  // Font overrides (for EPUB)
                  if (_book != null &&
                      LocalBookService.detectBookType(_book!.bookUrl) ==
                          LocalBookType.epub)
                    ListTile(
                      leading: const Icon(Icons.font_download),
                      title: const Text('字体覆盖'),
                      subtitle: const Text('覆盖EPUB内嵌字体'),
                      onTap: () {
                        Navigator.pop(context);
                        _showFontOverrideDialog(provider);
                      },
                    ),
                  // Reset settings
                  ListTile(
                    leading: const Icon(Icons.restore),
                    title: const Text('重置阅读设置'),
                    onTap: () {
                      provider.setFontSize(18.0);
                      provider.setLineHeight(1.5);
                      provider.setLetterSpacing(0.0);
                      provider.setParagraphSpacing(8.0);
                      provider.setTextIndent(2.0);
                      provider.setBackgroundColor(const Color(0xFFFFF8E1));
                      // 屏幕亮度需用 setScreenBrightness（写入 _screenBrightness 字段），
                      // 旧代码调用的 setBrightness 写的是另一个未生效字段 _brightness
                      provider.setScreenBrightness(1.0);
                      // 当前在夜间模式时需同步退出，否则背景变浅黄但 textColor 仍为白
                      if (provider.isNightMode) {
                        provider.toggleNightMode();
                      }
                      Navigator.pop(context);
                      // 重置后必须重新分页，否则 PageView/仿真模式仍按旧设置计算分页
                      _repaginatePreservingPosition();
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showTapZoneConfigDialog(ReaderProvider provider) {
    final actionLabels = {
      TapZoneAction.none: '无',
      TapZoneAction.showMenu: '菜单',
      TapZoneAction.previousPage: '上页',
      TapZoneAction.nextPage: '下页',
      TapZoneAction.previousChapter: '上章',
      TapZoneAction.nextChapter: '下章',
    };

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('点击区域设置'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('点击区域对应动作：'),
                  const SizedBox(height: DesignTokens.spacingSm),
                  ...List.generate(3, (row) {
                    return Row(
                      children: List.generate(3, (col) {
                        final action = provider.tapZoneActions[row][col];
                        return Expanded(
                          child: GestureDetector(
                            onTap: () async {
                              await _showTapZoneActionPicker(
                                provider,
                                row,
                                col,
                                actionLabels,
                              );
                              if (mounted) setDialogState(() {});
                            },
                            child: Container(
                              margin: const EdgeInsets.all(2),
                              padding: const EdgeInsets.all(
                                DesignTokens.spacingSm,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(
                                  DesignTokens.actionRadius,
                                ),
                                color: row == 1 && col == 1
                                    ? Theme.of(context).colorScheme.primary
                                          .withValues(alpha: 0.1)
                                    : null,
                              ),
                              child: Text(
                                actionLabels[action] ?? '无',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: DesignTokens.fontCaption,
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    );
                  }),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    // Reset to default
                    provider.setTapZoneAction(0, 0, TapZoneAction.none);
                    provider.setTapZoneAction(0, 1, TapZoneAction.previousPage);
                    provider.setTapZoneAction(0, 2, TapZoneAction.none);
                    provider.setTapZoneAction(1, 0, TapZoneAction.previousPage);
                    provider.setTapZoneAction(1, 1, TapZoneAction.showMenu);
                    provider.setTapZoneAction(1, 2, TapZoneAction.nextPage);
                    provider.setTapZoneAction(2, 0, TapZoneAction.none);
                    provider.setTapZoneAction(2, 1, TapZoneAction.nextPage);
                    provider.setTapZoneAction(2, 2, TapZoneAction.none);
                    setDialogState(() {});
                  },
                  child: const Text('恢复默认'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showTapZoneActionPicker(
    ReaderProvider provider,
    int row,
    int col,
    Map<TapZoneAction, String> actionLabels,
  ) {
    return showDialog(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text('区域 (${row + 1},${col + 1}) 动作'),
          children: TapZoneAction.values.map((action) {
            return SimpleDialogOption(
              onPressed: () {
                provider.setTapZoneAction(row, col, action);
                Navigator.pop(context);
              },
              child: Text(actionLabels[action] ?? '无'),
            );
          }).toList(),
        );
      },
    );
  }

  void _showHighlightRulesDialog(ReaderProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return StatefulBuilder(
              builder: (context, setSheetState) {
                // 每次重建都从 provider 重新读取，确保添加/删除后列表立即更新
                final rules = provider.highlightRules;
                return SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(DesignTokens.spacingLg),
                        child: Row(
                          children: [
                            Text(
                              '高亮规则',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.add),
                              onPressed: () async {
                                await _showAddHighlightRuleDialog(provider);
                                if (mounted) setSheetState(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                      const Divider(),
                      Expanded(
                        child: ListView.builder(
                          controller: scrollController,
                          itemCount: rules.length,
                          itemBuilder: (context, index) {
                            final rule = rules[index];
                            // SwitchListTile 没有 trailing 参数，用 ListTile + Switch + IconButton 自己布局
                            return ListTile(
                              title: Text(rule.name),
                              subtitle: Text(
                                rule.pattern,
                                style: const TextStyle(
                                  fontSize: DesignTokens.fontCaption,
                                  fontFamily: 'monospace',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // 自定义规则提供删除入口
                                  if (!rule.isBuiltIn)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: 20,
                                      ),
                                      onPressed: () {
                                        showDialog<bool>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: const Text('删除规则'),
                                            content: Text('确定删除「${rule.name}」吗？'),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, false),
                                                child: const Text('取消'),
                                              ),
                                              TextButton(
                                                onPressed: () {
                                                  provider.removeHighlightRule(
                                                    rule.id,
                                                  );
                                                  Navigator.pop(ctx, true);
                                                  setSheetState(() {});
                                                },
                                                child: const Text('删除'),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  Switch(
                                    value: rule.enabled,
                                    // 自定义规则允许切换 enabled；内置规则保持只读
                                    onChanged: rule.isBuiltIn
                                        ? null
                                        : (value) {
                                            // 直接通过 provider 翻转（内部已 _saveToStorage），避免重复 IO 与状态反转
                                            provider.toggleHighlightRule(rule.id);
                                            setSheetState(() {});
                                            // 高亮规则变化会触发 WebView 重新加载，保留当前阅读位置
                                            _repaginatePreservingPosition();
                                          },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _showAddHighlightRuleDialog(ReaderProvider provider) {
    final nameController = TextEditingController();
    final patternController = TextEditingController();
    var selectedColor = HighlightColor.yellow;
    var selectedStyle = HighlightStyle.background;

    // 在 Navigator.pop 后通过 addPostFrameCallback dispose，
    // 避免在 dialog 重建过程中引用已 dispose 的 controller
    void disposeControllers() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        nameController.dispose();
        patternController.dispose();
      });
    }

    return showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('添加高亮规则'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: '规则名称'),
                    ),
                    TextField(
                      controller: patternController,
                      decoration: const InputDecoration(
                        labelText: '正则表达式',
                        hintText: r'如：「[^」]+」',
                      ),
                    ),
                    const SizedBox(height: DesignTokens.spacingLg),
                    // Color picker
                    const Text('高亮颜色'),
                    Wrap(
                      spacing: 8,
                      children: HighlightColor.values.map((c) {
                        return GestureDetector(
                          onTap: () {
                            selectedColor = c;
                            setDialogState(() {});
                          },
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: c.color,
                              shape: BoxShape.circle,
                              border: selectedColor == c
                                  ? Border.all(color: Colors.black, width: 2)
                                  : null,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: DesignTokens.spacingLg),
                    // Style picker
                    const Text('高亮样式'),
                    Wrap(
                      spacing: 8,
                      children: HighlightStyle.values.map((s) {
                        final labels = ['背景色', '下划线', '删除线', '波浪线'];
                        return ChoiceChip(
                          label: Text(labels[s.index]),
                          selected: selectedStyle == s,
                          onSelected: (_) {
                            selectedStyle = s;
                            setDialogState(() {});
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    disposeControllers();
                  },
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () {
                    if (nameController.text.isEmpty ||
                        patternController.text.isEmpty) {
                      return;
                    }
                    // 验证正则表达式有效性，无效时提示用户而不是创建永远失败的规则
                    try {
                      RegExp(patternController.text);
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('正则表达式无效: $e')),
                      );
                      return;
                    }
                    final rule = HighlightRule(
                      id: DateTime.now().millisecondsSinceEpoch.toString(),
                      name: nameController.text,
                      pattern: patternController.text,
                      style: selectedStyle,
                      color: selectedColor,
                      enabled: true,
                      isBuiltIn: false,
                      serialNumber: provider.highlightRules.length,
                    );
                    StorageService.instance.saveHighlightRule(rule.toJson());
                    provider.addHighlightRule(rule);
                    Navigator.pop(context);
                    disposeControllers();
                  },
                  child: const Text('添加'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showFontOverrideDialog(ReaderProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            // 每次重建都从 provider 重新拉取最新副本，确保添加/删除后立即同步
            final overrides = provider.fontOverrides;
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(DesignTokens.spacingLg),
                    child: Row(
                      children: [
                        Text(
                          '字体覆盖',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: () async {
                            await _showAddFontOverrideDialog(provider);
                            if (mounted) setSheetState(() {});
                          },
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                  if (overrides.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('暂无字体覆盖规则'),
                    )
                  else
                    ...overrides.entries.map((entry) {
                      return ListTile(
                        title: Text(entry.key),
                        subtitle: Text('→ ${entry.value}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, size: 20),
                          onPressed: () {
                            provider.removeFontOverride(entry.key);
                            setSheetState(() {});
                          },
                        ),
                      );
                    }),
                  const SizedBox(height: DesignTokens.spacingLg),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showAddFontOverrideDialog(ReaderProvider provider) {
    final originalController = TextEditingController();
    final overrideController = TextEditingController();

    void disposeControllers() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        originalController.dispose();
        overrideController.dispose();
      });
    }

    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('添加字体覆盖'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: originalController,
                decoration: const InputDecoration(
                  labelText: '原字体名',
                  hintText: 'EPUB中的字体名称',
                ),
              ),
              TextField(
                controller: overrideController,
                decoration: const InputDecoration(
                  labelText: '替换字体',
                  hintText: '替换为的字体名称',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                disposeControllers();
              },
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                if (originalController.text.isEmpty ||
                    overrideController.text.isEmpty) {
                  return;
                }
                provider.setFontOverride(
                  originalController.text,
                  overrideController.text,
                );
                Navigator.pop(context);
                disposeControllers();
              },
              child: const Text('添加'),
            ),
          ],
        );
      },
    );
  }
}

// ==================== Helper Classes ====================

class _NovelChapterListPanel extends StatefulWidget {
  final Book? book;
  final List<Chapter> chapters;
  final int totalChapters;
  final int currentChapterIndex;
  final Color foregroundColor;
  final Function(int) onChapterSelected;
  // 书签增删后通知父页面（父页面顶栏书签图标需要同步刷新）
  final VoidCallback? onBookmarksChanged;

  const _NovelChapterListPanel({
    this.book,
    required this.chapters,
    required this.totalChapters,
    required this.currentChapterIndex,
    required this.foregroundColor,
    required this.onChapterSelected,
    this.onBookmarksChanged,
  });

  @override
  State<_NovelChapterListPanel> createState() => _NovelChapterListPanelState();
}

class _NovelChapterListPanelState extends State<_NovelChapterListPanel> {
  int _currentTab = 0;
  bool _showSearch = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Set<String> _cachedFiles = {};
  List<Bookmark> _bookmarks = [];
  bool _isReversed = false;
  bool _showWordCount = false;
  bool _useReplace = false;
  bool _foldVolume = true;
  bool _searchChapterName = true;
  bool _searchBookText = true;
  bool _searchContent = true;
  final Set<int> _expandedVolumes = {};
  final ScrollController _chapterScrollController = ScrollController();
  final Map<int, GlobalKey> _chapterKeys = {};
  bool _didScrollToCurrentChapter = false;

  @override
  void initState() {
    super.initState();
    _loadCacheInfo();
    _loadBookmarks();
    _loadPrefs();
  }

  @override
  void dispose() {
    _chapterScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showWordCount = prefs.getBool('tocShowWordCount') ?? false;
      _useReplace = prefs.getBool('tocUseReplace') ?? false;
      _foldVolume = prefs.getBool('tocFoldVolume') ?? true;
      _isReversed =
          prefs.getBool('tocReverse_${widget.book?.bookUrl ?? ""}') ?? false;
      _expandCurrentVolume();
    });
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _loadCacheInfo() async {
    if (widget.book == null || widget.book!.originType != BookOriginType.online)
      return;
    final files = await ChapterCacheService.instance.getChapterCacheFiles(
      widget.book!,
    );
    if (mounted) setState(() => _cachedFiles = files);
  }

  Future<void> _loadBookmarks() async {
    if (widget.book == null) return;
    final bookmarks = await ReaderBookmarkService().list(widget.book!.bookUrl);
    if (mounted) setState(() => _bookmarks = bookmarks);
  }

  List<Chapter> get _filteredChapters {
    var list = widget.chapters;
    if (_isReversed) list = list.reversed.toList();
    if (_searchQuery.isEmpty) return list;
    final query = _searchQuery.toLowerCase();
    return list.where((c) => c.title.toLowerCase().contains(query)).toList();
  }

  List<Chapter> _buildDisplayChapters(List<Chapter> source) {
    if (!_foldVolume) return source;
    final result = <Chapter>[];
    var i = 0;
    while (i < source.length) {
      final ch = source[i];
      if (ch.isVolume) {
        result.add(ch);
        final isExpanded = _expandedVolumes.contains(ch.index);
        if (!isExpanded) {
          i++;
          while (i < source.length && !source[i].isVolume) {
            i++;
          }
          continue;
        }
      }
      result.add(ch);
      i++;
    }
    return result;
  }

  void _expandCurrentVolume() {
    var volumeIndex = -1;
    for (final chapter in widget.chapters) {
      if (chapter.isVolume) volumeIndex = chapter.index;
      if (chapter.index == widget.currentChapterIndex) break;
    }
    if (volumeIndex >= 0) _expandedVolumes.add(volumeIndex);
  }

  bool _isCurrentVolume(int volumeIndex) {
    var activeVolume = -1;
    for (final chapter in widget.chapters) {
      if (chapter.isVolume) activeVolume = chapter.index;
      if (chapter.index == widget.currentChapterIndex) {
        return activeVolume == volumeIndex;
      }
    }
    return false;
  }

  List<Bookmark> get _filteredBookmarks {
    if (_searchQuery.isEmpty) return _bookmarks;
    final query = _searchQuery.toLowerCase();
    return _bookmarks.where((b) {
      bool hit = false;
      if (_searchChapterName && b.chapterTitle.toLowerCase().contains(query))
        hit = true;
      if (_searchBookText && b.content.toLowerCase().contains(query))
        hit = true;
      if (_searchContent && (b.note?.toLowerCase().contains(query) ?? false))
        hit = true;
      return hit;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.foregroundColor;
    final isOnline = widget.book?.originType == BookOriginType.online;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: DesignTokens.spacingLg,
            vertical: 8,
          ),
          child: Row(
            children: [
              _buildTab(0, '目录 (${widget.chapters.length})', fg),
              const SizedBox(width: 16),
              _buildTab(1, '书签 (${_bookmarks.length})', fg),
              const Spacer(),
              IconButton(
                icon: Icon(_showSearch ? Icons.close : Icons.search, color: fg),
                onPressed: () => setState(() {
                  _showSearch = !_showSearch;
                  if (!_showSearch) {
                    _searchController.clear();
                    _searchQuery = '';
                  }
                }),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: fg),
                tooltip: '更多',
                offset: const Offset(0, 48),
                onSelected: _handleMenuAction,
                itemBuilder: _currentTab == 0
                    ? (context) => [
                        _menuItem('reverse', '反转目录', _isReversed, fg),
                        _menuItem('use_replace', '使用替换', _useReplace, fg),
                        _menuItem('word_count', '加载字数', _showWordCount, fg),
                        _menuItem('fold_volume', '卷名折叠', _foldVolume, fg),
                      ]
                    : (context) => [
                        const PopupMenuItem(
                          value: 'export',
                          padding: EdgeInsets.symmetric(
                            horizontal: DesignTokens.spacingLg,
                            vertical: 12,
                          ),
                          child: Text('导出'),
                        ),
                        const PopupMenuItem(
                          value: 'export_md',
                          padding: EdgeInsets.symmetric(
                            horizontal: DesignTokens.spacingLg,
                            vertical: 12,
                          ),
                          child: Text('导出(MD)'),
                        ),
                        const PopupMenuDivider(),
                        _menuItem(
                          'bm_search_chapter',
                          '搜索章节名',
                          _searchChapterName,
                          fg,
                        ),
                        _menuItem(
                          'bm_search_text',
                          '搜索书文',
                          _searchBookText,
                          fg,
                        ),
                        _menuItem('bm_search_note', '搜索备注', _searchContent, fg),
                      ],
              ),
            ],
          ),
        ),
        if (_showSearch)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: DesignTokens.spacingLg,
            ),
            child: TextField(
              controller: _searchController,
              style: TextStyle(color: fg),
              decoration: InputDecoration(
                hintText: '搜索...',
                hintStyle: TextStyle(color: fg.withValues(alpha: 0.5)),
                border: InputBorder.none,
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
        Divider(height: 1, color: fg.withValues(alpha: 0.12)),
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.5,
          child: _currentTab == 0
              ? _buildChapterList(fg, isOnline)
              : _buildBookmarkList(fg),
        ),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    String label,
    bool checked,
    Color fg,
  ) {
    return PopupMenuItem(
      value: value,
      padding: const EdgeInsets.symmetric(
        horizontal: DesignTokens.spacingLg,
        vertical: 12,
      ),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          if (checked) Icon(Icons.check, size: 20, color: fg),
        ],
      ),
    );
  }

  Widget _buildTab(int index, String text, Color fg) {
    final selected = _currentTab == index;
    final accent = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: () => setState(() => _currentTab = index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: TextStyle(
              color: selected ? fg : fg.withValues(alpha: 0.5),
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          if (selected)
            Container(
              margin: const EdgeInsets.only(top: 4),
              width: 24,
              height: 2,
              color: accent,
            ),
        ],
      ),
    );
  }

  Widget _buildChapterList(Color fg, bool isOnline) {
    final display = _buildDisplayChapters(_filteredChapters);
    final accent = Theme.of(context).colorScheme.primary;
    _scheduleScrollToCurrentChapter(display);
    return ListView.separated(
      controller: _chapterScrollController,
      itemCount: display.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, thickness: 0.5, color: fg.withValues(alpha: 0.12)),
      itemBuilder: (context, index) {
        final chapter = display[index];
        if (chapter.isVolume) {
          final isExpanded = _expandedVolumes.contains(chapter.index);
          final isCurrentVolume = _isCurrentVolume(chapter.index);
          return InkWell(
            onTap: () => setState(() {
              if (isExpanded) {
                _expandedVolumes.remove(chapter.index);
              } else {
                _expandedVolumes.add(chapter.index);
              }
            }),
            child: Container(
              padding: const EdgeInsets.all(12),
              color: isCurrentVolume
                  ? accent.withValues(alpha: 0.1)
                  : Colors.transparent,
              child: Row(
                children: [
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 180),
                    turns: isExpanded ? 0.25 : 0,
                    child: Icon(
                      Icons.arrow_right,
                      color: isCurrentVolume ? accent : fg,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      chapter.title,
                      style: TextStyle(
                        color: isCurrentVolume ? accent : fg,
                        fontSize: DesignTokens.fontBody,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final isSelected = chapter.index == widget.currentChapterIndex;
        final fileName = ChapterCacheService.instance.getChapterFileName(
          chapter,
        );
        final isCached = !isOnline || _cachedFiles.contains(fileName);

        final selectedBg = Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.12)
            : accent.withValues(alpha: 0.10);
        final selectedText = Theme.of(context).brightness == Brightness.dark
            ? fg
            : accent;

        return InkWell(
          onTap: () => widget.onChapterSelected(chapter.index),
          child: Container(
            key: _keyForChapter(chapter.index),
            color: isSelected ? selectedBg : Colors.transparent,
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                if (chapter.isVip && !chapter.isPay)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: fg.withValues(alpha: 0.62),
                    ),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chapter.title,
                        style: TextStyle(
                          color: isSelected ? selectedText : fg,
                          fontSize: DesignTokens.fontBody,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if ((chapter.tag?.isNotEmpty ?? false) ||
                          (_showWordCount && (chapter.wordCount ?? 0) > 0))
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            [
                              if (chapter.tag?.isNotEmpty == true) chapter.tag!,
                              if (_showWordCount &&
                                  (chapter.wordCount ?? 0) > 0)
                                '${chapter.wordCount}字',
                            ].join('  '),
                            style: TextStyle(
                              color: fg.withValues(alpha: 0.62),
                              fontSize: DesignTokens.fontCaption,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: DesignTokens.spacingSm),
                if (isSelected)
                  Icon(Icons.check, size: 18, color: selectedText)
                else if (!isCached)
                  Icon(
                    Icons.cloud_outlined,
                    size: 18,
                    color: fg.withValues(alpha: 0.62),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  GlobalKey _keyForChapter(int index) {
    return _chapterKeys.putIfAbsent(index, GlobalKey.new);
  }

  void _scheduleScrollToCurrentChapter(List<Chapter> display) {
    if (_didScrollToCurrentChapter ||
        _currentTab != 0 ||
        _searchQuery.isNotEmpty ||
        display.isEmpty) {
      return;
    }
    final displayIndex = display.indexWhere(
      (c) => c.index == widget.currentChapterIndex,
    );
    if (displayIndex < 0) return;
    _didScrollToCurrentChapter = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_chapterScrollController.hasClients) {
        final roughOffset = max(0.0, (displayIndex - 2) * 56.0);
        _chapterScrollController.jumpTo(
          roughOffset.clamp(
            0.0,
            _chapterScrollController.position.maxScrollExtent,
          ),
        );
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = _chapterKeys[widget.currentChapterIndex]?.currentContext;
        if (ctx == null) return;
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.45,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      });
    });
  }

  Widget _buildBookmarkList(Color fg) {
    if (_bookmarks.isEmpty) {
      return Center(
        child: Text('暂无书签', style: TextStyle(color: fg.withValues(alpha: 0.5))),
      );
    }
    final list = _searchQuery.isEmpty ? _bookmarks : _filteredBookmarks;
    if (list.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的书签',
          style: TextStyle(color: fg.withValues(alpha: 0.5)),
        ),
      );
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, index) {
        final bookmark = list[index];
        return ListTile(
          title: Text(bookmark.chapterTitle, style: TextStyle(color: fg)),
          subtitle: Text(
            bookmark.note?.isNotEmpty == true
                ? bookmark.note!
                : bookmark.content,
            style: TextStyle(color: fg.withValues(alpha: 0.6)),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            _formatTime(bookmark.createdAt),
            style: TextStyle(
              color: fg.withValues(alpha: 0.5),
              fontSize: DesignTokens.fontCaption,
            ),
          ),
          onTap: () {
            Navigator.pop(context);
            widget.onChapterSelected(bookmark.chapterIndex);
          },
          onLongPress: () => _deleteBookmark(bookmark),
        );
      },
    );
  }

  void _handleMenuAction(String action) {
    setState(() {
      switch (action) {
        case 'reverse':
          _isReversed = !_isReversed;
          _saveBool('tocReverse_${widget.book?.bookUrl ?? ""}', _isReversed);
          break;
        case 'use_replace':
          _useReplace = !_useReplace;
          _saveBool('tocUseReplace', _useReplace);
          break;
        case 'word_count':
          _showWordCount = !_showWordCount;
          _saveBool('tocShowWordCount', _showWordCount);
          break;
        case 'fold_volume':
          _foldVolume = !_foldVolume;
          _saveBool('tocFoldVolume', _foldVolume);
          break;
        case 'bm_search_chapter':
          _searchChapterName = !_searchChapterName;
          break;
        case 'bm_search_text':
          _searchBookText = !_searchBookText;
          break;
        case 'bm_search_note':
          _searchContent = !_searchContent;
          break;
        case 'export':
          _exportBookmarks(false);
          break;
        case 'export_md':
          _exportBookmarks(true);
          break;
      }
    });
  }

  Future<void> _exportBookmarks(bool asMd) async {
    if (_bookmarks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂无书签可导出')));
      }
      return;
    }

    String text;
    if (asMd) {
      final buffer = StringBuffer();
      for (final b in _bookmarks) {
        buffer.writeln('## ${b.chapterTitle}');
        if (b.note?.isNotEmpty == true) buffer.writeln('> ${b.note}');
        buffer.writeln(b.content);
        buffer.writeln();
      }
      text = buffer.toString();
    } else {
      final data = _bookmarks.map((b) => b.toJson()).toList();
      text = const JsonEncoder.withIndent('  ').convert(data);
    }

    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(asMd ? '书签已导出为MD' : '书签已复制到剪贴板')));
    }
  }

  void _deleteBookmark(Bookmark bookmark) {
    final book = widget.book;
    if (book == null) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除书签'),
        content: const Text('确定要删除这个书签吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await ReaderBookmarkService().remove(
                bookUrl: book.bookUrl,
                bookmarkId: bookmark.id,
              );
              _loadBookmarks();
              // 通知父页面顶栏书签图标重新检查当前章节书签状态
              widget.onBookmarksChanged?.call();
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
