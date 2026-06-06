import 'package:flutter/material.dart';
import '../../models/book.dart';
import '../../models/chapter.dart';
import '../../services/book_data_provider.dart';
import '../../services/local_book/local_book_service.dart';
import '../../services/local_book/txt_parser.dart';
import '../../services/storage_service.dart';
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

  @override
  void initState() {
    super.initState();
    _loadData();
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
    Navigator.pushReplacementNamed(
      context,
      AppRoutes.novelReader,
      arguments: {
        'bookUrl': widget.bookUrl,
        'chapterIndex': chapter.index,
        'bookData': _book,
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

  void _toggleWordCount() {
    if (_book == null) return;
    final newValue = !_book!.showWordCount;
    final updatedBook = _book!.copyWith(showWordCount: newValue);
    StorageService.instance.saveBook(updatedBook);
    setState(() {
      _book = updatedBook;
    });
  }

  @override
  Widget build(BuildContext context) {
    final showWordCount = _book?.showWordCount ?? true;
    if (!_isLoading && _loadError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('目录')),
        body: Center(child: Text('目录加载失败\n$_loadError')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
            '目录 (${_chapters.length})${showWordCount && _totalWordCount > 0 ? ' · ${LocalBookService.formatWordCount(_totalWordCount)}字' : ''}'),
        actions: [
          IconButton(
            icon: Icon(showWordCount ? Icons.numbers : Icons.numbers_outlined),
            tooltip: showWordCount ? '隐藏字数' : '显示字数',
            onPressed: _toggleWordCount,
          ),
          IconButton(
            icon: const Icon(Icons.sort),
            tooltip: '排序',
            onPressed: () {
              setState(() {
                _isChapterReversed = !_isChapterReversed;
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '正则配置',
            onPressed: _showRegexConfig,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_searchQuery.isNotEmpty) {
      final chapters = _isChapterReversed
          ? _filteredChapters.reversed.toList()
          : _filteredChapters;
      return Column(
        children: [
          _buildSearchBar(),
          Expanded(
            child: ListView.builder(
              itemCount: chapters.length,
              itemBuilder: (context, index) =>
                  _buildChapterItem(chapters[index]),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        _buildSearchBar(),
        Expanded(
          child:
              _volumeGroups.length <= 1 ? _buildFlatList() : _buildVolumeList(),
        ),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        decoration: InputDecoration(
          hintText: '搜索章节...',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 20),
                  onPressed: () => _filterChapters(''),
                )
              : null,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
        onChanged: _filterChapters,
      ),
    );
  }

  Widget _buildFlatList() {
    final chapters =
        _isChapterReversed ? _chapters.reversed.toList() : _chapters;
    return ListView.builder(
      itemCount: chapters.length,
      itemBuilder: (context, index) => _buildChapterItem(chapters[index]),
    );
  }

  Widget _buildVolumeList() {
    final groups =
        _isChapterReversed ? _volumeGroups.reversed.toList() : _volumeGroups;
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group =
            groups[_isChapterReversed ? groups.length - 1 - index : index];
        final isExpanded = _expandedVolumes.contains(index);
        return _buildVolumeGroup(group, index, isExpanded);
      },
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
    final isCurrent = chapter.index == widget.currentChapterIndex;
    final showWordCount = _book?.showWordCount ?? true;
    final wordCountText =
        showWordCount && chapter.wordCount != null && chapter.wordCount! > 0
            ? LocalBookService.formatWordCount(chapter.wordCount!)
            : null;
    return ListTile(
      dense: true,
      title: Row(
        children: [
          Expanded(
            child: Text(
              chapter.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isCurrent ? Theme.of(context).colorScheme.primary : null,
                fontWeight: isCurrent ? FontWeight.bold : null,
              ),
            ),
          ),
          if (wordCountText != null) ...[
            const SizedBox(width: 8),
            Text(
              wordCountText,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
      trailing: isCurrent
          ? Icon(Icons.play_arrow,
              size: 16, color: Theme.of(context).colorScheme.primary)
          : null,
      selected: isCurrent,
      selectedTileColor:
          Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.15),
      onTap: () => _openChapter(chapter),
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
