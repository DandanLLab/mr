import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/chapter.dart';
import '../../routes/app_routes.dart';
import '../../services/book_data_provider.dart';
import '../../services/chapter_cache_service.dart';
import '../../services/native/platform_channel.dart';
import '../../services/reader_bookmark_service.dart';
import '../../services/source_engine/analyze_url.dart';
import '../../services/storage_service.dart';

enum MangaReadMode { scroll, horizontal, japanese }

class ComicReaderPage extends StatefulWidget {
  final String bookUrl;
  final int chapterIndex;
  final Book? initialBook;

  const ComicReaderPage({
    super.key,
    required this.bookUrl,
    this.chapterIndex = 0,
    this.initialBook,
  });

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage> {
  static const _modeKey = 'mangaReadMode';
  static const _scaleKey = 'disableMangaScale';
  static const _scaleDefaultFixedKey = 'mangaScaleDefaultFixed';
  static const _titleKey = 'hideMangaTitle';
  static const _footerKey = 'hideMangaFooter';
  static const _preloadKey = 'mangaPreloadCount';
  static const _brightnessKey = 'mangaScreenBrightness';
  static const _einkKey = 'mangaEinkMode';
  static const _grayscaleKey = 'mangaGrayscale';
  static const _eyeCareKey = 'mangaEyeCareMode';
  static const _keepScreenOnKey = 'mangaKeepScreenOn';

  Book? _book;
  BookDataProvider? _dataProvider;
  List<Chapter> _chapters = [];
  List<String> _images = [];
  List<String> _allImages = [];
  List<int> _globalToChapterIdx = [];
  List<int> _globalToPageIdx = [];
  List<int> _chapterStartIndices = [];
  int _currentGlobalIndex = 0;
  bool _isJumpingToChapter = false;
  int _currentChapterIndex = 0;
  int _currentPageIndex = 0;
  double _sliderPageIndex = 0; // 进度条拖拽时的视觉位置
  bool _isSliderDragging = false; // 进度条是否正在拖拽
  bool _isLoading = true;
  bool _showMenu = false;
  String? _error;

  MangaReadMode _readMode = MangaReadMode.scroll;
  bool _disableScale = false;
  bool _hideChapterTitle = false;
  bool _hideFooter = false;
  bool _isAutoPaging = false;
  bool _autoPageBusy = false;
  double _screenBrightness = -1;
  double _originalScreenBrightness = -1;
  int _preloadCount = 10;
  bool _einkMode = false;
  bool _grayscaleImages = false;
  bool _eyeCareMode = false;
  bool _keepScreenOn = false;
  final List<String> _imageLoadLog = [];
  Map<String, String> _imageHeaders = const {};
  final Map<String, Map<String, String>> _imageOptionHeaders = {};
  String _sourceName = '';
  BookSource? _bookSource;

  // 卷轴模式：全书图片扁平索引
  // 预加载设置拖动临时变量
  final ValueNotifier<double> _preloadSliderValue = ValueNotifier(10.0);
  bool _isPreloadDragging = false;

  final ScrollController _scrollController = ScrollController();
  final GlobalKey<_ComicZoomLayerState> _zoomLayerKey =
      GlobalKey<_ComicZoomLayerState>();
  final ValueNotifier<int> _pageNotifier = ValueNotifier(0);
  PageController? _pageController;
  Timer? _footerTimer;
  Timer? _autoPageTimer;
  final List<GlobalKey> _imageKeys = []; // 用于滚动模式定位图片
  final Map<int, GlobalKey> _globalImageKeys = {};

  Chapter? get _chapter {
    if (_chapters.isEmpty) return null;
    return _chapters.firstWhere(
      (chapter) => chapter.index == _currentChapterIndex,
      orElse: () => _chapters.first,
    );
  }

  bool get _isDarkMode => Theme.of(context).brightness == Brightness.dark;

  Color get _readerBackground {
    if (_einkMode) {
      return _isDarkMode ? Colors.black : Colors.white;
    }
    return _isDarkMode ? const Color(0xFF101010) : const Color(0xFFF5F5F5);
  }

  Color get _readerForeground {
    if (_einkMode) {
      return _isDarkMode ? Colors.white : Colors.black;
    }
    return _isDarkMode ? Colors.white : const Color(0xFF202020);
  }

  Color get _readerSecondary {
    if (_einkMode) {
      return _isDarkMode ? Colors.white70 : Colors.black54;
    }
    return _isDarkMode ? Colors.white70 : const Color(0xFF5F6368);
  }

  Color get _menuBackground => _isDarkMode
      ? const Color(0xFF1A1A1A)
      : Theme.of(context).colorScheme.surfaceContainer;

  Color get _menuForeground => Theme.of(context).colorScheme.onSurface;

  int get _horizontalLeadingCount => _hideChapterTitle ? 0 : 1;

  int get _horizontalItemCount => _images.length + (_hideChapterTitle ? 0 : 2);

  int _horizontalPageForImage(int imageIndex) {
    return imageIndex + _horizontalLeadingCount;
  }

  @override
  void initState() {
    super.initState();
    _currentChapterIndex = widget.chapterIndex;
    _scrollController.addListener(_updateScrollProgress);
    _initializeReader();
  }

  Future<void> _initializeReader() async {
    _originalScreenBrightness = await NativeChannel.instance
        .getScreenBrightness();
    await _loadSettings();
    await _loadBook();
  }

  @override
  void dispose() {
    _footerTimer?.cancel();
    _autoPageTimer?.cancel();
    _sliderThrottleTimer?.cancel();
    _scrollController.dispose();
    _pageNotifier.dispose();
    _preloadSliderValue.dispose();
    _pageController?.dispose();
    // 恢复原始亮度
    unawaited(
      NativeChannel.instance.setScreenBrightness(_originalScreenBrightness),
    );
    unawaited(WakelockPlus.disable());
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt(_modeKey) ?? 0;
    final scaleDefaultFixed = prefs.getBool(_scaleDefaultFixedKey) ?? false;
    if (!scaleDefaultFixed) {
      await prefs.setBool(_scaleKey, false);
      await prefs.setBool(_scaleDefaultFixedKey, true);
    }
    if (!mounted) return;

    // 获取当前亮度作为原始亮度
    try {
      _originalScreenBrightness =
          await NativeChannel.instance.getScreenBrightness();
    } catch (_) {
      _originalScreenBrightness = 0.5;
    }

    setState(() {
      _readMode = MangaReadMode
          .values[modeIndex.clamp(0, MangaReadMode.values.length - 1)];
      _disableScale = prefs.getBool(_scaleKey) ?? false;
      _hideChapterTitle = prefs.getBool(_titleKey) ?? false;
      _hideFooter = prefs.getBool(_footerKey) ?? false;
      _preloadCount = (prefs.getInt(_preloadKey) ?? 10).clamp(0, 30);
      _preloadSliderValue.value = _preloadCount.toDouble();
      _screenBrightness = prefs.getDouble(_brightnessKey) ?? -1;
      _einkMode = prefs.getBool(_einkKey) ?? false;
      _grayscaleImages = prefs.getBool(_grayscaleKey) ?? false;
      _eyeCareMode = prefs.getBool(_eyeCareKey) ?? false;
      _keepScreenOn = prefs.getBool(_keepScreenOnKey) ?? false;
    });
    // 设置亮度
    if (_screenBrightness >= 0) {
      unawaited(NativeChannel.instance.setScreenBrightness(_screenBrightness));
    }
    if (_keepScreenOn) {
      WakelockPlus.enable();
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setInt(_modeKey, _readMode.index),
      prefs.setBool(_scaleKey, _disableScale),
      prefs.setBool(_titleKey, _hideChapterTitle),
      prefs.setBool(_footerKey, _hideFooter),
      prefs.setInt(_preloadKey, _preloadCount),
      prefs.setDouble(_brightnessKey, _screenBrightness),
      prefs.setBool(_einkKey, _einkMode),
      prefs.setBool(_grayscaleKey, _grayscaleImages),
      prefs.setBool(_eyeCareKey, _eyeCareMode),
      prefs.setBool(_keepScreenOnKey, _keepScreenOn),
    ]);
  }

