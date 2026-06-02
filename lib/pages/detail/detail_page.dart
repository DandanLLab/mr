import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';
import '../../models/book.dart';
import '../../models/chapter.dart';
import '../../providers/bookshelf_provider.dart';
import '../../routes/app_routes.dart';
import '../../services/storage_service.dart';
import '../../services/local_book/local_book_service.dart';
import '../../widgets/book_edit_sheet.dart';

class DetailPage extends StatefulWidget {
  final String bookUrl;

  const DetailPage({super.key, required this.bookUrl});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  bool _isInBookshelf = false;
  bool _isLoading = true;
  Book? _book;
  List<Chapter> _chapters = [];
  bool _isDescExpanded = false;
  bool _isChapterReversed = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final bookData = StorageService.instance.getBook(widget.bookUrl);
    Book? book;
    if (bookData != null) {
      book = Book.fromJson(bookData);
    }

    List<Chapter> chapters = [];
    if (book != null) {
      chapters = await LocalBookService.instance.getChapterList(book);
    }

    final isInShelf = bookData != null;

    setState(() {
      _book = book;
      _chapters = chapters;
      _isInBookshelf = isInShelf;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_book == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('书籍信息未找到')),
      );
    }

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          _buildAppBar(),
          SliverToBoxAdapter(
            child: _buildHeader(),
          ),
          SliverToBoxAdapter(
            child: _buildActionButtons(),
          ),
          SliverToBoxAdapter(
            child: _buildDescription(),
          ),
          SliverToBoxAdapter(
            child: _buildTags(),
          ),
          SliverToBoxAdapter(
            child: _buildChapterHeader(),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final displayChapters = _isChapterReversed
                    ? _chapters.reversed.toList()
                    : _chapters;
                final lastThree = displayChapters.length > 3
                    ? displayChapters.sublist(displayChapters.length - 3)
                    : displayChapters;
                if (index == lastThree.length) {
                  return ListTile(
                    leading: const Icon(Icons.list),
                    title: const Text('查看完整目录'),
                    onTap: () => _openFullChapterList(),
                  );
                }
                return _buildChapterItem(lastThree[index]);
              },
              childCount: (_isChapterReversed
                      ? _chapters.reversed.toList()
                      : _chapters).length > 3
                  ? 4
                  : (_isChapterReversed
                      ? _chapters.reversed.toList()
                      : _chapters).length + 1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 200,
      pinned: true,
      actions: [
        PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'edit') _showBookEditSheet();
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'edit', child: Text('编辑信息')),
          ],
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Theme.of(context).colorScheme.primary.withOpacity(0.7),
                Theme.of(context).colorScheme.primary,
              ],
            ),
          ),
          child: Center(
            child: Icon(
              Icons.book,
              size: 80,
              color: Theme.of(context).colorScheme.onPrimary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 100,
              height: 140,
              color: Theme.of(context).colorScheme.surfaceVariant,
              child: _book!.displayCoverUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: _book!.displayCoverUrl,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => const Icon(Icons.book, size: 48),
                    )
                  : const Icon(Icons.book, size: 48),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _book!.displayName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  _book!.displayAuthor,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _book!.status ?? (_book!.originType == BookOriginType.local ? '本地' : '未知'),
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_book!.sourceName != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _book!.sourceName!,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_book!.lastCheckTime != null)
                  Text(
                    '最后更新: ${_formatDate(_book!.lastCheckTime)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                Text(
                  '共 ${_book!.totalChapterNum ?? _chapters.length} 章',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _toggleBookshelf,
              icon: Icon(_isInBookshelf ? Icons.bookmark : Icons.bookmark_border),
              label: Text(_isInBookshelf ? '已在书架' : '加入书架'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: _startReading,
              icon: const Icon(Icons.play_arrow),
              label: const Text('立即阅读'),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed: _showCacheManager,
            icon: const Icon(Icons.download),
            tooltip: '缓存管理',
          ),
          IconButton(
            onPressed: _refreshData,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新数据',
          ),
        ],
      ),
    );
  }

  bool _isHtmlContent(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith('<') && (trimmed.contains('</') || trimmed.contains('/>'));
  }

  bool _isMarkdownContent(String text) {
    int count = 0;
    if (RegExp(r'^#{1,6}\s', multiLine: true).hasMatch(text)) count++;
    if (RegExp(r'\*\*[^*]+\*\*').hasMatch(text)) count++;
    if (RegExp(r'(?<!\*)\*[^*]+\*(?!\*)').hasMatch(text)) count++;
    if (RegExp(r'^\s*[-*+]\s', multiLine: true).hasMatch(text)) count++;
    if (RegExp(r'\[.*?\]\(.*?\)').hasMatch(text)) count++;
    if (RegExp(r'```').hasMatch(text)) count++;
    if (RegExp(r'^>', multiLine: true).hasMatch(text)) count++;
    return count >= 2;
  }

  Widget _buildCollapsedIntro(String text) {
    if (_isHtmlContent(text)) {
      return Html(
        data: text,
        style: {
          'body': Style(
            maxLines: 3,
            textOverflow: TextOverflow.ellipsis,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        },
      );
    } else if (_isMarkdownContent(text)) {
      return MarkdownBody(
        data: text,
        selectable: true,
      );
    } else {
      return Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
  }

  Widget _buildFullIntro(String text) {
    if (_isHtmlContent(text)) {
      return Html(
        data: text,
        style: {
          'body': Style(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        },
      );
    } else if (_isMarkdownContent(text)) {
      return MarkdownBody(
        data: text,
        selectable: true,
      );
    } else {
      return Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
  }

  Widget _buildDescription() {
    final intro = _book!.displayIntro;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '简介',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () {
              setState(() {
                _isDescExpanded = !_isDescExpanded;
              });
            },
            child: intro.isNotEmpty
                ? (_isDescExpanded
                    ? _buildFullIntro(intro)
                    : _buildCollapsedIntro(intro))
                : Text(
                    '暂无简介',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                setState(() {
                  _isDescExpanded = !_isDescExpanded;
                });
              },
              child: Text(_isDescExpanded ? '收起' : '展开'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTags() {
    if (_book!.tags == null || _book!.tags!.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _book!.tags!.map((tag) {
          return Chip(
            label: Text(tag),
            backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildChapterHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '目录 (${_chapters.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          TextButton.icon(
            onPressed: () {
              setState(() {
                _isChapterReversed = !_isChapterReversed;
              });
            },
            icon: Icon(_isChapterReversed ? Icons.arrow_upward : Icons.arrow_downward),
            label: Text(_isChapterReversed ? '正序' : '倒序'),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterItem(Chapter chapter) {
    return ListTile(
      leading: chapter.isVip
          ? Icon(Icons.lock, color: Theme.of(context).colorScheme.primary)
          : null,
      title: Text(chapter.title),
      trailing: chapter.isCached
          ? Icon(
              Icons.download_done,
              color: Theme.of(context).colorScheme.primary,
            )
          : null,
      onTap: () => _openChapter(chapter),
      onLongPress: () => _openFullChapterList(),
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '未知';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  void _toggleBookshelf() {
    if (_book == null) return;
    final provider = context.read<BookshelfProvider>();
    if (_isInBookshelf) {
      provider.removeFromBookshelf(_book!.bookUrl);
    } else {
      provider.addToBookshelf(_book!);
    }
    setState(() {
      _isInBookshelf = !_isInBookshelf;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_isInBookshelf ? '已加入书架' : '已从书架移除'),
      ),
    );
  }

  void _startReading() {
    Navigator.pushNamed(
      context,
      AppRoutes.novelReader,
      arguments: {
        'bookUrl': widget.bookUrl,
        'chapterIndex': _book?.durChapterIndex ?? 0,
      },
    );
  }

  void _showCacheManager() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '缓存管理',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                        },
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.download),
                          label: const Text('缓存全部'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.delete),
                          label: const Text('清除缓存'),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: _chapters.length,
                    itemBuilder: (context, index) {
                      final chapter = _chapters[index];
                      return CheckboxListTile(
                        value: chapter.isCached,
                        onChanged: (checked) {},
                        title: Text(chapter.title),
                        secondary: chapter.isVip
                            ? const Icon(Icons.lock)
                            : null,
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _refreshData() async {
    setState(() {
      _isLoading = true;
    });
    await _loadData();
  }

  void _openFullChapterList() {
    Navigator.pushNamed(
      context,
      AppRoutes.chapterList,
      arguments: {'bookUrl': widget.bookUrl},
    );
  }

  void _showBookEditSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => BookEditSheet(
        book: _book!,
        onSaved: _refreshData,
      ),
    );
  }

  void _openChapter(Chapter chapter) {
    Navigator.pushNamed(
      context,
      AppRoutes.novelReader,
      arguments: {
        'bookUrl': widget.bookUrl,
        'chapterIndex': chapter.index,
      },
    );
  }
}
