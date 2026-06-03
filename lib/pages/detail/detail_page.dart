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
  bool _isRefreshing = false;
  Book? _book;
  List<Chapter> _chapters = [];
  bool _isDescExpanded = false;
  int _totalWordCount = 0;

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

    // 计算总字数
    _totalWordCount = chapters.fold<int>(
      0, (sum, ch) => sum + (ch.wordCount ?? 0));

    final isInShelf = bookData != null;

    if (mounted) {
      setState(() {
        _book = book;
        _chapters = chapters;
        _isInBookshelf = isInShelf;
        _isLoading = false;
      });
    }
  }

  Future<void> _refreshData() async {
    if (_isRefreshing) return;
    setState(() {
      _isRefreshing = true;
    });

    final bookData = StorageService.instance.getBook(widget.bookUrl);
    if (bookData != null) {
      _book = Book.fromJson(bookData);
      _chapters = await LocalBookService.instance.getChapterList(_book!);
      _totalWordCount = _chapters.fold<int>(
        0, (sum, ch) => sum + (ch.wordCount ?? 0));
    }

    if (mounted) {
      setState(() {
        _isRefreshing = false;
      });
    }
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
      body: RefreshIndicator(
        onRefresh: _refreshData,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _buildAppBar(),
            SliverToBoxAdapter(child: _buildHeader()),
            SliverToBoxAdapter(child: _buildActionButtons()),
            SliverToBoxAdapter(child: _buildDescription()),
            SliverToBoxAdapter(child: _buildTags()),
            SliverToBoxAdapter(child: _buildChapterHeader()),
            _buildChapterList(),
          ],
        ),
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
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
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
          // 封面
          Hero(
            tag: 'cover_${widget.bookUrl}',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 100,
                height: 140,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: _book!.displayCoverUrl.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: _book!.displayCoverUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        errorWidget: (_, __, ___) =>
                            const Icon(Icons.book, size: 48),
                      )
                    : const Icon(Icons.book, size: 48),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // 书籍信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _book!.displayName,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      Icons.person_outline,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _book!.displayAuthor,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 标签行
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _buildInfoChip(
                      _book!.status ??
                          (_book!.originType == BookOriginType.local
                              ? '本地'
                              : '未知'),
                    ),
                    if (_book!.sourceName != null)
                      _buildInfoChip(_book!.sourceName!),
                    _buildInfoChip(
                        '${_chapters.length} ${_chapters.length == 1 ? "章" : "章"}'),
                    if (_totalWordCount > 0)
                      _buildInfoChip(_formatWordCount(_totalWordCount)),
                  ],
                ),
                const SizedBox(height: 8),
                // 阅读进度
                if (_book!.durChapterIndex > 0) _buildReadProgress(),
                if (_book!.lastCheckTime != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '更新: ${_formatDate(_book!.lastCheckTime)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadProgress() {
    final chapterIndex = _book!.durChapterIndex;
    final chapterName = _book!.durChapterTitle ?? '第${chapterIndex + 1}章';
    final progress = _chapters.isNotEmpty
        ? (chapterIndex / _chapters.length * 100).toInt()
        : 0;

    return GestureDetector(
      onTap: _startReading,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.play_circle_outline,
              size: 14,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                chapterName,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '$progress%',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatWordCount(int count) {
    if (count >= 10000) {
      return '${(count / 10000).toStringAsFixed(1)}万字';
    }
    return '${count}字';
  }

  Widget _buildInfoChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _toggleBookshelf,
              icon: Icon(_isInBookshelf ? Icons.bookmark : Icons.bookmark_border, size: 20),
              label: Text(_isInBookshelf ? '已在书架' : '加入书架'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: _startReading,
              icon: const Icon(Icons.play_arrow, size: 20),
              label: const Text('立即阅读'),
            ),
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
          if (intro.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {
                  setState(() {
                    _isDescExpanded = !_isDescExpanded;
                  });
                },
                child: Text(_isDescExpanded ? '收起' : '展开全部'),
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
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          );
        }).toList(),
      ),
    );
  }

  Widget _buildChapterHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '目录',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          TextButton(
            onPressed: () => _openFullChapterList(),
            child: const Text('查看全部'),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterList() {
    // 只显示最新3章
    final displayChapters = _chapters.length > 3
        ? _chapters.sublist(_chapters.length - 3)
        : _chapters;

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          if (index < displayChapters.length) {
            return _buildChapterItem(displayChapters[index]);
          }
          // "查看完整目录"按钮
          return InkWell(
            onTap: () => _openFullChapterList(),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              alignment: Alignment.center,
              child: Text(
                '查看完整目录 (${_chapters.length}章)',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          );
        },
        childCount: displayChapters.length + 1,
      ),
    );
  }

  Widget _buildChapterItem(Chapter chapter) {
    return ListTile(
      dense: true,
      leading: chapter.isVip
          ? Icon(Icons.lock, size: 16, color: Theme.of(context).colorScheme.primary)
          : null,
      title: Text(
        chapter.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      trailing: chapter.isCached
          ? Icon(Icons.download_done, size: 16, color: Theme.of(context).colorScheme.primary)
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
        behavior: SnackBarBehavior.floating,
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

  Future<void> _refreshData() async {
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
