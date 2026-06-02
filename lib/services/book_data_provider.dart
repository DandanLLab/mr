import '../models/book.dart';
import '../models/chapter.dart';
import 'local_book/local_book_service.dart';
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

/// 在线书籍数据提供者（预留接口）
class OnlineBookDataProvider implements BookDataProvider {
  final String sourceUrl;

  OnlineBookDataProvider({required this.sourceUrl});

  @override
  Future<Book?> getBookInfo(String bookUrl) async {
    // TODO: 通过书源获取在线书籍信息
    throw UnimplementedError('在线书籍功能尚未实现');
  }

  @override
  Future<List<Chapter>> getChapterList(Book book) async {
    // TODO: 通过书源获取在线章节列表
    throw UnimplementedError('在线书籍功能尚未实现');
  }

  @override
  Future<String?> getContent(Book book, Chapter chapter) async {
    // TODO: 通过书源获取在线章节内容
    throw UnimplementedError('在线书籍功能尚未实现');
  }

  @override
  Future<List<Book>> searchBooks(String keyword) async {
    // TODO: 通过书源搜索在线书籍
    throw UnimplementedError('在线书籍功能尚未实现');
  }

  @override
  Future<void> saveBook(Book book) {
    return StorageService.instance.saveBook(book);
  }
}
