import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/book.dart';
import '../../models/chapter.dart';
import '../../models/highlight.dart';
import '../../providers/reader_provider.dart';
import '../../providers/bookshelf_provider.dart';
import '../../services/book_data_provider.dart';
import '../../services/chapter_cache_service.dart';
import '../../services/local_book/local_book_service.dart';
import '../../services/reader_bookmark_service.dart';
import '../../services/storage_service.dart';
import '../../services/read_record_service.dart';
import '../../widgets/reader/reader_control_overlay.dart';
import '../../widgets/reader/reader_settings_sheet.dart';
import '../../widgets/reader/reader_tts_bar.dart';

class NovelReaderPage extends StatefulWidget {
  final String bookUrl;
  final int chapterIndex;
  final Book? initialBook;

  const NovelReaderPage({
    super.key,
    required this.bookUrl,
    this.chapterIndex = 0,
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
  int _currentChapterIndex = 0;
  int _totalChapters = 0;
  bool _isLoading = true;
  Book? _book;
  List<Chapter> _chapters = [];
  BookDataProvider? _dataProvider;
  double _sliderValue = 0; // 滑动进度条的实时值
  bool _isSliderDragging = false; // 进度条是否正在拖拽

  String? _prevContent;
  String? _nextContent;
  String? _prevChapterTitle;
  String? _nextChapterTitle;

  // Pagination for non-scroll modes
  List<String> _pages = [];
  int _currentPage = 0;
  PageController? _pageController;

  // Scroll mode controller
  final ScrollController _scrollController = ScrollController();

  // Highlight selection state
  final String _selectedText = '';
  final int _selectionStart = -1;
  final int _selectionEnd = -1;
  bool _showHighlightMenu = false;
  final Offset _highlightMenuPosition = Offset.zero;

  // Animation
  late AnimationController _menuAnimController;
  late Animation<double> _menuAnim;

  // Simulation page curl
  double _dragStartX = 0;
  double _dragCurrentX = 0;
  bool _isDragging = false;

  // 增强版控制
  final bool _useEnhancedControls = true;
  bool _showSettingsSheet = false;
  bool _hasBookmark = false;
  double _ttsSpeed = 1.0;
  
  // 阅读记录
  int _readStartTime = 0;

  @override
  void initState() {
    super.initState();
    _currentChapterIndex = widget.chapterIndex;
    _sliderValue = widget.chapterIndex.toDouble();
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
          .where((b) =>
              b.bookUrl == _book!.bookUrl &&
              b.chapterIndex == _currentChapterIndex)
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
    setState(() {
      _showSettingsSheet = true;
    });
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

    // Auto-load next chapter when near bottom
    if (maxScroll - currentScroll < 500 && _nextContent == null) {
      _preloadNextChapter();
    }
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
          _currentChapterIndex =
              widget.chapterIndex.clamp(0, _totalChapters - 1);
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
    if (_book == null || _chapters.isEmpty) {
      setState(() {
        _isLoading = false;
        _content = '无法加载内容';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _sliderValue = _currentChapterIndex.toDouble();
    });

    final chapter = _currentChapterIndex < _chapters.length
        ? _chapters[_currentChapterIndex]
        : null;

    if (chapter == null) {
      setState(() {
        _isLoading = false;
        _content = '章节不存在';
      });
      return;
    }

    // 优先从缓存读取
    String? content;
    if (_book!.originType == BookOriginType.online) {
      content = await ChapterCacheService.instance.readChapterContent(_book!, chapter);
    }

    // 缓存没有则从网络获取
    if (content == null || content.isEmpty) {
      content = await _dataProvider!.getContent(_book!, chapter);
      // 保存到缓存
      if (content != null && content.isNotEmpty && _book!.originType == BookOriginType.online) {
        unawaited(ChapterCacheService.instance.saveChapterContent(_book!, chapter, content));
      }
    }

    _preloadAdjacentChapters();

    if (mounted) {
      setState(() {
        _chapterTitle = chapter.title;
        _content = content ?? '内容加载失败';
        _isLoading = false;
      });

      // 更新TTS内容
      context.read<ReaderProvider>().setTtsChapterContent(_content);

      // 检查书签
      _checkBookmark();

      _repaginate();

      // 滚动模式下重置滚动位置到顶部
      final provider = context.read<ReaderProvider>();
      if (provider.pageMode == PageMode.scroll && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }

      context.read<BookshelfProvider>().updateBookProgress(
            widget.bookUrl,
            durChapterIndex: _currentChapterIndex,
            durChapterTitle: chapter.title,
          );
    }
  }

  Future<void> _preloadAdjacentChapters() async {
    if (_book == null) return;

    if (_currentChapterIndex > 0) {
      final prevChapter = _chapters[_currentChapterIndex - 1];
      _prevContent = await _dataProvider!.getContent(_book!, prevChapter);
      _prevChapterTitle = prevChapter.title;
    } else {
      _prevContent = null;
      _prevChapterTitle = null;
    }

    if (_currentChapterIndex < _totalChapters - 1) {
      final nextChapter = _chapters[_currentChapterIndex + 1];
      _nextContent = await _dataProvider!.getContent(_book!, nextChapter);
      _nextChapterTitle = nextChapter.title;
    } else {
      _nextContent = null;
      _nextChapterTitle = null;
    }
  }

  Future<void> _preloadNextChapter() async {
    if (_book == null || _nextContent != null) return;
    if (_currentChapterIndex < _totalChapters - 1) {
      final nextChapter = _chapters[_currentChapterIndex + 1];
      _nextContent = await _dataProvider!.getContent(_book!, nextChapter);
      _nextChapterTitle = nextChapter.title;
      if (mounted) setState(() {});
    }
  }

  // ==================== Pagination ====================

  void _repaginate() {
    final provider = context.read<ReaderProvider>();
    if (provider.pageMode == PageMode.scroll) return;

    _pages = _splitContentToPages(_content, provider);
    _currentPage = 0;
    _pageController?.dispose();
    _pageController = PageController(initialPage: 0);
    if (mounted) setState(() {});
  }

  List<String> _splitContentToPages(String content, ReaderProvider provider) {
    final charsPerPage = _estimateCharsPerPage(provider);
    final paragraphs = _splitToParagraphs(content);
    final pages = <String>[];
    var currentPage = StringBuffer();

    for (final para in paragraphs) {
      if (currentPage.length + para.length > charsPerPage &&
          currentPage.isNotEmpty) {
        pages.add(currentPage.toString());
        currentPage = StringBuffer();
      }
      currentPage.writeln(para);
    }

    if (currentPage.isNotEmpty) {
      pages.add(currentPage.toString());
    }

    return pages.isEmpty ? [''] : pages;
  }

  int _estimateCharsPerPage(ReaderProvider provider) {
    // Rough estimate: assume ~800 chars per page for typical novel reading
    // Adjust based on font size
    final baseChars = 800;
    final fontSizeRatio = 18.0 / provider.fontSize;
    return (baseChars * fontSizeRatio).round().clamp(200, 2000);
  }

  List<String> _splitToParagraphs(String content) {
    return content
        .split(RegExp(r'\n'))
        .where((line) => line.trim().isNotEmpty)
        .toList();
  }

  // ==================== Tap Zone ====================

  void _handleTap(TapDownDetails details) {
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
      _scrollController.animateTo(
        max(_scrollController.offset - 300, 0),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      if (_currentPage > 0) {
        _pageController?.previousPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        _previousChapter();
      }
    }
  }

  void _nextPage() {
    final provider = context.read<ReaderProvider>();
    if (provider.pageMode == PageMode.scroll) {
      _scrollController.animateTo(
        _scrollController.offset + 300,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      if (_currentPage < _pages.length - 1) {
        _pageController?.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        _nextChapter();
      }
    }
  }

  void _previousChapter() {
    if (_currentChapterIndex > 0) {
      setState(() {
        _currentChapterIndex--;
      });
      _loadChapterContent();
    }
  }

  void _nextChapter() {
    if (_currentChapterIndex < _totalChapters - 1) {
      setState(() {
        _currentChapterIndex++;
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
          onTapDown: _handleTap,
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
                sourceName: '', // 暂时为空
                currentChapter: _currentChapterIndex,
                totalChapters: _totalChapters,
                hasBookmark: _hasBookmark,
                hasPrev: _currentChapterIndex > 0,
                hasNext: _currentChapterIndex < _totalChapters - 1,
                isAutoScroll: false,
                isNightMode: provider.isNightMode,
                sliderValue: _sliderValue,
                onBack: () => Navigator.pop(context),
                onChangeSource: () {},
                onRefresh: () {
                  _loadChapterContent();
                },
                onDownload: _showCacheOptions,
                onToggleBookmark: _toggleBookmark,
                onClose: _hideMenu,
                onPrevChapter: () {
                  if (_currentChapterIndex > 0) {
                    _previousChapter();
                  }
                },
                onNextChapter: () {
                  if (_currentChapterIndex < _totalChapters - 1) {
                    _nextChapter();
                  }
                },
                onStartSearch: () {},
                onToggleAutoScroll: () {},
                onToggleNightMode: () {
                  provider.toggleNightMode();
                },
                onOpenReplaceRules: () {},
                onShowDirectory: () {
                  _hideMenu();
                  _showChapterList();
                },
                onStartTts: _startTts,
                onShowSettings: _showEnhancedSettings,
                onSliderChanged: (value) {
                  setState(() {
                    _sliderValue = value;
                  });
                },
                onSliderChangeStart: () {
                  setState(() {
                    _isSliderDragging = true;
                  });
                },
                onSliderChangeEnd: (value) {
                  setState(() {
                    _isSliderDragging = false;
                  });
                  _currentChapterIndex = value;
                  _loadChapterContent();
                },
              )
            // 原版菜单
            else if (_showMenu)
              _buildMenu(provider),
            if (_showHighlightMenu) _buildHighlightMenu(provider),
            // 设置面板
            if (_showSettingsSheet)
              DraggableScrollableSheet(
                initialChildSize: 0.8,
                minChildSize: 0.3,
                maxChildSize: 0.9,
                expand: false,
                builder: (context, scrollController) {
                  return ReaderSettingsSheet(
                    fontSize: provider.fontSize,
                    lineHeight: provider.lineHeight,
                    letterSpacing: provider.letterSpacing,
                    paragraphSpacing: provider.paragraphSpacing,
                    horizontalPadding: 16.0,
                    verticalPadding: 12.0,
                    paragraphIndent: '\u3000\u3000',
                    fontWeightIndex: 1,
                    fontFamily: provider.fontFamily,
                    backgroundColor: provider.backgroundColor,
                    backgroundImagePath: null,
                    showReadingInfo: true,
                    showChapterTitle: true,
                    showClock: true,
                    showProgress: true,
                    pageAnim: provider.pageMode.index,
                    pageAnimDurationMs: 300,
                    screenBrightness: provider.brightness,
                    keepScreenOn: false,
                    enableVolumeKeyPage: false,
                    volumeKeyPageOnTts: false,
                    enableLongPressMenu: true,
                    autoScrollSpeed: 50,
                    autoPageIntervalSeconds: 0,
                    tapZones: [0, 4, 0, 0, 1, 0, 0, 3, 2],
                    isNightMode: provider.isNightMode,
                    onFontSizeChanged: (value) => provider.setFontSize(value),
                    onLineHeightChanged: (value) =>
                        provider.setLineHeight(value),
                    onLetterSpacingChanged: (value) =>
                        provider.setLetterSpacing(value),
                    onParagraphSpacingChanged: (value) =>
                        provider.setParagraphSpacing(value),
                    onHorizontalPaddingChanged: (value) {},
                    onVerticalPaddingChanged: (value) {},
                    onParagraphIndentChanged: (value) {},
                    onFontWeightChanged: (value) {},
                    onFontFamilyChanged: (value) =>
                        provider.setFontFamily(value),
                    onBackgroundColorChanged: (value) =>
                        provider.setBackgroundColor(value),
                    onBackgroundImageChanged: (value) {},
                    onShowReadingInfoChanged: (value) {},
                    onShowChapterTitleChanged: (value) {},
                    onShowClockChanged: (value) {},
                    onShowProgressChanged: (value) {},
                    onPageAnimChanged: (value) {
                      if (value < PageMode.values.length) {
                        provider.setPageMode(PageMode.values[value]);
                        _repaginate();
                      }
                    },
                    onPageAnimDurationChanged: (value) {},
                    onScreenBrightnessChanged: (value) =>
                        provider.setBrightness(value),
                    onKeepScreenOnChanged: (value) {},
                    onEnableVolumeKeyPageChanged: (value) {},
                    onVolumeKeyPageOnTtsChanged: (value) {},
                    onEnableLongPressMenuChanged: (value) {},
                    onAutoScrollSpeedChanged: (value) {},
                    onAutoPageIntervalChanged: (value) {},
                    onTapZonesChanged: (value) {},
                    onNightModeChanged: (value) {
                      provider.toggleNightMode();
                    },
                  );
                },
              ),
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
    }
  }

  // ==================== Scroll Mode ====================

  Widget _buildScrollContent(ReaderProvider provider) {
    return SafeArea(
      child: Column(
        children: [
          if (_showMenu)
            Container(
              height: kToolbarHeight,
              color: Theme.of(context).colorScheme.surface,
            ),
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_prevContent != null) ...[
                    _buildChapterContent(
                      provider,
                      _prevContent!,
                      _prevChapterTitle ?? '上一章',
                    ),
                    _buildChapterDivider(provider),
                  ],
                  _buildChapterContent(provider, _content, _chapterTitle),
                  if (_nextContent != null) ...[
                    _buildChapterDivider(provider),
                    _buildChapterContent(
                      provider,
                      _nextContent!,
                      _nextChapterTitle ?? '下一章',
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_showMenu)
            Container(
              height: 120,
              color: Theme.of(context).colorScheme.surface,
            ),
        ],
      ),
    );
  }

  Widget _buildChapterContent(
      ReaderProvider provider, String content, String title) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: provider.fontSize + 4,
            fontWeight: FontWeight.bold,
            color: provider.textColor,
            height: provider.lineHeight,
            fontFamily:
                provider.fontFamily.isNotEmpty ? provider.fontFamily : null,
          ),
        ),
        SizedBox(height: provider.paragraphSpacing),
        _buildRichContent(provider, content),
      ],
    );
  }

