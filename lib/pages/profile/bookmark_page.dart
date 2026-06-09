import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/reader_bookmark_service.dart';
import '../../services/storage_service.dart';
import '../../models/book.dart';

class BookmarkPage extends StatefulWidget {
  const BookmarkPage({super.key});

  @override
  State<BookmarkPage> createState() => _BookmarkPageState();
}

class _BookmarkPageState extends State<BookmarkPage> {
  final _bookmarkService = ReaderBookmarkService();
  List<Map<String, dynamic>> _bookmarks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
  }

  Future<void> _loadBookmarks() async {
    setState(() => _isLoading = true);

    // 获取所有书籍
    final bookDataList = StorageService.instance.getAllBooks();
    final allBookmarks = <Map<String, dynamic>>[];

    // 遍历每本书获取书签
    for (final bookData in bookDataList) {
      final book = Book.fromJson(bookData);
      final bookmarks = await _bookmarkService.list(book.bookUrl);
      for (final bookmark in bookmarks) {
        allBookmarks.add({
          'bookmark': bookmark,
          'book': book,
        });
      }
    }

    // 按创建时间排序（最新的在前）
    allBookmarks.sort((a, b) {
      final aTime = (a['bookmark'] as Bookmark).createdAt;
      final bTime = (b['bookmark'] as Bookmark).createdAt;
      return bTime.compareTo(aTime);
    });

    setState(() {
      _bookmarks = allBookmarks;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书签'),
        actions: [
          if (_bookmarks.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空书签',
              onPressed: () => _showClearConfirm(),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _bookmarks.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.bookmark_border, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('暂无书签', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _bookmarks.length,
                  itemBuilder: (context, index) {
                    final item = _bookmarks[index];
                    final bookmark = item['bookmark'] as Bookmark;
                    final book = item['book'] as Book;
                    return _buildBookmarkItem(bookmark, book);
                  },
                ),
    );
  }

  Widget _buildBookmarkItem(Bookmark bookmark, Book book) {
    return Dismissible(
      key: Key(bookmark.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Colors.red,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (direction) async {
        await _bookmarkService.remove(
          bookUrl: book.bookUrl,
          bookmarkId: bookmark.id,
        );
        _loadBookmarks();
      },
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: book.coverUrl.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: book.coverUrl,
                  width: 40,
                  height: 56,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Container(
                    width: 40,
                    height: 56,
                    color: Colors.grey[300],
                    child: const Icon(Icons.book, size: 20),
                  ),
                )
              : Container(
                  width: 40,
                  height: 56,
                  color: Colors.grey[300],
                  child: const Icon(Icons.book, size: 20),
                ),
        ),
        title: Text(book.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              bookmark.chapterTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              bookmark.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
            ),
          ],
        ),
        isThreeLine: true,
        trailing: Text(
          _formatTime(bookmark.createdAt),
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        onTap: () {
          // TODO: 跳转到阅读页面指定位置
          Navigator.pop(context, {
            'bookUrl': book.bookUrl,
            'chapterIndex': bookmark.chapterIndex,
          });
        },
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inDays == 0) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}天前';
    } else {
      return '${time.month}/${time.day}';
    }
  }

  void _showClearConfirm() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空书签'),
        content: const Text('确定要清空所有书签吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              // 清空所有书签
              final bookDataList = StorageService.instance.getAllBooks();
              for (final bookData in bookDataList) {
                final book = Book.fromJson(bookData);
                final bookmarks = await _bookmarkService.list(book.bookUrl);
                for (final bookmark in bookmarks) {
                  await _bookmarkService.remove(
                    bookUrl: book.bookUrl,
                    bookmarkId: bookmark.id,
                  );
                }
              }
              _loadBookmarks();
            },
            child: Text('确定', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
  }
}