  Future<void> _loadBook() async {
    try {
      final stored = StorageService.instance.getBook(widget.bookUrl);
      _book = stored != null ? Book.fromJson(stored) : widget.initialBook;
      if (_book == null) {
        throw StateError('书籍信息不存在');
      }
      _dataProvider = createBookDataProvider(_book!);
      _sourceName = _book!.sourceName ?? '';
      _chapters = (await _dataProvider!.getChapterList(
        _book!,
      )).where((chapter) => !chapter.isVolume).toList();
      final sourceUrl = _book!.sourceUrl;
      if (sourceUrl != null && sourceUrl.isNotEmpty) {
        final sourceData = StorageService.instance.getBookSource(sourceUrl);
        if (sourceData != null) {
          final source = BookSource.fromJson(sourceData);
          _bookSource = source;
          _sourceName = source.bookSourceName;
          _imageHeaders = source.getHeaderMap();
        }
      }
      if (_chapters.isEmpty) {
        throw StateError('目录为空');
      }
      if (!_chapters.any((chapter) => chapter.index == _currentChapterIndex)) {
        _currentChapterIndex = _chapters.first.index;
      }
      await _loadChapter();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadChapter({int pageIndex = 0}) async {
    if (_readMode == MangaReadMode.scroll) {
      await _loadScrollMode(pageIndex: pageIndex);
      return;
    }

    final chapter = _chapter;
    if (chapter == null || _book == null || _dataProvider == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
      _showMenu = false;
    });
    _resetZoom();

    try {
      List<String> images;

      // 优先从缓存读取
      if (_book!.originType == BookOriginType.online) {
        final cachedImages = await ChapterCacheService.instance.readComicChapterContent(_book!, chapter);
        if (cachedImages != null && cachedImages.isNotEmpty) {
          images = cachedImages;
        } else {
          // 缓存没有则从网络获取
          final content = await _dataProvider!.getContent(_book!, chapter);
          images = _extractImageUrls(
            content ?? '',
            baseUrl: chapter.url ?? _book!.bookUrl,
          );
          // 保存到缓存
          if (images.isNotEmpty) {
            unawaited(ChapterCacheService.instance.saveComicChapterContent(_book!, chapter, images));
          }
        }
      } else {
        final content = await _dataProvider!.getContent(_book!, chapter);
        images = _extractImageUrls(
          content ?? '',
          baseUrl: chapter.url ?? _book!.bookUrl,
        );
      }

      if (images.isEmpty) {
        throw StateError('本章没有解析到图片');
      }
      _currentPageIndex = pageIndex.clamp(0, images.length - 1).toInt();
      _pageNotifier.value = _currentPageIndex;
      _images = images;
      // 初始化图片的 GlobalKey 用于滚动模式定位
      _imageKeys.clear();
      _imageKeys.addAll(List.generate(images.length, (_) => GlobalKey()));
      _resetControllers();
      await _saveProgress();
      if (!mounted) return;
      setState(() => _isLoading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpToCurrentPage();
        _preloadImages();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadScrollMode({int pageIndex = 0}) async {
    if (_book == null || _dataProvider == null || _chapters.isEmpty) return;

    setState(() {
      _isLoading = true;
      _error = null;
      _showMenu = false;
      _isJumpingToChapter = true;
      _allImages = [];
      _globalToChapterIdx = [];
      _globalToPageIdx = [];
      _chapterStartIndices = [];
      _globalImageKeys.clear();
    });
    _resetZoom();

    try {
      final allImages = <String>[];
      final globalToChapterIdx = <int>[];
      final globalToPageIdx = <int>[];
      final chapterStartIndices = <int>[];
      final chapterImages = <int, List<String>>{};

      for (var chapterIdx = 0; chapterIdx < _chapters.length; chapterIdx++) {
        final chapter = _chapters[chapterIdx];
        chapterStartIndices.add(allImages.length);
        final images = await _loadChapterImages(chapter);
        chapterImages[chapter.index] = images;
        for (var pageIdx = 0; pageIdx < images.length; pageIdx++) {
          allImages.add(images[pageIdx]);
          globalToChapterIdx.add(chapterIdx);
          globalToPageIdx.add(pageIdx);
        }
      }

      if (allImages.isEmpty) {
        throw StateError('没有解析到任何漫画图片');
      }

      var chapterIdx = _chapters.indexWhere(
        (chapter) => chapter.index == _currentChapterIndex,
      );
      if (chapterIdx < 0) chapterIdx = 0;
      final targetGlobalIndex = _resolveGlobalIndex(chapterIdx, pageIndex,
          chapterStartIndices: chapterStartIndices,
          globalToChapterIdx: globalToChapterIdx);
      final targetChapterIdx = globalToChapterIdx[targetGlobalIndex];
      final targetChapter = _chapters[targetChapterIdx];
      final targetPage = globalToPageIdx[targetGlobalIndex];

      _allImages = allImages;
      _globalToChapterIdx = globalToChapterIdx;
      _globalToPageIdx = globalToPageIdx;
      _chapterStartIndices = chapterStartIndices;
      _currentGlobalIndex = targetGlobalIndex;
      _currentChapterIndex = targetChapter.index;
      _currentPageIndex = targetPage;
      _pageNotifier.value = targetPage;
      _images = chapterImages[targetChapter.index] ??
          _imagesForChapterListIndex(targetChapterIdx);
      _imageKeys.clear();
      _imageKeys.addAll(List.generate(_images.length, (_) => GlobalKey()));
      _resetControllers();
      await _saveProgress();

      if (!mounted) return;
      setState(() => _isLoading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollToGlobalIndex(_currentGlobalIndex, animated: false);
        } else {
          _isJumpingToChapter = false;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
        _isJumpingToChapter = false;
      });
    }
  }

  int _resolveGlobalIndex(
    int chapterIdx,
    int pageIndex, {
    List<int>? chapterStartIndices,
    List<int>? globalToChapterIdx,
  }) {
    final starts = chapterStartIndices ?? _chapterStartIndices;
    final chapterMap = globalToChapterIdx ?? _globalToChapterIdx;
    if (starts.isEmpty || chapterMap.isEmpty) return 0;

    final start = starts[chapterIdx].clamp(0, chapterMap.length - 1).toInt();
    var end = chapterIdx + 1 < starts.length
        ? starts[chapterIdx + 1]
        : chapterMap.length;
    end = end.clamp(start + 1, chapterMap.length).toInt();
    if (chapterMap[start] == chapterIdx) {
      return (start + pageIndex).clamp(start, end - 1).toInt();
    }

    for (var i = start; i < chapterMap.length; i++) {
      if (chapterMap[i] >= chapterIdx) return i;
    }
    return chapterMap.length - 1;
  }

  List<String> _imagesForChapterListIndex(int chapterIdx) {
    if (_allImages.isEmpty ||
        _chapterStartIndices.isEmpty ||
        chapterIdx < 0 ||
        chapterIdx >= _chapterStartIndices.length) {
      return const [];
    }
    final start = _chapterStartIndices[chapterIdx];
    final end = chapterIdx + 1 < _chapterStartIndices.length
        ? _chapterStartIndices[chapterIdx + 1]
        : _allImages.length;
    if (start < 0 || start >= end || start >= _allImages.length) {
      return const [];
    }
    return _allImages.sublist(start, end.clamp(start, _allImages.length).toInt());
  }

  List<String> _extractImageUrls(String content, {required String baseUrl}) {
    final urls = <String>[];
    final seen = <String>{};
    _imageOptionHeaders.clear();

    void add(String? raw) {
      if (raw == null) return;
      var value = raw
          .trim()
          .replaceAll('&amp;', '&')
          .replaceAll(r'\/', '/')
          .replaceAll(r'\"', '"');
      if (value.isEmpty || value.startsWith('blob:')) {
        return;
      }

      if (value.startsWith('data:')) {
        if (seen.add(value)) urls.add(value);
        return;
      }

      final parsed = AnalyzeUrl.parse(value, baseUrl: baseUrl);
      value = parsed.url.trim();
      final uri = Uri.tryParse(value);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return;
      }
      if (seen.add(value)) {
        urls.add(value);
        final optionHeaders = parsed.option?.headers;
        if (optionHeaders != null && optionHeaders.isNotEmpty) {
          _imageOptionHeaders[value] = optionHeaders;
        }
      }
    }

    final document = html_parser.parseFragment(content);
    for (final image in document.querySelectorAll('img, image')) {
      add(
        image.attributes['src'] ??
            image.attributes['data-src'] ??
            image.attributes['data-original'] ??
            image.attributes['data-url'] ??
            image.attributes['data-lazy-src'] ??
            image.attributes['lazy-src'],
      );
      final srcSet = image.attributes['srcset'];
      if (srcSet != null && srcSet.trim().isNotEmpty) {
        for (final candidate in srcSet.split(',')) {
          add(candidate.trim().split(RegExp(r'\s+')).firstOrNull);
        }
      }
    }

    final normalizedContent = content
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(
          RegExp(r'</?(?:p|div|li)[^>]*>', caseSensitive: false),
          '\n',
        );
    for (final line in normalizedContent.split(RegExp(r'[\r\n]+'))) {
      final value = line.trim();
      if (value.isNotEmpty &&
          !value.startsWith('<') &&
          (value.startsWith('data:') ||
              value.startsWith('http://') ||
              value.startsWith('https://') ||
              value.startsWith('//') ||
              value.startsWith('/') ||
              value.startsWith('./') ||
              value.startsWith('../'))) {
        add(value);
      }
    }

    final urlPattern = RegExp(
      r'''https?://[^\s"'<>\\]+(?:\?[^\s"'<>\\]*)?''',
      caseSensitive: false,
    );
    for (final match in urlPattern.allMatches(content)) {
      final value = match.group(0);
      if (value != null &&
          RegExp(
            r'\.(?:jpg|jpeg|png|webp|gif|avif)(?:\?|$)',
            caseSensitive: false,
          ).hasMatch(value)) {
        add(value);
      }
    }

    return urls;
  }

  Map<String, String> _headersForImage(String url) {
    final headers = <String, String>{..._imageHeaders};
    final optionHeaders = _imageOptionHeaders[url];
    if (optionHeaders != null) {
      headers.addAll(optionHeaders);
    }
    headers.putIfAbsent('Referer', () => _chapter?.url ?? _book?.bookUrl ?? '');
    headers.removeWhere((_, value) => value.trim().isEmpty);
    return headers;
  }

  Uint8List? _decodeDataImage(String source) {
    final comma = source.indexOf(',');
    if (comma < 0) return null;
    try {
      final metadata = source.substring(0, comma).toLowerCase();
      final payload = source.substring(comma + 1);
      if (metadata.contains(';base64')) {
        return base64Decode(base64.normalize(payload));
      }
      return Uint8List.fromList(Uri.decodeComponent(payload).codeUnits);
    } catch (_) {
      return null;
    }
  }

  void _resetControllers() {
    _resetZoom();
    _pageController?.dispose();
    _pageController = PageController(
      initialPage: _horizontalPageForImage(_currentPageIndex),
    );
  }

  void _resetZoom() {
    _zoomLayerKey.currentState?.reset();
  }

  void _jumpToCurrentPage() {
    if (_readMode == MangaReadMode.scroll) {
      _scrollToGlobalIndex(_currentGlobalIndex, animated: false);
      return;
    }
    // 非滚动模式：跳转到当前页面
    if (_pageController?.hasClients == true) {
      _pageController!.jumpToPage(_horizontalPageForImage(_currentPageIndex));
    }
  }

  Future<void> _saveProgress() async {
    if (_book == null) return;
    _book = _book!.copyWith(
      durChapterIndex: _currentChapterIndex,
      durChapterTitle: _chapter?.title ?? '',
      durChapterPos: _currentPageIndex,
      durChapterTime: DateTime.now(),
    );
    await _dataProvider?.saveBook(_book!);
  }

  void _updateScrollProgress() {
    if (_readMode != MangaReadMode.scroll ||
        !_scrollController.hasClients ||
        _allImages.isEmpty ||
        _isJumpingToChapter) {
      return;
    }

    final globalIndex = _findCenterGlobalIndex();
    if (globalIndex == null || globalIndex == _currentGlobalIndex) return;
    _applyGlobalIndex(globalIndex, save: true);
  }

  int? _findCenterGlobalIndex() {
    final centerY = MediaQuery.sizeOf(context).height / 2;
    int? result;
    var bestDistance = double.infinity;

    for (final entry in _globalImageKeys.entries) {
      final itemContext = entry.value.currentContext;
      if (itemContext == null) continue;
      final renderObject = itemContext.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) continue;

      final top = renderObject.localToGlobal(Offset.zero).dy;
      final bottom = top + renderObject.size.height;
      final distance = centerY >= top && centerY <= bottom
          ? 0.0
          : (centerY < top ? top - centerY : centerY - bottom);
      if (distance < bestDistance) {
        bestDistance = distance;
        result = entry.key;
      }
    }

    return result;
  }

  void _applyGlobalIndex(int globalIndex, {bool save = false}) {
    if (globalIndex < 0 || globalIndex >= _allImages.length) return;
    final chapterIdx = _globalToChapterIdx[globalIndex];
    final pageIdx = _globalToPageIdx[globalIndex];
    if (chapterIdx < 0 || chapterIdx >= _chapters.length) return;
    final chapterIndex = _chapters[chapterIdx].index;
    final chapterChanged = chapterIndex != _currentChapterIndex;

    _currentGlobalIndex = globalIndex;
    _currentChapterIndex = chapterIndex;
    _currentPageIndex = pageIdx;
    _pageNotifier.value = pageIdx;
    if (chapterChanged) {
      _images = _imagesForChapterListIndex(chapterIdx);
      _imageKeys.clear();
      _imageKeys.addAll(List.generate(_images.length, (_) => GlobalKey()));
    }
    if (save) _scheduleProgressSave();
  }

  void _scheduleProgressSave() {
    _footerTimer?.cancel();
    _footerTimer = Timer(const Duration(milliseconds: 400), _saveProgress);
  }

  void _preloadImages() {
    if (!mounted || _images.isEmpty || _preloadCount == 0) return;
    if (_readMode == MangaReadMode.scroll) return;
    final end = (_currentPageIndex + _preloadCount + 1).clamp(
      0,
      _images.length,
    );
    for (var index = _currentPageIndex + 1; index < end; index++) {
      if (_images[index].startsWith('data:')) continue;
      precacheImage(
        CachedNetworkImageProvider(
          _images[index],
          headers: _headersForImage(_images[index]),
        ),
        context,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body = Stack(
      children: [
        Positioned.fill(child: _buildZoomableReader()),
        if (!_hideFooter && !_isLoading && _error == null) _buildInfoFooter(),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_showMenu,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              reverseDuration: const Duration(milliseconds: 130),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.015),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: _showMenu
                  ? KeyedSubtree(
                      key: const ValueKey('comic_menu'),
                      child: _buildMenu(),
                    )
                  : const SizedBox.shrink(key: ValueKey('comic_menu_hidden')),
            ),
          ),
        ),
      ],
    );

