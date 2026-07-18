import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  // 下一章预加载缓存
  String? _nextContent;
  int? _nextContentChapterIndex;
  // 上一章缓存（用于滚动模式往上滑无缝衔接）
  String? _prevContent;
  int? _prevContentChapterIndex;
  int _chapterLoadToken = 0;
  // 预加载防重入标志位（避免滚动时多次触发 _preloadNextChapter/_preloadPrevChapter
  // 导致重复 getContent 请求）
  bool _isLoadingNext = false;
  bool _isLoadingPrev = false;

  // Pagination for non-scroll modes
  List<String> _pages = [];
  int _currentPage = 0;
  PageController? _pageController;

  // Scroll mode controller
  final ScrollController _scrollController = ScrollController();
  // 标记当前章节内容的边界，用于检测滚动到下一章
  final GlobalKey _currentChapterKey = GlobalKey();
  // 标记上一章缓存块的边界，用于跨章切换时测量其高度
  final GlobalKey _prevChapterKey = GlobalKey();
  // 跨章切换时临时禁用 _onScroll，避免在 jumpTo 期间误触发预加载或二次切章
  bool _isSwitchingChapter = false;

  // Animation
  late AnimationController _menuAnimController;

  // Simulation page curl
  double _dragStartX = 0;
  double _dragCurrentX = 0;
  bool _isDragging = false;

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

  @override
  void initState() {
    super.initState();
    _currentChapterIndex = widget.resumeProgress ? 0 : widget.chapterIndex;
    _sliderValue = _currentChapterIndex.toDouble();
    _readStartTime = ReadRecordService.instance.startReading();

    _menuAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );

    _scrollController.addListener(_onScroll);
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _loadBookAndChapters();
    _loadReaderContentOptions();
    _initTts();
    _checkBookmark();
  }

  @override
  void dispose() {
    _progressSaveTimer?.cancel();
    _clockTimer?.cancel();
    _autoScrollTimer?.cancel();
    _scrollProgressNotifier.dispose();
    _menuAnimController.dispose();
    _scrollController.dispose();
    _pageController?.dispose();
    context.read<ReaderProvider>().disposeTts();
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
    if (_isScrollLikeMode(provider)) {
      _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
        if (!mounted || !_isAutoScroll || _isLoading) return;
        // 跨章切换期间禁用滚动驱动，避免 jumpTo 与 timer 冲突
        if (_isSwitchingChapter) return;
        if (!_scrollController.hasClients) return;
        final position = _scrollController.position;
        final step = 0.8 + provider.autoScrollSpeed * 0.055;
        if (position.pixels < position.maxScrollExtent) {
          _scrollController.jumpTo(
            min(position.pixels + step, position.maxScrollExtent),
          );
        } else if (_nextContent != null &&
            _nextContentChapterIndex != null) {
          // 已预加载下一章，主动走无缝切换（_nextPage 在到底部时会走 _nextChapter 重新 load）
          _switchToPreloadedChapter();
        } else if (_nextReadableChapterIndex(_currentChapterIndex) != null) {
          _nextChapter();
        } else {
          _stopAutoScroll();
        }
      });
      return;
    }
    final configured = provider.autoPageIntervalSeconds;
    final seconds = configured > 0
        ? configured
        : (12 - provider.autoScrollSpeed ~/ 10).clamp(2, 11);
    _autoScrollTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (!mounted || !_isAutoScroll || _isLoading) return;
      final atBookEnd =
          _currentPage >= _pages.length - 1 &&
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
    final provider = context.read<ReaderProvider>();
    if (_isScrollLikeMode(provider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final fraction = contentLength == 0 ? 0.0 : offset / contentLength;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent * fraction,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
      });
      return;
    }

    var seen = 0;
    var targetPage = 0;
    var found = false;
    for (var pageIndex = 0; pageIndex < _pages.length; pageIndex++) {
      var start = 0;
      while (start < _pages[pageIndex].length) {
        final match = _pages[pageIndex].indexOf(query, start);
        if (match < 0) break;
        if (seen == occurrence) {
          targetPage = pageIndex;
          found = true;
          break;
        }
        seen++;
        start = match + max(query.length, 1);
      }
      if (found) break;
    }
    setState(() => _currentPage = targetPage);
    if (provider.pageMode == PageMode.simulation) return;
    if (_pageController?.hasClients == true) {
      _pageController!.jumpToPage(targetPage + _pagedLeadingCount);
    } else {
      _swapPageController(targetPage + _pagedLeadingCount);
    }
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

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final provider = context.read<ReaderProvider>();
    if (!_isScrollLikeMode(provider)) return;
    // 跨章切换期间（jumpTo 调整 offset）禁用滚动监听，避免误触发二次切章或预加载
    if (_isSwitchingChapter) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    final progress = maxScroll <= 0
        ? 0.0
        : (currentScroll / maxScroll).clamp(0.0, 1.0);
    if ((progress - _scrollProgress).abs() >= 0.01) {
      _scrollProgressNotifier.value = progress;
    }
    _scheduleProgressSave(pos: currentScroll.round());

    // 检测是否已滚动到下一章内容区域
    if (_nextContent != null && _nextContentChapterIndex != null) {
      final chapterContext = _currentChapterKey.currentContext;
      if (chapterContext != null) {
        final renderBox = chapterContext.findRenderObject() as RenderBox;
        // 获取当前章节内容的底部在视口中的位置
        final chapterBottom = renderBox.localToGlobal(
          Offset(0, renderBox.size.height),
        );
        // 如果当前章节底部已在视口顶部上方，说明用户已滚动到下一章
        if (chapterBottom.dy < 100) {
          _switchToPreloadedChapter();
          return;
        }
      }
    }

    // 检测是否已滚动到上一章内容区域
    if (_prevContent != null && _prevContentChapterIndex != null) {
      final chapterContext = _currentChapterKey.currentContext;
      if (chapterContext != null) {
        final renderBox = chapterContext.findRenderObject() as RenderBox;
        // 获取当前章节内容的顶部在视口中的位置
        final chapterTop = renderBox.localToGlobal(Offset.zero);
        // 如果当前章节顶部在视口底部下方，说明用户已滚动到上一章
        if (chapterTop.dy > MediaQuery.of(context).size.height - 100) {
          _switchToPrevChapter();
          return;
        }
      }
    }

    // Auto-load next chapter when near bottom
    // 阈值基于视口尺寸，确保用户接近底部时预加载已完成
    final viewport = _scrollController.position.viewportDimension;
    final preloadThreshold = viewport * 1.5;
    if (maxScroll - currentScroll < preloadThreshold && _nextContent == null) {
      _preloadNextChapter();
    }

    // 接近顶部时预加载上一章
    if (currentScroll < viewport * 1.5 && _prevContent == null) {
      _preloadPrevChapter();
    }
  }

  /// 滚动模式下无缝切换到预加载的下一章
  void _switchToPreloadedChapter() {
    if (_nextContent == null || _nextContentChapterIndex == null) return;
    if (_isSwitchingChapter) return;
    _isSwitchingChapter = true;

    final provider = context.read<ReaderProvider>();
    final oldOffset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;

    // 测量原 prevContent 块高度（含相邻 padding，用于正确计算新 offset）
    double prevBlockHeight = 0;
    final prevContext = _prevChapterKey.currentContext;
    if (prevContext != null) {
      final renderBox = prevContext.findRenderObject() as RenderBox;
      prevBlockHeight = renderBox.size.height;
    }
    // 测量原当前章块高度（不含 padding，因为当前章块直接是 Container）
    double currentChapterHeight = 0;
    final currentContext = _currentChapterKey.currentContext;
    if (currentContext != null) {
      final renderBox = currentContext.findRenderObject() as RenderBox;
      currentChapterHeight = renderBox.size.height;
    }

    // 计算用户在原 nextContent 内的偏移（相对 nextContent 开头）
    final nextContentInnerOffset = max(
      0.0,
      oldOffset - prevBlockHeight - currentChapterHeight,
    );

    // 更新状态：将下一章设为当前章，当前章变为上一章缓存
    setState(() {
      _prevContent = _content;
      _prevContentChapterIndex = _currentChapterIndex;
      _currentChapterIndex = _nextContentChapterIndex!;
      _chapterTitle = _chapters[_currentChapterIndex].title;
      _content = _nextContent!;
      _nextContent = null;
      _nextContentChapterIndex = null;
      _sliderValue = _currentChapterIndex.toDouble();
    });

    // 新布局里新当前章（原 nextContent）开头的 offset =
    // 新 prevContent 块高度 = 相邻 padding + 原当前章高度
    final newPrevBlockHeight =
        provider.paragraphSpacing * 2 + currentChapterHeight;
    final newOffset = newPrevBlockHeight + nextContentInnerOffset;

    // 立即同步 jumpTo，避免 setState 后到下一帧之间渲染一帧错误位置
    // （jumpTo 在新内容布局完成前可能被 clamp，下一帧再纠正）
    if (_scrollController.hasClients) {
      try {
        _scrollController.jumpTo(newOffset);
      } catch (_) {}
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _isSwitchingChapter = false;
          return;
        }
        if (_scrollController.hasClients &&
            (_scrollController.offset - newOffset).abs() > 1) {
          _scrollController.jumpTo(newOffset);
        }
        _isSwitchingChapter = false;
      });
    } else {
      _isSwitchingChapter = false;
    }

    _preloadNextChapter();
    _scheduleProgressSave(pos: newOffset.round());
  }

  /// 滚动模式下无缝切换到预加载的上一章
  void _switchToPrevChapter() {
    if (_prevContent == null || _prevContentChapterIndex == null) return;
    if (_isSwitchingChapter) return;
    _isSwitchingChapter = true;

    final provider = context.read<ReaderProvider>();
    final oldOffset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;

    // 用户原来在原当前章内的偏移（相对原当前章开头）
    // 原布局里原当前章开头 offset = 原 prevContent 块高度（如果有）
    double prevBlockHeight = 0;
    final prevContext = _prevChapterKey.currentContext;
    if (prevContext != null) {
      final renderBox = prevContext.findRenderObject() as RenderBox;
      prevBlockHeight = renderBox.size.height;
    }
    final currentChapterInnerOffset = max(
      0.0,
      oldOffset - prevBlockHeight,
    );

    // 更新状态：将上一章设为当前章，当前章变为下一章缓存
    setState(() {
      _nextContent = _content;
      _nextContentChapterIndex = _currentChapterIndex;
      _currentChapterIndex = _prevContentChapterIndex!;
      _chapterTitle = _chapters[_currentChapterIndex].title;
      _content = _prevContent!;
      _prevContent = null;
      _prevContentChapterIndex = null;
      _sliderValue = _currentChapterIndex.toDouble();
    });

    // 新布局 = [新当前章=原prevContent] + [新 nextContent 块（相邻 padding + 原当前章）]
    // 用户希望停留在原当前章内的相同视觉位置，现在变成新 nextContent 内偏移
    // 新 nextContent 块开头 offset = 新当前章高度（原 prevContent 高度）
    // 但我们无法在 setState 后立即测量新当前章高度，用相邻 padding + 原当前章高度近似
    // 新 nextContent 块开头 offset = 原prevContent块高度 - 相邻padding（因为原prevContent块含padding，新当前章不含padding）
    // 简化：新 offset = 原 prevContent 块高度（新当前章）+ 相邻 padding + 用户在原当前章内偏移
    final adjacentPadding = provider.paragraphSpacing * 2;
    // 新当前章高度 ≈ 原 prevContent 块高度 - 相邻 padding（因为原 prevContent 块含 padding）
    final newCurrentChapterHeight = max(0.0, prevBlockHeight - adjacentPadding);
    final newOffset =
        newCurrentChapterHeight + adjacentPadding + currentChapterInnerOffset;

    if (_scrollController.hasClients) {
      try {
        _scrollController.jumpTo(newOffset);
      } catch (_) {}
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _isSwitchingChapter = false;
          return;
        }
        if (_scrollController.hasClients &&
            (_scrollController.offset - newOffset).abs() > 1) {
          _scrollController.jumpTo(newOffset);
        }
        _isSwitchingChapter = false;
      });
    } else {
      _isSwitchingChapter = false;
    }

    _preloadPrevChapter();
    _scheduleProgressSave(pos: newOffset.round());
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

    final loadToken = ++_chapterLoadToken;
    final chapterIndex = _currentChapterIndex;
    // 同步捕获位置标志位并清空成员字段，防止被新 load 抢占后串到下一章
    final pendingToLast = _pendingInitialPageToEnd;
    final restoreInitial = _restoreInitialPosition;
    _pendingInitialPageToEnd = false;
    _restoreInitialPosition = false;
    setState(() {
      _isLoading = true;
      _sliderValue = _currentChapterIndex.toDouble();
      _nextContent = null;
      _nextContentChapterIndex = null;
      _prevContent = null;
      _prevContentChapterIndex = null;
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

        final provider = context.read<ReaderProvider>();
        final restorePos = pendingToLast
            ? 1 << 30
            : (restoreInitial ? _initialChapterPos : 0);
        _repaginate(initialPage: restorePos);

        // 滚动模式下重置滚动位置到顶部
        if (_isScrollLikeMode(provider)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _scrollController.hasClients) {
              final target = restorePos > 0 ? restorePos.toDouble() : 0.0;
              _scrollController.jumpTo(
                target.clamp(0.0, _scrollController.position.maxScrollExtent),
              );
            }
          });
        }

        // 用 clamp 后的真实位置保存到数据库，避免把 1<<30 写入 durChapterPos
        // 造成跨模式恢复时位置错误（_repaginate 已把 initialPage clamp 到 _pages.length-1）
        final actualPos = _isScrollLikeMode(provider)
            ? (_scrollController.hasClients
                  ? _scrollController.offset.round()
                  : 0)
            : _currentPage;
        unawaited(_saveCurrentProgress(chapter: chapter, pos: actualPos));
        unawaited(_preloadAdjacentChapters(_currentChapterIndex));

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
        final provider = context.read<ReaderProvider>();
        setState(() {
          _content = '加载失败：$e';
          _chapterTitle = '加载失败';
          _isLoading = false;
          if (!_isScrollLikeMode(provider)) {
            // 重建分页，避免翻页/仿真模式显示旧章节内容
            _pages = [_content];
            _currentPage = 0;
          }
        });
        if (!_isScrollLikeMode(provider)) {
          _swapPageController(_currentPage + _pagedLeadingCount);
        }
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
    var target = index.clamp(0, _chapters.length - 1);
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

  void _scheduleProgressSave({int? pos}) {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(const Duration(milliseconds: 700), () {
      unawaited(_saveCurrentProgress(pos: pos));
    });
  }

  Future<void> _saveCurrentProgress({Chapter? chapter, int? pos}) async {
    if (!mounted) return;
    final book = _book;
    if (book == null) return;
    final chapterTitle = chapter?.title ?? _chapterTitle;
    final chapterPos = pos ?? _currentChapterPos();

    _book = book.copyWith(
      durChapterIndex: _currentChapterIndex,
      durChapterTitle: chapterTitle,
      durChapterPos: chapterPos,
      durChapterTime: DateTime.now(),
    );

    await context.read<BookshelfProvider>().updateBookProgress(
      book.bookUrl,
      durChapterIndex: _currentChapterIndex,
      durChapterTitle: chapterTitle,
      durChapterPos: chapterPos,
    );
  }

  int _currentChapterPos() {
    final provider = context.read<ReaderProvider>();
    if (_isScrollLikeMode(provider) && _scrollController.hasClients) {
      return _scrollController.offset.round();
    }
    return _currentPage;
  }

  Future<void> _preloadAdjacentChapters(int chapterIndex) async {
    if (_book == null || _dataProvider == null) return;

    // 复用 _isLoadingNext / _isLoadingPrev 锁，避免与 _preloadNextChapter / _preloadPrevChapter
    // 并发触发导致重复 getContent 请求
    String? nextContent;
    final nextIndex = _nextReadableChapterIndex(chapterIndex);
    if (nextIndex != null && !_isLoadingNext && _nextContent == null) {
      _isLoadingNext = true;
      try {
        final nextChapter = _chapters[nextIndex];
        nextContent = await _dataProvider!.getContent(
          _book!,
          nextChapter,
          allChapters: _chapters,
        );
      } finally {
        _isLoadingNext = false;
      }
    }

    String? prevContent;
    final prevIndex = _previousReadableChapterIndex(chapterIndex);
    if (prevIndex != null && !_isLoadingPrev && _prevContent == null) {
      _isLoadingPrev = true;
      try {
        final prevChapter = _chapters[prevIndex];
        prevContent = await _dataProvider!.getContent(
          _book!,
          prevChapter,
          allChapters: _chapters,
        );
      } finally {
        _isLoadingPrev = false;
      }
    }

    if (!mounted || _currentChapterIndex != chapterIndex) return;
    setState(() {
      if (nextContent != null && _nextContent == null) {
        _nextContent = nextContent;
        _nextContentChapterIndex = nextIndex;
      }
      if (prevContent != null && _prevContent == null) {
        _prevContent = prevContent;
        _prevContentChapterIndex = prevIndex;
      }
    });
  }

  Future<void> _preloadNextChapter() async {
    if (_book == null ||
        _dataProvider == null ||
        _nextContent != null ||
        _isLoadingNext) {
      return;
    }
    final nextIndex = _nextReadableChapterIndex(_currentChapterIndex);
    if (nextIndex != null) {
      _isLoadingNext = true;
      try {
        final nextChapter = _chapters[nextIndex];
        final content = await _dataProvider!.getContent(
          _book!,
          nextChapter,
          allChapters: _chapters,
        );
        if (!mounted) return;
        // 章节切换守卫：await 期间用户已切到其他章节时丢弃结果，
        // 避免把旧章节的下一章内容赋给 _nextContent 导致后续预加载永久失效
        if (nextIndex != _nextReadableChapterIndex(_currentChapterIndex)) {
          return;
        }
        _nextContent = content;
        _nextContentChapterIndex = nextIndex;
        setState(() {});
      } finally {
        _isLoadingNext = false;
      }
    }
  }

  /// 预加载上一章（用于滚动模式往上滑）
  Future<void> _preloadPrevChapter() async {
    if (_book == null ||
        _dataProvider == null ||
        _prevContent != null ||
        _isLoadingPrev) {
      return;
    }
    final prevIndex = _previousReadableChapterIndex(_currentChapterIndex);
    if (prevIndex != null) {
      _isLoadingPrev = true;
      try {
        final prevChapter = _chapters[prevIndex];
        final content = await _dataProvider!.getContent(
          _book!,
          prevChapter,
          allChapters: _chapters,
        );
        if (!mounted) return;
        // 章节切换守卫：await 期间用户已切到其他章节时丢弃结果
        if (prevIndex != _previousReadableChapterIndex(_currentChapterIndex)) {
          return;
        }
        _prevContent = content;
        _prevContentChapterIndex = prevIndex;
        setState(() {});
      } finally {
        _isLoadingPrev = false;
      }
    }
  }

  // ==================== Pagination ====================

  void _repaginate({int initialPage = 0}) {
    final provider = context.read<ReaderProvider>();
    if (_isScrollLikeMode(provider)) return;

    _pages = _splitContentToPages(_processedContent(_content), provider);
    _currentPage = initialPage.clamp(0, max(_pages.length - 1, 0));
    _swapPageController(_currentPage + _pagedLeadingCount);
    _isChangingChapterByPageView = false;
    if (mounted) setState(() {});
  }

  void _repaginatePreservingPosition() {
    final provider = context.read<ReaderProvider>();
    var fraction = 0.0;
    if (_pages.length > 1) {
      fraction = _currentPage / (_pages.length - 1);
    } else if (_scrollController.hasClients &&
        _scrollController.position.maxScrollExtent > 0) {
      fraction =
          _scrollController.offset / _scrollController.position.maxScrollExtent;
    }

    if (_isScrollLikeMode(provider)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        _scrollController.jumpTo(
          (_scrollController.position.maxScrollExtent *
                  fraction.clamp(0.0, 1.0))
              .clamp(0.0, _scrollController.position.maxScrollExtent),
        );
      });
      return;
    }

    _pages = _splitContentToPages(_processedContent(_content), provider);
    final lastPage = max(_pages.length - 1, 0);
    _currentPage = (fraction.clamp(0.0, 1.0) * lastPage).round();
    _swapPageController(_currentPage + _pagedLeadingCount);
    _isChangingChapterByPageView = false;
    if (mounted) setState(() {});
    unawaited(_saveCurrentProgress(pos: _currentPage));
  }

  /// 安全替换 PageController：先创建新 controller 立即生效，
  /// 旧 controller 延迟到下一帧 dispose，避免 dispose 后到 setState 之间
  /// 的滚动通知触发 "ScrollController not attached" 异常
  void _swapPageController(int initialPage) {
    final oldController = _pageController;
    _pageController = PageController(initialPage: initialPage);
    if (oldController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldController.dispose();
      });
    }
  }

  List<String> _splitContentToPages(String content, ReaderProvider provider) {
    final displayContent = ChineseConverter.convert(
      content,
      provider.chineseConverterType,
    );
    final paragraphs = _splitToParagraphs(displayContent);
    final pages = <String>[];
    if (paragraphs.isEmpty) return [''];

    final metrics = _pageMetrics(provider);
    final textStyle = _readerTextStyle(provider);
    // 渲染时每段会包一层 Padding(bottom: paragraphSpacing)，分页测量时不再加，
    // 避免段距被计算两次（导致实际段距是配置值的 2 倍）。
    // 但页内最后一段不会渲染 Padding（下面会 trimRight），所以整页高度估算用
    // paragraphSpacing * (段数-1) 来近似。为简化实现，这里按每段都加一次
    // paragraphSpacing 估算，渲染时最后一段的 Padding 多余空间留作底部留白。
    final paragraphSpacing = provider.paragraphSpacing;
    var page = StringBuffer();
    var pageParagraphCount = 0;
    var usedHeight = _showChapterTitle(provider)
        ? _measureTextHeight(
                _displayChapterTitle(provider),
                _titleTextStyle(provider),
                metrics.width,
              ) +
              provider.titleTopSpacing.toDouble() +
              provider.titleBottomSpacing.toDouble()
        : 0.0;

    for (final rawParagraph in paragraphs) {
      // _splitToParagraphs 已把 HTML 标准化为纯文本，统一走纯文本路径
      var paragraph = _applyIndent(rawParagraph, provider);

      while (paragraph.isNotEmpty) {
        final paragraphHeight =
            _measureTextHeight(paragraph, textStyle, metrics.width) +
            paragraphSpacing;

        // 当前页还能放下整段
        if (usedHeight + paragraphHeight <= metrics.height) {
          page.writeln(paragraph);
          usedHeight += paragraphHeight;
          pageParagraphCount++;
          paragraph = '';
          continue;
        }

        // 当前页已有内容：先翻页，再重试本段
        if (pageParagraphCount > 0) {
          pages.add(page.toString().trimRight());
          page = StringBuffer();
          pageParagraphCount = 0;
          usedHeight = 0;
          continue;
        }

        // 走到这里：当前页为空 + 整段放不下 —— 需要字符级切割
        // （纯文本路径，不再有 HTML 标签结构限制）
        final remainingHeight = max(
          metrics.height - usedHeight - paragraphSpacing,
          _singleLineHeight(textStyle, metrics.width),
        );

        final splitIndex = _findFittingTextIndex(
          paragraph,
          textStyle,
          metrics.width,
          remainingHeight,
        );

        // 关键守卫：splitIndex 必须 > 0，否则 substring(0,0) 返回空字符串，
        // 下一轮 while(paragraph.isNotEmpty) 不会变空，导致死循环 + 栈溢出崩溃
        if (splitIndex <= 0) {
          // 兜底：强制取 1 个字符，确保 paragraph 每轮至少缩短 1 字符
          pages.add(paragraph.substring(0, 1).trimRight());
          paragraph = paragraph.substring(1);
          // 注意：不 trimLeft！trimLeft 会剥掉全角空格缩进，导致续页首行没缩进
          usedHeight = 0;
          continue;
        }

        pages.add(paragraph.substring(0, splitIndex).trimRight());
        // 不 trimLeft：保留续页首行的全角空格缩进
        paragraph = paragraph.substring(splitIndex);
        usedHeight = 0;
      }
    }

    if (pageParagraphCount > 0) {
      pages.add(page.toString().trimRight());
    }

    return pages.isEmpty ? [''] : pages;
  }

  /// 测量单行文本高度（用于 splitIndex 兜底，确保至少能放 1 行）
  double _singleLineHeight(TextStyle style, double width) {
    return _measureTextHeight('一', style, width);
  }

  ({double width, double height}) _pageMetrics(ReaderProvider provider) {
    final mq = MediaQuery.of(context);
    final width = max(
      80.0,
      mq.size.width -
          mq.padding.left -
          mq.padding.right -
          provider.paddingLeft -
          provider.paddingRight,
    );
    final height = max(
      120.0,
      mq.size.height -
          mq.padding.top -
          mq.padding.bottom -
          provider.paddingTop -
          provider.paddingBottom -
          _headerExtent(provider) -
          _footerExtent(provider),
    );
    return (width: width, height: height);
  }

  TextStyle _titleTextStyle(ReaderProvider provider) {
    return TextStyle(
      fontSize: max(10.0, provider.fontSize + provider.titleSize),
      fontWeight: _fontWeight(provider.titleFontWeight),
      color: provider.textColor,
      height: provider.lineHeight,
      fontFamily: provider.fontFamily.isNotEmpty ? provider.fontFamily : null,
    );
  }

  /// 从 _readerHtmlStyle 派生的 TextStyle，用于 TextPainter 测量。
  /// 关键：测量和渲染用同一份样式定义（字号、行高、字距、字重、字族），
  /// 保证分页测量高度与 Html 组件渲染高度零偏差。
  TextStyle _readerTextStyle(ReaderProvider provider) {
    return TextStyle(
      fontSize: provider.fontSize,
      color: provider.textColor,
      height: provider.lineHeight,
      letterSpacing: provider.letterSpacing,
      fontWeight: _readerFontWeight(provider),
      fontFamily: provider.fontFamily.isNotEmpty ? provider.fontFamily : null,
    );
  }

  /// 测量 HTML 段落的渲染高度（用与 _readerHtmlStyle 一致的 TextStyle）
  /// 纯文本直接用 TextPainter；HTML 段落先剥离标签再测量，
  /// 因为 Html 组件内部用 RichText 渲染，TextSpan 高度 = 剥离标签后文本高度。
  /// textAlign 与 _readerHtmlStyle 的 body.textAlign 保持一致（justify），
  /// 避免测量与渲染在断行行为上产生细微差异。
  double _measureTextHeight(String text, TextStyle style, double width) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: null,
      textAlign: TextAlign.justify,
    )..layout(maxWidth: width);
    return painter.height;
  }

  int _findFittingTextIndex(
    String text,
    TextStyle style,
    double width,
    double height,
  ) {
    // 边界守卫：空文本直接返回 0（外层会走兜底逻辑，强制取 1 字符）
    if (text.isEmpty) return 0;

    // 单行都放不下时直接返回 1（至少放 1 字符，避免死循环）
    final singleCharHeight = _measureTextHeight(
      text.substring(0, 1),
      style,
      width,
    );
    if (singleCharHeight > height) return 1;

    // 二分搜索：找到最大的 mid 使得 text[0..mid] 高度 <= height
    // 关键：low/high 都向 best 收敛，保证循环终止
    var low = 1;
    var high = text.length;
    var best = 1;
    var iterations = 0;
    // 安全上限：log2(N) + 常数，避免极端情况死循环
    final maxIterations = 64;
    while (low <= high && iterations < maxIterations) {
      iterations++;
      final mid = (low + high) >> 1;
      final candidate = text.substring(0, mid);
      final h = _measureTextHeight(candidate, style, width);
      if (h <= height) {
        best = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    // 最终守卫：best 至少为 1（前面已保证单字符能放下）
    return best.clamp(1, text.length);
  }

  static final _asciiEdgeWhitespace = RegExp(r'^[\t \r\f]+|[\t \r\f]+$');

  /// 将 HTML 内容标准化为纯文本：
  /// - 块级标签（p/div）的闭标签转为双换行（确保段落分隔）
  /// - 块级标签的开标签转为单换行
  /// - `<br>` 转为换行
  /// - 其他标签直接剥掉（保留内容）
  /// - HTML 实体解码
  ///
  /// 标准化后所有内容统一走纯文本路径，避免 `_splitToParagraphs` 按 `\n`
  /// 切分时破坏 HTML 标签结构（如 `<p>第一行\n第二行</p>` 被切成碎片，
  /// 闭标签 `</p>` 被当作纯文本处理，flutter_html 解析出错）。
  String _normalizeHtmlToText(String content) {
    if (!_containsHtml(content)) return content;
    var result = content;
    // </p>、</div> 后补双换行（确保段落分隔）
    result = result.replaceAll(
      RegExp(r'</(?:p|div)\b[^>]*>', caseSensitive: false),
      '\n\n',
    );
    // <p>、<div> 开标签转为换行
    result = result.replaceAll(
      RegExp(r'<(?:p|div)\b[^>]*>', caseSensitive: false),
      '\n',
    );
    // <br> 转为换行
    result = result.replaceAll(
      RegExp(r'<br\s*/?>', caseSensitive: false),
      '\n',
    );
    // 剥掉其他所有标签（保留内容）
    result = result.replaceAll(_htmlTagStripRegex, '');
    // HTML 实体解码
    result = result.replaceAll('&nbsp;', ' ');
    result = result.replaceAll('&#x3000;', '\u3000');
    result = result.replaceAll('&amp;', '&');
    result = result.replaceAll('&lt;', '<');
    result = result.replaceAll('&gt;', '>');
    result = result.replaceAll('&quot;', '"');
    result = result.replaceAll('&#39;', "'");
    return result;
  }

  List<String> _splitToParagraphs(String content) {
    // 如果内容含 HTML，先标准化为纯文本，避免按 \n 切分时破坏标签结构
    if (_containsHtml(content)) {
      content = _normalizeHtmlToText(content);
    }
    // 不能用 String.trim()：它会剥离全角空格 \u3000（首行缩进）。
    // 仅剥离 ASCII 边缘空白；空行判断时把 \u3000 也视作空白。
    return content
        .split(RegExp(r'\r\n|\r|\n'))
        .map((line) => line.replaceAll(_asciiEdgeWhitespace, ''))
        .where((line) => line.replaceAll('\u3000', '').isNotEmpty)
        .toList();
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
    // 简单 tap 判定：移动距离 < kTouchSlop，且为左键
    final dx = event.position.dx - down.position.dx;
    final dy = event.position.dy - down.position.dy;
    if (dx * dx + dy * dy > 18 * 18) return; // 18px ≈ kTouchSlop
    if (event.buttons != kPrimaryButton && event.buttons != 0) return;
    _handleTap(TapUpDetails(
      kind: event.kind,
      globalPosition: event.position,
      localPosition: event.localPosition,
    ));
  }

  void _onPointerDown(PointerDownEvent event) {
    _lastDownEvent = event;
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
      if (!_scrollController.hasClients) return;
      if (_scrollController.offset <= 8) {
        // 已预加载上一章时优先走无缝切换，避免丢弃缓存重新 load
        if (_prevContent != null && _prevContentChapterIndex != null) {
          _switchToPrevChapter();
        } else {
          _previousChapter(toLastPage: true);
        }
        return;
      }
      _scrollController.animateTo(
        max(_scrollController.offset - _scrollPageExtent(), 0),
        duration: _pageAnimationDuration(provider),
        curve: Curves.easeOutCubic,
      );
    } else {
      if (_currentPage > 0) {
        if (provider.pageMode == PageMode.simulation) {
          setState(() => _currentPage--);
          _scheduleProgressSave(pos: _currentPage);
        } else if (_pageController?.hasClients == true) {
          _pageController?.previousPage(
            duration: _pageAnimationDuration(provider),
            curve: Curves.easeOut,
          );
        } else {
          // PageController 未挂载，重建控制器以跳转到目标页
          _currentPage--;
          _swapPageController(_currentPage + _pagedLeadingCount);
          _scheduleProgressSave(pos: _currentPage);
          setState(() {});
        }
      } else {
        _previousChapter(toLastPage: true);
      }
    }
  }

  void _nextPage() {
    final provider = context.read<ReaderProvider>();
    if (_isScrollLikeMode(provider)) {
      if (!_scrollController.hasClients) return;
      final maxScroll = _scrollController.position.maxScrollExtent;
      // 已预加载下一章：到底部时走无缝切换（保留缓存），否则继续向下滚动
      if (_nextContent != null) {
        if (_scrollController.offset >= maxScroll - 8) {
          _switchToPreloadedChapter();
          return;
        }
        _scrollController.animateTo(
          min(_scrollController.offset + _scrollPageExtent(), maxScroll),
          duration: _pageAnimationDuration(provider),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      // 只有当下一章未预加载时，才在接近底部时加载下一章
      if (_scrollController.offset >= maxScroll - 8) {
        _nextChapter();
        return;
      }
      _scrollController.animateTo(
        min(_scrollController.offset + _scrollPageExtent(), maxScroll),
        duration: _pageAnimationDuration(provider),
        curve: Curves.easeOutCubic,
      );
    } else {
      if (_currentPage < _pages.length - 1) {
        if (provider.pageMode == PageMode.simulation) {
          setState(() => _currentPage++);
          _scheduleProgressSave(pos: _currentPage);
        } else if (_pageController?.hasClients == true) {
          _pageController?.nextPage(
            duration: _pageAnimationDuration(provider),
            curve: Curves.easeOut,
          );
        } else {
          // PageController 未挂载，重建控制器以跳转到目标页
          _currentPage++;
          _swapPageController(_currentPage + _pagedLeadingCount);
          _scheduleProgressSave(pos: _currentPage);
          setState(() {});
        }
      } else {
        _nextChapter();
      }
    }
  }

  double _scrollPageExtent() {
    final viewport = _scrollController.hasClients
        ? _scrollController.position.viewportDimension
        : MediaQuery.of(context).size.height;
    // 90% 视口高度，保留 10% 重叠让上下滚动连续感更强、视觉更丝滑
    return max(120.0, viewport * 0.9);
  }

  Duration _pageAnimationDuration(ReaderProvider provider) {
    return Duration(milliseconds: provider.pageAnimDurationMs.clamp(80, 1200));
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

  void _toggleMenu() {
    setState(() {
      _showMenu = !_showMenu;
    });
    if (_showMenu) {
      _menuAnimController.forward();
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

  /// PageMode.none 在渲染上复用滚动模式（_buildContent 中 case 走 _buildScrollContent），
  /// 因此所有「是否滚动模式」的交互判断都必须把 none 也算进去，
  /// 否则 none 模式下翻页/进度/预加载/自动滚动/搜索跳转/页码提示全部失效。
  bool _isScrollLikeMode(ReaderProvider provider) =>
      provider.pageMode == PageMode.scroll ||
      provider.pageMode == PageMode.none;

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
        body: Listener(
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
              // 使用 SelectionArea 包裹正文，长按即可选择文字
              SelectionArea(child: _buildContent(provider)),
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
              if (_showMenu)
                ReaderControlOverlay(
                  bookName: _book?.name ?? '',
                  chapterTitle: _chapterTitle,
                  chapterUrl: _chapterUrl,
                  sourceName:
                      _book?.sourceName ??
                      (_book?.originType == BookOriginType.local ? '本地书籍' : ''),
                  hasBookSource: _bookSource != null,
                  currentChapter: _currentChapterIndex,
                  totalChapters: _totalChapters,
                  hasBookmark: _hasBookmark,
                  hasPrev:
                      _previousReadableChapterIndex(_currentChapterIndex) !=
                      null,
                  hasNext:
                      _nextReadableChapterIndex(_currentChapterIndex) != null,
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
                    if (_previousReadableChapterIndex(_currentChapterIndex) !=
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
                )
            ],
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

    switch (provider.pageMode) {
      case PageMode.scroll:
        return _buildScrollContent(provider);
      case PageMode.slide:
        return _buildSlideContent(provider);
      case PageMode.cover:
        return _buildCoverContent(provider);
      case PageMode.simulation:
        return _buildSimulationContent(provider);
      case PageMode.none:
        // 无动画模式，使用滚动模式渲染
        return _buildScrollContent(provider);
    }
  }

  // ==================== Scroll Mode ====================

  Widget _buildScrollContent(ReaderProvider provider) {
    return SafeArea(
      child: Column(
        children: [
          if (_headerVisible(provider))
            _buildScrollPageTip(provider, isHeader: true),
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollController,
              // 始终使用带弹性的滚动物理，让上下滚动到边界时有 iOS 风格的回弹，
              // 视觉上更柔和、更有"丝滑"感
              physics: const BouncingScrollPhysics(
                parent: RangeMaintainingScrollPhysics(),
              ),
              padding: EdgeInsets.fromLTRB(
                provider.paddingLeft,
                provider.paddingTop,
                provider.paddingRight,
                provider.paddingBottom,
              ),
              child: RepaintBoundary(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_prevContent != null &&
                        _prevContentChapterIndex != null &&
                        _prevContentChapterIndex! < _chapters.length &&
                        _prevContentChapterIndex ==
                            _previousReadableChapterIndex(_currentChapterIndex))
                      Container(
                        key: _prevChapterKey,
                        child: _buildAdjacentChapterContent(
                          provider,
                          _prevContent!,
                          _chapters[_prevContentChapterIndex!].title,
                        ),
                      ),
                    Container(
                      key: _currentChapterKey,
                      child: _buildChapterContent(
                        provider,
                        _processedContent(_content),
                        _chapterTitle,
                      ),
                    ),
                    if (_nextContent != null &&
                        _nextContentChapterIndex != null &&
                        _nextContentChapterIndex! < _chapters.length &&
                        _nextContentChapterIndex ==
                            _nextReadableChapterIndex(_currentChapterIndex))
                      _buildAdjacentChapterContent(
                        provider,
                        _nextContent!,
                        _chapters[_nextContentChapterIndex!].title,
                      ),
                  ],
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

  bool _hasBackgroundImage(ReaderProvider provider) {
    final path = provider.backgroundImagePath;
    return !kIsWeb && path != null && path.isNotEmpty;
  }

  Color _pageBackgroundColor(ReaderProvider provider) {
    return _hasBackgroundImage(provider)
        ? Colors.transparent
        : provider.backgroundColor;
  }

  Widget _buildAdjacentChapterContent(
    ReaderProvider provider,
    String content,
    String title,
  ) {
    // 上一章最后 <p> 的 margin-bottom 已经提供一次段距，
    // 这里再补一次段距作为章节间额外间隔（总间隔 = paragraphSpacing × 2，
    // 与章节内段距 paragraphSpacing × 1 形成合理的视觉层次）
    return Padding(
      padding: EdgeInsets.only(top: provider.paragraphSpacing),
      child: _buildChapterContent(provider, _processedContent(content), title),
    );
  }

  /// 构建章节标题 Widget（统一入口）
  ///
  /// 关键渲染层级修复：
  /// - 外层包 MediaQuery 强制 textScaler=1.0，与正文 Html 行为一致
  /// - 避免 main.dart 的 MaterialApp.builder 注入的 textScaler=currentFontScale/10
  ///   导致标题字号被缩放，而正文 Html 内部覆盖 textScaler=1.0 不被缩放，
  ///   产生标题与正文比例失调
  /// - _buildChapterContent（滚动模式）和 _buildPageContent（分页模式）共用此方法
  Widget _buildChapterTitle(ReaderProvider provider, String title) {
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: const TextScaler.linear(1.0),
      ),
      child: Align(
        alignment: _titleAlignment(provider),
        child: Text(
          ChineseConverter.convert(title, provider.chineseConverterType),
          style: _titleTextStyle(provider),
          textAlign: _titleTextAlign(provider),
        ),
      ),
    );
  }

  Widget _buildChapterContent(
    ReaderProvider provider,
    String content,
    String title,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 章节标题
        if (_showChapterTitle(provider)) ...[
          SizedBox(height: provider.titleTopSpacing.toDouble()),
          _buildChapterTitle(provider, title),
          SizedBox(height: provider.titleBottomSpacing.toDouble()),
        ],
        _buildRichContent(provider, content),
      ],
    );
  }

  // ==================== Rich Content with Highlights ====================

  /// 检测内容是否包含 HTML 标签
  static final _htmlTagRegex = RegExp(
    r'<(?:br|p|div|span|a|img|b|i|strong|em|h[1-6]|ul|ol|li|table|tr|td|th|blockquote|pre|code|hr|font)\b[^>]*>',
    caseSensitive: false,
  );

  bool _containsHtml(String content) {
    return _htmlTagRegex.hasMatch(content);
  }

  Widget _buildRichContent(
    ReaderProvider provider,
    String content, {
    bool applyIndent = true,
    bool convertChinese = true,
  }) {
    final displayContent = convertChinese
        ? ChineseConverter.convert(content, provider.chineseConverterType)
        : content;
    // 统一走 HTML 渲染路径：纯文本也包装成 <p> 标签，所有样式用 CSS 定义，
    // 分页测量和渲染用同一套样式数据源，消除双套计算偏差。
    // 高亮规则通过内联 <span style="..."> 注入到 HTML 字符串。
    final html = _buildUnifiedHtml(provider, displayContent, applyIndent);
    // 关键修复：外层包 MediaQuery 强制 textScaler = 1.0
    // - flutter_html 内部 CssBoxWidget 对 top:false 子节点会强制 textScaler=1.0
    //   但 top:true 的 body 根节点不覆盖，会受外层 MediaQuery 影响
    // - main.dart 的 MaterialApp.builder 注入了 textScaler = currentFontScale/10
    //   这会导致 Html 的 body 几何计算被缩放，但正文 Text.rich 不被缩放（内部覆盖）
    //   产生 body 容器与文本不匹配的几何偏差
    // - 这里显式覆盖为 1.0，让 Html 整体不受 UI 字号缩放影响
    //   章节标题 Text 也用同样处理（见 _buildChapterContent），保持比例一致
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: const TextScaler.linear(1.0),
      ),
      child: Html(
        data: html,
        style: _readerHtmlStyle(provider),
      ),
    );
  }

  /// 统一构建 HTML 内容：所有内容统一走纯文本路径。
  ///
  /// `_splitToParagraphs` 内部会先调用 `_normalizeHtmlToText` 把 HTML
  /// 标准化为纯文本（块级标签转换行、剥掉其他标签、解码实体），所以这里
  /// 不再需要区分 HTML/纯文本，所有段落统一包装成 `<p>` + 缩进实体 + 高亮。
  ///
  /// 高亮与缩进实体顺序：先 highlight 再 prepend 实体，避免贪婪匹配的高亮规则
  /// 误匹配 `&#x3000;` 实体后转义成 `&amp;#x3000;` 导致缩进消失。
  String _buildUnifiedHtml(
    ReaderProvider provider,
    String content,
    bool applyIndent,
  ) {
    final rules = provider.highlightRules.where((r) => r.enabled).toList();
    final paragraphs = _splitToParagraphs(content);
    final buf = StringBuffer();

    if (applyIndent) {
      // 滚动模式：内容是整章原文，需要剥掉源内容自带缩进，
      // 统一 prepend 配置的缩进实体（&#x3000;），保证每段首行缩进一致
      final indent = provider.paragraphIndent;
      final entity = indent.replaceAll('\u3000', '&#x3000;');
      for (final para in paragraphs) {
        // 先 highlight 再 prepend 实体，避免贪婪匹配的高亮规则
        // 误匹配 &#x3000; 实体后转义成 &amp;#x3000; 导致缩进消失
        final trimmed = para.replaceAll(_leadingIndentRegex, '');
        final highlighted = _wrapWithHighlightHtml(trimmed, rules);
        final body = entity.isEmpty ? highlighted : '$entity$highlighted';
        buf.write('<p>');
        buf.write(body);
        buf.write('</p>');
      }
    } else {
      // 分页模式：pageText 已经过 _splitContentToPages + _applyIndent 处理，
      // 每段首行已含 \u3000 缩进，续页首行（段落被切分的后半部分）无缩进。
      // 这里保留原样，不再二次加缩进，否则续页首行会被错误地加上缩进，
      // 导致"段首缩进不统一"（段落开头有缩进，续页首行也有缩进）。
      // \u3000 是合法 Unicode 字符，flutter_html 可直接渲染，无需转义成实体。
      for (final para in paragraphs) {
        final highlighted = _wrapWithHighlightHtml(para, rules);
        buf.write('<p>');
        buf.write(highlighted);
        buf.write('</p>');
      }
    }
    return buf.toString();
  }

  /// 统一的 HTML CSS 样式表：字号、行高、字距、段距、缩进、颜色、字重
  ///
  /// 关键修复：flutter_html 的根 StyledElement 会继承 DefaultTextStyle.of(context).style，
  /// 所有未显式设置的字段都会继承 Scaffold/Material 注入的 DefaultTextStyle。
  /// 因此必须显式设置所有可能影响布局/视觉的字段，避免继承导致样式不可控。
  ///
  /// 同时清零 flutter_html 默认样式：
  /// - <body> 默认 margin: Margins.all(8.0) → 显式 margin: Margins.zero
  /// - <p> 默认 margin: Margins.symmetric(vertical: 1, unit: Unit.em) → 显式 only(bottom)
  /// - <p> 默认 display: Display.block → 保留（block 才能独占一行）
  Map<String, Style> _readerHtmlStyle(ReaderProvider provider) {
    final fontFamily = provider.fontFamily.isNotEmpty ? provider.fontFamily : null;
    return {
      'body': Style(
        fontSize: FontSize(provider.fontSize),
        color: provider.textColor,
        lineHeight: LineHeight(provider.lineHeight),
        fontFamily: fontFamily,
        fontWeight: _readerFontWeight(provider),
        letterSpacing: provider.letterSpacing,
        textAlign: TextAlign.justify,
        // 显式设置可能被 DefaultTextStyle 继承的字段，避免继承导致样式不可控
        backgroundColor: Colors.transparent,
        fontStyle: FontStyle.normal,
        textDecoration: TextDecoration.none,
        wordSpacing: 0,
        // 显式清零 flutter_html <body> 默认 margin: Margins.all(8.0)
        padding: HtmlPaddings.zero,
        margin: Margins.zero,
        display: Display.block,
      ),
      'p': Style(
        // 显式清零 flutter_html <p> 默认 margin: Margins.symmetric(vertical: 1, unit: Unit.em)
        // 只保留 bottom margin 作为段距，top/left/right 全部为 0
        margin: Margins.only(
          top: 0,
          bottom: provider.paragraphSpacing,
          left: 0,
          right: 0,
        ),
        // 继承 body 的字号/颜色/行高/字距/字重/字体等（通过 copyOnlyInherited）
        // 但显式设置以下字段避免继承 DefaultTextStyle
        letterSpacing: provider.letterSpacing,
        padding: HtmlPaddings.zero,
        backgroundColor: Colors.transparent,
        display: Display.block,
      ),
      'div': Style(
        margin: Margins.only(
          top: 0,
          bottom: provider.paragraphSpacing,
          left: 0,
          right: 0,
        ),
        letterSpacing: provider.letterSpacing,
        padding: HtmlPaddings.zero,
        backgroundColor: Colors.transparent,
        display: Display.block,
      ),
      // 高亮 span 标签：只继承 body/p 的样式，不额外设置
      'span': Style(
        backgroundColor: Colors.transparent,
      ),
    };
  }

  /// 把高亮规则应用到文本，包装成内联 <span style="..."> 标签
  /// flutter_html 3.0.0-beta.2 不支持 CSS class 选择器扩展，
  /// 所以直接用内联 style 属性，兼容性最好。
  String _wrapWithHighlightHtml(String html, List<HighlightRule> rules) {
    if (rules.isEmpty) return html;
    var result = html;
    for (final rule in rules) {
      if (rule.pattern.isEmpty) continue;
      try {
        final regex = RegExp(rule.pattern, multiLine: true);
        final styleStr = _highlightStyleToCss(rule);
        result = result.replaceAllMapped(regex, (match) {
          final matched = match.group(0) ?? '';
          // 转义 HTML 特殊字符，避免破坏标签
          final escaped = matched
              .replaceAll('&', '&amp;')
              .replaceAll('<', '&lt;')
              .replaceAll('>', '&gt;');
          return '<span style="$styleStr">$escaped</span>';
        });
      } catch (_) {}
    }
    return result;
  }

  String _highlightStyleToCss(HighlightRule rule) {
    // Flutter 3.41 起 Color.red/green/blue/alpha 已弃用，改用 r/g/b/a (0.0-1.0)
    final c = rule.color.color;
    final r = (c.r * 255).round().clamp(0, 255);
    final g = (c.g * 255).round().clamp(0, 255);
    final b = (c.b * 255).round().clamp(0, 255);
    final a = (c.a * 255).round().clamp(0, 255);
    final rgba = 'rgba($r, $g, $b, ${a / 255})';
    return switch (rule.style) {
      HighlightStyle.background =>
        'background-color: rgba($r, $g, $b, 0.4);',
      HighlightStyle.underline =>
        'text-decoration: underline; text-decoration-color: $rgba; text-decoration-thickness: 2px;',
      HighlightStyle.strikethrough =>
        'text-decoration: line-through; text-decoration-color: $rgba; text-decoration-thickness: 2px;',
      HighlightStyle.wavy =>
        'text-decoration: underline wavy; text-decoration-color: $rgba; text-decoration-thickness: 2px;',
    };
  }

  static final _leadingIndentRegex = RegExp(r'^[\u3000\t ]+');

  String _applyIndent(String paragraph, ReaderProvider provider) {
    // 去除源内容自带的全角空格缩进 + ASCII 左空白，再统一加上配置缩进
    final trimmed = paragraph.replaceAll(_leadingIndentRegex, '');
    if (provider.paragraphIndent.isEmpty) return trimmed;
    return '${provider.paragraphIndent}$trimmed';
  }

  /// 剥离 HTML 标签的正则（用于 _normalizeHtmlToText）
  static final _htmlTagStripRegex = RegExp(r'<[^>]+>');

  FontWeight _readerFontWeight(ReaderProvider provider) {
    return _fontWeight(provider.textFontWeight);
  }

  FontWeight _fontWeight(int value) {
    final index = ((value.clamp(100, 900) / 100).round() - 1).clamp(0, 8);
    return FontWeight.values[index];
  }

  bool _showChapterTitle(ReaderProvider provider) =>
      provider.showChapterTitle && provider.titleMode != 2;

  String _displayChapterTitle(ReaderProvider provider) =>
      ChineseConverter.convert(_chapterTitle, provider.chineseConverterType);

  TextAlign _titleTextAlign(ReaderProvider provider) {
    return switch (provider.titleMode) {
      1 => TextAlign.center,
      3 => TextAlign.right,
      _ => TextAlign.left,
    };
  }

  Alignment _titleAlignment(ReaderProvider provider) {
    return switch (provider.titleMode) {
      1 => Alignment.center,
      3 => Alignment.centerRight,
      _ => Alignment.centerLeft,
    };
  }

  // ==================== Slide Mode (PageView) ====================

  Widget _buildSlideContent(ReaderProvider provider) {
    return SafeArea(child: _buildPagedView(provider));
  }

  // ==================== Cover Mode ====================

  Widget _buildCoverContent(ReaderProvider provider) {
    return SafeArea(
      child: _pages.isEmpty
          ? Center(
              child: Text('无内容', style: TextStyle(color: provider.textColor)),
            )
          : AnimatedSwitcher(
              duration: _pageAnimationDuration(provider),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeOut,
              transitionBuilder: (child, animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: RepaintBoundary(
                key: ValueKey(
                  'cover-${_currentChapterIndex}-${_currentPage.clamp(0, _pages.length - 1)}',
                ),
                child: _buildPageContent(
                  provider,
                  _pages[_currentPage.clamp(0, _pages.length - 1)],
                  pageIndex: _currentPage.clamp(0, _pages.length - 1),
                ),
              ),
            ),
    );
  }

  Widget _buildPagedView(ReaderProvider provider) {
    if (_pages.isEmpty) {
      return Center(
        child: Text('无内容', style: TextStyle(color: provider.textColor)),
      );
    }
    final leadingCount = _pagedLeadingCount;
    final itemCount = _pages.length + leadingCount + _pagedTrailingCount;
    return PageView.builder(
      controller: _pageController,
      onPageChanged: _onPageChanged,
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index < leadingCount) {
          return _buildChapterBoundaryPage(provider, '正在加载上一章...');
        }
        final pageIndex = index - leadingCount;
        if (pageIndex >= _pages.length) {
          return _buildChapterBoundaryPage(provider, '正在加载下一章...');
        }
        return RepaintBoundary(
          child: _buildPageContent(
            provider,
            _pages[pageIndex],
            pageIndex: pageIndex,
          ),
        );
      },
    );
  }

  int get _pagedLeadingCount =>
      _previousReadableChapterIndex(_currentChapterIndex) == null ? 0 : 1;

  int get _pagedTrailingCount =>
      _nextReadableChapterIndex(_currentChapterIndex) == null ? 0 : 1;

  void _onPageChanged(int index) {
    if (_isChangingChapterByPageView) return;
    final leadingCount = _pagedLeadingCount;
    if (index < leadingCount) {
      _isChangingChapterByPageView = true;
      setState(() => _isLoading = true);
      _previousChapter(toLastPage: true);
      return;
    }
    final pageIndex = index - leadingCount;
    if (pageIndex >= _pages.length) {
      _isChangingChapterByPageView = true;
      setState(() => _isLoading = true);
      _nextChapter();
      return;
    }
    setState(() {
      _currentPage = pageIndex;
    });
    unawaited(_saveCurrentProgress(pos: pageIndex));
  }

  Widget _buildChapterBoundaryPage(ReaderProvider provider, String text) {
    return Container(
      color: _pageBackgroundColor(provider),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: provider.textColor.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            text,
            style: TextStyle(
              color: provider.textColor.withValues(alpha: 0.58),
              fontSize: max(14, provider.fontSize - 2),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== Simulation Mode ====================

  Widget _buildSimulationContent(ReaderProvider provider) {
    return SafeArea(
      child: _pages.isEmpty
          ? Center(
              child: Text('无内容', style: TextStyle(color: provider.textColor)),
            )
          : GestureDetector(
              onHorizontalDragStart: (details) {
                _dragStartX = details.globalPosition.dx;
                _isDragging = true;
              },
              onHorizontalDragUpdate: (details) {
                if (!_isDragging) return;
                _dragCurrentX = details.globalPosition.dx;
                setState(() {});
              },
              onHorizontalDragEnd: (details) {
                if (!_isDragging) return;
                _isDragging = false;
                final delta = _dragCurrentX - _dragStartX;
                _dragCurrentX = 0;
                _dragStartX = 0;
                if (delta < -50) {
                  _nextPage();
                } else if (delta > 50) {
                  _previousPage();
                } else {
                  // 未触发翻页，仅刷新以隐藏卷曲效果
                  setState(() {});
                }
              },
              child: Stack(
                children: [
                  RepaintBoundary(
                    child: _buildPageContent(
                      provider,
                      _pages[_currentPage.clamp(0, _pages.length - 1)],
                      pageIndex: _currentPage,
                    ),
                  ),
                  if (_isDragging) _buildCurlEffect(provider),
                ],
              ),
            ),
    );
  }

  Widget _buildCurlEffect(ReaderProvider provider) {
    final size = MediaQuery.of(context).size;
    final dragDelta = _dragCurrentX - _dragStartX;
    final isDragLeft = dragDelta < 0;

    return Positioned(
      left: 0,
      top: 0,
      right: 0,
      bottom: 0,
      child: CustomPaint(
        painter: _PageCurlPainter(
          dragDelta: dragDelta.abs(),
          isDragLeft: isDragLeft,
          backgroundColor: provider.backgroundColor,
          width: size.width,
          height: size.height,
        ),
      ),
    );
  }

  Widget _buildPageContent(
    ReaderProvider provider,
    String pageText, {
    required int pageIndex,
  }) {
    final showTitle = _showChapterTitle(provider) && pageIndex == 0;
    return Container(
      color: _pageBackgroundColor(provider),
      child: Column(
        children: [
          if (_headerVisible(provider))
            _buildPageTip(provider, isHeader: true, pageIndex: pageIndex),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                provider.paddingLeft,
                provider.paddingTop,
                provider.paddingRight,
                provider.paddingBottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showTitle) ...[
                    SizedBox(height: provider.titleTopSpacing.toDouble()),
                    _buildChapterTitle(provider, _chapterTitle),
                    SizedBox(height: provider.titleBottomSpacing.toDouble()),
                  ],
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: _buildRichContent(
                        provider,
                        pageText,
                        // 分页结果已含缩进（_applyIndent 处理过），
                        // 续页首行无缩进，不能再加缩进
                        applyIndent: false,
                        convertChinese: false,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_footerVisible(provider))
            _buildPageTip(provider, isHeader: false, pageIndex: pageIndex),
        ],
      ),
    );
  }

  bool _headerVisible(ReaderProvider provider) {
    if (!provider.showReadingInfo) return false;
    return provider.headerMode == 1;
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
          pageIndex: _currentPage,
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
    final pageCount = max(_pages.length, 1);
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
      tapZones: provider.tapZones,
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
      onBackgroundColorChanged: (value) => provider.setBackgroundColor(value),
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
      onPageAnimDurationChanged: (value) =>
          provider.setPageAnimDurationMs(value),
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
      onTapZonesChanged: (value) => provider.setTapZones(value),
      onNightModeChanged: (value) {
        if (provider.isNightMode != value) {
          provider.toggleNightMode();
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

// ==================== Page Curl Painter ====================

class _PageCurlPainter extends CustomPainter {
  final double dragDelta;
  final bool isDragLeft;
  final Color backgroundColor;
  final double width;
  final double height;

  _PageCurlPainter({
    required this.dragDelta,
    required this.isDragLeft,
    required this.backgroundColor,
    required this.width,
    required this.height,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (dragDelta < 1) return;

    final paint = Paint()..color = Colors.white.withValues(alpha: 0.9);
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    final curlWidth = dragDelta.clamp(0.0, width);
    final touchX = isDragLeft ? width - curlWidth : curlWidth;

    // Draw shadow
    final shadowPath = Path();
    if (isDragLeft) {
      shadowPath.moveTo(touchX, 0);
      shadowPath.lineTo(touchX + 20, 0);
      shadowPath.lineTo(touchX + 20, height);
      shadowPath.lineTo(touchX, height);
    } else {
      shadowPath.moveTo(touchX, 0);
      shadowPath.lineTo(touchX - 20, 0);
      shadowPath.lineTo(touchX - 20, height);
      shadowPath.lineTo(touchX, height);
    }
    canvas.drawPath(shadowPath, shadowPaint);

    // Draw curl effect with bezier curve
    final curlPath = Path();
    final curlHeight = min(40.0, curlWidth * 0.15);

    if (isDragLeft) {
      curlPath.moveTo(touchX, 0);
      curlPath.lineTo(width, 0);
      curlPath.lineTo(width, height);
      curlPath.lineTo(touchX, height);
      // Bezier curl at the edge
      curlPath.cubicTo(
        touchX + curlHeight,
        height * 0.75,
        touchX + curlHeight,
        height * 0.25,
        touchX,
        0,
      );
    } else {
      curlPath.moveTo(touchX, 0);
      curlPath.lineTo(0, 0);
      curlPath.lineTo(0, height);
      curlPath.lineTo(touchX, height);
      curlPath.cubicTo(
        touchX - curlHeight,
        height * 0.75,
        touchX - curlHeight,
        height * 0.25,
        touchX,
        0,
      );
    }

    paint.color = backgroundColor.withValues(alpha: 0.95);
    canvas.drawPath(curlPath, paint);

    // Draw curl line
    final linePaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(touchX, 0), Offset(touchX, height), linePaint);
  }

  @override
  bool shouldRepaint(covariant _PageCurlPainter oldDelegate) {
    return oldDelegate.dragDelta != dragDelta ||
        oldDelegate.isDragLeft != isDragLeft;
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
