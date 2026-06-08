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
import '../../services/source_engine/web_book.dart';
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
        // 定制按钮（书源有定制按钮时才显示）
        if (_bookSource?.customButton == true)
          IconButton(
            icon: const Icon(Icons.album_outlined),
            tooltip: '定制',
            onPressed: _showCustomButton,
          ),
        // 编辑按钮（仅在书架中显示）
        if (_isInBookshelf)
          IconButton(
            icon: const Icon(Icons.edit_note),
            tooltip: '编辑',
            onPressed: _showBookEditSheet,
          ),
        // 分享按钮
        IconButton(
          icon: const Icon(Icons.share_outlined, size: 22),
          tooltip: '分享',
          onPressed: _shareBook,
        ),
        // 更多选项
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: '更多',
          offset: const Offset(0, 48),
          onSelected: (value) {
            switch (value) {
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
            PopupMenuItem(
              value: 'refresh',
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: const Text('刷新'),
            ),
            if (isOnline)
              const PopupMenuItem(
                value: 'login',
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text('登录'),
              ),
            if (_isInBookshelf)
              PopupMenuItem(
                value: 'top',
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text('设置源变量'),
              ),
            const PopupMenuItem(
              value: 'set_book_variable',
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('设置书籍变量'),
            ),
            const PopupMenuItem(
              value: 'copy_book_url',
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('拷贝书籍URL'),
            ),
            if (_book!.tocUrl?.isNotEmpty == true)
              const PopupMenuItem(
                value: 'copy_toc_url',
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text('拷贝目录URL'),
              ),
            if (isOnline)
              PopupMenuItem(
                value: 'can_update',
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Expanded(child: Text('删除提醒')),
                    _buildCheckbox(_book!.deleteAlert ?? false, fg),
                  ],
                ),
              ),
            PopupMenuItem(
              value: 'show_read_record',
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Expanded(child: Text('显示阅读记录')),
                  _buildCheckbox(_showReadRecord, fg),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'clear_cache',
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('清理缓存'),
            ),
            const PopupMenuItem(
              value: 'log',
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                    // 书名（可点击）
                    InkWell(
                      onTap: () => _searchBookName(),
                      onLongPress: () => _copyBookName(),
                      child: Text(
                        _book!.displayName,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
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
          // 作者（可点击）
          InkWell(
            onTap: () => _searchAuthor(),
            onLongPress: () => _copyAuthor(),
            child: _buildInfoRow(
              icon: Icons.person_outline,
              label: '作者',
              value: _book!.displayAuthor,
            ),
          ),
          const SizedBox(height: 8),
          // 来源（可点击）
          InkWell(
            onTap: () => _editSource(),
            child: _buildInfoRow(
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
          ),
          const SizedBox(height: 8),
          // 分组
          InkWell(
            onTap: _showChangeGroupDialog,
            child: _buildInfoRow(
              icon: Icons.folder_outlined,
              label: '分组',
              value: _getGroupName(),
              trailing: TextButton(
                onPressed: _showChangeGroupDialog,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(50, 30),
                ),
                child: const Text('修改'),
              ),
            ),
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

  String _getGroupName() {
    if (_book!.originType == BookOriginType.local) {
      return '本地无分组';
    }
    return _book!.groupId ?? '无分组';
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
    if (_book == null) return;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ChangeSourceSheet(
        bookName: _book!.displayName,
        bookAuthor: _book!.displayAuthor,
        currentSourceUrl: _book!.sourceUrl,
        currentSourceName: _book!.sourceName,
        onSourceSelected: (sourceUrl, sourceName, bookData) async {
          // 切换书源
          if (_book == null) return;
          
          try {
            // 显示加载提示
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('正在获取目录...')),
            );
            
            // 创建新的书籍对象
            final newBook = _book!.copyWith(
              sourceUrl: sourceUrl,
              sourceName: sourceName,
              bookUrl: bookData['bookUrl'] ?? _book!.bookUrl,
              name: bookData['name'] ?? _book!.name,
              author: bookData['author'] ?? _book!.author,
              coverUrl: bookData['coverUrl'] ?? _book!.coverUrl,
              intro: bookData['intro'] ?? _book!.intro,
              lastChapter: bookData['lastChapter'] ?? _book!.lastChapter,
            );
            
            // 获取新书源的目录
            _dataProvider = createBookDataProvider(newBook);
            final chapters = await _dataProvider!.getChapterList(newBook);
            
            // 更新书籍
            final updatedBook = newBook.copyWith(
              totalChapterNum: chapters.length,
            );
            
            // 保存到书架
            if (_isInBookshelf) {
              StorageService.instance.addToBookshelf(updatedBook.toJson());
              final provider = context.read<BookshelfProvider>();
              provider.loadBooks();
            }
            
            // 更新状态
            setState(() {
              _book = updatedBook;
              _chapters = chapters;
              _totalWordCount = chapters.fold<int>(0, (sum, ch) => sum + (ch.wordCount ?? 0));
            });
            
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已切换到 $sourceName')),
              );
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('换源失败: $e')),
              );
            }
          }
        },
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
        (context, index) => _buildChapterItem(displayChapters[index]),
        childCount: displayChapters.length,
      ),
    );
  }

  Widget _buildChapterItem(Chapter chapter) {
    final fg = Theme.of(context).colorScheme.onSurface;
    final isOnline = _book!.originType == BookOriginType.online;
    final isSelected = chapter.index == _book!.durChapterIndex;
    final isCached = chapter.isCached || !isOnline;
    final hasTag = chapter.tag != null && chapter.tag!.isNotEmpty;
    final hasWordCount = chapter.wordCount != null && chapter.wordCount! > 0;
    final showSubtitle = hasTag || hasWordCount;

    return InkWell(
      onTap: () => _openChapter(chapter),
      onLongPress: () => _openFullChapterList(),
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
                      color: isSelected ? fg : fg.withValues(alpha: 0.85),
                      fontWeight: isSelected ? FontWeight.bold : null,
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
            if (isSelected)
              Icon(Icons.check, size: 18, color: fg)
            else if (!isCached)
              Icon(Icons.cloud_outlined, size: 18, color: fg.withValues(alpha: 0.4)),
          ],
        ),
      ),
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

  void _searchBookName() async {
    if (_book == null) return;
    
    // 执行书源回调，如果返回true则不执行默认操作
    final handled = await _executeSourceCallback(
      'clickBookName',
      result: _book!.displayName,
    );
    
    if (!handled && mounted) {
      // 跳转到搜索页面搜索书名
      Navigator.pushNamed(
        context,
        AppRoutes.search,
        arguments: {'keyword': _book!.displayName},
      );
    }
  }

  void _copyBookName() async {
    if (_book == null) return;
    
    // 执行书源回调
    final handled = await _executeSourceCallback(
      'longClickBookName',
      result: _book!.displayName,
    );
    
    if (!handled && mounted) {
      Clipboard.setData(ClipboardData(text: _book!.displayName));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书名已复制')),
      );
    }
  }

  void _searchAuthor() async {
    if (_book == null) return;
    
    // 执行书源回调
    final handled = await _executeSourceCallback(
      'clickAuthor',
      result: _book!.displayAuthor,
    );
    
    if (!handled && mounted) {
      // 跳转到搜索页面搜索作者
      Navigator.pushNamed(
        context,
        AppRoutes.search,
        arguments: {'keyword': _book!.displayAuthor},
      );
    }
  }

  void _copyAuthor() async {
    if (_book == null) return;
    
    // 执行书源回调
    final handled = await _executeSourceCallback(
      'longClickAuthor',
      result: _book!.displayAuthor,
    );
    
    if (!handled && mounted) {
      Clipboard.setData(ClipboardData(text: _book!.displayAuthor));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('作者已复制')),
      );
    }
  }

  /// 执行书源回调
  /// 返回 true 表示回调已处理，不需要执行默认操作
  Future<bool> _executeSourceCallback(
    String event, {
    String? result,
  }) async {
    if (_bookSource == null || !_bookSource!.eventListener) {
      return false;
    }
    
    final callBackJs = _bookSource!.ruleContent?.callBackJs;
    if (callBackJs == null || callBackJs.isEmpty) {
      return false;
    }
    
    try {
      // TODO: 实现JS执行
      // 参考 SourceCallBack.callBackBtn
      // 执行JS: source.evalJS(jsStr) { put("event", event); put("result", result); put("book", book); }
      // 如果返回 "true"，则不执行默认操作
      
      debugPrint('执行书源回调: $event, result: $result');
      // 目前先返回false，执行默认操作
      return false;
    } catch (e) {
      debugPrint('执行书源回调失败: $e');
      return false;
    }
  }

  void _editSource() {
    if (_book == null) return;
    if (_book!.originType == BookOriginType.local) return;
    if (_book!.sourceUrl == null) return;
    
    // 跳转到书源编辑页面
    Navigator.pushNamed(
      context,
      AppRoutes.bookSourceEdit,
      arguments: {'sourceUrl': _book!.sourceUrl},
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

/// 换源对话框
class _ChangeSourceSheet extends StatefulWidget {
  final String bookName;
  final String bookAuthor;
  final String? currentSourceUrl;
  final String? currentSourceName;
  final Function(String sourceUrl, String sourceName, Map<String, dynamic> bookData) onSourceSelected;

  const _ChangeSourceSheet({
    required this.bookName,
    required this.bookAuthor,
    this.currentSourceUrl,
    this.currentSourceName,
    required this.onSourceSelected,
  });

  @override
  State<_ChangeSourceSheet> createState() => _ChangeSourceSheetState();
}

class _ChangeSourceSheetState extends State<_ChangeSourceSheet> {
  final List<Map<String, dynamic>> _searchResults = [];
  bool _isLoading = true;
  String? _error;
  int _currentSourceIndex = -1;

  @override
  void initState() {
    super.initState();
    _searchSources();
  }

  Future<void> _searchSources() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // 获取所有启用的书源
      final sourcesData = StorageService.instance.getAllBookSources();
      final sources = <BookSource>[];
      
      for (final data in sourcesData) {
        try {
          final source = BookSource.fromJson(data);
          if (source.enabled && source.searchUrl != null && source.searchUrl!.isNotEmpty) {
            sources.add(source);
          }
        } catch (e) {
          debugPrint('跳过无效书源: $e');
        }
      }

      if (sources.isEmpty) {
        setState(() {
          _isLoading = false;
          _error = '没有可用的书源';
        });
        return;
      }

      // 使用书名+作者搜索
      final keyword = '${widget.bookName} ${widget.bookAuthor}'.trim();
      
      // 并发搜索所有书源
      final futures = <Future<void>>[];
      final results = <Map<String, dynamic>>[];
      
      for (final source in sources) {
        futures.add(() async {
          try {
            final searchResult = await WebBook(source).searchBook(keyword)
                .timeout(const Duration(seconds: 15));
            
            for (final book in searchResult) {
              // 检查是否匹配（书名相似）
              final bookName = (book['name'] as String?)?.trim() ?? '';
              if (_isNameMatch(widget.bookName, bookName)) {
                book['sourceUrl'] = source.bookSourceUrl;
                book['sourceName'] = source.bookSourceName;
                book['searchTime'] = DateTime.now().millisecondsSinceEpoch;
                results.add(book);
              }
            }
          } catch (e) {
            debugPrint('搜索书源 ${source.bookSourceName} 失败: $e');
          }
        }());
      }

      await Future.wait(futures);

      // 按书源名排序，当前书源排第一
      results.sort((a, b) {
        final aUrl = a['sourceUrl'] as String?;
        final bUrl = b['sourceUrl'] as String?;
        
        if (aUrl == widget.currentSourceUrl) return -1;
        if (bUrl == widget.currentSourceUrl) return 1;
        
        return (a['sourceName'] as String? ?? '').compareTo(b['sourceName'] as String? ?? '');
      });

      // 找到当前书源的索引
      int currentIndex = -1;
      for (int i = 0; i < results.length; i++) {
        if (results[i]['sourceUrl'] == widget.currentSourceUrl) {
          currentIndex = i;
          break;
        }
      }

      setState(() {
        _searchResults.clear();
        _searchResults.addAll(results);
        _isLoading = false;
        _currentSourceIndex = currentIndex;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = '搜索失败: $e';
      });
    }
  }

  bool _isNameMatch(String name1, String name2) {
    // 简单的名称匹配检查
    final n1 = name1.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final n2 = name2.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    
    // 完全匹配
    if (n1 == n2) return true;
    
    // 包含关系
    if (n1.contains(n2) || n2.contains(n1)) return true;
    
    // 相似度检查（至少80%相似）
    if (n1.length > 0 && n2.length > 0) {
      final longer = n1.length > n2.length ? n1 : n2;
      final shorter = n1.length > n2.length ? n2 : n1;
      int matchCount = 0;
      for (int i = 0; i < shorter.length; i++) {
        if (longer.contains(shorter[i])) matchCount++;
      }
      if (matchCount / shorter.length > 0.8) return true;
    }
    
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('换源', style: Theme.of(context).textTheme.titleLarge),
                      Text(
                        '${widget.bookName} - ${widget.bookAuthor}',
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新',
                  onPressed: _searchSources,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: _buildContent(scrollController),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ScrollController scrollController) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在搜索书源...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _searchSources,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 48),
            SizedBox(height: 16),
            Text('未找到匹配的书源'),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: scrollController,
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final result = _searchResults[index];
        final sourceUrl = result['sourceUrl'] as String?;
        final sourceName = result['sourceName'] as String? ?? '未知';
        final bookName = result['name'] as String? ?? '';
        final author = result['author'] as String? ?? '';
        final lastChapter = result['lastChapter'] as String? ?? '';
        final isCurrentSource = sourceUrl == widget.currentSourceUrl;

        return ListTile(
          leading: Icon(
            Icons.source,
            color: isCurrentSource ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  sourceName,
                  style: TextStyle(
                    fontWeight: isCurrentSource ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
              if (isCurrentSource)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '当前',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (bookName.isNotEmpty && bookName != widget.bookName)
                Text('书名: $bookName', style: const TextStyle(fontSize: 12)),
              if (author.isNotEmpty && author != widget.bookAuthor)
                Text('作者: $author', style: const TextStyle(fontSize: 12)),
              if (lastChapter.isNotEmpty)
                Text('最新: $lastChapter', style: const TextStyle(fontSize: 12)),
            ],
          ),
          trailing: isCurrentSource
              ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
              : null,
          onTap: isCurrentSource
              ? null
              : () {
                  Navigator.pop(context);
                  widget.onSourceSelected(sourceUrl!, sourceName, result);
                },
        );
      },
    );
  }
}
