import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/book.dart';
import '../../models/chapter.dart';
import '../../services/book_data_provider.dart';
import '../../services/local_book/local_book_service.dart';
import '../../services/local_book/txt_parser.dart';
import '../../services/storage_service.dart';
import '../../services/chapter_cache_service.dart';
import '../../services/reader_bookmark_service.dart';
import '../../routes/app_routes.dart';

class ChapterListPage extends StatefulWidget {
  final String bookUrl;
  final int currentChapterIndex;
  final Book? initialBook;

  const ChapterListPage({
    super.key,
    required this.bookUrl,
    this.currentChapterIndex = 0,
    this.initialBook,
  });

  @override
  State<ChapterListPage> createState() => _ChapterListPageState();
}

class _ChapterListPageState extends State<ChapterListPage> {
  Book? _book;
  List<Chapter> _chapters = [];
  List<Chapter> _filteredChapters = [];
  List<_VolumeGroup> _volumeGroups = [];
  bool _isLoading = true;
  String _searchQuery = '';
  bool _isChapterReversed = false;
  Set<int> _expandedVolumes = {};
  final ScrollController _scrollController = ScrollController();
  final PageController _pageController = PageController();
  BookDataProvider? _dataProvider;
  String? _loadError;
  Set<String> _cachedFiles = {};
  bool _showWordCount = false;
  bool _useReplace = false;
  bool _foldVolume = true;
  bool _showSearch = false;
  int _currentTab = 0;
  List<Bookmark> _bookmarks = [];
  bool _searchChapterName = true;
  bool _searchBookText = true;
  bool _searchNote = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _loadData();
    _loadBookmarks();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadBookmarks() async {
    final bookmarks = await ReaderBookmarkService().list(widget.bookUrl);
    if (mounted) setState(() => _bookmarks = bookmarks);
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _showWordCount = prefs.getBool('tocShowWordCount') ?? false;
      _useReplace = prefs.getBool('tocUseReplace') ?? false;
      _foldVolume = prefs.getBool('tocFoldVolume') ?? true;
      _isChapterReversed =
          prefs.getBool('tocReverse_${widget.bookUrl}') ?? false;
      if (_chapters.isNotEmpty) {
        _groupChaptersByVolume();
      }
    });
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _loadData() async {
    try {
      final bookData = StorageService.instance.getBook(widget.bookUrl);
      _book = bookData != null ? Book.fromJson(bookData) : widget.initialBook;
      if (_book == null) {
        throw StateError('书籍信息不存在');
      }
      _dataProvider = createBookDataProvider(_book!);
      _chapters = await _dataProvider!.getChapterList(_book!);
      _filteredChapters = _chapters;
      _groupChaptersByVolume();
      // 加载缓存信息
      if (_book!.originType == BookOriginType.online) {
        _cachedFiles = await ChapterCacheService.instance.getChapterCacheFiles(
          _book!,
        );
      }
      _loadError = null;
    } catch (e) {
      _loadError = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentChapter();
    });
  }

  void _groupChaptersByVolume() {
    _volumeGroups = [];
    _expandedVolumes = {};

    final volumePattern = RegExp(
      r'^第[零一二三四五六七八九十百千万\d]+卷|^卷[零一二三四五六七八九十百千万\d]+|^[Vv]olume\s+\d+',
      caseSensitive: false,
    );

    _VolumeGroup? currentGroup;
    for (final chapter in _chapters) {
      if (chapter.isVolume || volumePattern.hasMatch(chapter.title)) {
        currentGroup = _VolumeGroup(
          title: chapter.title,
          chapterIndex: chapter.index,
          chapters: [],
        );
        _volumeGroups.add(currentGroup);
      } else if (currentGroup != null) {
        currentGroup.chapters.add(chapter);
      } else {
        if (_volumeGroups.isEmpty) {
          currentGroup = _VolumeGroup(
            title: '正文',
            chapterIndex: -1,
            chapters: [],
          );
          _volumeGroups.add(currentGroup);
        }
        _volumeGroups.first.chapters.add(chapter);
      }
    }

    if (_volumeGroups.isEmpty) {
      _volumeGroups.add(
        _VolumeGroup(
          title: '全部章节',
          chapterIndex: -1,
          chapters: List.from(_chapters),
        ),
      );
    }

    if (_foldVolume) {
      final currentGroup = _volumeGroups.lastWhere(
        (group) => group.chapters.any(
          (chapter) => chapter.index == widget.currentChapterIndex,
        ),
        orElse: () => _volumeGroups.first,
      );
      _expandedVolumes.add(currentGroup.chapterIndex);
    } else {
      _expandedVolumes.addAll(_volumeGroups.map((group) => group.chapterIndex));
    }
  }

  void _scrollToCurrentChapter() {
    if (!_scrollController.hasClients) return;
    var targetIndex = _visibleChapterEntries.indexWhere(
      (ch) => ch.index == widget.currentChapterIndex,
    );
    if (targetIndex < 0) {
      final group = _volumeGroups.where(
        (item) => item.chapters.any(
          (chapter) => chapter.index == widget.currentChapterIndex,
        ),
      );
      if (group.isEmpty) return;
      setState(() => _expandedVolumes.add(group.first.chapterIndex));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scrollToCurrentChapter();
      });
      return;
    }

    final estimatedOffset = targetIndex * 49.0;
    _scrollController.animateTo(
      estimatedOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _filterChapters(String query) {
    setState(() {
      _searchQuery = query;
      if (query.isEmpty) {
        _filteredChapters = _chapters;
      } else {
        _filteredChapters = _chapters
            .where((c) => c.title.toLowerCase().contains(query.toLowerCase()))
            .toList();
      }
    });
  }

  void _openChapter(Chapter chapter) {
    if (chapter.isVolume) return;
    _doOpenChapter(chapter);
  }

  /// 参照 Legado 路由优先级：video → audio → comic → novel
  String _readerRouteName() {
    final mediaType = _book?.mediaType;
    if (mediaType == MediaType.video) return AppRoutes.videoPlayer;
    if (mediaType == MediaType.audio) return AppRoutes.audioPlayer;
    if (mediaType == MediaType.comic) return AppRoutes.comicReader;
    return AppRoutes.novelReader;
  }

  void _doOpenChapter(Chapter chapter) {
    Navigator.pushReplacementNamed(
      context,
      _readerRouteName(),
      arguments: {
        'bookUrl': widget.bookUrl,
        'bookId': widget.bookUrl,
        'chapterIndex': chapter.index,
        'trackId': chapter.index.toString(),
        'episodeId': chapter.index.toString(),
        'resumeProgress': false,
        'bookData': _book,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    if (!_isLoading && _loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('目录')),
        body: Center(child: Text('目录加载失败\n$_loadError')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: _showSearch
            ? Row(
                children: [
                  Expanded(
                    child: TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: '搜索...',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: fg.withValues(alpha: 0.3),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: fg.withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                      onChanged: _filterChapters,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: fg),
                    onPressed: () {
                      _filterChapters('');
                      setState(() => _showSearch = false);
                    },
                  ),
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildTab(0, '目录', fg),
                  const SizedBox(width: 24),
                  _buildTab(1, '书签', fg),
                ],
              ),
        actions: _showSearch
            ? null
            : [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.search, size: 22),
                      tooltip: '搜索',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                      onPressed: () => setState(() => _showSearch = true),
                    ),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert, size: 22),
                      tooltip: '更多',
                      offset: const Offset(0, 48),
                      padding: EdgeInsets.zero,
                      onSelected: _handleMenuAction,
                      itemBuilder: (context) => _currentTab == 0
                          ? [
                              _menuItem(
                                'reverse',
                                '反转目录',
                                _isChapterReversed,
                                fg,
                              ),
                              _menuItem('use_replace', '使用替换', _useReplace, fg),
                              _menuItem(
                                'word_count',
                                '加载字数',
                                _showWordCount,
                                fg,
                              ),
                              _menuItem('fold_volume', '卷名折叠', _foldVolume, fg),
                              const PopupMenuItem(
                                value: 'regex_config',
                                padding: EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                child: Text('正则配置'),
                              ),
                            ]
                          : [
                              const PopupMenuItem(
                                value: 'export',
                                padding: EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                child: Text('导出'),
                              ),
                              const PopupMenuItem(
                                value: 'export_md',
                                padding: EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                child: Text('导出(MD)'),
                              ),
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
                              _menuItem(
                                'bm_search_note',
                                '搜索备注',
                                _searchNote,
                                fg,
                              ),
                            ],
                    ),
                  ],
                ),
              ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(fg),
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

  void _handleMenuAction(String action) {
    switch (action) {
      case 'reverse':
        setState(() => _isChapterReversed = !_isChapterReversed);
        _saveBool('tocReverse_${widget.bookUrl}', _isChapterReversed);
        break;
      case 'use_replace':
        setState(() => _useReplace = !_useReplace);
        _saveBool('tocUseReplace', _useReplace);
        break;
      case 'word_count':
        setState(() => _showWordCount = !_showWordCount);
        _saveBool('tocShowWordCount', _showWordCount);
        break;
      case 'fold_volume':
        setState(() {
          _foldVolume = !_foldVolume;
          _groupChaptersByVolume();
        });
        _saveBool('tocFoldVolume', _foldVolume);
        break;
      case 'regex_config':
        _showRegexConfig();
        break;
      case 'bm_search_chapter':
        setState(() => _searchChapterName = !_searchChapterName);
        break;
      case 'bm_search_text':
        setState(() => _searchBookText = !_searchBookText);
        break;
      case 'bm_search_note':
        setState(() => _searchNote = !_searchNote);
        break;
      case 'export':
        _exportBookmarks();
        break;
      case 'export_md':
        _exportBookmarksMarkdown();
        break;
    }
  }

  Future<void> _exportBookmarks() async {
    final data = const JsonEncoder.withIndent(
      '  ',
    ).convert(_bookmarks.map((bookmark) => bookmark.toJson()).toList());
    await _shareBookmarkFile(
      fileName: 'bookmark-${_safeFileName(_book?.displayName ?? "book")}.json',
      content: data,
      text: '导出书签',
    );
  }

  Future<void> _exportBookmarksMarkdown() async {
    final buffer = StringBuffer()
      ..writeln('## ${_book?.displayName ?? ""} ${_book?.displayAuthor ?? ""}')
      ..writeln();
    for (final bookmark in _bookmarks) {
      buffer
        ..writeln('#### ${bookmark.chapterTitle}')
        ..writeln()
        ..writeln(bookmark.content)
        ..writeln();
      if (bookmark.note?.isNotEmpty == true) {
        buffer
          ..writeln('> ${bookmark.note}')
          ..writeln();
      }
    }
    await _shareBookmarkFile(
      fileName: 'bookmark-${_safeFileName(_book?.displayName ?? "book")}.md',
      content: buffer.toString(),
      text: '导出书签 Markdown',
    );
  }

  Future<void> _shareBookmarkFile({
    required String fileName,
    required String content,
    required String text,
  }) async {
    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}${Platform.pathSeparator}$fileName');
      await file.writeAsString(content);
      await Share.shareXFiles([XFile(file.path)], text: text);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败：$error')));
    }
  }

  String _safeFileName(String value) {
    return value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  void _showRegexConfig() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return _RegexConfigSheet(
          bookUrl: widget.bookUrl,
          onReparse: _reparseWithNewRules,
        );
      },
    );
  }

  Future<void> _reparseWithNewRules() async {
    LocalBookService.instance.clearCache(bookUrl: widget.bookUrl);
    setState(() {
      _isLoading = true;
    });
    await _loadData();
  }

  Widget _buildBody(Color fg) {
    return PageView(
      controller: _pageController,
      onPageChanged: (index) => setState(() => _currentTab = index),
      children: [_buildChapterPage(), _buildBookmarkList(fg)],
    );
  }

  Widget _buildChapterPage() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(child: _buildChapterContent()),
        Material(
          color: scheme.surface,
          elevation: 5,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 36,
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _scrollToCurrentChapter,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _currentChapterInfo,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _scrollToTop,
                    icon: const Icon(Icons.arrow_drop_up),
                    tooltip: '置顶',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                  ),
                  IconButton(
                    onPressed: _scrollToBottom,
                    icon: const Icon(Icons.arrow_drop_down),
                    tooltip: '置底',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
              ),
            ),
          ),
        ),
      ],
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
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterContent() {
    final entries = _visibleChapterEntries;
    if (entries.isEmpty) {
      return Center(
        child: Text(
          _searchQuery.isEmpty ? '目录列表为空' : '没有匹配的章节',
          style: TextStyle(
            color: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      );
    }
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: ListView.separated(
        controller: _scrollController,
        padding: EdgeInsets.zero,
        itemCount: entries.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          thickness: 0.5,
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.65),
        ),
        itemBuilder: (context, index) => _buildChapterItem(entries[index]),
      ),
    );
  }

  List<Chapter> get _visibleChapterEntries {
    if (_searchQuery.isNotEmpty) {
      final matches = _filteredChapters.where((chapter) => !chapter.isVolume);
      return _isChapterReversed
          ? matches.toList().reversed.toList()
          : matches.toList();
    }

    final entries = <Chapter>[];
    final groups = _isChapterReversed ? _volumeGroups.reversed : _volumeGroups;
    for (final group in groups) {
      final volume = _chapters.where(
        (chapter) => chapter.index == group.chapterIndex && chapter.isVolume,
      );
      entries.addAll(volume);

      final expanded = _expandedVolumes.contains(group.chapterIndex);
      if (expanded || volume.isEmpty) {
        entries.addAll(
          _isChapterReversed ? group.chapters.reversed : group.chapters,
        );
      }
    }
    return entries;
  }

  String get _currentChapterInfo {
    final current = _chapters.where(
      (chapter) => chapter.index == widget.currentChapterIndex,
    );
    final title = current.isNotEmpty
        ? current.first.title
        : (_book?.durChapterTitle.isNotEmpty == true
              ? _book!.durChapterTitle
              : '未开始阅读');
    final total = _chapters.where((chapter) => !chapter.isVolume).length;
    if (total == 0) return title;
    final position =
        _chapters
            .where((chapter) => !chapter.isVolume)
            .toList()
            .indexWhere(
              (chapter) => chapter.index == widget.currentChapterIndex,
            ) +
        1;
    return '$title(${position > 0 ? position : 1}/$total)';
  }

  void _scrollToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
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
      if (_searchNote && (b.note?.toLowerCase().contains(query) ?? false))
        hit = true;
      return hit;
    }).toList();
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
    return Scrollbar(
      thumbVisibility: true,
      child: ListView.separated(
        itemCount: list.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          thickness: 0.5,
          color: Theme.of(
            context,
          ).colorScheme.outlineVariant.withValues(alpha: 0.65),
        ),
        itemBuilder: (context, index) {
          final bookmark = list[index];
          return InkWell(
            onTap: () => _doOpenChapterAtIndex(bookmark.chapterIndex),
            onLongPress: () => _deleteBookmark(bookmark),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(
                      bookmark.chapterTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: fg),
                    ),
                  ),
                  if (bookmark.content.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(
                        bookmark.content,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.68),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  if (bookmark.note?.isNotEmpty == true)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(
                        bookmark.note!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.68),
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _doOpenChapterAtIndex(int chapterIndex) {
    Navigator.pushReplacementNamed(
      context,
      _readerRouteName(),
      arguments: {
        'bookUrl': widget.bookUrl,
        'bookId': widget.bookUrl,
        'chapterIndex': chapterIndex,
        'trackId': chapterIndex.toString(),
        'episodeId': chapterIndex.toString(),
        'resumeProgress': false,
        'bookData': _book,
      },
    );
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
                bookUrl: widget.bookUrl,
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

  Widget _buildChapterItem(Chapter chapter) {
    final scheme = Theme.of(context).colorScheme;
    final isOnline = _book?.originType == BookOriginType.online;
    final isCurrent = chapter.index == widget.currentChapterIndex;
    final isCurrentVolume =
        chapter.isVolume &&
        _isChapterInsideVolume(widget.currentChapterIndex, chapter.index);
    final isExpanded = _expandedVolumes.contains(chapter.index);
    final fileName = ChapterCacheService.instance.getChapterFileName(
      chapter,
      suffix: 'cb',
    );
    final isCached =
        !isOnline || chapter.isVolume || _cachedFiles.contains(fileName);
    final hasTag = chapter.tag != null && chapter.tag!.isNotEmpty;
    final hasWordCount =
        _showWordCount && chapter.wordCount != null && chapter.wordCount! > 0;
    final showSubtitle = hasTag || hasWordCount;
    final titleColor = isCurrent || isCurrentVolume
        ? scheme.primary
        : scheme.onSurface;

    return Material(
      color: isCurrentVolume
          ? scheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: () {
          if (!chapter.isVolume) {
            _openChapter(chapter);
            return;
          }
          setState(() {
            if (isExpanded) {
              _expandedVolumes.remove(chapter.index);
            } else {
              _expandedVolumes.add(chapter.index);
            }
          });
        },
        onLongPress: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(chapter.title),
              duration: const Duration(seconds: 1),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              if (chapter.isVolume)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: AnimatedRotation(
                    duration: const Duration(milliseconds: 180),
                    turns: isExpanded ? 0.25 : 0,
                    child: Icon(Icons.arrow_right, size: 20, color: titleColor),
                  ),
                ),
              if (chapter.isVip && !chapter.isPay)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    Icons.lock_outline,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chapter.title,
                      style: TextStyle(color: titleColor, fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (showSubtitle && !chapter.isVolume)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            if (hasTag)
                              Flexible(
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 18),
                                  child: Text(
                                    chapter.tag!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: scheme.onSurfaceVariant,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                            if (hasWordCount)
                              Text(
                                '${chapter.wordCount}字',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
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
              SizedBox(
                width: 24,
                height: 24,
                child: isCurrent
                    ? Icon(Icons.check, size: 18, color: scheme.primary)
                    : !isCached
                    ? Icon(
                        Icons.cloud_outlined,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isChapterInsideVolume(int chapterIndex, int volumeIndex) {
    var activeVolume = -1;
    for (final chapter in _chapters) {
      if (chapter.isVolume) activeVolume = chapter.index;
      if (chapter.index == chapterIndex) {
        return activeVolume == volumeIndex;
      }
    }
    return false;
  }
}

class _VolumeGroup {
  final String title;
  final int chapterIndex;
  final List<Chapter> chapters;

  _VolumeGroup({
    required this.title,
    required this.chapterIndex,
    required this.chapters,
  });
}

// ===== Regex Configuration Sheet =====

class _RegexConfigSheet extends StatefulWidget {
  final String bookUrl;
  final VoidCallback onReparse;

  const _RegexConfigSheet({required this.bookUrl, required this.onReparse});

  @override
  State<_RegexConfigSheet> createState() => _RegexConfigSheetState();
}

class _RegexConfigSheetState extends State<_RegexConfigSheet> {
  List<TxtTocRule> _presetRules = [];
  List<TxtTocRule> _customRules = [];
  String _newRuleName = '';
  String _newRulePattern = '';
  String? _editError;

  @override
  void initState() {
    super.initState();
    _presetRules = TxtParser.defaultTocRules;
    _customRules = TxtParser.loadCustomRules();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text('目录正则配置', style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _buildSectionTitle('预设规则'),
                  ..._presetRules.map(
                    (rule) => _buildRuleTile(rule, isPreset: true),
                  ),
                  const Divider(),
                  _buildSectionTitle('自定义规则'),
                  ..._customRules.map(
                    (rule) => _buildRuleTile(rule, isPreset: false),
                  ),
                  _buildAddRuleForm(),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 14,
          color: Colors.grey[700],
        ),
      ),
    );
  }

  Widget _buildRuleTile(TxtTocRule rule, {required bool isPreset}) {
    return ListTile(
      dense: true,
      title: Text(rule.name),
      subtitle: Text(
        rule.rule,
        style: TextStyle(
          fontSize: 12,
          color: Colors.grey[600],
          fontFamily: 'monospace',
        ),
      ),
      trailing: isPreset
          ? null
          : IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () async {
                _customRules.remove(rule);
                await TxtParser.saveCustomRules(_customRules);
                setState(() {});
              },
            ),
    );
  }

  Widget _buildAddRuleForm() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '添加自定义规则',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Colors.grey[700],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(
              labelText: '规则名称',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => _newRuleName = v,
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: InputDecoration(
              labelText: '正则表达式',
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: _editError,
            ),
            onChanged: (v) {
              _newRulePattern = v;
              final isValid = TxtParser.validateRule(v);
              if (isValid) {
                setState(() {
                  _editError = null;
                });
              }
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              ElevatedButton(
                onPressed: _addCustomRule,
                child: const Text('添加'),
              ),
              const SizedBox(width: 8),
              if (_newRulePattern.isNotEmpty)
                TextButton(
                  onPressed: () {
                    final matches = TxtParser.testRule(
                      'sample text',
                      _newRulePattern,
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('测试匹配: ${matches.length} 行'),
                        duration: const Duration(seconds: 1),
                      ),
                    );
                  },
                  child: const Text('测试'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _addCustomRule() {
    if (_newRuleName.isEmpty || _newRulePattern.isEmpty) return;
    final isValid = TxtParser.validateRule(_newRulePattern);
    if (!isValid) {
      setState(() {
        _editError = '无效的正则表达式';
      });
      return;
    }
    final newRule = TxtTocRule(
      name: _newRuleName,
      rule: _newRulePattern,
      serialNumber: _customRules.length + 100,
    );
    _customRules.add(newRule);
    TxtParser.saveCustomRules(_customRules);
    setState(() {
      _newRuleName = '';
      _newRulePattern = '';
      _editError = null;
    });
    widget.onReparse();
  }
}
