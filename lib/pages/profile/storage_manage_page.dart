import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/storage_service.dart';
import '../../models/book.dart';
import '../../utils/design_tokens.dart';

class StorageManagePage extends StatefulWidget {
  const StorageManagePage({super.key});

  @override
  State<StorageManagePage> createState() => _StorageManagePageState();
}

class _StorageManagePageState extends State<StorageManagePage> {
  List<Map<String, dynamic>> _books = [];
  bool _isLoading = true;
  int _totalSize = 0;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  void _loadBooks() {
    final bookDataList = StorageService.instance.getAllBooks();
    final books = <Map<String, dynamic>>[];
    int totalSize = 0;

    for (final bookData in bookDataList) {
      final book = Book.fromJson(bookData);
      // 计算书籍缓存大小（这里简化处理，实际需要计算章节缓存）
      final size = bookData.toString().length; // 简化计算
      totalSize += size;
      books.add({
        'book': book,
        'size': size,
      });
    }

    // 按大小排序
    books.sort((a, b) => (b['size'] as int).compareTo(a['size'] as int));

    setState(() {
      _books = books;
      _totalSize = totalSize;
      _isLoading = false;
    });
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('存储管理'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'clear_all') {
                _showClearAllConfirm();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'clear_all',
                child: Text('清空所有缓存'),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 总大小统计
                Container(
                  padding: const EdgeInsets.all(DesignTokens.spacingLg),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.storage,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: DesignTokens.spacingMd),
                      Text(
                        '共 ${_books.length} 本书籍',
                        style: const TextStyle(fontSize: DesignTokens.fontBody),
                      ),
                      const Spacer(),
                      Text(
                        '总大小: ${_formatSize(_totalSize)}',
                        style: TextStyle(
                          fontSize: DesignTokens.fontBody,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                // 书籍列表
                Expanded(
                  child: _books.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.inbox, size: DesignTokens.emptyIconSize, color: Theme.of(context).colorScheme.onSurfaceVariant),
                              const SizedBox(height: DesignTokens.spacingLg),
                              Text('暂无书籍', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: _books.length,
                          itemBuilder: (context, index) {
                            final item = _books[index];
                            final book = item['book'] as Book;
                            final size = item['size'] as int;
                            return _buildBookItem(book, size);
                          },
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildBookItem(Book book, int size) {
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
        clipBehavior: Clip.hardEdge,
        child: book.coverUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: book.coverUrl,
                width: 40,
                height: 56,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Container(
                  width: 40,
                  height: 56,
                  color: Theme.of(context).colorScheme.outlineVariant,
                  child: const Icon(Icons.book, size: 20),
                ),
              )
            : Container(
                width: 40,
                height: 56,
                color: Theme.of(context).colorScheme.outlineVariant,
                child: const Icon(Icons.book, size: 20),
              ),
      ),
      title: Text(book.name),
      subtitle: Text(
        book.author.isNotEmpty ? book.author : '未知作者',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _formatSize(size),
            style: TextStyle(
              fontSize: DesignTokens.fontCaption,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: '删除',
            onPressed: () => _showDeleteConfirm(book),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirm(Book book) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定要删除《${book.name}》吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await StorageService.instance.removeFromBookshelf(book.bookUrl);
              _loadBooks();
            },
            child: Text('确定', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
  }

  void _showClearAllConfirm() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空所有缓存'),
        content: const Text('确定要清空所有书籍缓存吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              // 清空所有书籍
              final bookDataList = StorageService.instance.getAllBooks();
              for (final bookData in bookDataList) {
                final book = Book.fromJson(bookData);
                await StorageService.instance.removeFromBookshelf(book.bookUrl);
              }
              _loadBooks();
            },
            child: Text('确定', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
  }
}
