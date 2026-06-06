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

BookDataProvider createBookDataProvider(Book book) {
  if (book.originType == BookOriginType.online) {
    final sourceUrl = book.sourceUrl;
    if (sourceUrl == null || sourceUrl.isEmpty) {
      throw StateError('在线书籍缺少 sourceUrl: ${book.bookUrl}');
    }
    return OnlineBookDataProvider(sourceUrl: sourceUrl);
  }
  return LocalBookDataProvider();
}

Book mergeBookMetadata(Book primary, Book fallback) {
  String prefer(String value, String fallbackValue) =>
      value.trim().isNotEmpty ? value : fallbackValue;
  String? preferNullable(String? value, String? fallbackValue) =>
      value != null && value.trim().isNotEmpty ? value : fallbackValue;

  final primaryTags = primary.tags ?? const <String>[];
  final fallbackTags = fallback.tags ?? const <String>[];
  final kind = preferNullable(primary.kind, fallback.kind);

  return primary.copyWith(
    name: prefer(primary.name, fallback.name),
    author: prefer(primary.author, fallback.author),
    coverUrl: prefer(primary.coverUrl, fallback.coverUrl),
    intro: prefer(primary.intro, fallback.intro),
    mediaType: fallback.mediaType,
    originType: fallback.originType,
    sourceUrl: preferNullable(primary.sourceUrl, fallback.sourceUrl),
    sourceName: preferNullable(primary.sourceName, fallback.sourceName),
    kind: kind,
    lastChapter: preferNullable(primary.lastChapter, fallback.lastChapter),
    totalChapterNum: primary.totalChapterNum ?? fallback.totalChapterNum,
    status: preferNullable(primary.status, fallback.status),
    tags: primaryTags.isNotEmpty
        ? primaryTags
        : fallbackTags.isNotEmpty
            ? fallbackTags
            : _tagsFromKind(kind),
    tocUrl: preferNullable(primary.tocUrl, fallback.tocUrl),
    wordCount: preferNullable(primary.wordCount, fallback.wordCount),
  );
}

List<String>? _tagsFromKind(String? kind) {
  if (kind == null || kind.trim().isEmpty) return null;
  final tags = kind
      .split(RegExp(r'[,，/|·\s]+'))
      .map((tag) => tag.trim())
      .where((tag) => tag.isNotEmpty)
      .toSet()
      .toList();
  return tags.isEmpty ? null : tags;
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
    final configuredTocUrl = book.tocUrl?.trim();
    final tocUrl = configuredTocUrl == null || configuredTocUrl.isEmpty
        ? book.bookUrl
        : configuredTocUrl;
    return webBook.getChapterList(tocUrl, book: book);
  }

  @override
  Future<String?> getContent(Book book, Chapter chapter) async {
    if (chapter.isVolume && (chapter.url ?? '').startsWith(chapter.title)) {
      return '';
    }
    final webBook = await _getWebBook();
    if (chapter.url != null) {
      return webBook.getContent(chapter.url!, book: book, chapter: chapter);
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
