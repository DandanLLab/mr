import 'dart:ui';
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
import '../../services/book_data_provider.dart';
import '../../widgets/book_edit_sheet.dart';

class DetailPage extends StatefulWidget {
  final String bookUrl;
  final Book? initialBook;

  const DetailPage({
    super.key,
    required this.bookUrl,
    this.initialBook,
  });

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
  BookDataProvider? _dataProvider;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final storedData = StorageService.instance.getBook(widget.bookUrl);
    final storedBook = storedData == null ? null : Book.fromJson(storedData);
    Book? book = storedBook ?? widget.initialBook;
    List<Chapter> chapters = [];
    String? error;

    if (book != null) {
      try {
        _dataProvider = createBookDataProvider(book);
        if (book.originType == BookOriginType.online) {
          final detailedBook = await _dataProvider!.getBookInfo(book.bookUrl);
          if (detailedBook != null) {
            book = mergeBookMetadata(detailedBook, book);
          }
        }
        chapters = await _dataProvider!.getChapterList(book);
        if (book.totalChapterNum == null && chapters.isNotEmpty) {
          book = book.copyWith(totalChapterNum: chapters.length);
        }
      } catch (e) {
        error = e.toString();
      }
    }

    _totalWordCount =
        chapters.fold<int>(0, (sum, ch) => sum + (ch.wordCount ?? 0));

