import '../models/book.dart';
import '../models/book_source.dart';
import '../models/chapter.dart';
import 'local_book/local_book_service.dart';
import 'source_engine/source_engine.dart';
import 'storage_service.dart';

/// 书籍数据提供者抽象接口
/// 预留在线书籍接口，本地和在线书籍统一抽象
abstract class BookDataProvider {
  /// 获取书籍信息
  Future<Book?> getBookInfo(String bookUrl);

  /// 获取章节列表
  Future<List<Chapter>> getChapterList(Book book);

  /// 获取章节内容
  Future<String?> getContent(Book book, Chapter chapter);

  /// 搜索书籍
  Future<List<Book>> searchBooks(String keyword);

  /// 保存书籍
  Future<void> saveBook(Book book);
}

/// 本地书籍数据提供者
class LocalBookDataProvider implements BookDataProvider {
  @override
  Future<Book?> getBookInfo(String bookUrl) async {
    final data = StorageService.instance.getBook(bookUrl);
    if (data == null) return null;
    return Book.fromJson(data);
  }

  @override
  Future<List<Chapter>> getChapterList(Book book) {
    return LocalBookService.instance.getChapterList(book);
  }

  @override
  Future<String?> getContent(Book book, Chapter chapter) {
    return LocalBookService.instance.getContent(book, chapter);
  }

  @override
  Future<List<Book>> searchBooks(String keyword) async {
    // 本地书籍不支持搜索
    return [];
  }

  @override
  Future<void> saveBook(Book book) {
    return StorageService.instance.saveBook(book);
  }
}

/// 在线书籍数据提供者
class OnlineBookDataProvider implements BookDataProvider {
  final String sourceUrl;

  OnlineBookDataProvider({required this.sourceUrl});

  BookSource? _source;
  WebBook? _webBook;

  Future<WebBook> _getWebBook() async {
    if (_webBook != null) return _webBook!;
    final sourceData = StorageService.instance.getBookSource(sourceUrl);
    if (sourceData == null) throw Exception('书源不存在: $sourceUrl');
    _source = BookSource.fromJson(sourceData);
    _webBook = WebBook(_source!);
    return _webBook!;
  }

  @override
  Future<Book?> getBookInfo(String bookUrl) async {
    final webBook = await _getWebBook();
    return webBook.getBookInfo(bookUrl);
  }

  @override
  Future<List<Chapter>> getChapterList(Book book) async {
    final webBook = await _getWebBook();
    final tocUrl = book.tocUrl ?? book.bookUrl;
    return webBook.getChapterList(tocUrl);
  }

  @override
  Future<String?> getContent(Book book, Chapter chapter) async {
    if (chapter.isVolume && (chapter.url ?? '').startsWith(chapter.title)) {
      return '';
    }
    final webBook = await _getWebBook();
    if (chapter.url != null) {
      return webBook.getContent(chapter.url!);
    }
    return null;
  }

  @override
  Future<List<Book>> searchBooks(String keyword) async {
    final webBook = await _getWebBook();
    final results = await webBook.searchBook(keyword);
    return results.map((data) => Book.fromJson(data)).toList();
  }

  @override
  Future<void> saveBook(Book book) {
    return StorageService.instance.saveBook(book);
  }
}
