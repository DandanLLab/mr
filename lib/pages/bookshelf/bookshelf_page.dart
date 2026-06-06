import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:file_picker/file_picker.dart';
import '../../models/book.dart';
import '../../providers/bookshelf_provider.dart';
import '../../routes/app_routes.dart';
import '../../services/local_book/local_book_service.dart';

/// 书架布局类型
enum BookshelfLayout {
  list,        // 列表
  listCompact, // 紧凑列表
  grid2,       // 2列网格
  grid3,       // 3列网格
  grid4,       // 4列网格
  grid5,       // 5列网格
  grid6,       // 6列网格
}

/// 书架排序类型
enum BookshelfSort {
  byTime,      // 按阅读时间
  byName,      // 按书名
  byAuthor,    // 按作者
  byLatest,    // 按最新章节
  byAddTime,   // 按添加时间
}

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  final List<String> _groups = ['全部', '追更', '漫画', '已完结'];
  int _selectedGroupIndex = 0;
  
  // 书架配置
  BookshelfLayout _layout = BookshelfLayout.grid3;
  BookshelfSort _sort = BookshelfSort.byTime;
  bool _showUnread = true;
  bool _showLastUpdateTime = true;
  bool _showBookName = true;
  int _gridColumnCount = 3;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              Navigator.pushNamed(context, AppRoutes.search);
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) => _handleMenuSelection(value),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'refresh',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('更新目录'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'import_local',
                child: ListTile(
                  leading: Icon(Icons.folder),
                  title: Text('本地导入'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'import_url',
                child: ListTile(
                  leading: Icon(Icons.link),
                  title: Text('URL导入'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'batch',
                child: ListTile(
                  leading: Icon(Icons.checklist),
                  title: Text('批量管理'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'group_manage',
                child: ListTile(
                  leading: Icon(Icons.folder_open),
                  title: Text('分组管理'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'config',
                child: ListTile(
                  leading: Icon(Icons.settings),
                  title: Text('书架设置'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Consumer<BookshelfProvider>(
        builder: (context, provider, child) {
          return Column(
            children: [
              _buildGroupTabs(provider),
              Expanded(
                child: provider.isBatchMode
                    ? _buildBatchView(provider)
                    : _buildMainView(provider),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showImportDialog,
        child: const Icon(Icons.add),
      ),
    );
  }

  void _handleMenuSelection(String value) {
    final provider = context.read<BookshelfProvider>();
    switch (value) {
      case 'refresh':
        _refreshAllBooks();
        break;
      case 'import_local':
        _showImportDialog();
        break;
      case 'import_url':
        _showUrlImportDialog();
        break;
      case 'batch':
        provider.enterBatchMode();
        break;
      case 'group_manage':
        _showGroupManageDialog();
        break;
      case 'config':
        _showBookshelfConfigDialog();
        break;
    }
  }

  Future<void> _refreshAllBooks() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在更新书籍目录...')),
    );
    // TODO: 实现更新逻辑
  }

  void _showUrlImportDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('URL导入'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入书籍URL',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              // TODO: 实现URL导入
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  void _showGroupManageDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => StatefulBuilder(
          builder: (context, setSheetState) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('分组管理', style: Theme.of(context).textTheme.titleLarge),
                    IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () {
                        _showCreateGroupDialog();
                      },
                    ),
                  ],
                ),
              ),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: _groups.length,
                  itemBuilder: (context, index) => ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(_groups[index]),
                    trailing: index > 0
                        ? IconButton(
                            icon: const Icon(Icons.delete, size: 20),
                            onPressed: () {
                              setSheetState(() {
                                _groups.removeAt(index);
                              });
                            },
                          )
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBookshelfConfigDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('书架设置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 布局选择
                Text('布局样式', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    _buildLayoutChip('列表', BookshelfLayout.list, setDialogState),
                    _buildLayoutChip('紧凑', BookshelfLayout.listCompact, setDialogState),
                    _buildLayoutChip('2列', BookshelfLayout.grid2, setDialogState),
                    _buildLayoutChip('3列', BookshelfLayout.grid3, setDialogState),
                    _buildLayoutChip('4列', BookshelfLayout.grid4, setDialogState),
                    _buildLayoutChip('5列', BookshelfLayout.grid5, setDialogState),
                    _buildLayoutChip('6列', BookshelfLayout.grid6, setDialogState),
                  ],
                ),
                const SizedBox(height: 16),
                // 排序选择
                Text('排序方式', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    _buildSortChip('阅读时间', BookshelfSort.byTime, setDialogState),
                    _buildSortChip('书名', BookshelfSort.byName, setDialogState),
                    _buildSortChip('作者', BookshelfSort.byAuthor, setDialogState),
                    _buildSortChip('最新章节', BookshelfSort.byLatest, setDialogState),
                    _buildSortChip('添加时间', BookshelfSort.byAddTime, setDialogState),
                  ],
                ),
                const SizedBox(height: 16),
                // 显示选项
                Text('显示选项', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text('显示未读数'),
                  value: _showUnread,
                  onChanged: (v) => setDialogState(() => _showUnread = v),
                  contentPadding: EdgeInsets.zero,
                ),
                SwitchListTile(
                  title: const Text('显示更新时间'),
                  value: _showLastUpdateTime,
                  onChanged: (v) => setDialogState(() => _showLastUpdateTime = v),
                  contentPadding: EdgeInsets.zero,
                ),
                SwitchListTile(
                  title: const Text('显示书名'),
                  value: _showBookName,
                  onChanged: (v) => setDialogState(() => _showBookName = v),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLayoutChip(String label, BookshelfLayout layout, StateSetter setDialogState) {
    return ChoiceChip(
      label: Text(label),
      selected: _layout == layout,
      onSelected: (selected) {
        if (selected) {
          setDialogState(() {
            _layout = layout;
            _gridColumnCount = _getGridColumnCount(layout);
          });
        }
      },
    );
  }

  Widget _buildSortChip(String label, BookshelfSort sort, StateSetter setDialogState) {
    return ChoiceChip(
      label: Text(label),
      selected: _sort == sort,
      onSelected: (selected) {
        if (selected) {
          setDialogState(() => _sort = sort);
        }
      },
    );
  }

  int _getGridColumnCount(BookshelfLayout layout) {
    switch (layout) {
      case BookshelfLayout.list:
      case BookshelfLayout.listCompact:
        return 1;
      case BookshelfLayout.grid2:
        return 2;
      case BookshelfLayout.grid3:
        return 3;
      case BookshelfLayout.grid4:
        return 4;
      case BookshelfLayout.grid5:
        return 5;
      case BookshelfLayout.grid6:
        return 6;
    }
  }

  Widget _buildMainView(BookshelfProvider provider) {
    final isList = _layout == BookshelfLayout.list || _layout == BookshelfLayout.listCompact;
    
    if (provider.books.isEmpty) {
      return _buildEmptyState();
    }

    return RefreshIndicator(
      onRefresh: provider.loadBooks,
      child: isList
          ? _buildListView(provider)
          : _buildGridView(provider),
    );
  }

  Widget _buildGroupTabs(BookshelfProvider provider) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _groups.length + 1,
        itemBuilder: (context, index) {
          if (index == _groups.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ActionChip(
                label: const Text('+ 新建分组'),
                onPressed: () {
                  _showCreateGroupDialog();
                },
              ),
            );
          }

          final isSelected = index == _selectedGroupIndex;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: FilterChip(
              label: Text(_groups[index]),
              selected: isSelected,
              onSelected: (selected) {
                setState(() {
                  _selectedGroupIndex = index;
                });
                provider.setGroup(
                  index == 0 ? null : _groups[index],
                );
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildGridView(BookshelfProvider provider) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _gridColumnCount,
        childAspectRatio: 0.65,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: provider.books.length,
      itemBuilder: (context, index) {
        final book = provider.books[index];
        return _buildGridBookCard(book, provider);
      },
    );
  }

  Widget _buildGridBookCard(Book book, BookshelfProvider provider) {
    return GestureDetector(
      onTap: () => _openBook(book),
      onLongPress: () => _showBookOptions(book, provider),
      child: Stack(
        children: [
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: book.coverUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: book.coverUrl,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                            child: const Center(
                              child: CircularProgressIndicator(),
                            ),
                          ),
                          errorWidget: (context, url, error) => Container(
                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.book, size: 48),
                          ),
                        )
                      : Container(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.book, size: 48),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: book.progress,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (book.originType == BookOriginType.local)
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '本地',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          if (book.isTop)
            Positioned(
              top: 8,
              right: 8,
              child: Icon(
                Icons.push_pin,
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildListView(BookshelfProvider provider) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: provider.books.length,
      itemBuilder: (context, index) {
        final book = provider.books[index];
        return _buildListBookCard(book, provider);
      },
    );
  }

  Widget _buildListBookCard(Book book, BookshelfProvider provider) {
    final isCompact = _layout == BookshelfLayout.listCompact;
    
    return Slidable(
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        children: [
          SlidableAction(
            onPressed: (_) => provider.toggleTop(book.bookUrl),
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
            icon: book.isTop ? Icons.push_pin_outlined : Icons.push_pin,
            label: book.isTop ? '取消置顶' : '置顶',
          ),
          SlidableAction(
            onPressed: (_) => provider.removeFromBookshelf(book.bookUrl),
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
            foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            icon: Icons.delete,
            label: '移除',
          ),
        ],
      ),
      child: InkWell(
        onTap: () => _openBook(book),
        onLongPress: () => _showBookOptions(book, provider),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 封面
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: isCompact ? 48 : 66,
                  height: isCompact ? 64 : 90,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: book.coverUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: book.coverUrl,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          ),
                          errorWidget: (context, url, error) => const Icon(Icons.book),
                        )
                      : const Icon(Icons.book),
                ),
              ),
              const SizedBox(width: 12),
              // 书籍信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 书名行
                    if (_showBookName)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              book.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (_showUnread && book.unreadCount > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${book.unreadCount}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                        ],
                      ),
                    if (!isCompact) ...[
                      const SizedBox(height: 4),
                      // 作者行
                      Row(
                        children: [
                          Icon(
                            Icons.person_outline,
                            size: 14,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              book.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (_showLastUpdateTime && book.lastCheckTime != null)
                            Text(
                              _formatUpdateTime(book.lastCheckTime!),
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 4),
                    // 阅读进度行
                    Row(
                      children: [
                        Icon(
                          Icons.history,
                          size: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            book.durChapterTitle.isNotEmpty 
                                ? book.durChapterTitle 
                                : '未开始阅读',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (!isCompact) ...[
                      const SizedBox(height: 4),
                      // 最新章节行
                      Row(
                        children: [
                          Icon(
                            Icons.new_releases_outlined,
                            size: 14,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              book.latestChapterTitle.isNotEmpty 
                                  ? '最新: ${book.latestChapterTitle}' 
                                  : '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              // 来源标签
              if (book.originType == BookOriginType.local)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '本地',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatUpdateTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inDays == 0) {
      return '今天';
    } else if (diff.inDays == 1) {
      return '昨天';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}天前';
    } else {
      return '${time.month}/${time.day}';
    }
  }

  Widget _buildBatchView(BookshelfProvider provider) {
    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _gridColumnCount,
              childAspectRatio: 0.65,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: provider.books.length,
            itemBuilder: (context, index) {
              final book = provider.books[index];
              final isSelected = provider.selectedBookIds.contains(book.bookUrl);

              return GestureDetector(
                onTap: () => provider.toggleBookSelection(book.bookUrl),
                child: Stack(
                  children: [
                    _buildGridBookCard(book, provider),
                    if (isSelected)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Icon(
                              Icons.check_circle,
                              size: 48,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                onPressed: provider.selectedBookIds.isEmpty
                    ? null
                    : () => provider.batchRemove(),
                icon: const Icon(Icons.delete),
                label: const Text('批量移除'),
              ),
              TextButton.icon(
                onPressed: provider.selectedBookIds.isEmpty
                    ? null
                    : () => _showBatchUpdateDialog(provider),
                icon: const Icon(Icons.update),
                label: const Text('批量更新'),
              ),
              TextButton.icon(
                onPressed: () => provider.exitBatchMode(),
                icon: const Icon(Icons.close),
                label: const Text('取消'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showBatchUpdateDialog(BookshelfProvider provider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('批量更新'),
        content: Text('确定要更新选中的 ${provider.selectedBookIds.length} 本书籍吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              // TODO: 实现批量更新
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('正在更新...')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.book_outlined,
            size: 80,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            '书架空空如也',
            style: TextStyle(
              fontSize: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击右下角按钮导入书籍',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  void _showImportDialog() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.folder),
                title: const Text('扫描目录'),
                subtitle: const Text('选择文件夹自动识别支持的格式'),
                onTap: () {
                  Navigator.pop(context);
                  _scanDirectory();
                },
              ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file),
                title: const Text('选择文件'),
                subtitle: const Text('手动选择单个或多个文件'),
                onTap: () {
                  Navigator.pop(context);
                  _selectFiles();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _scanDirectory() async {
    try {
      String? directoryPath = await FilePicker.platform.getDirectoryPath();
      if (directoryPath != null) {
        final books = await LocalBookService.instance.scanDirectory(directoryPath);
        for (final book in books) {
          await context.read<BookshelfProvider>().addToBookshelf(book);
        }
        if (books.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已导入 ${books.length} 本书籍')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未找到支持的书籍文件')),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('扫描失败: $e')),
      );
    }
  }

  void _selectFiles() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: ['txt', 'epub', 'pdf'],
      );
      if (result != null) {
        int successCount = 0;
        for (final file in result.files) {
          if (file.path != null) {
            final book = await LocalBookService.instance.importFile(file.path!);
            if (book != null) {
              await context.read<BookshelfProvider>().addToBookshelf(book);
              successCount++;
            }
          }
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入 $successCount 本书籍')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
  }

  void _showCreateGroupDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('新建分组'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: '分组名称',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.isNotEmpty) {
                  setState(() {
                    _groups.add(controller.text);
                  });
                  Navigator.pop(context);
                }
              },
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
  }

  void _showBookOptions(Book book, BookshelfProvider provider) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(book.isTop ? Icons.push_pin_outlined : Icons.push_pin),
                title: Text(book.isTop ? '取消置顶' : '置顶'),
                onTap: () {
                  provider.toggleTop(book.bookUrl);
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder),
                title: const Text('移动到分组'),
                onTap: () {
                  Navigator.pop(context);
                  _showMoveToGroupDialog(book, provider);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('从书架移除'),
                onTap: () {
                  provider.removeFromBookshelf(book.bookUrl);
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showMoveToGroupDialog(Book book, BookshelfProvider provider) {
    String? selectedGroup = book.groupId;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('移动到分组'),
            content: RadioGroup<String>(
              groupValue: selectedGroup,
              onChanged: (String? value) {
                setDialogState(() => selectedGroup = value);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: _groups.map((group) {
                  return RadioListTile<String>(
                    title: Text(group),
                    value: group,
                  );
                }).toList(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  provider.moveBookToGroup(book.bookUrl, selectedGroup == '全部' ? null : selectedGroup);
                  Navigator.pop(context);
                },
                child: const Text('确定'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _openBook(Book book) {
    Navigator.pushNamed(
      context,
      AppRoutes.detail,
      arguments: {'bookUrl': book.bookUrl},
    );
  }
}
