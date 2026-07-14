import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../services/reader_bookmark_service.dart';
import '../../services/storage_service.dart';
import '../../services/image_decode_provider.dart';
import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../routes/app_routes.dart';
import '../../utils/design_tokens.dart';

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
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.bookmark_border, size: 64, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(height: DesignTokens.spacingLg),
                      Text('暂无书签', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
        padding: const EdgeInsets.only(right: DesignTokens.spacingLg),
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
          borderRadius: BorderRadius.circular(DesignTokens.actionRadius),
          clipBehavior: Clip.hardEdge,
          child: book.coverUrl.isNotEmpty
              ? _buildCover(book)
              : Container(
                  width: 40,
                  height: 56,
                  color: Theme.of(context).colorScheme.outlineVariant,
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
                fontSize: DesignTokens.fontCaption,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: DesignTokens.spacingXs),
            Text(
              bookmark.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: DesignTokens.fontCaption,
                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
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
          final routeName = switch (book.mediaType) {
            MediaType.video => AppRoutes.videoPlayer,
            MediaType.audio => AppRoutes.audioPlayer,
            MediaType.comic => AppRoutes.comicReader,
            MediaType.novel => AppRoutes.novelReader,
          };
          final args = <String, dynamic>{
            'bookUrl': book.bookUrl,
            'bookId': book.bookUrl,
            'bookData': book,
            'resumeProgress': false,
          };
          switch (book.mediaType) {
            case MediaType.audio:
              args['trackId'] = bookmark.chapterIndex.toString();
            case MediaType.video:
              args['episodeId'] = bookmark.chapterIndex.toString();
            case MediaType.comic:
            case MediaType.novel:
              args['chapterIndex'] = bookmark.chapterIndex;
          }
          Navigator.pushNamed(context, routeName, arguments: args);
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

  /// 根据 Book 的 sourceUrl 查找书源（用于封面解密判断和请求头构建）
  BookSource? _findBookSource(Book book) {
    final sourceUrl = book.sourceUrl;
    if (sourceUrl == null || sourceUrl.isEmpty) return null;
    final sourceData = StorageService.instance.getBookSource(sourceUrl);
    if (sourceData == null) return null;
    try {
      return BookSource.fromJson(sourceData);
    } catch (_) {
      return null;
    }
  }

  /// 根据书源构建封面图请求头
  Map<String, String> _buildCoverHeaders(BookSource source) {
    final headers = <String, String>{};
    final headerStr = source.header;
    if (headerStr != null && headerStr.isNotEmpty) {
      try {
        final decoded = json.decode(headerStr);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            final val = value.toString();
            if (val.isNotEmpty) {
              headers[key.toString()] = val;
            }
          });
        }
      } catch (_) {
        for (final line in headerStr.split('\n')) {
          final parts = line.split(':');
          if (parts.length >= 2) {
            final key = parts[0].trim();
            final val = parts.sublist(1).join(':').trim();
            if (key.isNotEmpty && val.isNotEmpty) {
              headers[key] = val;
            }
          }
        }
      }
    }
    final sourceUrl = source.bookSourceUrl;
    if (sourceUrl.isNotEmpty) {
      final uri = Uri.tryParse(sourceUrl);
      if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
        headers.putIfAbsent('Referer', () => '${uri.scheme}://${uri.host}');
      }
    }
    headers.putIfAbsent(
      'User-Agent',
      () => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    );
    return headers;
  }

  /// 构建封面图（书源配置了 coverDecodeJs 时走解密链路）
  Widget _buildCover(Book book) {
    final source = _findBookSource(book);
    if (source != null && DecodedImageProvider.needsDecode(source, true)) {
      return Image(
        image: DecodedImageProvider(
          url: book.coverUrl,
          headers: _buildCoverHeaders(source),
          source: source,
          isCover: true,
          book: book,
        ),
        width: 40,
        height: 56,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => Container(
          width: 40,
          height: 56,
          color: Theme.of(context).colorScheme.outlineVariant,
          child: const Icon(Icons.book, size: 20),
        ),
      );
    }
    return CachedNetworkImage(
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
    );
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
