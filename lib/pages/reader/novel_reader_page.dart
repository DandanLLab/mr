import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/chapter.dart';
import '../../models/highlight.dart';
import '../../providers/reader_provider.dart';
import '../../providers/bookshelf_provider.dart';
import '../../services/app_logger.dart';
import '../../services/book_data_provider.dart';
import '../../services/chapter_cache_service.dart';
import '../../services/chapter_prefetch_service.dart';
import '../../services/crash_log_service.dart';
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
  int? _pendingInitialPage;
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

  // Pagination for non-scroll modes
  List<String> _pages = [];
  int _currentPage = 0;
  PageController? _pageController;

  // Scroll mode controller
  final ScrollController _scrollController = ScrollController();
  // 标记当前章节内容的边界，用于检测滚动到下一章
  final GlobalKey _currentChapterKey = GlobalKey();

  // Highlight selection state
  String _selectedText = '';
  int _selectionStart = -1;
  int _selectionEnd = -1;
  bool _showHighlightMenu = false;
  Offset _highlightMenuPosition = Offset.zero;

  // Animation
  late AnimationController _menuAnimController;
  late Animation<double> _menuAnim;

  // Simulation page curl
  double _dragStartX = 0;
  double _dragCurrentX = 0;
  bool _isDragging = false;

  // 增强版控制
  final bool _useEnhancedControls = true;
  bool _hasBookmark = false;
  double _ttsSpeed = 1.0;

  // 阅读记录
  int _readStartTime = 0;
  Timer? _progressSaveTimer;

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
    _menuAnim = CurvedAnimation(
      parent: _menuAnimController,
      curve: Curves.easeInOut,
    );

    _scrollController.addListener(_onScroll);
    _loadBookAndChapters();
    _initTts();
    _checkBookmark();
  }

  @override
  void dispose() {
    _progressSaveTimer?.cancel();
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
    // 局部变量捕获：避免 await 期间 _book 被置 null
    final book = _book;
    if (book == null) return;
    final provider = context.read<ReaderProvider>();
    await provider.loadBookmarks(book.bookUrl);
    if (!mounted) return;
    _hasBookmark = await provider.hasBookmarkForChapter(
      book.bookUrl,
      _currentChapterIndex,
    );
    if (mounted) setState(() {});
  }

  Future<void> _toggleBookmark() async {
    final book = _book;
    if (book == null) return;
    final provider = context.read<ReaderProvider>();
    if (_hasBookmark) {
      // 移除书签
      final bookmarks = provider.bookmarks
          .where(
            (b) =>
                b.bookUrl == book.bookUrl &&
                b.chapterIndex == _currentChapterIndex,
          )
          .toList();
      for (final b in bookmarks) {
        await provider.removeBookmark(book.bookUrl, b.id);
      }
    } else {
      // 添加书签
      await provider.addBookmark(
        bookUrl: book.bookUrl,
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
    provider.setTtsChapterContent(_content);
    provider.startTts();
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
    if (provider.pageMode != PageMode.scroll) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
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

    // 获取旧章节内容的高度（用于调整滚动位置）
    double oldChapterHeight = 0;
    final oldContext = _currentChapterKey.currentContext;
    if (oldContext != null) {
      final renderBox = oldContext.findRenderObject() as RenderBox;
      oldChapterHeight = renderBox.size.height;
    }

    // 更新状态：将下一章设为当前章，当前章变为上一章缓存
    setState(() {
      // 当前章变为上一章缓存（保留缓存方便回滚）
      _prevContent = _content;
      _prevContentChapterIndex = _currentChapterIndex;
      // 下一章变为当前章
      _currentChapterIndex = _nextContentChapterIndex!;
      _chapterTitle = _chapters[_currentChapterIndex].title;
      _content = _nextContent!;
      _nextContent = null;
      _nextContentChapterIndex = null;
      _sliderValue = _currentChapterIndex.toDouble();
    });

    // 在下一帧调整滚动位置（减去旧章节高度，保持视觉位置不变）
    if (oldChapterHeight > 0 && _scrollController.hasClients) {
      final newOffset =
          max(0.0, _scrollController.offset - oldChapterHeight);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(newOffset);
        }
      });
    }

    // 预加载新的下一章
    _preloadNextChapter();
    // 保存进度
    _scheduleProgressSave(pos: 0);
  }

  /// 滚动模式下无缝切换到预加载的上一章
  void _switchToPrevChapter() {
    if (_prevContent == null || _prevContentChapterIndex == null) return;

    // 获取上一章内容的高度（用于调整滚动位置）
    double prevChapterHeight = 0;
    final chapterContext = _currentChapterKey.currentContext;
    if (chapterContext != null) {
      final renderBox = chapterContext.findRenderObject() as RenderBox;
      prevChapterHeight = renderBox.size.height;
    }

    // 更新状态：将上一章设为当前章，当前章变为下一章缓存
    setState(() {
      // 当前章变为下一章缓存
      _nextContent = _content;
      _nextContentChapterIndex = _currentChapterIndex;
      // 上一章变为当前章
      _currentChapterIndex = _prevContentChapterIndex!;
      _chapterTitle = _chapters[_currentChapterIndex].title;
      _content = _prevContent!;
      _prevContent = null;
      _prevContentChapterIndex = null;
      _sliderValue = _currentChapterIndex.toDouble();
    });

    // 在下一帧调整滚动位置（加上当前章节高度，保持视觉位置不变）
    if (prevChapterHeight > 0 && _scrollController.hasClients) {
      final newOffset =
          _scrollController.offset + prevChapterHeight;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(newOffset);
        }
      });
    }

    // 预加载新的上一章
    _preloadPrevChapter();
    // 保存进度
    _scheduleProgressSave(pos: 0);
  }

  Future<void> _loadBookAndChapters() async {
    try {
      final bookData = StorageService.instance.getBook(widget.bookUrl);
      _book = bookData != null ? Book.fromJson(bookData) : widget.initialBook;
      // 局部变量捕获：避免 await 期间 _book 被置 null
      final book = _book;
      if (book != null) {
        final dataProvider = createBookDataProvider(book);
        _dataProvider = dataProvider;
        _chapters = await dataProvider.getChapterList(book);
        // await 后用户可能已退出
        if (!mounted) return;
        _totalChapters = _chapters.length;
        if (_totalChapters > 0) {
          final initialIndex = widget.resumeProgress
              ? book.durChapterIndex
              : widget.chapterIndex;
          _currentChapterIndex = _readableChapterIndex(initialIndex);
          _initialChapterPos = widget.resumeProgress ? book.durChapterPos : 0;
          _restoreInitialPosition =
              widget.resumeProgress && _initialChapterPos > 0;
          _sliderValue = _currentChapterIndex.toDouble();
        }
        // 加载书源信息
        if (book.originType == BookOriginType.online &&
            book.sourceUrl != null) {
          final sourceData = StorageService.instance.getBookSource(
            book.sourceUrl!,
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
      // 局部变量捕获：避免 await 期间 _book / _dataProvider 被置 null
      final book = _book;
      final dataProvider = _dataProvider;
      if (book == null || dataProvider == null) {
        _isChangingChapterByPageView = false;
        setState(() {
          _isLoading = false;
          _content = '无法加载内容';
        });
        return;
      }
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

      // 内存熔断：单章内容超过 5MB 时截断，防止 OOM 崩溃
      if (content != null && content.length > 5 * 1024 * 1024) {
        if (kDebugMode) debugPrint('⚠️ 章节内容过大 (${content.length} chars)，熔断截断');
        AppLogger.instance.warn(LogCategory.system, '章节内容过大熔断',
            detail: 'chapter=${chapter.title}, size=${content.length}');
        CrashLogService.instance.logJsEngineError(
          'Reader.oom',
          '章节内容过大: chapter=${chapter.title}, size=${content.length}',
        );
        content = '${content.substring(0, 5 * 1024 * 1024)}\n\n...(内容过长已截断)';
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

        // 更新TTS内容
        context.read<ReaderProvider>().setTtsChapterContent(_content);

        // 检查书签
        _checkBookmark();

        final provider = context.read<ReaderProvider>();
        final restorePos = _pendingInitialPageToEnd
            ? 1 << 30
            : _pendingInitialPage ??
                  (_restoreInitialPosition ? _initialChapterPos : 0);
        _restoreInitialPosition = false;
        _pendingInitialPage = null;
        _pendingInitialPageToEnd = false;
        _repaginate(initialPage: restorePos);

        // 滚动模式下重置滚动位置到顶部
        if (provider.pageMode == PageMode.scroll) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _scrollController.hasClients) {
              final target = restorePos > 0 ? restorePos.toDouble() : 0.0;
              _scrollController.jumpTo(
                target.clamp(0.0, _scrollController.position.maxScrollExtent),
              );
            }
          });
        }

        unawaited(_saveCurrentProgress(chapter: chapter, pos: restorePos));
        unawaited(_preloadAdjacentChapters(_currentChapterIndex));

        // 后台预取后续 N 章（Phase 3 流水线化：用户翻页时瞬时返回）
        if (book.originType == BookOriginType.online &&
            chapterIndex + 1 < _chapters.length) {
          final prefetchIndices = ChapterPrefetchService.computePrefetchIndices(
            chapterIndex,
            _chapters.length,
            5,
            isReadable: (i) => !_chapters[i].isVolume && _chapters[i].url != null,
          );
          if (prefetchIndices.isNotEmpty) {
            final prefetchChs =
                prefetchIndices.map((i) => _chapters[i]).toList();
            unawaited(ChapterPrefetchService.instance.prefetchChapters(
              book: book,
              chapters: prefetchChs,
              provider: dataProvider,
              allChapters: _chapters,
            ));
          }
        }
      }
    } catch (e) {
      if (mounted) {
        final provider = context.read<ReaderProvider>();
        setState(() {
          _content = '加载失败：$e';
          _chapterTitle = '加载失败';
          _isLoading = false;
          if (provider.pageMode != PageMode.scroll) {
            // 重建分页，避免翻页/仿真模式显示旧章节内容
            _pages = [_content];
            _currentPage = 0;
          }
        });
        if (provider.pageMode != PageMode.scroll) {
          _pageController?.dispose();
          _pageController = PageController(
            initialPage: _currentPage + _pagedLeadingCount,
          );
        }
      }
    } finally {
      // 始终释放翻页导航锁，防止阅读器卡死无法翻页
      _isChangingChapterByPageView = false;
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
    if (provider.pageMode == PageMode.scroll && _scrollController.hasClients) {
      return _scrollController.offset.round();
    }
    return _currentPage;
  }

  Future<void> _preloadAdjacentChapters(int chapterIndex) async {
    // 局部变量捕获：避免 await 期间 _book / _dataProvider 被置 null
    final book = _book;
    final dataProvider = _dataProvider;
    if (book == null || dataProvider == null) return;

    // 预加载下一章
    String? nextContent;
    final nextIndex = _nextReadableChapterIndex(chapterIndex);
    if (nextIndex != null) {
      final nextChapter = _chapters[nextIndex];
      nextContent = await dataProvider.getContent(
        book,
        nextChapter,
        allChapters: _chapters,
      );
    }

    // 预加载上一章
    String? prevContent;
    final prevIndex = _previousReadableChapterIndex(chapterIndex);
    if (prevIndex != null) {
      final prevChapter = _chapters[prevIndex];
      prevContent = await dataProvider.getContent(
        book,
        prevChapter,
        allChapters: _chapters,
      );
    }

    if (!mounted || _currentChapterIndex != chapterIndex) return;
    setState(() {
      _nextContent = nextContent;
      _nextContentChapterIndex = nextContent == null ? null : nextIndex;
      _prevContent = prevContent;
      _prevContentChapterIndex = prevContent == null ? null : prevIndex;
    });
  }

  Future<void> _preloadNextChapter() async {
    // 局部变量捕获：避免 await 期间 _book / _dataProvider 被置 null
    final book = _book;
    final dataProvider = _dataProvider;
    if (book == null || dataProvider == null || _nextContent != null) return;
    final nextIndex = _nextReadableChapterIndex(_currentChapterIndex);
    if (nextIndex != null) {
      final nextChapter = _chapters[nextIndex];
      _nextContent = await dataProvider.getContent(
        book,
        nextChapter,
        allChapters: _chapters,
      );
      _nextContentChapterIndex = nextIndex;
      if (mounted) setState(() {});
    }
  }

  /// 预加载上一章（用于滚动模式往上滑）
  Future<void> _preloadPrevChapter() async {
    // 局部变量捕获：避免 await 期间 _book / _dataProvider 被置 null
    final book = _book;
    final dataProvider = _dataProvider;
    if (book == null || dataProvider == null || _prevContent != null) return;
    final prevIndex = _previousReadableChapterIndex(_currentChapterIndex);
    if (prevIndex != null) {
      final prevChapter = _chapters[prevIndex];
      _prevContent = await dataProvider.getContent(
        book,
        prevChapter,
        allChapters: _chapters,
      );
      _prevContentChapterIndex = prevIndex;
      if (mounted) setState(() {});
    }
  }

  // ==================== Pagination ====================

  void _repaginate({int initialPage = 0}) {
    final provider = context.read<ReaderProvider>();
    if (provider.pageMode == PageMode.scroll) return;

    _pages = _splitContentToPages(_content, provider);
    _currentPage = initialPage.clamp(0, max(_pages.length - 1, 0));
    _pageController?.dispose();
    _pageController = PageController(
      initialPage: _currentPage + _pagedLeadingCount,
    );
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

    if (provider.pageMode == PageMode.scroll) {
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

    _pages = _splitContentToPages(_content, provider);
    final lastPage = max(_pages.length - 1, 0);
    _currentPage = (fraction.clamp(0.0, 1.0) * lastPage).round();
    _pageController?.dispose();
    _pageController = PageController(
      initialPage: _currentPage + _pagedLeadingCount,
    );
    _isChangingChapterByPageView = false;
    if (mounted) setState(() {});
    unawaited(_saveCurrentProgress(pos: _currentPage));
  }

  List<String> _splitContentToPages(String content, ReaderProvider provider) {
    final paragraphs = _splitToParagraphs(content);
    final pages = <String>[];
    if (paragraphs.isEmpty) return [''];

    final metrics = _pageMetrics(provider);
    final textStyle = _readerTextStyle(provider);
    var page = StringBuffer();
    var usedHeight = provider.showChapterTitle
        ? _measureTextHeight(
                _chapterTitle,
                _titleTextStyle(provider),
                metrics.width,
              ) +
              provider.paragraphSpacing
        : 0.0;

    for (final rawParagraph in paragraphs) {
      var paragraph = _applyIndent(rawParagraph, provider);
      while (paragraph.isNotEmpty) {
        final paragraphHeight =
            _measureTextHeight(paragraph, textStyle, metrics.width) +
            provider.paragraphSpacing;

        if (usedHeight + paragraphHeight <= metrics.height) {
          page.writeln(paragraph);
          usedHeight += paragraphHeight;
          paragraph = '';
          continue;
        }

        if (page.isNotEmpty) {
          pages.add(page.toString().trimRight());
          page = StringBuffer();
          usedHeight = 0;
          continue;
        }

        final splitIndex = _findFittingTextIndex(
          paragraph,
          textStyle,
          metrics.width,
          max(metrics.height - usedHeight - provider.paragraphSpacing,
              provider.fontSize),
        );
        pages.add(paragraph.substring(0, splitIndex).trimRight());
        paragraph = paragraph.substring(splitIndex).trimLeft();
        // 续页不再渲染标题，重置已用高度
        usedHeight = 0;
      }
    }

    if (page.isNotEmpty) {
      pages.add(page.toString().trimRight());
    }

    return pages.isEmpty ? [''] : pages;
  }

  ({double width, double height}) _pageMetrics(ReaderProvider provider) {
    final mq = MediaQuery.of(context);
    final width = max(
      80.0,
      mq.size.width -
          mq.padding.left -
          mq.padding.right -
          provider.horizontalPadding * 2,
    );
    final height = max(
      120.0,
      mq.size.height -
          mq.padding.top -
          mq.padding.bottom -
          provider.verticalPadding * 2,
    );
    return (width: width, height: height);
  }

  TextStyle _titleTextStyle(ReaderProvider provider) {
    return TextStyle(
      fontSize: provider.fontSize + 4,
      fontWeight: FontWeight.bold,
      color: provider.textColor,
      height: provider.lineHeight,
      fontFamily: provider.fontFamily.isNotEmpty ? provider.fontFamily : null,
    );
  }

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

  double _measureTextHeight(String text, TextStyle style, double width) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: width);
    return painter.height;
  }

  int _findFittingTextIndex(
    String text,
    TextStyle style,
    double width,
    double height,
  ) {
    var low = 1;
    var high = text.length;
    var best = 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final candidate = text.substring(0, mid);
      if (_measureTextHeight(candidate, style, width) <= height) {
        best = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return best.clamp(1, text.length);
  }

  static final _asciiEdgeWhitespace = RegExp(r'^[\t \r\f]+|[\t \r\f]+$');

  List<String> _splitToParagraphs(String content) {
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
    if (_showMenu || _isLoading) return;
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
    if (provider.pageMode == PageMode.scroll) {
      if (!_scrollController.hasClients) return;
      if (_scrollController.offset <= 8) {
        _previousChapter(toLastPage: true);
        return;
      }
      _scrollController.animateTo(
        max(_scrollController.offset - _scrollPageExtent(), 0),
        duration: _pageAnimationDuration(provider),
        curve: Curves.easeOut,
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
          _pageController?.dispose();
          _pageController = PageController(
            initialPage: _currentPage + _pagedLeadingCount,
          );
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
    if (provider.pageMode == PageMode.scroll) {
      if (!_scrollController.hasClients) return;
      final maxScroll = _scrollController.position.maxScrollExtent;
      // 如果已追加下一章内容，让用户继续滚动即可，不需要调用 _nextChapter()
      if (_nextContent != null) {
        // 下一章内容已追加到滚动列表，继续滚动
        _scrollController.animateTo(
          min(_scrollController.offset + _scrollPageExtent(), maxScroll),
          duration: _pageAnimationDuration(provider),
          curve: Curves.easeOut,
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
        curve: Curves.easeOut,
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
          _pageController?.dispose();
          _pageController = PageController(
            initialPage: _currentPage + _pagedLeadingCount,
          );
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
    return max(120.0, viewport - 48);
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
    }
  }

  void _nextChapter() {
    final nextIndex = _nextReadableChapterIndex(_currentChapterIndex);
    if (nextIndex != null) {
      setState(() {
        _currentChapterIndex = nextIndex;
      });
      _loadChapterContent();
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
        body: GestureDetector(
          onTapUp: _handleTap,
          onLongPressStart: _onLongPressStart,
          child: Stack(
            children: [
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
              if (_useEnhancedControls && _showMenu)
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
                  isAutoScroll: false,
                  isNightMode: provider.isNightMode,
                  sliderValue: _sliderValue,
                  onBack: () => Navigator.pop(context),
                  onChangeSource: _showChangeSourceDialog,
                  onOpenDetail: _openBookDetail,
                  onOpenChapterUrl: _openChapterUrl,
                  onEditSource: () => _handleSourceAction('edit'),
                  onDisableSource: () => _handleSourceAction('disable'),
                  onRefresh: () {
                    _loadChapterContent();
                  },
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
                  onStartSearch: () {},
                  onToggleAutoScroll: () {},
                  onToggleNightMode: () {
                    provider.toggleNightMode();
                  },
                  onOpenReplaceRules: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('替换规则功能暂未开放'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
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
              // 原版菜单
              else if (_showMenu)
                _buildMenu(provider),
              if (_showHighlightMenu) _buildHighlightMenu(provider),
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
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: EdgeInsets.symmetric(
          horizontal: provider.horizontalPadding,
          vertical: provider.verticalPadding,
        ),
        child: RepaintBoundary(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 上一章内容（往上滑无缝衔接）
              if (_prevContent != null &&
                  _prevContentChapterIndex != null &&
                  _prevContentChapterIndex! < _chapters.length &&
                  _prevContentChapterIndex ==
                      _previousReadableChapterIndex(_currentChapterIndex))
                _buildAdjacentChapterContent(
                  provider,
                  _prevContent!,
                  _chapters[_prevContentChapterIndex!].title,
                ),
              // 当前章节内容，用 GlobalKey 包裹以便检测滚动位置
              Container(
                key: _currentChapterKey,
                child: _buildChapterContent(
                  provider,
                  _content,
                  _chapterTitle,
                ),
              ),
              // 下一章内容（往下滑无缝衔接）
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
    );
  }

  Widget _buildAdjacentChapterContent(
    ReaderProvider provider,
    String content,
    String title,
  ) {
    return Padding(
      padding: EdgeInsets.only(top: provider.paragraphSpacing * 2),
      child: _buildChapterContent(provider, content, title),
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
        if (provider.showChapterTitle)
          Text(
            title,
            style: _titleTextStyle(provider),
            textAlign: TextAlign.center,
          ),
        SizedBox(height: provider.paragraphSpacing),
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
  }) {
    // 如果内容包含 HTML 标签，使用 Html 组件渲染
    if (_containsHtml(content)) {
      // 全角空格宽度等于字号本身，两个全角空格 = 2 * fontSize
      final indentWidth = provider.paragraphIndent.isNotEmpty
          ? provider.paragraphIndent.length * provider.fontSize
          : 0.0;
      // 使用 CSS text-indent 实现首行缩进（不是整个段落左移）
      final htmlWithIndent = indentWidth > 0
          ? '<style>p, div { text-indent: ${indentWidth}px; }</style>$content'
          : content;
      return Html(
        data: htmlWithIndent,
        style: {
          'body': Style(
            fontSize: FontSize(provider.fontSize),
            color: provider.textColor,
            lineHeight: LineHeight(provider.lineHeight),
            fontFamily: provider.fontFamily,
            fontWeight: _readerFontWeight(provider),
            textAlign: TextAlign.justify,
          ),
          'p': Style(
            margin: Margins.only(bottom: provider.paragraphSpacing),
          ),
          'div': Style(
            margin: Margins.only(bottom: provider.paragraphSpacing),
          ),
        },
      );
    }

    final paragraphs = _splitToParagraphs(content);
    final highlights = _getActiveHighlights();
    final rules = provider.highlightRules.where((r) => r.enabled).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: paragraphs.map((para) {
        final indentedPara = applyIndent ? _applyIndent(para, provider) : para;
        return Padding(
          padding: EdgeInsets.only(bottom: provider.paragraphSpacing),
          child: _buildRichParagraph(provider, indentedPara, highlights, rules),
        );
      }).toList(),
    );
  }

  String _applyIndent(String paragraph, ReaderProvider provider) {
    // 去除源内容自带的全角空格缩进 + ASCII 左空白，再统一加上配置缩进
    final trimmed = paragraph.replaceAll(RegExp(r'^[\u3000\t ]+'), '');
    if (provider.paragraphIndent.isEmpty) return trimmed;
    return '${provider.paragraphIndent}$trimmed';
  }

  Widget _buildRichParagraph(
    ReaderProvider provider,
    String text,
    List<Highlight> highlights,
    List<HighlightRule> rules,
  ) {
    final spans = _buildTextSpans(provider, text, highlights, rules);
    return Text.rich(
      TextSpan(children: spans),
      style: _readerTextStyle(provider),
      textAlign: TextAlign.justify,
      softWrap: true,
    );
  }

  FontWeight _readerFontWeight(ReaderProvider provider) {
    switch (provider.fontWeightIndex) {
      case 0:
        return FontWeight.w300;
      case 2:
        return FontWeight.w700;
      default:
        return FontWeight.w400;
    }
  }

  List<InlineSpan> _buildTextSpans(
    ReaderProvider provider,
    String text,
    List<Highlight> highlights,
    List<HighlightRule> rules,
  ) {
    // Build a map of character indices to highlight/style info
    final styleMap = <int, _HighlightInfo>{};

    // Apply manual highlights
    for (final h in highlights) {
      for (var i = h.startIndex; i < h.endIndex && i < text.length; i++) {
        styleMap[i] = _HighlightInfo(
          color: h.color,
          style: h.style,
          note: h.note,
        );
      }
    }

    // Apply regex rules
    for (final rule in rules) {
      try {
        final regex = RegExp(rule.pattern, multiLine: true);
        for (final match in regex.allMatches(text)) {
          for (var i = match.start; i < match.end && i < text.length; i++) {
            styleMap.putIfAbsent(
              i,
              () => _HighlightInfo(color: rule.color, style: rule.style),
            );
          }
        }
      } catch (_) {}
    }

    if (styleMap.isEmpty) {
      return [TextSpan(text: text)];
    }

    final spans = <InlineSpan>[];
    var currentStart = 0;
    _HighlightInfo? currentInfo;

    for (var i = 0; i <= text.length; i++) {
      final info = styleMap[i];
      if (info != currentInfo) {
        if (i > currentStart && currentInfo != null) {
          spans.add(
            _buildHighlightSpan(
              text.substring(currentStart, i),
              currentInfo,
              provider,
            ),
          );
        } else if (i > currentStart) {
          spans.add(TextSpan(text: text.substring(currentStart, i)));
        }
        currentStart = i;
        currentInfo = info;
      }
    }

    return spans;
  }

  InlineSpan _buildHighlightSpan(
    String text,
    _HighlightInfo info,
    ReaderProvider provider,
  ) {
    final highlightColor = info.color.color;

    switch (info.style) {
      case HighlightStyle.background:
        return TextSpan(
          text: text,
          style: TextStyle(
            backgroundColor: highlightColor.withValues(alpha: 0.4),
            color: provider.textColor,
          ),
        );
      case HighlightStyle.underline:
        return TextSpan(
          text: text,
          style: TextStyle(
            decoration: TextDecoration.underline,
            decorationColor: highlightColor,
            decorationThickness: 2,
            color: provider.textColor,
          ),
        );
      case HighlightStyle.strikethrough:
        return TextSpan(
          text: text,
          style: TextStyle(
            decoration: TextDecoration.lineThrough,
            decorationColor: highlightColor,
            decorationThickness: 2,
            color: provider.textColor,
          ),
        );
      case HighlightStyle.wavy:
        return TextSpan(
          text: text,
          style: TextStyle(
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.wavy,
            decorationColor: highlightColor,
            decorationThickness: 2,
            color: provider.textColor,
          ),
        );
    }
  }

  List<Highlight> _getActiveHighlights() {
    if (_book == null) return [];
    return StorageService.instance
        .getChapterHighlights(
          _book?.bookUrl ?? widget.bookUrl,
          _currentChapterIndex,
        )
        .map((e) => Highlight.fromJson(e))
        .toList();
  }

  // ==================== Slide Mode (PageView) ====================

  Widget _buildSlideContent(ReaderProvider provider) {
    return SafeArea(child: _buildPagedView(provider));
  }

  // ==================== Cover Mode ====================

  Widget _buildCoverContent(ReaderProvider provider) {
    return SafeArea(child: _buildPagedView(provider));
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
          return _buildChapterBoundaryPage(provider, '上一章');
        }
        final pageIndex = index - leadingCount;
        if (pageIndex >= _pages.length) {
          return _buildChapterBoundaryPage(provider, '下一章');
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
      _previousChapter(toLastPage: true);
      return;
    }
    final pageIndex = index - leadingCount;
    if (pageIndex >= _pages.length) {
      _isChangingChapterByPageView = true;
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
      color: provider.backgroundColor,
      alignment: Alignment.center,
      child: Text(
        text,
        style: TextStyle(
          color: provider.textColor.withValues(alpha: 0.58),
          fontSize: max(14, provider.fontSize - 2),
        ),
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
                if (delta < -50) {
                  _nextPage();
                } else if (delta > 50) {
                  _previousPage();
                }
                _dragCurrentX = 0;
                _dragStartX = 0;
                setState(() {});
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
    final showTitle = provider.showChapterTitle && pageIndex == 0;
    return Container(
      color: provider.backgroundColor,
      padding: EdgeInsets.symmetric(
        horizontal: provider.horizontalPadding,
        vertical: provider.verticalPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle)
            Text(
              _chapterTitle,
              style: _titleTextStyle(provider),
              textAlign: TextAlign.center,
            ),
          if (showTitle) SizedBox(height: provider.paragraphSpacing),
          Expanded(
            child: _buildRichContent(provider, pageText),
          ),
        ],
      ),
    );
  }

  // ==================== Highlight Selection ====================

  void _onLongPressStart(LongPressStartDetails details) {
    // Show selection handles via SelectableText is handled differently
    // For now, we'll use a simple approach with a dialog
    _showTextSelectionDialog();
  }

  void _showTextSelectionDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('选择文字'),
          content: TextField(
            autofocus: true,
            decoration: const InputDecoration(hintText: '输入要高亮的文字'),
            onSubmitted: (value) {
              Navigator.pop(context, value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                // This is a simplified approach
                Navigator.pop(context);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHighlightMenu(ReaderProvider provider) {
    return Positioned(
      top: _highlightMenuPosition.dy - 60,
      left: max(16, _highlightMenuPosition.dx - 100),
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: DesignTokens.spacingSm, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _highlightActionButton('高亮', Icons.highlight, () {
                _showHighlightColorPicker();
              }),
              _highlightActionButton('笔记', Icons.note_add, () {
                _showNoteDialog();
              }),
              _highlightActionButton('复制', Icons.copy, () {
                _copySelectedText();
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _highlightActionButton(
    String label,
    IconData icon,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DesignTokens.spacingSm, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20),
            Text(label, style: const TextStyle(fontSize: DesignTokens.fontCaption)),
          ],
        ),
      ),
    );
  }

  void _showHighlightColorPicker() {
    final colors = HighlightColor.values;

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(DesignTokens.spacingLg),
                child: Text('选择高亮样式', style: TextStyle(fontSize: DesignTokens.fontSubtitle)),
              ),
              // Color row
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: colors.map((c) {
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                        _showHighlightStylePicker(c);
                      },
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: c.color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.grey),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: DesignTokens.spacingLg),
            ],
          ),
        );
      },
    );
  }

  void _showHighlightStylePicker(HighlightColor color) {
    final styles = HighlightStyle.values;
    final styleNames = ['背景色', '下划线', '删除线', '波浪线'];

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(DesignTokens.spacingLg),
                child: Text('选择高亮类型', style: TextStyle(fontSize: DesignTokens.fontSubtitle)),
              ),
              ...List.generate(styles.length, (i) {
                return ListTile(
                  leading: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: color.color.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
                    ),
                  ),
                  title: Text(styleNames[i]),
                  onTap: () {
                    _createHighlight(color, styles[i]);
                    Navigator.pop(context);
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  void _createHighlight(HighlightColor color, HighlightStyle style) {
    if (_book == null || _selectionStart < 0 || _selectionEnd < 0) return;

    final highlight = Highlight(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      bookUrl: _book!.bookUrl,
      chapterIndex: _currentChapterIndex,
      startIndex: _selectionStart,
      endIndex: _selectionEnd,
      selectedText: _selectedText,
      style: style,
      color: color,
      createdAt: DateTime.now(),
    );

    StorageService.instance.saveHighlight(highlight.toJson());
    context.read<ReaderProvider>().addHighlight(highlight);

    setState(() {
      _showHighlightMenu = false;
    });
  }

  void _showNoteDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('添加笔记'),
          content: TextField(
            controller: controller,
            maxLines: 3,
            decoration: const InputDecoration(hintText: '输入笔记内容'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final note = controller.text.trim();
                if (note.isNotEmpty) {
                  _createHighlightWithNote(note);
                }
                Navigator.pop(context);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _createHighlightWithNote(String note) {
    if (_book == null || _selectionStart < 0 || _selectionEnd < 0) return;

    final highlight = Highlight(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      bookUrl: _book!.bookUrl,
      chapterIndex: _currentChapterIndex,
      startIndex: _selectionStart,
      endIndex: _selectionEnd,
      selectedText: _selectedText,
      style: HighlightStyle.background,
      color: HighlightColor.yellow,
      note: note,
      createdAt: DateTime.now(),
    );

    StorageService.instance.saveHighlight(highlight.toJson());
    context.read<ReaderProvider>().addHighlight(highlight);

    setState(() {
      _showHighlightMenu = false;
    });
  }

  void _copySelectedText() {
    if (_selectedText.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: _selectedText));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制到剪贴板'),
          duration: Duration(seconds: 1),
        ),
      );
    }
    setState(() {
      _showHighlightMenu = false;
    });
  }

  // ==================== Menu ====================

  Widget _buildMenu(ReaderProvider provider) {
    return FadeTransition(
      opacity: _menuAnim,
      child: Column(
        children: [_buildTopBar(), const Spacer(), _buildBottomBar(provider)],
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Text(
                _chapterTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: DesignTokens.fontSubtitle),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.list),
              onPressed: _showChapterList,
              tooltip: '目录',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(ReaderProvider provider) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgressSlider(),
            const SizedBox(height: DesignTokens.spacingSm),
            _buildQuickActionsGrid(provider),
            const SizedBox(height: DesignTokens.spacingSm),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressSlider() {
    final maxCh = (_totalChapters - 1).clamp(0, 999999).toDouble();
    final displayChapter = (_sliderValue + 1).round();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg),
      child: Row(
        children: [
          Text('$displayChapter', style: const TextStyle(fontSize: DesignTokens.fontCaption)),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                value: _totalChapters > 0 ? _sliderValue.clamp(0.0, maxCh) : 0,
                min: 0,
                max: maxCh > 0 ? maxCh : 1,
                onChanged: (value) {
                  setState(() {
                    _sliderValue = value;
                  });
                },
                onChangeEnd: (value) {
                  _currentChapterIndex = _readableChapterIndex(value.round());
                  _loadChapterContent();
                },
              ),
            ),
          ),
          Text('$_totalChapters', style: const TextStyle(fontSize: DesignTokens.fontCaption)),
        ],
      ),
    );
  }

  // ==================== 9-Grid Quick Actions ====================

  Widget _buildQuickActionsGrid(ReaderProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          // Row 1: [目录] [夜间模式] [字体]
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _quickActionButton(
                icon: Icons.list,
                label: '目录',
                onTap: _showChapterList,
              ),
              _quickActionButton(
                icon: provider.isNightMode ? Icons.light_mode : Icons.dark_mode,
                label: provider.isNightMode ? '日间' : '夜间',
                onTap: () {
                  provider.toggleNightMode();
                },
              ),
              _quickActionButton(
                icon: Icons.font_download,
                label: '字体',
                onTap: () => _showFontDialog(provider),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Row 2: [翻页模式] [背景色] [更多设置]
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _quickActionButton(
                icon: _pageModeIcon(provider.pageMode),
                label: _pageModeLabel(provider.pageMode),
                onTap: () => _showPageModePicker(provider),
              ),
              _quickActionButton(
                icon: Icons.palette,
                label: '背景色',
                onTap: () => _showBackgroundColorDialog(provider),
              ),
              _quickActionButton(
                icon: Icons.settings,
                label: '更多',
                onTap: () => _showMoreSettingsDialog(provider),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _quickActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(fontSize: DesignTokens.fontCaption),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  IconData _pageModeIcon(PageMode mode) {
    switch (mode) {
      case PageMode.scroll:
        return Icons.view_agenda;
      case PageMode.slide:
        return Icons.swap_horiz;
      case PageMode.cover:
        return Icons.auto_stories;
      case PageMode.simulation:
        return Icons.menu_book;
      case PageMode.none:
        return Icons.block;
    }
  }

  String _pageModeLabel(PageMode mode) {
    switch (mode) {
      case PageMode.scroll:
        return '滚动';
      case PageMode.slide:
        return '滑动';
      case PageMode.cover:
        return '覆盖';
      case PageMode.simulation:
        return '仿真';
      case PageMode.none:
        return '无动画';
    }
  }

  // ==================== Dialogs ====================

  void _showChangeSourceDialog() {
    _hideMenu();
    // 局部变量捕获：避免弹窗显示期间 _book 被置 null
    final book = _book;
    if (book == null || book.originType != BookOriginType.online) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本地书籍不支持换源')));
      return;
    }

    ChangeSourceSheet.show(
      context: context,
      bookName: book.displayName,
      bookAuthor: book.displayAuthor,
      currentSourceUrl: book.sourceUrl,
      currentSourceName: book.sourceName,
      onSourceSelected: (sourceUrl, sourceName, bookData) async {
        // 回调可能在弹窗显示后任意时刻触发，使用局部变量避免 _book 野指针
        if (!mounted) return;

        try {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('正在切换书源...')));

          // 创建新的书籍对象（用局部 book 而非 _book!）
          final newBook = book.copyWith(
            sourceUrl: sourceUrl,
            sourceName: sourceName,
            bookUrl: bookData['bookUrl'] ?? book.bookUrl,
            name: bookData['name'] ?? book.name,
            author: bookData['author'] ?? book.author,
            coverUrl: bookData['coverUrl'] ?? book.coverUrl,
            intro: bookData['intro'] ?? book.intro,
            lastChapter: bookData['lastChapter'] ?? book.lastChapter,
          );

          // 获取新书源的目录
          final dataProvider = createBookDataProvider(newBook);
          _dataProvider = dataProvider;
          final chapters = await dataProvider.getChapterList(newBook);

          // await 后页面可能已退出
          if (!mounted) return;

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

          _loadChapterContent();

          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('已切换到 $sourceName')));
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
      ),
    );
  }

  void _showFontDialog(ReaderProvider provider) {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('字体设置'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Font size
                    Row(
                      children: [
                        const Text('字号'),
                        Expanded(
                          child: Slider(
                            value: provider.fontSize,
                            min: 12,
                            max: 32,
                            divisions: 20,
                            onChanged: (value) {
                              provider.setFontSize(value);
                              setDialogState(() {});
                            },
                          ),
                        ),
                        Text('${provider.fontSize.toInt()}'),
                      ],
                    ),
                    // Letter spacing
                    Row(
                      children: [
                        const Text('字距'),
                        Expanded(
                          child: Slider(
                            value: provider.letterSpacing,
                            min: 0,
                            max: 5,
                            divisions: 50,
                            onChanged: (value) {
                              provider.setLetterSpacing(value);
                              setDialogState(() {});
                            },
                          ),
                        ),
                        Text(provider.letterSpacing.toStringAsFixed(1)),
                      ],
                    ),
                    // Font family
                    const SizedBox(height: DesignTokens.spacingSm),
                    Row(
                      children: [
                        const Text('字体'),
                        const SizedBox(width: DesignTokens.spacingSm),
                        Expanded(
                          child: DropdownButton<String>(
                            value: provider.fontFamily.isEmpty
                                ? '默认'
                                : provider.fontFamily,
                            isExpanded: true,
                            items: ['默认', ..._getSystemFonts()].map((f) {
                              return DropdownMenuItem(value: f, child: Text(f));
                            }).toList(),
                            onChanged: (value) {
                              provider.setFontFamily(
                                value == '默认' ? '' : value!,
                              );
                              setDialogState(() {});
                            },
                          ),
                        ),
                      ],
                    ),
                    // EPUB font loading
                    if (_book != null &&
                        LocalBookService.detectBookType(_book!.bookUrl) ==
                            LocalBookType.epub) ...[
                      const SizedBox(height: DesignTokens.spacingSm),
                      SwitchListTile(
                        title: const Text('加载EPUB内嵌字体'),
                        value: provider.loadEpubFonts,
                        onChanged: (value) {
                          provider.setLoadEpubFonts(value);
                          setDialogState(() {});
                        },
                      ),
                    ],
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

  List<String> _getSystemFonts() {
    // Common system fonts
    return ['serif', 'sans-serif', 'monospace'];
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

  void _showPageModePicker(ReaderProvider provider) {
    final modes = PageMode.values;
    final labels = ['滚动', '滑动', '覆盖', '仿真'];
    final icons = [
      Icons.view_agenda,
      Icons.swap_horiz,
      Icons.auto_stories,
      Icons.menu_book,
    ];

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(DesignTokens.spacingLg),
                child: Text(
                  '翻页模式',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(modes.length, (i) {
                  final isSelected = provider.pageMode == modes[i];
                  return GestureDetector(
                    onTap: () {
                      provider.setPageMode(modes[i]);
                      _repaginatePreservingPosition();
                      Navigator.pop(context);
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.2)
                                : Colors.grey.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(DesignTokens.panelRadius),
                            border: isSelected
                                ? Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    width: 2,
                                  )
                                : null,
                          ),
                          child: Icon(
                            icons[i],
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          labels[i],
                          style: TextStyle(
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : null,
                            fontWeight: isSelected ? FontWeight.bold : null,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
              const SizedBox(height: DesignTokens.spacingLg),
            ],
          ),
        );
      },
    );
  }

  void _showBackgroundColorDialog(ReaderProvider provider) {
    final colors = [
      const Color(0xFFFFF8E1), // warm yellow
      const Color(0xFFE8F5E9), // green
      const Color(0xFFE3F2FD), // blue
      const Color(0xFFFFF3E0), // orange
      const Color(0xFFF3E5F5), // purple
      const Color(0xFF1A1A1A), // dark
    ];

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('背景色'),
          content: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: colors.map((color) {
              return GestureDetector(
                onTap: () {
                  provider.setBackgroundColor(color);
                  Navigator.pop(context);
                },
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: provider.backgroundColor == color
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                      width: 2,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
  }

  void _showBrightnessDialog(ReaderProvider provider) {
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
                    value: provider.brightness,
                    min: 0.1,
                    max: 1.0,
                    onChanged: (value) {
                      provider.setBrightness(value);
                      setDialogState(() {});
                    },
                  ),
                  Text('${(provider.brightness * 100).toInt()}%'),
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
                },
              ),
              if (_book?.originType == BookOriginType.online) ...[
                ListTile(
                  leading: const Icon(Icons.download_for_offline),
                  title: const Text('缓存后续50章'),
                  onTap: () {
                    Navigator.pop(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.cloud_download),
                  title: const Text('缓存全本'),
                  onTap: () {
                    Navigator.pop(context);
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
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
    return ReaderSettingsSheet(
      fontSize: provider.fontSize,
      lineHeight: provider.lineHeight,
      letterSpacing: provider.letterSpacing,
      paragraphSpacing: provider.paragraphSpacing,
      horizontalPadding: provider.horizontalPadding,
      verticalPadding: provider.verticalPadding,
      paragraphIndent: provider.paragraphIndent,
      fontWeightIndex: provider.fontWeightIndex,
      fontFamily: provider.fontFamily,
      backgroundColor: provider.backgroundColor,
      backgroundImagePath: provider.backgroundImagePath,
      showReadingInfo: provider.showReadingInfo,
      showChapterTitle: provider.showChapterTitle,
      showClock: provider.showClock,
      showProgress: provider.showProgress,
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
      onHorizontalPaddingChanged: (value) {
        provider.setHorizontalPadding(value);
        _repaginatePreservingPosition();
      },
      onVerticalPaddingChanged: (value) {
        provider.setVerticalPadding(value);
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
      onFontFamilyChanged: (value) => provider.setFontFamily(value),
      onBackgroundColorChanged: (value) => provider.setBackgroundColor(value),
      onBackgroundImageChanged: (value) =>
          provider.setBackgroundImagePath(value),
      onShowReadingInfoChanged: (value) => provider.setShowReadingInfo(value),
      onShowChapterTitleChanged: (value) {
        provider.setShowChapterTitle(value);
        _repaginatePreservingPosition();
      },
      onShowClockChanged: (value) => provider.setShowClock(value),
      onShowProgressChanged: (value) => provider.setShowProgress(value),
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
                      provider.setBrightness(1.0);
                      Navigator.pop(context);
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
                            onTap: () {
                              _showTapZoneActionPicker(
                                provider,
                                row,
                                col,
                                actionLabels,
                              );
                              setDialogState(() {});
                            },
                            child: Container(
                              margin: const EdgeInsets.all(2),
                              padding: const EdgeInsets.all(DesignTokens.spacingSm),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
                                color: row == 1 && col == 1
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.primary.withValues(alpha: 0.1)
                                    : null,
                              ),
                              child: Text(
                                actionLabels[action] ?? '无',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: DesignTokens.fontCaption),
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

  void _showTapZoneActionPicker(
    ReaderProvider provider,
    int row,
    int col,
    Map<TapZoneAction, String> actionLabels,
  ) {
    showDialog(
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
    final rules = provider.highlightRules;

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
                              onPressed: () {
                                _showAddHighlightRuleDialog(provider);
                                setSheetState(() {});
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
                            return SwitchListTile(
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
                              value: rule.enabled,
                              onChanged: rule.isBuiltIn
                                  ? (value) {
                                      final updated = HighlightRule(
                                        id: rule.id,
                                        name: rule.name,
                                        pattern: rule.pattern,
                                        style: rule.style,
                                        color: rule.color,
                                        enabled: value,
                                        isBuiltIn: rule.isBuiltIn,
                                        serialNumber: rule.serialNumber,
                                      );
                                      StorageService.instance.saveHighlightRule(
                                        updated.toJson(),
                                      );
                                      provider.toggleHighlightRule(rule.id);
                                      setSheetState(() {});
                                    }
                                  : null,
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

  void _showAddHighlightRuleDialog(ReaderProvider provider) {
    final nameController = TextEditingController();
    final patternController = TextEditingController();
    var selectedColor = HighlightColor.yellow;
    var selectedStyle = HighlightStyle.background;

    showDialog(
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
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () {
                    if (nameController.text.isEmpty ||
                        patternController.text.isEmpty)
                      return;
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
    final overrides = Map<String, String>.from(provider.fontOverrides);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
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
                          onPressed: () {
                            _showAddFontOverrideDialog(provider);
                            setSheetState(() {});
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
                            overrides.remove(entry.key);
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

  void _showAddFontOverrideDialog(ReaderProvider provider) {
    final originalController = TextEditingController();
    final overrideController = TextEditingController();

    showDialog(
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
              onPressed: () => Navigator.pop(context),
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
    if (isDragLeft) {
      canvas.drawLine(Offset(touchX, 0), Offset(touchX, height), linePaint);
    } else {
      canvas.drawLine(Offset(touchX, 0), Offset(touchX, height), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PageCurlPainter oldDelegate) {
    return oldDelegate.dragDelta != dragDelta ||
        oldDelegate.isDragLeft != isDragLeft;
  }
}

// ==================== Helper Classes ====================

class _HighlightInfo {
  final HighlightColor color;
  final HighlightStyle style;
  final String? note;

  _HighlightInfo({required this.color, required this.style, this.note});
}

class _NovelChapterListPanel extends StatefulWidget {
  final Book? book;
  final List<Chapter> chapters;
  final int totalChapters;
  final int currentChapterIndex;
  final Color foregroundColor;
  final Function(int) onChapterSelected;

  const _NovelChapterListPanel({
    this.book,
    required this.chapters,
    required this.totalChapters,
    required this.currentChapterIndex,
    required this.foregroundColor,
    required this.onChapterSelected,
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

  @override
  void initState() {
    super.initState();
    _loadCacheInfo();
    _loadBookmarks();
    _loadPrefs();
  }

  @override
  void dispose() {
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
          padding: const EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg, vertical: 8),
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
            padding: const EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg),
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
      padding: const EdgeInsets.symmetric(horizontal: DesignTokens.spacingLg, vertical: 12),
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
    return ListView.separated(
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

        return InkWell(
          onTap: () => widget.onChapterSelected(chapter.index),
          child: Padding(
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
                          color: isSelected ? accent : fg,
                          fontSize: DesignTokens.fontBody,
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
                  Icon(Icons.check, size: 18, color: accent)
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
            style: TextStyle(color: fg.withValues(alpha: 0.5), fontSize: DesignTokens.fontCaption),
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
                bookUrl: widget.book!.bookUrl,
                bookmarkId: bookmark.id,
              );
              _loadBookmarks();
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