    if (mounted) {
      setState(() {
        _book = book;
        _chapters = chapters;
        _isInBookshelf = storedData != null;
        _isLoading = false;
      });
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('部分信息加载失败：$error')),
        );
      }
    }
  }

  Future<void> _refreshData() async {
    if (_isRefreshing) return;
    setState(() {
      _isRefreshing = true;
    });

    if (_book != null) {
      try {
        _dataProvider = createBookDataProvider(_book!);
        if (_book!.originType == BookOriginType.online) {
          final detailedBook = await _dataProvider!.getBookInfo(_book!.bookUrl);
          if (detailedBook != null) {
            _book = mergeBookMetadata(detailedBook, _book!);
          }
        }
        _chapters = await _dataProvider!.getChapterList(_book!);
      } catch (_) {
        // Keep the currently displayed metadata if refreshing fails.
      }
      _totalWordCount =
          _chapters.fold<int>(0, (sum, ch) => sum + (ch.wordCount ?? 0));
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
      body: Stack(
        children: [
          // 背景模糊图片
          if (_book!.coverUrl.isNotEmpty)
            Positioned.fill(
              child: CachedNetworkImage(
                imageUrl: _book!.coverUrl,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Container(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                color: Theme.of(context)
                    .colorScheme
                    .surface
                    .withValues(alpha: 0.85),
              ),
            ),
          ),
          // 主内容
          RefreshIndicator(
            onRefresh: _refreshData,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                _buildAppBar(),
                SliverToBoxAdapter(child: _buildHeader()),
                SliverToBoxAdapter(child: _buildInfoRows()),
                SliverToBoxAdapter(child: _buildActionButtons()),
                SliverToBoxAdapter(child: _buildDescription()),
                SliverToBoxAdapter(child: _buildTags()),
                SliverToBoxAdapter(child: _buildChapterHeader()),
                _buildChapterList(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 56,
      pinned: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      actions: [
        PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'edit':
                _showBookEditSheet();
                break;
              case 'refresh':
                _refreshData();
                break;
              case 'change_source':
                _showChangeSourceDialog();
                break;
              case 'download':
                _showDownloadDialog();
                break;
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'edit', child: Text('编辑信息')),
            const PopupMenuItem(value: 'refresh', child: Text('刷新目录')),
            if (_book!.originType == BookOriginType.online)
              const PopupMenuItem(value: 'change_source', child: Text('换源')),
            if (_book!.originType == BookOriginType.online)
              const PopupMenuItem(value: 'download', child: Text('下载')),
          ],
        ),
      ],
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // 封面和基本信息
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 封面 - 带阴影和圆角
              Hero(
                tag: 'cover_${widget.bookUrl}',
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 110,
                      height: 160,
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: _book!.displayCoverUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: _book!.displayCoverUrl,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => const Center(
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                              errorWidget: (_, __, ___) =>
                                  const Icon(Icons.book, size: 48),
                            )
                          : const Icon(Icons.book, size: 48),
                    ),
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
                        if (_chapters.isNotEmpty ||
                            (_book!.totalChapterNum ?? 0) > 0)
                          _buildInfoChip(
                            '${_chapters.isNotEmpty ? _chapters.length : _book!.totalChapterNum}章',
                          ),
                        if (_displayWordCount.isNotEmpty)
                          _buildInfoChip(_displayWordCount),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 阅读进度
                    if (_book!.durChapterIndex > 0) _buildReadProgress(),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRows() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          // 作者
          _buildInfoRow(
            icon: Icons.person_outline,
            label: '作者',
            value: _book!.displayAuthor,
          ),
          const SizedBox(height: 8),
          // 来源
          _buildInfoRow(
            icon: Icons.public_outlined,
            label: '来源',
            value: _book!.sourceName ?? '本地',
            trailing: _book!.originType == BookOriginType.online
                ? TextButton(
                    onPressed: _showChangeSourceDialog,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(50, 30),
                    ),
                    child: const Text('换源'),
                  )
                : null,
          ),
          const SizedBox(height: 8),
          // 最新章节
          if (_book!.latestChapterTitle.isNotEmpty)
            _buildInfoRow(
              icon: Icons.new_releases_outlined,
              label: '最新',
              value: _book!.latestChapterTitle,
            ),
          if (_book!.latestChapterTitle.isNotEmpty) const SizedBox(height: 8),
          // 分组
          if (_book!.groupId != null && _book!.groupId!.isNotEmpty)
            _buildInfoRow(
              icon: Icons.folder_outlined,
              label: '分组',
              value: _book!.groupId!,
              trailing: TextButton(
                onPressed: _showChangeGroupDialog,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(50, 30),
                ),
                child: const Text('修改'),
              ),
            ),
          if (_book!.groupId != null && _book!.groupId!.isNotEmpty)
            const SizedBox(height: 8),
          // 阅读记录
          if (_book!.durChapterIndex > 0)
            _buildInfoRow(
              icon: Icons.history,
              label: '进度',
              value: _book!.durChapterTitle,
              trailing: TextButton(
                onPressed: _showReadRecordDialog,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(50, 30),
                ),
                child: const Text('记录'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
    Widget? trailing,
  }) {
    return Row(
      children: [
        Icon(
          icon,
          size: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 14,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  void _showChangeSourceDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('换源', style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: 5, // 示例数据
                itemBuilder: (context, index) => ListTile(
                  leading: const Icon(Icons.source),
                  title: Text('书源 ${index + 1}'),
                  subtitle: Text('响应时间: ${(index + 1) * 100}ms'),
                  trailing: index == 0
                      ? const Icon(Icons.check, color: Colors.green)
                      : null,
                  onTap: () {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已切换书源')),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showChangeGroupDialog() {
    final groups = ['全部', '追更', '漫画', '已完结'];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改分组'),
        content: RadioGroup<String>(
          groupValue: _book!.groupId ?? '全部',
          onChanged: (value) {
            Navigator.pop(context);
            // TODO: 更新分组
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: groups
                .map((group) => RadioListTile<String>(
                      title: Text(group),
                      value: group,
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  void _showReadRecordDialog() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('阅读记录', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('累计阅读'),
              subtitle: Text('2小时30分钟'),
              contentPadding: EdgeInsets.zero,
            ),
            ListTile(
              leading: const Icon(Icons.calendar_today),
              title: const Text('最近阅读'),
              subtitle: Text('今天 14:30'),
              contentPadding: EdgeInsets.zero,
            ),
            ListTile(
              leading: const Icon(Icons.menu_book),
              title: const Text('阅读章节'),
              subtitle:
                  Text('${_book!.durChapterIndex + 1}/${_chapters.length}'),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }

  void _showDownloadDialog() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下载当前章节'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_for_offline),
              title: const Text('下载后续50章'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.cloud_download),
              title: const Text('下载全本'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReadProgress() {
    final chapterIndex = _book!.durChapterIndex;
    final chapterName = _book!.durChapterTitle.isEmpty
        ? '第${chapterIndex + 1}章'
        : _book!.durChapterTitle;
    final progress = _chapters.isNotEmpty
        ? (chapterIndex / _chapters.length * 100).toInt()
        : 0;

    return GestureDetector(
      onTap: _startReading,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .primaryContainer
              .withValues(alpha: 0.5),
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
              icon: Icon(
                  _isInBookshelf ? Icons.bookmark : Icons.bookmark_border,
                  size: 20),
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
    return trimmed.startsWith('<') &&
        (trimmed.contains('</') || trimmed.contains('/>'));
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
    final tags = _book!.tags ??
        (_book!.kind ?? '')
            .split(RegExp(r'[,，/|·\s]+'))
            .where((tag) => tag.trim().isNotEmpty)
            .toList();
    if (tags.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: tags.map((tag) {
          return Chip(
            label: Text(tag),
            backgroundColor:
                Theme.of(context).colorScheme.surfaceContainerHighest,
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
          ? Icon(Icons.lock,
              size: 16, color: Theme.of(context).colorScheme.primary)
          : null,
      title: Text(
        chapter.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      trailing: chapter.isCached
          ? Icon(Icons.download_done,
              size: 16, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: () => _openChapter(chapter),
      onLongPress: () => _openFullChapterList(),
    );
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
    if (_chapters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目录为空，无法开始阅读')),
      );
      return;
    }
    final route = _book?.mediaType == MediaType.comic
        ? AppRoutes.comicReader
        : AppRoutes.novelReader;
    Navigator.pushNamed(
      context,
      route,
      arguments: {
        'bookUrl': widget.bookUrl,
        'chapterIndex': _book?.durChapterIndex ?? 0,
        'bookData': _book,
      },
    );
  }

  void _openFullChapterList() {
    Navigator.pushNamed(
      context,
      AppRoutes.chapterList,
      arguments: {
        'bookUrl': widget.bookUrl,
        'bookData': _book,
        'currentChapterIndex': _book?.durChapterIndex ?? 0,
      },
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
    if (chapter.isVolume) return;
    final route = _book?.mediaType == MediaType.comic
        ? AppRoutes.comicReader
        : AppRoutes.novelReader;
    Navigator.pushNamed(
      context,
      route,
      arguments: {
        'bookUrl': widget.bookUrl,
        'chapterIndex': chapter.index,
        'bookData': _book,
      },
    );
  }

  String get _displayWordCount {
    if (_book?.wordCount?.trim().isNotEmpty == true) {
      final value = _book!.wordCount!.trim();
      return value.endsWith('字') ? value : '$value字';
    }
    return _totalWordCount > 0 ? _formatWordCount(_totalWordCount) : '';
  }
}
