import 'package:flutter/material.dart';
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
  int _totalWordCount = 0;
  final ScrollController _scrollController = ScrollController();
  bool _confirmChapterJump = false;
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

  Future<void> _loadBookmarks() async {
    final bookmarks = await ReaderBookmarkService().list(widget.bookUrl);
    if (mounted) setState(() => _bookmarks = bookmarks);
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
      _totalWordCount =
          _chapters.fold<int>(0, (sum, ch) => sum + (ch.wordCount ?? 0));
      _groupChaptersByVolume();
      // 加载缓存信息
      if (_book!.originType == BookOriginType.online) {
        _cachedFiles = await ChapterCacheService.instance.getChapterCacheFiles(_book!);
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
        _expandedVolumes.add(_volumeGroups.length - 1);
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
          _expandedVolumes.add(0);
        }
        _volumeGroups.first.chapters.add(chapter);
      }
    }

    if (_volumeGroups.isEmpty) {
      _volumeGroups.add(_VolumeGroup(
        title: '全部章节',
        chapterIndex: -1,
        chapters: List.from(_chapters),
      ));
      _expandedVolumes.add(0);
    }
  }

  void _scrollToCurrentChapter() {
    if (!_scrollController.hasClients) return;
    if (widget.currentChapterIndex <= 0) return;

    // 找到当前章节在_filteredChapters中的位置
    final targetIndex = _filteredChapters
        .indexWhere((ch) => ch.index == widget.currentChapterIndex);
    if (targetIndex < 0) return;

    // 估算位置 - 每个item大约56高度
    final estimatedOffset = targetIndex * 56.0;
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
    if (!_confirmChapterJump &&
        (chapter.index - widget.currentChapterIndex).abs() > 3) {
      // 跨章节跳转超过3章，显示确认
      _showChapterJumpConfirm(chapter);
    } else {
      _doOpenChapter(chapter);
    }
  }

  void _doOpenChapter(Chapter chapter) {
    final routeName = _book?.mediaType == MediaType.comic
        ? AppRoutes.comicReader
        : AppRoutes.novelReader;
    Navigator.pushReplacementNamed(
      context,
      routeName,
      arguments: {
        'bookUrl': widget.bookUrl,
        'chapterIndex': chapter.index,
        'initialBook': _book,
      },
    );
  }

  void _showChapterJumpConfirm(Chapter chapter) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('章节跳转确认'),
        content: Text('确定要跳转到 "${chapter.title}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _confirmChapterJump = true;
              _doOpenChapter(chapter);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    final isOnline = _book?.originType == BookOriginType.online;
    if (!_isLoading && _loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('目录')),
        body: Center(child: Text('目录加载失败\n$_loadError')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: _showSearch
            ? Row(
                children: [
                  Expanded(
                    child: TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: '搜索...',
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
                      onChanged: _filterChapters,
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
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
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
                              _menuItem('reverse', '反转目录', _isChapterReversed, fg),
                              _menuItem('use_replace', '使用替换', _useReplace, fg),
                              _menuItem('word_count', '加载字数', _showWordCount, fg),
                              _menuItem('fold_volume', '卷名折叠', _foldVolume, fg),
                              const PopupMenuItem(
                                value: 'regex_config',
                                child: Text('正则配置'),
                              ),
                            ]
                          : [
                              const PopupMenuItem(
                                value: 'export',
                                child: Text('导出'),
                              ),
                              const PopupMenuItem(
                                value: 'export_md',
                                child: Text('导出(MD)'),
                              ),
                              _menuItem('bm_search_chapter', '搜索章节名', _searchChapterName, fg),
                              _menuItem('bm_search_text', '搜索书文', _searchBookText, fg),
                              _menuItem('bm_search_note', '搜索备注', _searchNote, fg),
                            ],
                    ),
                  ],
                ),
              ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(fg, isOnline),
    );
  }

  PopupMenuItem<String> _menuItem(String value, String label, bool checked, Color fg) {
    return PopupMenuItem(
      value: value,
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
        setState(() => _foldVolume = !_foldVolume);
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

  void _exportBookmarks() {
    // TODO: 导出书签
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('导出书签功能开发中')),
    );
  }

  void _exportBookmarksMarkdown() {
    // TODO: 导出书签为Markdown
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('导出书签(MD)功能开发中')),
    );
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

  Widget _buildBody(Color fg, bool isOnline) {
    return PageView(
      onPageChanged: (index) => setState(() => _currentTab = index),
      children: [
        _buildChapterContent(isOnline),
        _buildBookmarkList(fg),
      ],
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

  Widget _buildChapterContent(bool isOnline) {
    if (_searchQuery.isNotEmpty) {
      final chapters = _isChapterReversed
          ? _filteredChapters.reversed.toList()
          : _filteredChapters;
      return Scrollbar(
        thumbVisibility: true,
        child: ListView.builder(
          itemCount: chapters.length,
          itemBuilder: (context, index) =>
              _buildChapterItem(chapters[index]),
        ),
      );
    }
    return _volumeGroups.length <= 1 ? _buildFlatList() : _buildVolumeList();
  }

  List<Bookmark> get _filteredBookmarks {
    if (_searchQuery.isEmpty) return _bookmarks;
    final query = _searchQuery.toLowerCase();
    return _bookmarks.where((b) {
      bool hit = false;
      if (_searchChapterName && b.chapterTitle.toLowerCase().contains(query)) hit = true;
      if (_searchBookText && b.content.toLowerCase().contains(query)) hit = true;
      if (_searchNote && (b.note?.toLowerCase().contains(query) ?? false)) hit = true;
      return hit;
    }).toList();
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
              _doOpenChapterAtIndex(bookmark.chapterIndex);
            },
            onLongPress: () => _deleteBookmark(bookmark),
          );
        },
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.month}/${time.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  void _doOpenChapterAtIndex(int chapterIndex) {
    final routeName = _book?.mediaType == MediaType.comic
        ? AppRoutes.comicReader
        : AppRoutes.novelReader;
    Navigator.pushReplacementNamed(
      context,
      routeName,
      arguments: {
        'bookUrl': widget.bookUrl,
        'chapterIndex': chapterIndex,
        'initialBook': _book,
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
              await ReaderBookmarkService().remove(bookUrl: widget.bookUrl, bookmarkId: bookmark.id);
              _loadBookmarks();
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Widget _buildFlatList() {
    final chapters =
        _isChapterReversed ? _chapters.reversed.toList() : _chapters;
    return Scrollbar(
      thumbVisibility: true,
      child: ListView.builder(
        itemCount: chapters.length,
        itemBuilder: (context, index) => _buildChapterItem(chapters[index]),
      ),
    );
  }

  Widget _buildVolumeList() {
    final groups =
        _isChapterReversed ? _volumeGroups.reversed.toList() : _volumeGroups;
    return Scrollbar(
      thumbVisibility: true,
      child: ListView.builder(
        itemCount: groups.length,
        itemBuilder: (context, index) {
          final group =
              groups[_isChapterReversed ? groups.length - 1 - index : index];
          final isExpanded = _expandedVolumes.contains(index);
          return _buildVolumeGroup(group, index, isExpanded);
        },
      ),
    );
  }

  Widget _buildVolumeGroup(_VolumeGroup group, int index, bool isExpanded) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              if (isExpanded) {
                _expandedVolumes.remove(index);
              } else {
                _expandedVolumes.add(index);
              }
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                AnimatedRotation(
                  duration: const Duration(milliseconds: 200),
                  turns: isExpanded ? 0.25 : 0,
                  child: Icon(Icons.chevron_right,
                      color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(width: 8),
                Text(
                  group.title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '(${group.chapters.length})',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ),
        if (isExpanded)
          ...group.chapters.map((chapter) => _buildChapterItem(chapter)),
      ],
    );
  }

  Widget _buildChapterItem(Chapter chapter) {
    final fg = Theme.of(context).colorScheme.onSurface;
    final isOnline = _book?.originType == BookOriginType.online;
    final isCurrent = chapter.index == widget.currentChapterIndex;
    final fileName = ChapterCacheService.instance.getChapterFileName(chapter, suffix: 'cb');
    final isCached = !isOnline || _cachedFiles.contains(fileName);
    final hasTag = chapter.tag != null && chapter.tag!.isNotEmpty;
    final hasWordCount = _showWordCount && chapter.wordCount != null && chapter.wordCount! > 0;
    final showSubtitle = hasTag || hasWordCount;

    return InkWell(
      onTap: () => _openChapter(chapter),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // VIP锁定图标
            if (chapter.isVip && !chapter.isPay)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.lock_outline, size: 18, color: fg.withValues(alpha: 0.6)),
              ),
            // 章节信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 章节名称
                  Text(
                    chapter.title,
                    style: TextStyle(
                      color: isCurrent ? fg : fg.withValues(alpha: 0.85),
                      fontWeight: isCurrent ? FontWeight.bold : null,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // 副标题（tag、字数）
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
            // 右侧图标
            if (isCurrent)
              Icon(Icons.check, size: 18, color: fg)
            else if (!isCached)
              Icon(Icons.cloud_outlined, size: 18, color: fg.withValues(alpha: 0.4)),
          ],
        ),
      ),
    );
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
                      child: const Text('完成')),
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
                  ..._presetRules
                      .map((rule) => _buildRuleTile(rule, isPreset: true)),
                  const Divider(),
                  _buildSectionTitle('自定义规则'),
                  ..._customRules
                      .map((rule) => _buildRuleTile(rule, isPreset: false)),
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
      child: Text(title,
          style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Colors.grey[700])),
    );
  }

  Widget _buildRuleTile(TxtTocRule rule, {required bool isPreset}) {
    return ListTile(
      dense: true,
      title: Text(rule.name),
      subtitle: Text(rule.rule,
          style: TextStyle(
              fontSize: 12, color: Colors.grey[600], fontFamily: 'monospace')),
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
          Text('添加自定义规则',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.grey[700])),
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
                    final matches =
                        TxtParser.testRule('sample text', _newRulePattern);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text('测试匹配: ${matches.length} 行'),
                          duration: const Duration(seconds: 1)),
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
