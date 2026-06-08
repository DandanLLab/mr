import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../models/chapter.dart';
import '../../providers/bookshelf_provider.dart';
import '../../routes/app_routes.dart';
import '../../services/storage_service.dart';
import '../../services/book_data_provider.dart';
import '../../services/chapter_cache_service.dart';
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
  bool _showReadRecord = true;
  BookSource? _bookSource;

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
    BookSource? bookSource;

    if (book != null) {
      try {
        _dataProvider = createBookDataProvider(book);
        if (book.originType == BookOriginType.online) {
          final detailedBook = await _dataProvider!.getBookInfo(book.bookUrl);
          if (detailedBook != null) {
            book = mergeBookMetadata(detailedBook, book);
          }
          // 获取书源
          if (book.sourceUrl != null) {
            final sourceData = StorageService.instance.getBookSource(book.sourceUrl!);
            if (sourceData != null) {
              bookSource = BookSource.fromJson(sourceData);
            }
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
        _bookSource = bookSource;
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
                color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
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
    final isOnline = _book!.originType == BookOriginType.online;
    final isLocal = _book!.originType == BookOriginType.local;
    final fg = Theme.of(context).colorScheme.onSurface;

    return SliverAppBar(
      expandedHeight: 56,
      pinned: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      actions: [
        // 定制按钮
        IconButton(
          icon: const Icon(Icons.album_outlined),
          tooltip: '定制按钮',
          onPressed: _showCustomButton,
        ),
        // 数源编辑按钮
        IconButton(
          icon: const Icon(Icons.edit_note),
          tooltip: '编辑',
          onPressed: _showBookEditSheet,
        ),
        // 更多选项
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: '更多',
          offset: const Offset(0, 48),
          onSelected: (value) {
            switch (value) {
              case 'share':
                _shareBook();
                break;
              case 'refresh':
                _refreshData();
                break;
              case 'login':
                _showSourceLogin();
                break;
              case 'top':
                _topBook();
                break;
              case 'set_source_variable':
                _showSetSourceVariable();
                break;
              case 'set_book_variable':
                _showSetBookVariable();
                break;
              case 'copy_book_url':
                _copyBookUrl();
                break;
              case 'copy_toc_url':
                _copyTocUrl();
                break;
              case 'can_update':
                _toggleCanUpdate();
                break;
              case 'delete_alert':
                _toggleDeleteAlert();
                break;
              case 'show_read_record':
                _toggleShowReadRecord();
                break;
              case 'clear_cache':
                _clearCache();
                break;
              case 'log':
                _showLog();
                break;
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'share',
              child: Text('分享'),
            ),
            const PopupMenuItem(
              value: 'refresh',
              child: Text('刷新'),
            ),
            if (isOnline)
              const PopupMenuItem(
                value: 'login',
                child: Text('登录'),
              ),
            if (_isInBookshelf)
              PopupMenuItem(
                value: 'top',
                child: Row(
                  children: [
                    const Expanded(child: Text('置顶')),
                    _buildCheckbox(_book!.isTop, fg),
                  ],
                ),
              ),
            if (isOnline)
              const PopupMenuItem(
                value: 'set_source_variable',
                child: Text('设置源变量'),
              ),
            const PopupMenuItem(
              value: 'set_book_variable',
              child: Text('设置书籍变量'),
            ),
            const PopupMenuItem(
              value: 'copy_book_url',
              child: Text('拷贝书籍URL'),
            ),
            if (_book!.tocUrl?.isNotEmpty == true)
              const PopupMenuItem(
                value: 'copy_toc_url',
                child: Text('拷贝目录URL'),
              ),
            if (isOnline)
              PopupMenuItem(
                value: 'can_update',
                child: Row(
                  children: [
                    const Expanded(child: Text('允许更新')),
                    _buildCheckbox(_book!.canUpdate, fg),
                  ],
                ),
              ),
            if (_isInBookshelf)
              PopupMenuItem(
                value: 'delete_alert',
                child: Row(
                  children: [
                    const Expanded(child: Text('删除提醒')),
                    _buildCheckbox(_book!.deleteAlert ?? false, fg),
                  ],
                ),
              ),
            PopupMenuItem(
              value: 'show_read_record',
              child: Row(
                children: [
                  const Expanded(child: Text('显示阅读记录')),
                  _buildCheckbox(_showReadRecord, fg),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'clear_cache',
              child: Text('清理缓存'),
            ),
            const PopupMenuItem(
              value: 'log',
              child: Text('日志'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCheckbox(bool checked, Color fg) {
    return Container(
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
          color:
              Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.5),
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
    final routeName = _book?.mediaType == MediaType.comic
        ? AppRoutes.comicReader
        : AppRoutes.novelReader;
    Navigator.pushNamed(
      context,
      routeName,
      arguments: {
        'bookUrl': widget.bookUrl,
        'chapterIndex': _book?.durChapterIndex ?? 0,
        'initialBook': _book,
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
    Navigator.pushNamed(
      context,
      AppRoutes.novelReader,
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

  void _shareBook() {
    if (_book == null) return;
    final shareText = '${_book!.displayName}\n作者：${_book!.displayAuthor}\n来源：${_book!.sourceName ?? "本地"}\n链接：${_book!.bookUrl}';
    Clipboard.setData(ClipboardData(text: shareText));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('书籍信息已复制到剪贴板')),
    );
  }

  void _copyBookUrl() {
    if (_book == null) return;
    Clipboard.setData(ClipboardData(text: _book!.bookUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('书籍链接已复制')),
    );
  }

  void _copyTocUrl() {
    if (_book == null || _book!.tocUrl == null) return;
    Clipboard.setData(ClipboardData(text: _book!.tocUrl!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('目录链接已复制')),
    );
  }

  void _clearCache() async {
    if (_book == null) return;
    try {
      await ChapterCacheService.instance.clearBookCache(_book!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('缓存已清除')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清除缓存失败：$e')),
        );
      }
    }
  }

  void _topBook() {
    if (_book == null) return;
    final newTop = !_book!.isTop;
    final provider = context.read<BookshelfProvider>();
    if (_isInBookshelf) {
      provider.toggleTop(_book!.bookUrl);
    }
    _book = _book!.copyWith(isTop: newTop);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(newTop ? '已置顶' : '已取消置顶')),
    );
  }

  void _toggleCanUpdate() {
    if (_book == null) return;
    final newValue = !_book!.canUpdate;
    _book = _book!.copyWith(canUpdate: newValue);
    if (_isInBookshelf) {
      StorageService.instance.addToBookshelf(_book!.toJson());
    }
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(newValue ? '已允许更新' : '已禁止更新')),
    );
  }

  void _toggleDeleteAlert() {
    if (_book == null) return;
    final newValue = !(_book!.deleteAlert ?? false);
    _book = _book!.copyWith(deleteAlert: newValue);
    if (_isInBookshelf) {
      StorageService.instance.addToBookshelf(_book!.toJson());
    }
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(newValue ? '已开启删除提醒' : '已关闭删除提醒')),
    );
  }

  void _toggleShowReadRecord() {
    setState(() {
      _showReadRecord = !_showReadRecord;
    });
  }

  void _showCustomButton() async {
    // 检查书源是否有定制按钮
    if (_bookSource != null && _bookSource!.customButton) {
      // 书源有定制按钮，执行书源回调
      // TODO: 实现书源回调JS执行
      // 参考 SourceCallBack.callBackBtn
      final callBackJs = _bookSource!.ruleContent?.callBackJs;
      if (callBackJs != null && callBackJs.isNotEmpty) {
        // 执行回调JS
        try {
          // 这里需要执行JS并处理结果
          // 如果JS返回true，则不显示默认菜单
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('执行书源定制按钮回调...')),
          );
          return;
        } catch (e) {
          debugPrint('执行定制按钮回调失败: $e');
        }
      }
    }

    // 没有书源定制按钮或回调返回false，显示默认菜单
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.8,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('定制按钮', style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(16),
                children: [
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('刷新目录'),
                    onTap: () {
                      Navigator.pop(context);
                      _refreshData();
                    },
                  ),
                  if (_book!.originType == BookOriginType.online)
                    ListTile(
                      leading: const Icon(Icons.swap_horiz),
                      title: const Text('换源'),
                      onTap: () {
                        Navigator.pop(context);
                        _showChangeSourceDialog();
                      },
                    ),
                  if (_book!.originType == BookOriginType.online)
                    ListTile(
                      leading: const Icon(Icons.download),
                      title: const Text('下载'),
                      onTap: () {
                        Navigator.pop(context);
                        _showDownloadDialog();
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _uploadToRemote() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('上传功能开发中...')),
    );
  }

  void _showSourceLogin() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('登录功能开发中...')),
    );
  }

  void _showSetSourceVariable() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置源变量'),
        content: const TextField(
          decoration: InputDecoration(
            hintText: '输入源变量',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('源变量已设置')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showSetBookVariable() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置书籍变量'),
        content: const TextField(
          decoration: InputDecoration(
            hintText: '输入书籍变量',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('书籍变量已设置')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showLog() {
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
                  Text('日志', style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.all(16),
                children: [
                  Text('书籍URL: ${_book?.bookUrl ?? "未知"}'),
                  const SizedBox(height: 8),
                  Text('书源: ${_book?.sourceName ?? "本地"}'),
                  const SizedBox(height: 8),
                  Text('章节数: ${_chapters.length}'),
                  const SizedBox(height: 8),
                  Text('当前章节: ${_book?.durChapterTitle ?? "无"}'),
                  const SizedBox(height: 8),
                  Text('阅读进度: ${_book?.durChapterIndex ?? 0}/${_chapters.length}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