  Widget _buildChapterDivider(ReaderProvider provider) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: provider.paragraphSpacing * 2),
      child: Divider(
        color: provider.textColor.withValues(alpha: 0.2),
        thickness: 1,
      ),
    );
  }

  // ==================== Rich Content with Highlights ====================

  Widget _buildRichContent(ReaderProvider provider, String content) {
    final paragraphs = _splitToParagraphs(content);
    final highlights = _getActiveHighlights();
    final rules = provider.highlightRules.where((r) => r.enabled).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: paragraphs.map((para) {
        final indentedPara = _applyIndent(para, provider);
        return Padding(
          padding: EdgeInsets.only(bottom: provider.paragraphSpacing),
          child: _buildRichParagraph(provider, indentedPara, highlights, rules),
        );
      }).toList(),
    );
  }

  String _applyIndent(String paragraph, ReaderProvider provider) {
    final indent = provider.textIndent;
    if (indent <= 0) return paragraph;
    final indentStr = '\u3000' * indent.round();
    return '$indentStr$paragraph';
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
      style: TextStyle(
        fontSize: provider.fontSize,
        color: provider.textColor,
        height: provider.lineHeight,
        letterSpacing: provider.letterSpacing,
        fontFamily: provider.fontFamily.isNotEmpty ? provider.fontFamily : null,
      ),
    );
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
              () => _HighlightInfo(
                color: rule.color,
                style: rule.style,
              ),
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
          spans.add(_buildHighlightSpan(
            text.substring(currentStart, i),
            currentInfo,
            provider,
          ));
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
            backgroundColor: highlightColor.withOpacity(0.4),
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
        .getChapterHighlights(widget.bookUrl, _currentChapterIndex)
        .map((e) => Highlight.fromJson(e))
        .toList();
  }

  // ==================== Slide Mode (PageView) ====================

  Widget _buildSlideContent(ReaderProvider provider) {
    return SafeArea(
      child: Column(
        children: [
          if (_showMenu)
            Container(
              height: kToolbarHeight,
              color: Theme.of(context).colorScheme.surface,
            ),
          Expanded(
            child: _pages.isEmpty
                ? Center(
                    child: Text('无内容',
                        style: TextStyle(color: provider.textColor)))
                : PageView.builder(
                    controller: _pageController,
                    onPageChanged: (index) {
                      setState(() {
                        _currentPage = index;
                      });
                      // Auto load next chapter at end
                      if (index == _pages.length - 1 &&
                          _currentChapterIndex < _totalChapters - 1) {
                        _nextChapter();
                      }
                      // Auto load prev chapter at start
                      if (index == 0 && _currentChapterIndex > 0) {
                        _previousChapter();
                      }
                    },
                    itemCount: _pages.length,
                    itemBuilder: (context, index) {
                      return _buildPageContent(provider, _pages[index]);
                    },
                  ),
          ),
          if (_showMenu)
            Container(
              height: 120,
              color: Theme.of(context).colorScheme.surface,
            ),
        ],
      ),
    );
  }

  // ==================== Cover Mode ====================

  Widget _buildCoverContent(ReaderProvider provider) {
    return SafeArea(
      child: Column(
        children: [
          if (_showMenu)
            Container(
              height: kToolbarHeight,
              color: Theme.of(context).colorScheme.surface,
            ),
          Expanded(
            child: _pages.isEmpty
                ? Center(
                    child: Text('无内容',
                        style: TextStyle(color: provider.textColor)))
                : PageView.builder(
                    controller: _pageController,
                    onPageChanged: (index) {
                      setState(() {
                        _currentPage = index;
                      });
                      if (index == _pages.length - 1 &&
                          _currentChapterIndex < _totalChapters - 1) {
                        _nextChapter();
                      }
                      if (index == 0 && _currentChapterIndex > 0) {
                        _previousChapter();
                      }
                    },
                    itemCount: _pages.length,
                    itemBuilder: (context, index) {
                      return _buildPageContent(provider, _pages[index]);
                    },
                  ),
          ),
          if (_showMenu)
            Container(
              height: 120,
              color: Theme.of(context).colorScheme.surface,
            ),
        ],
      ),
    );
  }

  // ==================== Simulation Mode ====================

  Widget _buildSimulationContent(ReaderProvider provider) {
    return SafeArea(
      child: Column(
        children: [
          if (_showMenu)
            Container(
              height: kToolbarHeight,
              color: Theme.of(context).colorScheme.surface,
            ),
          Expanded(
            child: _pages.isEmpty
                ? Center(
                    child: Text('无内容',
                        style: TextStyle(color: provider.textColor)))
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
                        // Current page
                        _buildPageContent(
                            provider,
                            _pages.isNotEmpty
                                ? _pages[
                                    _currentPage.clamp(0, _pages.length - 1)]
                                : ''),
                        // Curl effect overlay
                        if (_isDragging) _buildCurlEffect(provider),
                      ],
                    ),
                  ),
          ),
          if (_showMenu)
            Container(
              height: 120,
              color: Theme.of(context).colorScheme.surface,
            ),
        ],
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

  Widget _buildPageContent(ReaderProvider provider, String pageText) {
    return Container(
      color: provider.backgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Chapter title on first page
            Text(
              _chapterTitle,
              style: TextStyle(
                fontSize: provider.fontSize + 4,
                fontWeight: FontWeight.bold,
                color: provider.textColor,
                height: provider.lineHeight,
                fontFamily:
                    provider.fontFamily.isNotEmpty ? provider.fontFamily : null,
              ),
            ),
            SizedBox(height: provider.paragraphSpacing),
            _buildRichContent(provider, pageText),
          ],
        ),
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
            decoration: const InputDecoration(
              hintText: '输入要高亮的文字',
            ),
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
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
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
      String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20),
            Text(label, style: const TextStyle(fontSize: 10)),
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
                padding: EdgeInsets.all(16),
                child: Text('选择高亮样式', style: TextStyle(fontSize: 16)),
              ),
              // Color row
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
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
              const SizedBox(height: 16),
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
                padding: EdgeInsets.all(16),
                child: Text('选择高亮类型', style: TextStyle(fontSize: 16)),
              ),
              ...List.generate(styles.length, (i) {
                return ListTile(
                  leading: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: color.color.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(4),
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
      bookUrl: widget.bookUrl,
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
      bookUrl: widget.bookUrl,
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
    // Copy to clipboard would need additional import
    setState(() {
      _showHighlightMenu = false;
    });
  }

  // ==================== Menu ====================

  Widget _buildMenu(ReaderProvider provider) {
    return FadeTransition(
      opacity: _menuAnim,
      child: Column(
        children: [
          _buildTopBar(),
          const Spacer(),
          _buildBottomBar(provider),
        ],
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
                style: const TextStyle(fontSize: 16),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.list),
              onPressed: _showChapterList,
              tooltip: '目录',
            ),
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: _showMoreOptions,
              tooltip: '更多',
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
            const SizedBox(height: 8),
            _buildQuickActionsGrid(provider),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressSlider() {
    final maxCh = (_totalChapters - 1).clamp(0, 999999).toDouble();
    final displayChapter = (_sliderValue + 1).round();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(
            '$displayChapter',
            style: const TextStyle(fontSize: 12),
          ),
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
                onChangeStart: (value) {
                  setState(() {
                    _isSliderDragging = true;
                  });
                },
                onChanged: (value) {
                  setState(() {
                    _sliderValue = value;
                  });
                },
                onChangeEnd: (value) {
                  setState(() {
                    _isSliderDragging = false;
                  });
                  _currentChapterIndex = value.round();
                  _loadChapterContent();
                },
              ),
            ),
          ),
          Text(
            '$_totalChapters',
            style: const TextStyle(fontSize: 12),
          ),
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
          // Row 2: [行距] [翻页模式] [背景色]
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _quickActionButton(
                icon: Icons.format_line_spacing,
                label: '行距',
                onTap: () => _showSpacingDialog(provider),
              ),
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
            ],
          ),
          const SizedBox(height: 12),
          // Row 3: [亮度] [缓存] [更多设置]
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _quickActionButton(
                icon: Icons.brightness_6,
                label: '亮度',
                onTap: () => _showBrightnessDialog(provider),
              ),
              _quickActionButton(
                icon: Icons.download,
                label: '缓存',
                onTap: _showCacheOptions,
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
              style: const TextStyle(fontSize: 11),
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
    }
  }

  // ==================== Dialogs ====================

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
          setState(() => _currentChapterIndex = index);
          _loadChapterContent();
          Navigator.pop(context);
        },
      ),
    );
  }

  void _showMoreOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_book?.originType == BookOriginType.online)
                ListTile(
                  leading: const Icon(Icons.download),
                  title: const Text('缓存本章'),
                  onTap: () {
                    Navigator.pop(context);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('分享'),
                onTap: () {
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
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
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('字体'),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButton<String>(
                            value: provider.fontFamily.isEmpty
                                ? '默认'
                                : provider.fontFamily,
                            isExpanded: true,
                            items: [
                              '默认',
                              ..._getSystemFonts(),
                            ].map((f) {
                              return DropdownMenuItem(
                                value: f,
                                child: Text(f),
                              );
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
                      const SizedBox(height: 8),
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
    return [
      'serif',
      'sans-serif',
      'monospace',
    ];
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
                padding: const EdgeInsets.all(16),
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
                      _repaginate();
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
                                ? Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.2)
                                : Colors.grey.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: isSelected
                                ? Border.all(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                    width: 2)
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
              const SizedBox(height: 16),
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
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      '更多设置',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
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
                  const SizedBox(height: 8),
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
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(4),
                                color: row == 1 && col == 1
                                    ? Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withOpacity(0.1)
                                    : null,
                              ),
                              child: Text(
                                actionLabels[action] ?? '无',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 12),
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
                        padding: const EdgeInsets.all(16),
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
                                    fontSize: 11, fontFamily: 'monospace'),
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
                                      StorageService.instance
                                          .saveHighlightRule(updated.toJson());
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
                    const SizedBox(height: 16),
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
                    const SizedBox(height: 16),
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
                        patternController.text.isEmpty) return;
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
                    padding: const EdgeInsets.all(16),
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
                  const SizedBox(height: 16),
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

    final paint = Paint()..color = Colors.white.withOpacity(0.9);
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.3)
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

    paint.color = backgroundColor.withOpacity(0.95);
    canvas.drawPath(curlPath, paint);

    // Draw curl line
    final linePaint = Paint()
      ..color = Colors.grey.withOpacity(0.5)
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

  _HighlightInfo({
    required this.color,
    required this.style,
    this.note,
  });
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
    setState(() {
      _showWordCount = prefs.getBool('tocShowWordCount') ?? false;
      _useReplace = prefs.getBool('tocUseReplace') ?? false;
      _foldVolume = prefs.getBool('tocFoldVolume') ?? true;
    });
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _loadCacheInfo() async {
    if (widget.book == null || widget.book!.originType != BookOriginType.online) return;
    final files = await ChapterCacheService.instance.getChapterCacheFiles(widget.book!);
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

  List<Bookmark> get _filteredBookmarks {
    if (_searchQuery.isEmpty) return _bookmarks;
    final query = _searchQuery.toLowerCase();
    return _bookmarks.where((b) {
      bool hit = false;
      if (_searchChapterName && b.chapterTitle.toLowerCase().contains(query)) hit = true;
      if (_searchBookText && b.content.toLowerCase().contains(query)) hit = true;
      if (_searchContent && (b.note?.toLowerCase().contains(query) ?? false)) hit = true;
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Text('导出'),
                          ),
                          const PopupMenuItem(
                            value: 'export_md',
                            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Text('导出(MD)'),
                          ),
                          const PopupMenuDivider(),
                          _menuItem('bm_search_chapter', '搜索章节名', _searchChapterName, fg),
                          _menuItem('bm_search_text', '搜索书文', _searchBookText, fg),
                          _menuItem('bm_search_note', '搜索备注', _searchContent, fg),
                        ],
              ),
            ],
          ),
        ),
        if (_showSearch)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
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

  PopupMenuItem<String> _menuItem(String value, String label, bool checked, Color fg) {
    return PopupMenuItem(
      value: value,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              color: fg,
            ),
        ],
      ),
    );
  }

  Widget _buildChapterList(Color fg, bool isOnline) {
    final display = _buildDisplayChapters(_filteredChapters);
    return ListView.builder(
      itemCount: display.length,
      itemBuilder: (context, index) {
        final chapter = display[index];
        if (chapter.isVolume) {
          final isExpanded = _expandedVolumes.contains(chapter.index);
          return InkWell(
            onTap: () => setState(() {
              if (isExpanded) {
                _expandedVolumes.remove(chapter.index);
              } else {
                _expandedVolumes.add(chapter.index);
              }
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: fg.withValues(alpha: 0.06),
              child: Row(
                children: [
                  Icon(isExpanded ? Icons.keyboard_arrow_down : Icons.chevron_right,
                      color: fg, size: 20),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(chapter.title,
                        style: TextStyle(color: fg, fontWeight: FontWeight.bold),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          );
        }

        final isSelected = chapter.index == widget.currentChapterIndex;
        final fileName = ChapterCacheService.instance.getChapterFileName(chapter);
        final isCached = !isOnline || _cachedFiles.contains(fileName);

        return ListTile(
          selected: isSelected,
          selectedTileColor: fg.withValues(alpha: 0.1),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  chapter.title,
                  style: TextStyle(
                    color: isSelected ? fg : fg.withValues(alpha: 0.8),
                    fontWeight: isSelected ? FontWeight.bold : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_showWordCount && chapter.wordCount != null && chapter.wordCount! > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    '${(chapter.wordCount! / 10000).toStringAsFixed(1)}万',
                    style: TextStyle(color: fg.withValues(alpha: 0.5), fontSize: 12),
                  ),
                ),
              if (chapter.isVip && !chapter.isPay)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(Icons.lock, size: 16, color: Colors.red.shade400),
                ),
              if (!isCached)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(Icons.cloud_outlined, size: 16, color: fg.withValues(alpha: 0.5)),
                ),
            ],
          ),
          trailing: isSelected ? Icon(Icons.check, color: fg) : null,
          onTap: () => widget.onChapterSelected(chapter.index),
        );
      },
    );
  }

  Widget _buildBookmarkList(Color fg) {
    if (_bookmarks.isEmpty) {
      return Center(child: Text('暂无书签', style: TextStyle(color: fg.withValues(alpha: 0.5))));
    }
    final list = _searchQuery.isEmpty ? _bookmarks : _filteredBookmarks;
    if (list.isEmpty) {
      return Center(child: Text('没有匹配的书签', style: TextStyle(color: fg.withValues(alpha: 0.5))));
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, index) {
        final bookmark = list[index];
        return ListTile(
          title: Text(bookmark.chapterTitle, style: TextStyle(color: fg)),
          subtitle: Text(
            bookmark.note?.isNotEmpty == true ? bookmark.note! : bookmark.content,
            style: TextStyle(color: fg.withValues(alpha: 0.6)),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            _formatTime(bookmark.createdAt),
            style: TextStyle(color: fg.withValues(alpha: 0.5), fontSize: 12),
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂无书签可导出')),
        );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(asMd ? '书签已导出为MD' : '书签已复制到剪贴板')),
      );
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
