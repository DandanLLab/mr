import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/chapter.dart';
import '../../services/book_data_provider.dart';
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
  static const _titleKey = 'hideMangaTitle';
  static const _footerKey = 'hideMangaFooter';
  static const _preloadKey = 'mangaPreloadCount';

  Book? _book;
  BookDataProvider? _dataProvider;
  List<Chapter> _chapters = [];
  List<String> _images = [];
  int _currentChapterIndex = 0;
  int _currentPageIndex = 0;
  bool _isLoading = true;
  bool _showMenu = false;
  String? _error;

  MangaReadMode _readMode = MangaReadMode.scroll;
  bool _disableScale = true;
  bool _hideChapterTitle = false;
  bool _hideFooter = false;
  int _preloadCount = 10;
  Map<String, String> _imageHeaders = const {};
  String _sourceName = '';

  final ScrollController _scrollController = ScrollController();
  PageController? _pageController;
  Timer? _footerTimer;

  Chapter? get _chapter {
    if (_chapters.isEmpty) return null;
    return _chapters.firstWhere(
      (chapter) => chapter.index == _currentChapterIndex,
      orElse: () => _chapters.first,
    );
  }

  @override
  void initState() {
    super.initState();
    _currentChapterIndex = widget.chapterIndex;
    _scrollController.addListener(_updateScrollProgress);
    _loadSettings().then((_) => _loadBook());
  }

  @override
  void dispose() {
    _footerTimer?.cancel();
    _scrollController.dispose();
    _pageController?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt(_modeKey) ?? 0;
    if (!mounted) return;
    setState(() {
      _readMode = MangaReadMode
          .values[modeIndex.clamp(0, MangaReadMode.values.length - 1)];
      _disableScale = prefs.getBool(_scaleKey) ?? true;
      _hideChapterTitle = prefs.getBool(_titleKey) ?? false;
      _hideFooter = prefs.getBool(_footerKey) ?? false;
      _preloadCount = (prefs.getInt(_preloadKey) ?? 10).clamp(0, 30);
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setInt(_modeKey, _readMode.index),
      prefs.setBool(_scaleKey, _disableScale),
      prefs.setBool(_titleKey, _hideChapterTitle),
      prefs.setBool(_footerKey, _hideFooter),
      prefs.setInt(_preloadKey, _preloadCount),
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
      _chapters = (await _dataProvider!.getChapterList(_book!))
          .where((chapter) => !chapter.isVolume)
          .toList();
      final sourceUrl = _book!.sourceUrl;
      if (sourceUrl != null && sourceUrl.isNotEmpty) {
        final sourceData = StorageService.instance.getBookSource(sourceUrl);
        if (sourceData != null) {
          final source = BookSource.fromJson(sourceData);
          _sourceName = source.bookSourceName;
          final headers = source.getHeaderMap();
          headers.putIfAbsent('Referer', () => source.bookSourceUrl);
          _imageHeaders = headers;
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
    final chapter = _chapter;
    if (chapter == null || _book == null || _dataProvider == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
      _showMenu = false;
    });

    try {
      final content = await _dataProvider!.getContent(_book!, chapter);
      final images = _extractImageUrls(content ?? '');
      if (images.isEmpty) {
        throw StateError('本章没有解析到图片');
      }
      _currentPageIndex = pageIndex.clamp(0, images.length - 1);
      _images = images;
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

  List<String> _extractImageUrls(String content) {
    final urls = <String>[];
    final seen = <String>{};

    void add(String? raw) {
      if (raw == null) return;
      final value = raw.trim().replaceAll('&amp;', '&').replaceAll(r'\/', '/');
      if (!value.startsWith('http://') && !value.startsWith('https://')) {
        return;
      }
      if (seen.add(value)) urls.add(value);
    }

    final imageTagPattern = RegExp(
      r'''<(?:img|image)[^>]+(?:src|data-src|data-original)\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    );
    for (final match in imageTagPattern.allMatches(content)) {
      add(match.group(1));
    }

    for (final line in content.split(RegExp(r'[\r\n]+'))) {
      final value = line.trim();
      if (RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(value)) {
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
          RegExp(r'\.(?:jpg|jpeg|png|webp|gif|avif)(?:\?|$)',
                  caseSensitive: false)
              .hasMatch(value)) {
        add(value);
      }
    }

    return urls;
  }

  void _resetControllers() {
    _pageController?.dispose();
    _pageController = PageController(initialPage: _currentPageIndex);
  }

  void _jumpToCurrentPage() {
    if (_readMode == MangaReadMode.scroll) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    } else if (_pageController?.hasClients == true) {
      _pageController!.jumpToPage(_currentPageIndex);
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
        _images.isEmpty) {
      return;
    }
    final position = _scrollController.position;
    final total = position.maxScrollExtent + position.viewportDimension;
    if (total <= 0) return;
    final page = ((position.pixels + position.viewportDimension * 0.45) /
            total *
            _images.length)
        .floor()
        .clamp(0, _images.length - 1);
    if (page != _currentPageIndex) {
      setState(() => _currentPageIndex = page);
      _scheduleProgressSave();
      _preloadImages();
    }
  }

  void _scheduleProgressSave() {
    _footerTimer?.cancel();
    _footerTimer = Timer(const Duration(milliseconds: 400), _saveProgress);
  }

  void _preloadImages() {
    if (!mounted || _images.isEmpty || _preloadCount == 0) return;
    final end =
        (_currentPageIndex + _preloadCount + 1).clamp(0, _images.length);
    for (var index = _currentPageIndex + 1; index < end; index++) {
      precacheImage(
        CachedNetworkImageProvider(
          _images[index],
          headers: _imageHeaders,
        ),
        context,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101010),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: _handleTap,
        child: Stack(
          children: [
            Positioned.fill(child: _buildReader()),
            if (!_hideFooter && !_isLoading && _error == null)
              _buildInfoFooter(),
            if (_showMenu) _buildMenu(),
          ],
        ),
      ),
    );
  }

  Widget _buildReader() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    if (_error != null) {
      return _buildError();
    }
    if (_readMode == MangaReadMode.scroll) {
      return _buildScrollReader();
    }
    return _buildHorizontalReader();
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined,
                color: Colors.white54, size: 48),
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
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
        MediaQuery.sizeOf(context).height * 3,
      ),
      slivers: [
        if (!_hideChapterTitle)
          SliverToBoxAdapter(
            child: _buildChapterEdge('阅读 ${_chapter?.title ?? ''}'),
          ),
        SliverList.builder(
          itemCount: _images.length,
          itemBuilder: (context, index) => _buildImage(
            _images[index],
            fit: BoxFit.fitWidth,
            minHeight: index == _images.length - 1
                ? MediaQuery.sizeOf(context).height * 0.66
                : 0,
          ),
        ),
        if (!_hideChapterTitle)
          SliverToBoxAdapter(
            child: _buildChapterEdge('已读完 ${_chapter?.title ?? ''}'),
          ),
        SliverToBoxAdapter(child: _buildChapterNavigation()),
      ],
    );
  }

  Widget _buildHorizontalReader() {
    return PageView.builder(
      controller: _pageController,
      reverse: _readMode == MangaReadMode.japanese,
      physics: const PageScrollPhysics(),
      itemCount: _images.length,
      onPageChanged: (index) {
        setState(() => _currentPageIndex = index);
        _scheduleProgressSave();
        _preloadImages();
      },
      itemBuilder: (context, index) {
        return SafeArea(
          child: _buildImage(_images[index], fit: BoxFit.contain),
        );
      },
    );
  }

  Widget _buildImage(
    String url, {
    required BoxFit fit,
    double minHeight = 0,
  }) {
    final image = CachedNetworkImage(
      imageUrl: url,
      httpHeaders: _imageHeaders,
      width: double.infinity,
      fit: fit,
      fadeInDuration: const Duration(milliseconds: 120),
      progressIndicatorBuilder: (context, _, progress) {
        final value = progress.progress;
        return Container(
          constraints: BoxConstraints(
            minHeight: minHeight > 0
                ? minHeight
                : MediaQuery.sizeOf(context).height * 0.55,
          ),
          color: const Color(0xFF101010),
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                value: value,
                color: Colors.white,
                strokeWidth: 3,
              ),
              if (value != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${(value * 100).round()}%',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ],
          ),
        );
      },
      errorWidget: (context, _, __) => Container(
        height: MediaQuery.sizeOf(context).height * 0.65,
        color: const Color(0xFF101010),
        alignment: Alignment.center,
        child: FilledButton.tonalIcon(
          onPressed: () => setState(() {}),
          icon: const Icon(Icons.refresh),
          label: const Text('重新加载图片'),
        ),
      ),
    );

    final child = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: image,
    );
    if (_disableScale) return child;
    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      panEnabled: true,
      scaleEnabled: true,
      child: child,
    );
  }

  Widget _buildChapterEdge(String text) {
    return SizedBox(
      height: 96,
      child: Center(
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildChapterNavigation() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _hasPreviousChapter ? _previousChapter : null,
                icon: const Icon(Icons.chevron_left),
                label: const Text('上一章'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _hasNextChapter ? _nextChapter : null,
                icon: const Icon(Icons.chevron_right),
                label: const Text('下一章'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoFooter() {
    final chapterPosition = _chapters
        .indexWhere((chapter) => chapter.index == _currentChapterIndex);
    final chapterNumber = chapterPosition < 0 ? 1 : chapterPosition + 1;
    final pageNumber = _images.isEmpty ? 0 : _currentPageIndex + 1;
    final totalProgress = _chapters.isEmpty || _images.isEmpty
        ? 0.0
        : ((chapterNumber - 1) / _chapters.length) +
            (pageNumber / _images.length / _chapters.length);

    return Positioned(
      left: 10,
      right: 10,
      bottom: MediaQuery.paddingOf(context).bottom + 8,
      child: IgnorePointer(
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
      ),
    );
  }

  Widget _buildMenu() {
    return Positioned.fill(
      child: Column(
        children: [
          Material(
            color: Colors.black.withValues(alpha: 0.86),
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      tooltip: '返回',
                    ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _book?.displayName ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            _sourceName.isEmpty ? '未知书源' : _sourceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: _loadChapter,
                      icon: const Icon(Icons.refresh, color: Colors.white),
                      tooltip: '刷新',
                    ),
                    IconButton(
                      onPressed: _showChapterList,
                      icon: const Icon(Icons.list, color: Colors.white),
                      tooltip: '目录',
                    ),
                  ],
                ),
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
            color: Colors.black.withValues(alpha: 0.88),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed:
                              _hasPreviousChapter ? _previousChapter : null,
                          icon: const Icon(Icons.chevron_left),
                          color: Colors.white,
                          tooltip: '上一章',
                        ),
                        Expanded(
                          child: Slider(
                            value: _images.isEmpty
                                ? 0
                                : _currentPageIndex.toDouble(),
                            min: 0,
                            max: _images.length > 1
                                ? (_images.length - 1).toDouble()
                                : 1,
                            divisions:
                                _images.length > 1 ? _images.length - 1 : 1,
                            onChanged: _images.isEmpty
                                ? null
                                : (value) => _goToPage(value.round()),
                          ),
                        ),
                        IconButton(
                          onPressed: _hasNextChapter ? _nextChapter : null,
                          icon: const Icon(Icons.chevron_right),
                          color: Colors.white,
                          tooltip: '下一章',
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _menuButton(Icons.list, '目录', _showChapterList),
                        _menuButton(_modeIcon, _modeLabel, _cycleReadMode),
                        _menuButton(Icons.tune, '设置', _showQuickSettings),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _menuButton(IconData icon, String label, VoidCallback action) {
    return TextButton.icon(
      onPressed: action,
      icon: Icon(icon, color: Colors.white),
      label: Text(label, style: const TextStyle(color: Colors.white)),
    );
  }

  IconData get _modeIcon {
    switch (_readMode) {
      case MangaReadMode.scroll:
        return Icons.view_stream;
      case MangaReadMode.horizontal:
        return Icons.swipe;
      case MangaReadMode.japanese:
        return Icons.keyboard_double_arrow_left;
    }
  }

  String get _modeLabel {
    switch (_readMode) {
      case MangaReadMode.scroll:
        return '连续';
      case MangaReadMode.horizontal:
        return '横向';
      case MangaReadMode.japanese:
        return '日漫';
    }
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
    SystemChrome.setEnabledSystemUIMode(
      _showMenu ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  bool get _hasPreviousChapter {
    final position = _chapters
        .indexWhere((chapter) => chapter.index == _currentChapterIndex);
    return position > 0;
  }

  bool get _hasNextChapter {
    final position = _chapters
        .indexWhere((chapter) => chapter.index == _currentChapterIndex);
    return position >= 0 && position < _chapters.length - 1;
  }

  void _previousChapter() {
    final position = _chapters
        .indexWhere((chapter) => chapter.index == _currentChapterIndex);
    if (position <= 0) return;
    _currentChapterIndex = _chapters[position - 1].index;
    _loadChapter();
  }

  void _nextChapter() {
    final position = _chapters
        .indexWhere((chapter) => chapter.index == _currentChapterIndex);
    if (position < 0 || position >= _chapters.length - 1) return;
    _currentChapterIndex = _chapters[position + 1].index;
    _loadChapter();
  }

  void _previousPage() {
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
    if (_currentPageIndex < _images.length - 1) {
      _pageController?.nextPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _nextChapter();
    }
  }

  void _goToPage(int page) {
    if (_images.isEmpty) return;
    final target = page.clamp(0, _images.length - 1);
    setState(() => _currentPageIndex = target);
    if (_readMode != MangaReadMode.scroll) {
      _pageController?.jumpToPage(target);
    }
  }

  void _cycleReadMode() {
    final next = (_readMode.index + 1) % MangaReadMode.values.length;
    _applyReadMode(MangaReadMode.values[next]);
  }

  void _applyReadMode(MangaReadMode mode) {
    setState(() {
      _readMode = mode;
      _showMenu = false;
      _resetControllers();
    });
    unawaited(_saveSettings());
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToCurrentPage());
  }

  void _showChapterList() {
    setState(() => _showMenu = false);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF181818),
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.72,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '目录',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              Expanded(
                child: ListView.builder(
                  itemCount: _chapters.length,
                  itemBuilder: (context, index) {
                    final chapter = _chapters[index];
                    final selected = chapter.index == _currentChapterIndex;
                    return ListTile(
                      selected: selected,
                      selectedTileColor: Colors.white10,
                      title: Text(
                        chapter.title,
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.white70,
                        ),
                      ),
                      trailing: selected
                          ? const Icon(Icons.check, color: Colors.white)
                          : null,
                      onTap: () {
                        Navigator.pop(context);
                        _currentChapterIndex = chapter.index;
                        _loadChapter();
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
  }

  void _showQuickSettings() {
    setState(() => _showMenu = false);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF181818),
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
                  const Text(
                    '漫画设置',
                    style: TextStyle(
                      color: Colors.white,
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
                        label: Text('连续'),
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
                    title: const Text('允许图片缩放',
                        style: TextStyle(color: Colors.white)),
                    onChanged: (value) => update(() => _disableScale = !value),
                  ),
                  SwitchListTile(
                    value: _hideChapterTitle,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('隐藏章节首尾提示',
                        style: TextStyle(color: Colors.white)),
                    onChanged: (value) =>
                        update(() => _hideChapterTitle = value),
                  ),
                  SwitchListTile(
                    value: _hideFooter,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('隐藏底部进度',
                        style: TextStyle(color: Colors.white)),
                    onChanged: (value) => update(() => _hideFooter = value),
                  ),
                  Row(
                    children: [
                      const Expanded(
                        child: Text('图片预加载',
                            style: TextStyle(color: Colors.white)),
                      ),
                      Text('$_preloadCount 张',
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                  Slider(
                    value: _preloadCount.toDouble(),
                    min: 0,
                    max: 30,
                    divisions: 30,
                    onChanged: (value) =>
                        update(() => _preloadCount = value.round()),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      setState(_resetControllers);
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToCurrentPage());
    });
  }
}