    // 护眼模式：添加暖色调滤镜，减少蓝光
    if (_eyeCareMode) {
      body = ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          1.1, 0, 0, 0, 0,    // R 增强红色
          0, 0.95, 0, 0, 0,   // G 略微降低绿色
          0, 0, 0.8, 0, 0,    // B 降低蓝色
          0, 0, 0, 1, 0,
        ]),
        child: body,
      );
    }

    return Scaffold(
      backgroundColor: _readerBackground,
      body: body,
    );
  }

  Widget _buildReader() {
    if (_isLoading) {
      return Center(child: CircularProgressIndicator(color: _readerForeground));
    }
    if (_error != null) {
      return _buildError();
    }
    if (_readMode == MangaReadMode.scroll) {
      return _buildScrollReader();
    }
    return _buildHorizontalReader();
  }

  Widget _buildZoomableReader() {
    return _ComicZoomLayer(
      key: _zoomLayerKey,
      enabled: !_disableScale,
      readingAxis: _readMode == MangaReadMode.scroll
          ? Axis.vertical
          : Axis.horizontal,
      onTapUp: _handleTap,
      child: _buildReader(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.broken_image_outlined,
              color: _readerSecondary,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: _readerSecondary),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loadChapter,
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
          ],
        ),
      ),
    );
  }


  Widget _buildScrollReader() {
    return CustomScrollView(
      controller: _scrollController,
      scrollCacheExtent: ScrollCacheExtent.pixels(
        MediaQuery.sizeOf(context).height * 2,
      ),
      slivers: [
        SliverList.builder(
          itemCount: _allImages.length,
          itemBuilder: (context, globalIndex) {
            final key = _globalImageKeys.putIfAbsent(
              globalIndex,
              () => GlobalKey(),
            );
            final isLast = globalIndex == _allImages.length - 1;
            return KeyedSubtree(
              key: key,
              child: RepaintBoundary(
                child: _buildImage(
                  _allImages[globalIndex],
                  fit: BoxFit.fitWidth,
                  minHeight: isLast
                      ? MediaQuery.sizeOf(context).height * 0.66
                      : MediaQuery.sizeOf(context).height * 0.55,
                ),
              ),
            );
          },
        ),
      ],
    );
  }


  Future<List<String>> _loadChapterImages(Chapter chapter) async {
    if (_book == null || _dataProvider == null) return [];

    try {
      List<String> images;
      if (_book!.originType == BookOriginType.online) {
        final cachedImages = await ChapterCacheService.instance.readComicChapterContent(_book!, chapter);
        if (cachedImages != null && cachedImages.isNotEmpty) {
          images = cachedImages;
        } else {
          final content = await _dataProvider!.getContent(_book!, chapter);
          images = _extractImageUrls(content ?? '', baseUrl: chapter.url ?? _book!.bookUrl);
          if (images.isNotEmpty) {
            unawaited(ChapterCacheService.instance.saveComicChapterContent(_book!, chapter, images));
          }
        }
      } else {
        final content = await _dataProvider!.getContent(_book!, chapter);
        images = _extractImageUrls(content ?? '', baseUrl: chapter.url ?? _book!.bookUrl);
      }
      return images;
    } catch (e) {
      return [];
    }
  }

  Widget _buildHorizontalReader() {
    return PageView.builder(
      controller: _pageController,
      reverse: _readMode == MangaReadMode.japanese,
      physics: const PageScrollPhysics(),
      itemCount: _horizontalItemCount,
      onPageChanged: (itemIndex) {
        final imageIndex = itemIndex - _horizontalLeadingCount;
        if (imageIndex < 0 || imageIndex >= _images.length) return;
        _currentPageIndex = imageIndex;
        _pageNotifier.value = imageIndex;
        _scheduleProgressSave();
        _preloadImages();
      },
      itemBuilder: (context, itemIndex) {
        if (!_hideChapterTitle && itemIndex == 0) {
          return _buildHorizontalChapterEdge('阅读 ${_chapter?.title ?? ''}');
        }
        if (!_hideChapterTitle && itemIndex == _horizontalItemCount - 1) {
          return _buildHorizontalChapterEdge('已读完 ${_chapter?.title ?? ''}');
        }
        final imageIndex = itemIndex - _horizontalLeadingCount;
        return _buildImage(_images[imageIndex], fit: BoxFit.contain);
      },
    );
  }

  Widget _buildHorizontalChapterEdge(String text) {
    return ColoredBox(
      color: _readerBackground,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _readerForeground,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImage(String url, {required BoxFit fit, double minHeight = 0}) {
    final data = url.startsWith('data:') ? _decodeDataImage(url) : null;
    final Widget image;
    if (data != null) {
      image = Image.memory(
        data,
        width: double.infinity,
        fit: fit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => _buildImageError(),
      );
    } else if (url.startsWith('data:')) {
      image = _buildImageError(message: 'Base64 图片解析失败');
    } else {
      final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
      final targetCacheWidth =
          (MediaQuery.sizeOf(context).width * devicePixelRatio * 2)
              .round()
              .clamp(720, 4096);
      image = CachedNetworkImage(
        imageUrl: url,
        httpHeaders: _headersForImage(url),
        memCacheWidth: targetCacheWidth,
        width: double.infinity,
        fit: fit,
        filterQuality: _readMode == MangaReadMode.scroll
            ? FilterQuality.low
            : FilterQuality.medium,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        progressIndicatorBuilder: (context, _, progress) {
          final value = progress.progress;
          final now = DateTime.now();
          final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
          if (value != null && _imageLoadLog.length < 500) {
            final existingLog = _imageLoadLog.lastWhere(
              (l) => l.contains(url.substring(0, url.length.clamp(0, 50))),
              orElse: () => '',
            );
            if (existingLog.isEmpty) {
              _imageLoadLog.add('[$timeStr] 开始加载: ${url.substring(0, url.length.clamp(0, 80))}...');
            }
          }
          return Container(
            constraints: BoxConstraints(
              minHeight: minHeight > 0
                  ? minHeight
                  : MediaQuery.sizeOf(context).height * 0.55,
            ),
            color: _readerBackground,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  value: value,
                  color: _readerForeground,
                  strokeWidth: 3,
                ),
                if (value != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${(value * 100).round()}%',
                    style: TextStyle(color: _readerSecondary),
                  ),
                ],
              ],
            ),
          );
        },
        errorWidget: (_, error, ___) {
          final now = DateTime.now();
          final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
          if (_imageLoadLog.length < 500) {
            _imageLoadLog.add('[$timeStr] 加载失败: ${url.substring(0, url.length.clamp(0, 80))} - ${error.toString().substring(0, error.toString().length.clamp(0, 50))}');
          }
          return _buildImageError();
        },
      );
    }

    Widget child = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: image,
    );

    // 灰度滤镜
    if (_grayscaleImages) {
      child = ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: child,
      );
    }

    return child;
  }

  Widget _buildImageError({String message = '图片加载失败'}) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.65,
      child: ColoredBox(
        color: _readerBackground,
        child: Center(
          child: FilledButton.tonalIcon(
            onPressed: () => setState(() {}),
            icon: const Icon(Icons.refresh),
            label: Text(message),
          ),
        ),
      ),
    );
  }

  Widget _buildChapterEdge(String text) {
    return SizedBox(
      height: 96,
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            color: _readerForeground,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildInfoFooter() {
    final chapterPosition = _chapters.indexWhere(
      (chapter) => chapter.index == _currentChapterIndex,
    );
    final chapterNumber = chapterPosition < 0 ? 1 : chapterPosition + 1;
    return Positioned(
      left: 10,
      right: 10,
      bottom: MediaQuery.paddingOf(context).bottom + 8,
      child: ValueListenableBuilder<int>(
        valueListenable: _pageNotifier,
        builder: (context, pageIndex, _) {
          final pageNumber = _images.isEmpty ? 0 : pageIndex + 1;
          final totalProgress = _chapters.isEmpty || _images.isEmpty
              ? 0.0
              : ((chapterNumber - 1) / _chapters.length) +
                    (pageNumber / _images.length / _chapters.length);
          return IgnorePointer(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_chapter?.title ?? ''}  $pageNumber/${_images.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                    ),
                  ),
                ),
                Text(
                  '$chapterNumber/${_chapters.length}  '
                  '${(totalProgress.clamp(0.0, 1.0) * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Timer? _sliderThrottleTimer;
  int _lastSliderJumpIndex = -1;

  void _onSliderChanged(double value) {
    setState(() {
      _sliderPageIndex = value;
      _isSliderDragging = true;
    });

    // 实时跳转到对应位置（节流处理）
    final targetIndex = value.round().clamp(0, _images.length - 1);
    if (targetIndex != _lastSliderJumpIndex) {
      _lastSliderJumpIndex = targetIndex;
      _jumpToSliderPosition(targetIndex);
    }
  }

  void _jumpToSliderPosition(int targetIndex) {
    if (_images.isEmpty) return;

    if (_readMode != MangaReadMode.scroll) {
      // 横向/日漫模式：直接跳转到对应页面
      _pageController?.jumpToPage(_horizontalPageForImage(targetIndex));
    } else {
      _goToPage(targetIndex, animated: false);
    }
  }

  Widget _buildMenu() {
    return Column(
      children: [
        Material(
          color: _menuBackground,
          child: SafeArea(
            bottom: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(Icons.arrow_back, color: _menuForeground),
                        tooltip: '返回',
                      ),
                      Expanded(
                        child: InkWell(
                          onTap: _openBookDetail,
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _book?.displayName ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ).copyWith(color: _menuForeground),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.chevron_right,
                                  color: _menuForeground.withValues(
                                    alpha: 0.54,
                                  ),
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _downloadCurrentChapter,
                        icon: Icon(Icons.download, color: _menuForeground),
                        tooltip: '下载',
                      ),
                      IconButton(
                        onPressed: _loadChapter,
                        icon: Icon(Icons.refresh, color: _menuForeground),
                        tooltip: '刷新',
                      ),
                      PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert, color: _menuForeground),
                        tooltip: '更多',
                        offset: const Offset(0, 48),
                        onSelected: (value) {
                          switch (value) {
                            case 'footer':
                              _showFooterConfig();
                              break;
                            case 'eink':
                              _toggleEinkMode();
                              break;
                            case 'grayscale':
                              _toggleGrayscale();
                              break;
                            case 'log':
                              _showImageLoadLog();
                              break;
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'footer',
                            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Text('页脚配置'),
                          ),
                          PopupMenuItem(
                            value: 'eink',
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Row(
                              children: [
                                const Text('墨水屏'),
                                const Spacer(),
                                Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: _einkMode
                                          ? Theme.of(context).colorScheme.primary
                                          : _menuForeground.withValues(alpha: 0.5),
                                      width: 1.5,
                                    ),
                                    borderRadius: BorderRadius.circular(3),
                                    color: _einkMode
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.transparent,
                                  ),
                                  child: _einkMode
                                      ? Icon(
                                          Icons.check,
                                          size: 14,
                                          color: Theme.of(context).colorScheme.onPrimary,
                                        )
                                      : null,
                                ),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'grayscale',
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Row(
                              children: [
                                const Text('图片灰色'),
                                const Spacer(),
                                Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: _grayscaleImages
                                          ? Theme.of(context).colorScheme.primary
                                          : _menuForeground.withValues(alpha: 0.5),
                                      width: 1.5,
                                    ),
                                    borderRadius: BorderRadius.circular(3),
                                    color: _grayscaleImages
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.transparent,
                                  ),
                                  child: _grayscaleImages
                                      ? Icon(
                                          Icons.check,
                                          size: 14,
                                          color: Theme.of(context).colorScheme.onPrimary,
                                        )
                                      : null,
                                ),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'log',
                            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Text('日志'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 4, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: _openChapterUrl,
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _chapter?.title ?? '',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: _menuForeground,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.open_in_new,
                                      color: _menuForeground.withValues(
                                        alpha: 0.54,
                                      ),
                                      size: 14,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _chapter?.url ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _menuForeground.withValues(
                                      alpha: 0.6,
                                    ),
                                    fontSize: 11,
                                    decoration: TextDecoration.underline,
                                    decorationColor: _menuForeground.withValues(
                                      alpha: 0.38,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<String>(
                        enabled: _bookSource != null,
                        tooltip: '书源操作',
                        offset: const Offset(0, 48),
                        onSelected: _handleSourceAction,
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'edit',
                            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: ListTile(
                              leading: Icon(Icons.edit_outlined),
                              title: Text('编辑书源'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          PopupMenuItem(
                            value: 'disable',
                            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: ListTile(
                              leading: Icon(Icons.block),
                              title: Text('禁用书源'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ],
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 132),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  _sourceName.isEmpty ? '未知书源' : _sourceName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onPrimary,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 3),
                              Icon(
                                Icons.arrow_drop_down,
                                color: Theme.of(context).colorScheme.onPrimary,
                                size: 16,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleMenu,
          ),
        ),
        Material(
          color: _menuBackground,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      TextButton(
                        onPressed: _hasPreviousChapter
                            ? _previousChapter
                            : null,
                        style: TextButton.styleFrom(
                          foregroundColor: _menuForeground,
                          disabledForegroundColor: _menuForeground,
                        ),
                        child: const Text('上一章'),
                      ),
                      Expanded(
                        child: Slider(
                          value: _images.isEmpty
                              ? 0
                              : (_isSliderDragging
                                  ? _sliderPageIndex
                                  : _currentPageIndex.toDouble()),
                          min: 0,
                          max: _images.length > 1
                              ? (_images.length - 1).toDouble()
                              : 1,
                          onChanged: _images.isEmpty ? null : _onSliderChanged,
                          onChangeEnd: (value) {
                            setState(() {
                              _isSliderDragging = false;
                            });
                            _lastSliderJumpIndex = -1;
                            _goToPage(value.round());
                          },
                        ),
                      ),
                      TextButton(
                        onPressed: _hasNextChapter ? _nextChapter : null,
                        style: TextButton.styleFrom(
                          foregroundColor: _menuForeground,
                          disabledForegroundColor: _menuForeground,
                        ),
                        child: const Text('下一章'),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _menuButton(Icons.list, '目录', _showChapterList),
                      _menuButton(
                        _isAutoPaging ? Icons.pause : Icons.play_arrow,
                        _isAutoPaging ? '停止' : '自动',
                        _toggleAutoPage,
                        active: _isAutoPaging,
                      ),
                      _menuButton(
                        Icons.brightness_6,
                        '亮度',
                        _showBrightnessSheet,
                      ),
                      _menuButton(Icons.tune, '设置', _showQuickSettings),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuButton(
    IconData icon,
    String label,
    VoidCallback action, {
    bool active = false,
  }) {
    return InkWell(
      onTap: action,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 64,
        height: 54,
        decoration: BoxDecoration(
          color: active
              ? _menuForeground.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : _menuForeground,
              size: 21,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(color: _menuForeground, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadCurrentChapter() async {
    if (_images.isEmpty) return;
    final tasks = _images
        .where((url) => !url.startsWith('data:'))
        .map(
          (url) => precacheImage(
            CachedNetworkImageProvider(url, headers: _headersForImage(url)),
            context,
          ),
        )
        .toList();
    await Future.wait(tasks);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已加入预缓存')));
  }

  void _handleTap(TapUpDetails details) {
    if (_showMenu) return;
    final width = MediaQuery.sizeOf(context).width;
    if (_readMode != MangaReadMode.scroll &&
        details.localPosition.dx < width * 0.28) {
      _readMode == MangaReadMode.japanese ? _nextPage() : _previousPage();
    } else if (_readMode != MangaReadMode.scroll &&
        details.localPosition.dx > width * 0.72) {
      _readMode == MangaReadMode.japanese ? _previousPage() : _nextPage();
    } else {
      _toggleMenu();
    }
  }

  void _toggleMenu() {
    setState(() => _showMenu = !_showMenu);
    final showMenu = _showMenu;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _showMenu != showMenu) return;
      SystemChrome.setEnabledSystemUIMode(
        showMenu ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      );
    });
  }

  void _openBookDetail() {
    final book = _book;
    if (book == null) return;
    _disableAutoPaging();
    setState(() => _showMenu = false);
    Navigator.pushNamed(
      context,
      AppRoutes.detail,
      arguments: {'bookUrl': book.bookUrl, 'bookData': book},
    );
  }

  Future<void> _openChapterUrl() async {
    final rawUrl = _chapter?.url?.split(',{').first.trim() ?? '';
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _showMessage('当前章节没有可打开的网页链接');
      return;
    }
    _disableAutoPaging();
    await Navigator.pushNamed(
      context,
      AppRoutes.internalBrowser,
      arguments: {
        'url': uri.toString(),
        'title': _chapter?.title ?? '',
        'sourceUrl': _book?.sourceUrl ?? '',
        'sourceName': _sourceName,
        'headers': _imageHeaders,
      },
    );
  }

  void _handleSourceAction(String action) {
    switch (action) {
      case 'edit':
        final sourceUrl = _bookSource?.bookSourceUrl;
        if (sourceUrl == null || sourceUrl.isEmpty) return;
        _disableAutoPaging();
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
      _sourceName = source.bookSourceName;
      _imageHeaders = source.getHeaderMap();
    });
  }

  Future<void> _disableBookSource() async {
    final source = _bookSource;
    if (source == null || !source.enabled) {
      _showMessage('该书源已禁用');
      return;
    }
    await StorageService.instance.saveBookSource(
      source.copyWith(enabled: false).toJson(),
    );
    if (!mounted) return;
    setState(() => _bookSource = source.copyWith(enabled: false));
    _showMessage('已禁用书源');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  bool get _hasPreviousChapter {
    final position = _chapters.indexWhere(
      (chapter) => chapter.index == _currentChapterIndex,
    );
    return position > 0;
  }

  bool get _hasNextChapter {
    final position = _chapters.indexWhere(
      (chapter) => chapter.index == _currentChapterIndex,
    );
    return position >= 0 && position < _chapters.length - 1;
  }

  void _previousChapter() {
    final position = _chapters.indexWhere(
      (chapter) => chapter.index == _currentChapterIndex,
    );
    if (position <= 0) return;
    if (_readMode == MangaReadMode.scroll) {
      _jumpToChapterListIndex(position - 1);
      return;
    }
    _currentChapterIndex = _chapters[position - 1].index;
    _loadChapter();
  }

  void _nextChapter() {
    final position = _chapters.indexWhere(
      (chapter) => chapter.index == _currentChapterIndex,
    );
    if (position < 0 || position >= _chapters.length - 1) return;
    if (_readMode == MangaReadMode.scroll) {
      _jumpToChapterListIndex(position + 1);
      return;
    }
    _currentChapterIndex = _chapters[position + 1].index;
    _loadChapter();
  }

  void _jumpToChapterListIndex(
    int chapterListIndex, {
    int pageIndex = 0,
    bool animated = true,
  }) {
    if (_readMode != MangaReadMode.scroll || _allImages.isEmpty) return;
    if (chapterListIndex < 0 || chapterListIndex >= _chapters.length) return;
    final globalIndex = _resolveGlobalIndex(chapterListIndex, pageIndex);
    _scrollToGlobalIndex(globalIndex, animated: animated);
  }

  void _previousPage() {
    if (_readMode == MangaReadMode.scroll) {
      if (_currentPageIndex > 0) {
        _goToPage(_currentPageIndex - 1);
      } else {
        _previousChapter();
      }
      return;
    }
    if (_currentPageIndex > 0) {
      _pageController?.previousPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _previousChapter();
    }
  }

  void _nextPage() {
    if (_readMode == MangaReadMode.scroll) {
      if (_currentPageIndex < _images.length - 1) {
        _goToPage(_currentPageIndex + 1);
      } else {
        _nextChapter();
      }
      return;
    }
    if (_currentPageIndex < _images.length - 1) {
      _pageController?.nextPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _nextChapter();
    }
  }

  void _goToPage(int page, {bool animated = true}) {
    if (_images.isEmpty) return;
    final target = page.clamp(0, _images.length - 1).toInt();
    _currentPageIndex = target;
    _pageNotifier.value = target;
    if (_readMode != MangaReadMode.scroll) {
      _pageController?.jumpToPage(_horizontalPageForImage(target));
    } else {
      _scrollToImageIndex(target, animated: animated);
    }
  }

  void _scrollToImageIndex(int targetIndex, {bool animated = true}) {
    if (_readMode != MangaReadMode.scroll || _images.isEmpty) return;
    final chapterIdx = _chapters.indexWhere(
      (chapter) => chapter.index == _currentChapterIndex,
    );
    if (chapterIdx < 0) return;
    final globalIndex = _resolveGlobalIndex(chapterIdx, targetIndex);
    _scrollToGlobalIndex(globalIndex, animated: animated);
  }

  void _scrollToGlobalIndex(int globalIndex, {bool animated = true}) {
    if (!_scrollController.hasClients || _allImages.isEmpty) return;
    final target = globalIndex.clamp(0, _allImages.length - 1).toInt();
    _isJumpingToChapter = true;
    _applyGlobalIndex(target, save: true);

    void finish() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _isJumpingToChapter = false;
        _updateScrollProgress();
      });
    }

    final targetContext = _globalImageKeys[target]?.currentContext;
    if (targetContext != null) {
      Scrollable.ensureVisible(
        targetContext,
        duration: animated ? const Duration(milliseconds: 300) : Duration.zero,
        curve: Curves.easeOut,
        alignment: 0,
      ).whenComplete(finish);
      return;
    }

    final position = _scrollController.position;
    final ratio = _allImages.length > 1 ? target / (_allImages.length - 1) : 0.0;
    final estimatedOffset = (position.maxScrollExtent * ratio)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if (animated) {
      _scrollController
          .animateTo(
            estimatedOffset,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          )
          .whenComplete(() {
        final retryContext = _globalImageKeys[target]?.currentContext;
        if (retryContext != null) {
          Scrollable.ensureVisible(
            retryContext,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            alignment: 0,
          );
        }
        finish();
      });
    } else {
      _scrollController.jumpTo(estimatedOffset);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final retryContext = _globalImageKeys[target]?.currentContext;
        if (retryContext != null) {
          Scrollable.ensureVisible(
            retryContext,
            duration: Duration.zero,
            alignment: 0,
          );
        }
        finish();
      });
    }
  }

  void _toggleAutoPage() {
    setState(() {
      _isAutoPaging = !_isAutoPaging;
      _showMenu = false;
    });
    if (_isAutoPaging) {
      _startAutoPageTimer();
    } else {
      _stopAutoPageTimer();
    }
  }

  void _startAutoPageTimer() {
    _autoPageTimer?.cancel();
    final interval = _readMode == MangaReadMode.scroll
        ? const Duration(milliseconds: 32)
        : const Duration(seconds: 3);
    _autoPageTimer = Timer.periodic(interval, (_) => _runAutoPageStep());
  }

  void _stopAutoPageTimer() {
    _autoPageTimer?.cancel();
    _autoPageTimer = null;
    _autoPageBusy = false;
  }

  void _disableAutoPaging() {
    _stopAutoPageTimer();
    if (mounted && _isAutoPaging) {
      setState(() => _isAutoPaging = false);
    }
  }

  Future<void> _runAutoPageStep() async {
    if (!_isAutoPaging ||
        _autoPageBusy ||
        _isLoading ||
        _error != null ||
        _showMenu) {
      return;
    }

    if (_readMode == MangaReadMode.scroll) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (position.pixels >= position.maxScrollExtent - 2) {
        _disableAutoPaging();
        _showMessage('Reached the end');
        return;
      }
      _autoPageBusy = true;
      try {
        final targetOffset = (position.pixels + 72)
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();
        await _scrollController.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 180),
          curve: Curves.linear,
        );
      } finally {
        _autoPageBusy = false;
      }
      return;
    }

    _autoPageBusy = true;
    try {
      if (_currentPageIndex >= _images.length - 1) {
        await _advanceAutoChapter();
      } else if (_pageController?.hasClients == true) {
        await _pageController!.nextPage(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );
      }
    } finally {
      _autoPageBusy = false;
    }
  }

  Future<void> _advanceAutoChapter() async {
    if (_readMode == MangaReadMode.scroll) {
      _disableAutoPaging();
      _showMessage('Reached the end');
      return;
    }

    if (!_hasNextChapter) {
      if (mounted) {
        setState(() => _isAutoPaging = false);
        _stopAutoPageTimer();
        _showMessage('Reached the end');
      }
      return;
    }

    _autoPageBusy = true;
    try {
      final position = _chapters.indexWhere(
        (chapter) => chapter.index == _currentChapterIndex,
      );
      _currentChapterIndex = _chapters[position + 1].index;
      await _loadChapter();
    } finally {
      _autoPageBusy = false;
    }
  }

  void _showChapterList() {
    final resumeAutoPaging = _isAutoPaging;
    _autoPageTimer?.cancel();
    setState(() => _showMenu = false);
    showModalBottomSheet(
      context: context,
      backgroundColor: _menuBackground,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      showDragHandle: true,
      builder: (context) => _ChapterListPanel(
        book: _book,
        chapters: _chapters,
        currentChapterIndex: _currentChapterIndex,
        bookSource: _bookSource,
        foregroundColor: _menuForeground,
        backgroundColor: _menuBackground,
        onChapterSelected: (index) {
          Navigator.pop(context);
          if (_readMode == MangaReadMode.scroll) {
            final chapterListIndex = _chapters.indexWhere(
              (chapter) => chapter.index == index,
            );
            if (chapterListIndex >= 0) {
              _jumpToChapterListIndex(chapterListIndex, animated: false);
            }
            return;
          }
          _currentChapterIndex = index;
          _loadChapter();
        },
      ),
    ).whenComplete(() {
      if (resumeAutoPaging && mounted && _isAutoPaging) {
        _startAutoPageTimer();
      }
    });
  }

  void _showBrightnessSheet() {
    final resumeAutoPaging = _isAutoPaging;
    _autoPageTimer?.cancel();
    setState(() => _showMenu = false);

    // 节流相关变量
    int lastNativeCallTime = 0;
    Timer? throttleTimer;
    double? pendingValue;

    void callNativeThrottled(double value) {
      final now = DateTime.now().millisecondsSinceEpoch;
      // 每 30ms 最多调用一次原生方法
      if (now - lastNativeCallTime >= 30) {
        lastNativeCallTime = now;
        NativeChannel.instance.setScreenBrightness(value);
        pendingValue = null;
      } else {
        pendingValue = value;
        throttleTimer?.cancel();
        throttleTimer = Timer(const Duration(milliseconds: 30), () {
          if (pendingValue != null) {
            NativeChannel.instance.setScreenBrightness(pendingValue!);
            pendingValue = null;
          }
        });
      }
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: _menuBackground,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          // 滑动过程中实时更新亮度（节流调用原生方法）
          void updateBrightnessImmediate(double value) {
            setState(() => _screenBrightness = value);
            setSheetState(() {});
            callNativeThrottled(value);
          }

          // 滑动结束时保存设置
          Future<void> saveBrightness(double value) async {
            throttleTimer?.cancel();
            // 确保最后的值被设置
            await NativeChannel.instance.setScreenBrightness(value);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setDouble(_brightnessKey, value);
          }

          // 切换跟随系统亮度
          Future<void> toggleFollowSystem(bool followSystem) async {
            final value = followSystem ? -1.0 : 0.5;
            setState(() => _screenBrightness = value);
            setSheetState(() {});
            await NativeChannel.instance.setScreenBrightness(value);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setDouble(_brightnessKey, value);
          }

          Future<void> toggleEyeCare(bool value) async {
            setState(() => _eyeCareMode = value);
            setSheetState(() {});
            unawaited(_saveSettings());
          }

          Future<void> toggleKeepScreenOn(bool value) async {
            setState(() => _keepScreenOn = value);
            setSheetState(() {});
            if (value) {
              await WakelockPlus.enable();
            } else {
              await WakelockPlus.disable();
            }
            unawaited(_saveSettings());
          }

          final followsSystem = _screenBrightness < 0;
          final sliderValue = followsSystem ? 0.5 : _screenBrightness;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '亮度',
                    style: TextStyle(
                      color: _menuForeground,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '跟随系统亮度',
                      style: TextStyle(color: _menuForeground),
                    ),
                    value: followsSystem,
                    onChanged: toggleFollowSystem,
                  ),
                  Row(
                    children: [
                      Icon(
                        Icons.brightness_low,
                        color: _menuForeground.withValues(alpha: 0.7),
                      ),
                      Expanded(
                        child: Slider(
                          value: sliderValue.clamp(0.01, 1.0),
                          min: 0.01,
                          max: 1,
                          onChanged: followsSystem
                              ? null
                              : updateBrightnessImmediate,
                          onChangeEnd: followsSystem
                              ? null
                              : saveBrightness,
                        ),
                      ),
                      Icon(
                        Icons.brightness_high,
                        color: _menuForeground.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 44,
                        child: Text(
                          followsSystem
                              ? '系统'
                              : '${(sliderValue * 100).round()}%',
                          textAlign: TextAlign.end,
                          style: TextStyle(color: _menuForeground),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(
                      Icons.remove_red_eye_outlined,
                      color: _menuForeground,
                    ),
                    title: Text(
                      '护眼模式',
                      style: TextStyle(color: _menuForeground),
                    ),
                    subtitle: Text(
                      '减少蓝光，保护眼睛',
                      style: TextStyle(
                        color: _menuForeground.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                    value: _eyeCareMode,
                    onChanged: toggleEyeCare,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(
                      Icons.screen_lock_portrait_outlined,
                      color: _menuForeground,
                    ),
                    title: Text(
                      '屏幕常亮',
                      style: TextStyle(color: _menuForeground),
                    ),
                    value: _keepScreenOn,
                    onChanged: toggleKeepScreenOn,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      throttleTimer?.cancel();
      if (resumeAutoPaging && mounted && _isAutoPaging) {
        _startAutoPageTimer();
      }
    });
  }

  void _showFooterConfig() {
    setState(() => _showMenu = false);
    showModalBottomSheet(
      context: context,
      backgroundColor: _menuBackground,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '页脚配置',
                    style: TextStyle(
                      color: _menuForeground,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    value: !_hideFooter,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '显示底部进度',
                      style: TextStyle(color: _menuForeground),
                    ),
                    onChanged: (value) {
                      setState(() => _hideFooter = !value);
                      setSheetState(() {});
                      unawaited(_saveSettings());
                    },
                  ),
                  SwitchListTile(
                    value: !_hideChapterTitle,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '显示章节首尾提示',
                      style: TextStyle(color: _menuForeground),
                    ),
                    onChanged: (value) {
                      setState(() => _hideChapterTitle = !value);
                      setSheetState(() {});
                      unawaited(_saveSettings());
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _toggleEinkMode() {
    setState(() => _einkMode = !_einkMode);
    unawaited(_saveSettings());
  }

  void _toggleGrayscale() {
    setState(() => _grayscaleImages = !_grayscaleImages);
    unawaited(_saveSettings());
  }

  void _showImageLoadLog() {
    setState(() => _showMenu = false);
    showModalBottomSheet(
      context: context,
      backgroundColor: _menuBackground,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text(
                      '图片加载日志',
                      style: TextStyle(
                        color: _menuForeground,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        setState(() => _imageLoadLog.clear());
                        Navigator.pop(context);
                      },
                      child: const Text('清空'),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: _menuForeground.withValues(alpha: 0.12)),
              Expanded(
                child: _imageLoadLog.isEmpty
                    ? Center(
                        child: Text(
                          '暂无日志',
                          style: TextStyle(color: _menuForeground.withValues(alpha: 0.6)),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _imageLoadLog.length,
                        itemBuilder: (context, index) {
                          final log = _imageLoadLog[_imageLoadLog.length - 1 - index];
                          return ListTile(
                            dense: true,
                            title: Text(
                              log,
                              style: TextStyle(color: _menuForeground, fontSize: 12),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showQuickSettings() {
    final resumeAutoPaging = _isAutoPaging;
    _autoPageTimer?.cancel();
    setState(() => _showMenu = false);
    showModalBottomSheet(
      context: context,
      backgroundColor: _menuBackground,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(VoidCallback action) {
            setState(action);
            setSheetState(() {});
            unawaited(_saveSettings());
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '漫画设置',
                    style: TextStyle(
                      color: _menuForeground,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<MangaReadMode>(
                    segments: const [
                      ButtonSegment(
                        value: MangaReadMode.scroll,
                        icon: Icon(Icons.view_stream),
                        label: Text('卷轴'),
                      ),
                      ButtonSegment(
                        value: MangaReadMode.horizontal,
                        icon: Icon(Icons.swipe),
                        label: Text('横向'),
                      ),
                      ButtonSegment(
                        value: MangaReadMode.japanese,
                        icon: Icon(Icons.keyboard_double_arrow_left),
                        label: Text('日漫'),
                      ),
                    ],
                    selected: {_readMode},
                    onSelectionChanged: (value) {
                      final mode = value.first;
                      update(() {
                        _readMode = mode;
                        _resetControllers();
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    value: !_disableScale,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '允许图片缩放',
                      style: TextStyle(color: _menuForeground),
                    ),
                    onChanged: (value) => update(() {
                      _disableScale = !value;
                      if (_disableScale) _resetZoom();
                    }),
                  ),
                  SwitchListTile(
                    value: _hideChapterTitle,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '隐藏章节首尾提示',
                      style: TextStyle(color: _menuForeground),
                    ),
                    onChanged: (value) =>
                        update(() => _hideChapterTitle = value),
                  ),
                  SwitchListTile(
                    value: _hideFooter,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '隐藏底部进度',
                      style: TextStyle(color: _menuForeground),
                    ),
                    onChanged: (value) => update(() => _hideFooter = value),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '图片预加载',
                          style: TextStyle(color: _menuForeground),
                        ),
                      ),
                      ValueListenableBuilder<double>(
                        valueListenable: _preloadSliderValue,
                        builder: (context, value, _) {
                          final displayValue = _isPreloadDragging
                              ? value.round()
                              : _preloadCount;
                          return Text(
                            '$displayValue 张',
                            style: TextStyle(
                              color: _menuForeground.withValues(alpha: 0.7),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  ValueListenableBuilder<double>(
                    valueListenable: _preloadSliderValue,
                    builder: (context, value, _) {
                      return Slider(
                        value: _isPreloadDragging ? value : _preloadCount.toDouble(),
                        min: 0,
                        max: 30,
                        divisions: 30,
                        onChanged: (newValue) {
                          _isPreloadDragging = true;
                          _preloadSliderValue.value = newValue;
                        },
                        onChangeEnd: (newValue) {
                          setState(() {
                            _preloadCount = newValue.round();
                            _isPreloadDragging = false;
                          });
                          unawaited(_saveSettings());
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      // 只在非滚动模式下才重置控制器和跳转
      if (_readMode != MangaReadMode.scroll) {
        setState(_resetControllers);
        WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToCurrentPage());
      }
      if (resumeAutoPaging && mounted && _isAutoPaging) {
        _startAutoPageTimer();
      }
    });
  }
}

class _ComicZoomValue {
  const _ComicZoomValue(this.scale, this.offset);

  final double scale;
  final Offset offset;
}

class _ComicZoomLayer extends StatefulWidget {
  const _ComicZoomLayer({
    super.key,
    required this.enabled,
    required this.readingAxis,
    required this.onTapUp,
    required this.child,
  });

  final bool enabled;
  final Axis readingAxis;
  final ValueChanged<TapUpDetails> onTapUp;
  final Widget child;

  @override
  State<_ComicZoomLayer> createState() => _ComicZoomLayerState();
}

class _ComicZoomLayerState extends State<_ComicZoomLayer>
    with SingleTickerProviderStateMixin {
  static const double _minScale = 0.5;
  static const double _defaultScale = 1;
  static const double _maxScale = 3;
  static const Duration _doubleTapTimeout = Duration(milliseconds: 260);

  final ValueNotifier<_ComicZoomValue> _zoom = ValueNotifier(
    const _ComicZoomValue(_defaultScale, Offset.zero),
  );
  final Map<int, Offset> _pointers = {};

  late final AnimationController _animationController;
  Size _viewportSize = Size.zero;
  double _pinchStartScale = _defaultScale;
  double _pinchStartDistance = 0;
  Offset _pinchContentPoint = Offset.zero;
  Offset? _lastPanPosition;
  int? _panPointer;
  VelocityTracker? _velocityTracker;
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;
  Offset? _tapDownPosition;
  bool _tapMoved = false;
  Timer? _singleTapTimer;
  _ComicZoomValue _animationStart = const _ComicZoomValue(
    _defaultScale,
    Offset.zero,
  );
  _ComicZoomValue _animationEnd = const _ComicZoomValue(
    _defaultScale,
    Offset.zero,
  );

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    )..addListener(_applyAnimation);
  }

  @override
  void didUpdateWidget(covariant _ComicZoomLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      reset(animate: false);
    }
  }

  @override
  void dispose() {
    _singleTapTimer?.cancel();
    _animationController.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void reset({bool animate = true}) {
    _pointers.clear();
    _lastPanPosition = null;
    _panPointer = null;
    _velocityTracker = null;
    if (animate && (_zoom.value.scale - _defaultScale).abs() > 0.001) {
      _animateTo(const _ComicZoomValue(_defaultScale, Offset.zero));
    } else {
      _animationController.stop();
      _zoom.value = const _ComicZoomValue(_defaultScale, Offset.zero);
    }
  }

  void _applyAnimation() {
    final curved = Curves.decelerate.transform(_animationController.value);
    final start = _animationStart;
    final end = _animationEnd;
    _zoom.value = _ComicZoomValue(
      start.scale + (end.scale - start.scale) * curved,
      Offset.lerp(start.offset, end.offset, curved)!,
    );
  }

  void _animateTo(
    _ComicZoomValue target, {
    Duration duration = const Duration(milliseconds: 320),
  }) {
    _animationController.stop();
    _animationController.duration = duration;
    _animationStart = _zoom.value;
    _animationEnd = target;
    _animationController.forward(from: 0);
  }

  Offset _clampOffset(Offset offset, double scale) {
    if (_viewportSize.isEmpty) return Offset.zero;
    if (scale < _defaultScale) {
      return Offset(
        _viewportSize.width * (1 - scale) / 2,
        _viewportSize.height * (1 - scale) / 2,
      );
    }
    if (scale == _defaultScale) return Offset.zero;
    final minX = _viewportSize.width * (1 - scale);
    final minY = _viewportSize.height * (1 - scale);
    return Offset(
      offset.dx.clamp(minX, 0).toDouble(),
      offset.dy.clamp(minY, 0).toDouble(),
    );
  }

  void _beginPinch() {
    if (_pointers.length < 2) return;
    _animationController.stop();
    final points = _pointers.values.take(2).toList(growable: false);
    final focalPoint = (points[0] + points[1]) / 2;
    _pinchStartDistance = (points[0] - points[1]).distance;
    _pinchStartScale = _zoom.value.scale;
    _pinchContentPoint = (focalPoint - _zoom.value.offset) / _pinchStartScale;
    _lastPanPosition = null;
    _panPointer = null;
    _velocityTracker = null;
  }

  void _beginPan(PointerEvent event) {
    _animationController.stop();
    _panPointer = event.pointer;
    _lastPanPosition = event.localPosition;
    _velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.localPosition);
  }

  void _fling(Offset velocity) {
    final current = _zoom.value;
    if (current.scale <= _defaultScale || velocity.distance < 50) return;
    final panVelocity = widget.readingAxis == Axis.vertical
        ? Offset(velocity.dx, 0)
        : Offset(0, velocity.dy);
    if (panVelocity.distance < 50) return;
    final targetOffset = _clampOffset(
      current.offset + panVelocity * 0.2,
      current.scale,
    );
    if ((targetOffset - current.offset).distance < 0.5) return;
    _animateTo(
      _ComicZoomValue(current.scale, targetOffset),
      duration: const Duration(milliseconds: 400),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pointers.isEmpty) {
      _tapDownPosition = event.localPosition;
      _tapMoved = false;
    }
    if (!widget.enabled) return;
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      _beginPinch();
    } else if (_pointers.length == 1 && _zoom.value.scale > _defaultScale) {
      _beginPan(event);
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    // 即使缩放禁用，也需要更新 _tapMoved 以区分滑动和点击
    if (_tapDownPosition != null &&
        (event.localPosition - _tapDownPosition!).distance > 18) {
      _tapMoved = true;
    }
    if (!widget.enabled || !_pointers.containsKey(event.pointer)) return;
    final previous = _pointers[event.pointer]!;
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length >= 2 && _pinchStartDistance > 0) {
      final points = _pointers.values.take(2).toList(growable: false);
      final distance = (points[0] - points[1]).distance;
      final focalPoint = (points[0] + points[1]) / 2;
      final scale = (_pinchStartScale * distance / _pinchStartDistance)
          .clamp(_minScale, _maxScale)
          .toDouble();
      final offset = _clampOffset(
        focalPoint - _pinchContentPoint * scale,
        scale,
      );
      _zoom.value = _ComicZoomValue(scale, offset);
      return;
    }

    if (_pointers.length == 1 && _zoom.value.scale > _defaultScale) {
      if (_panPointer != event.pointer || _velocityTracker == null) {
        _beginPan(event);
      } else {
        _velocityTracker!.addPosition(event.timeStamp, event.localPosition);
      }
      final delta = event.localPosition - (_lastPanPosition ?? previous);
      final panDelta = widget.readingAxis == Axis.vertical
          ? Offset(delta.dx, 0)
          : Offset(0, delta.dy);
      final current = _zoom.value;
      _zoom.value = _ComicZoomValue(
        current.scale,
        _clampOffset(current.offset + panDelta, current.scale),
      );
      _lastPanPosition = event.localPosition;
    }
  }

  void _onPointerEnd(PointerEvent event, {required bool allowFling}) {
    // 当缩放禁用时，仍然处理点击事件
    if (!widget.enabled) {
      // 处理点击事件
      if (_pointers.isEmpty &&
          !_tapMoved &&
          _tapDownPosition != null &&
          allowFling) {
        widget.onTapUp(
          TapUpDetails(
            kind: event.kind,
            localPosition: event.localPosition,
            globalPosition: event.localPosition,
          ),
        );
      }
      _tapDownPosition = null;
      _tapMoved = false;
      return;
    }
    final isTap =
        allowFling &&
        _pointers.length == 1 &&
        !_tapMoved &&
        _tapDownPosition != null;
    if (isTap) {
      final now = DateTime.now();
      final isDoubleTap =
          _lastTapTime != null &&
          now.difference(_lastTapTime!) <= _doubleTapTimeout &&
          _lastTapPosition != null &&
          (event.localPosition - _lastTapPosition!).distance <= 48;
      if (isDoubleTap) {
        _singleTapTimer?.cancel();
        _lastTapTime = null;
        _lastTapPosition = null;
        _onDoubleTap(event.localPosition);
      } else {
        _lastTapTime = now;
        _lastTapPosition = event.localPosition;
        final position = event.localPosition;
        final kind = event.kind;
        _singleTapTimer?.cancel();
        _singleTapTimer = Timer(_doubleTapTimeout, () {
          _lastTapTime = null;
          _lastTapPosition = null;
          widget.onTapUp(
            TapUpDetails(
              kind: kind,
              localPosition: position,
              globalPosition: position,
            ),
          );
        });
      }
    }
    Offset velocity = Offset.zero;
    if (allowFling &&
        _pointers.length == 1 &&
        _panPointer == event.pointer &&
        _zoom.value.scale > _defaultScale) {
      _velocityTracker?.addPosition(event.timeStamp, event.localPosition);
      velocity = _velocityTracker?.getVelocity().pixelsPerSecond ?? Offset.zero;
    }
    _pointers.remove(event.pointer);
    if (_pointers.length >= 2) {
      _beginPinch();
    } else {
      _pinchStartDistance = 0;
      _lastPanPosition = _pointers.isEmpty ? null : _pointers.values.first;
      _panPointer = _pointers.isEmpty ? null : _pointers.keys.first;
      _velocityTracker = null;
      _tapDownPosition = null;
      _tapMoved = false;
      if (_zoom.value.scale < _defaultScale ||
          (_zoom.value.scale > _defaultScale &&
              _zoom.value.scale < _defaultScale + 0.12)) {
        reset();
      } else if (_pointers.isEmpty) {
        _fling(velocity);
      }
    }
  }

  void _onDoubleTap(Offset position) {
    if (!widget.enabled) return;
    final current = _zoom.value;
    if ((current.scale - _defaultScale).abs() > 0.01) {
      reset();
      return;
    }

    const targetScale = 2.0;
    _animateTo(
      _ComicZoomValue(
        targetScale,
        _clampOffset(position - position * targetScale, targetScale),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportSize = constraints.biggest;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: (event) => _onPointerEnd(event, allowFling: true),
          onPointerCancel: (event) => _onPointerEnd(event, allowFling: false),
          child: ClipRect(
            child: ValueListenableBuilder<_ComicZoomValue>(
              valueListenable: _zoom,
              child: widget.child,
              builder: (context, zoom, child) {
                final matrix = Matrix4.identity()
                  ..setEntry(0, 0, zoom.scale)
                  ..setEntry(1, 1, zoom.scale)
                  ..setEntry(0, 3, zoom.offset.dx)
                  ..setEntry(1, 3, zoom.offset.dy);
                return Transform(
                  alignment: Alignment.topLeft,
                  transform: matrix,
                  child: child,
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _ChapterListPanel extends StatefulWidget {
  final Book? book;
  final List<Chapter> chapters;
  final int currentChapterIndex;
  final BookSource? bookSource;
  final Color foregroundColor;
  final Color backgroundColor;
  final Function(int) onChapterSelected;

  const _ChapterListPanel({
    this.book,
    required this.chapters,
    required this.currentChapterIndex,
    this.bookSource,
    required this.foregroundColor,
    required this.backgroundColor,
    required this.onChapterSelected,
  });

  @override
  State<_ChapterListPanel> createState() => _ChapterListPanelState();
}

class _ChapterListPanelState extends State<_ChapterListPanel> {
  int _currentTab = 0;
  bool _showSearch = false;
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
  final ScrollController _scrollController = ScrollController();
  final PageController _pageController = PageController();

  @override
  void initState() {
    super.initState();
    _loadCacheInfo();
    _loadBookmarks();
    _loadPrefs();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentChapter();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _scrollToCurrentChapter() {
    if (!_scrollController.hasClients) return;
    if (widget.currentChapterIndex <= 0) return;

    // 找到当前章节在列表中的位置
    final display = _buildDisplayChapters(_filteredChapters);
    final targetIndex = display.indexWhere((ch) => ch.index == widget.currentChapterIndex);
    if (targetIndex < 0) return;

    // 估算位置 - 每个item大约48高度
    final estimatedOffset = targetIndex * 48.0;
    _scrollController.animateTo(
      estimatedOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
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
    final files = await ChapterCacheService.instance.getChapterCacheFiles(widget.book!, isComic: true);
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
          child: _showSearch
              ? Row(
                  children: [
                    Expanded(
                      child: TextField(
                        autofocus: true,
                        style: TextStyle(color: fg),
                        decoration: InputDecoration(
                          hintText: '搜索...',
                          hintStyle: TextStyle(color: fg.withValues(alpha: 0.5)),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: fg.withValues(alpha: 0.3)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: fg.withValues(alpha: 0.3)),
                          ),
                        ),
                        onChanged: (query) => setState(() => _searchQuery = query),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: fg),
                      onPressed: () => setState(() {
                        _showSearch = false;
                        _searchQuery = '';
                      }),
                    ),
                  ],
                )
              : Row(
                  children: [
                    _buildTab(0, '目录', fg),
                    const SizedBox(width: 24),
                    _buildTab(1, '书签', fg),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.search, color: fg, size: 22),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      onPressed: () => setState(() => _showSearch = true),
                    ),
                    PopupMenuButton<String>(
                      icon: Icon(Icons.more_vert, color: fg, size: 22),
                      tooltip: '更多',
                      offset: const Offset(0, 48),
                      padding: EdgeInsets.zero,
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
                                _menuItem('bm_search_chapter', '搜索章节名', _searchChapterName, fg),
                                _menuItem('bm_search_text', '搜索书文', _searchBookText, fg),
                                _menuItem('bm_search_note', '搜索备注', _searchContent, fg),
                              ],
                    ),
                  ],
                ),
        ),
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.5,
          child: PageView(
            controller: _pageController,
            onPageChanged: (index) => setState(() => _currentTab = index),
            children: [
              _buildChapterList(fg, isOnline),
              _buildBookmarkList(fg),
            ],
          ),
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
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              border: Border.all(
                color: checked
                    ? Theme.of(context).colorScheme.primary
                    : fg.withValues(alpha: 0.5),
                width: 1.5,
              ),
              borderRadius: BorderRadius.circular(3),
              color: checked
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
            ),
            child: checked
                ? Icon(
                    Icons.check,
                    size: 14,
                    color: Theme.of(context).colorScheme.onPrimary,
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildTab(int index, String text, Color fg) {
    final selected = _currentTab == index;
    return GestureDetector(
      onTap: () {
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: TextStyle(
              color: selected ? fg : fg.withValues(alpha: 0.5),
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: 28,
            height: 3,
            decoration: BoxDecoration(
              color: selected ? Theme.of(context).colorScheme.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterList(Color fg, bool isOnline) {
    final display = _buildDisplayChapters(_filteredChapters);
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: ListView.builder(
        controller: _scrollController,
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
          final fileName = ChapterCacheService.instance.getChapterFileName(chapter, suffix: 'cb');
          final isCached = !isOnline || _cachedFiles.contains(fileName);
          final hasTag = chapter.tag != null && chapter.tag!.isNotEmpty;
          final hasWordCount = _showWordCount && chapter.wordCount != null && chapter.wordCount! > 0;
          final showSubtitle = hasTag || hasWordCount;

          return InkWell(
            onTap: () => widget.onChapterSelected(chapter.index),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  if (chapter.isVip && !chapter.isPay)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(Icons.lock_outline, size: 18, color: fg.withValues(alpha: 0.6)),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          chapter.title,
                          style: TextStyle(
                            color: isSelected ? fg : fg.withValues(alpha: 0.85),
                            fontWeight: isSelected ? FontWeight.bold : null,
                            fontSize: 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (showSubtitle)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Row(
                              children: [
                                if (hasTag)
                                  Text(
                                    chapter.tag!,
                                    style: TextStyle(
                                      color: fg.withValues(alpha: 0.5),
                                      fontSize: 12,
                                    ),
                                  ),
                                if (hasTag && hasWordCount)
                                  const SizedBox(width: 8),
                                if (hasWordCount)
                                  Text(
                                    '${(chapter.wordCount! / 10000).toStringAsFixed(1)}万',
                                    style: TextStyle(
                                      color: fg.withValues(alpha: 0.5),
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (isSelected)
                    Icon(Icons.check, size: 18, color: fg)
                  else if (!isCached)
                    Icon(Icons.cloud_outlined, size: 18, color: fg.withValues(alpha: 0.4)),
                ],
              ),
            ),
          );
        },
      ),
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
    return Scrollbar(
      thumbVisibility: true,
      child: ListView.builder(
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
      ),
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
