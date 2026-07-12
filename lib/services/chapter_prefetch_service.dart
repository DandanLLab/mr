import 'dart:async';
import 'dart:collection';
import '../models/book.dart';
import '../models/chapter.dart';
import 'book_data_provider.dart';
import 'chapter_cache_service.dart';

/// 章节预取缓存服务（Phase 3：网络 I/O 与解密流水线化）
///
/// 核心思想：
/// - 用户阅读当前章节时，后台并发预取后续 N 章
/// - 每章获取完成立即入内存缓存（不等待全部完成）
/// - 用户翻页时若命中内存缓存则瞬时返回（跳过文件 I/O 与网络）
/// - 配合 [ChapterCacheService] 文件缓存形成两级缓存
///
/// 内存模型：LRU 缓存，默认 50 章
/// 并发模型：默认 4 路并发预取（可配置）
class ChapterPrefetchService {
  static final ChapterPrefetchService instance =
      ChapterPrefetchService._internal();
  ChapterPrefetchService._internal();

  /// 内存 LRU 缓存：key = bookUrl|chapterUrl
  final LinkedHashMap<String, String> _memoryCache = LinkedHashMap();

  /// 正在预取的章节 key 集合（避免重复预取）
  final Set<String> _prefetching = {};

  /// 默认内存缓存上限（章）
  static const int _maxMemoryCacheSize = 50;

  /// 默认预取并发数
  static const int _defaultConcurrency = 4;

  int get memoryCacheSize => _memoryCache.length;
  int get prefetchingCount => _prefetching.length;

  /// 生成缓存 key
  String _key(String bookUrl, String chapterUrl) => '$bookUrl|$chapterUrl';

  /// 从内存缓存读取（命中时提升到 LRU 队尾）
  String? getCachedContent(String bookUrl, String chapterUrl) {
    final k = _key(bookUrl, chapterUrl);
    final content = _memoryCache[k];
    if (content != null) {
      // LRU 提升
      _memoryCache.remove(k);
      _memoryCache[k] = content;
    }
    return content;
  }

  /// 预取章节列表（后台并发，每章完成即入缓存）
  ///
  /// [book] 书籍
  /// [chapters] 要预取的章节列表（按阅读顺序）
  /// [provider] 数据提供者
  /// [allChapters] 全部章节（用于熔断断点）
  /// [concurrency] 并发数
  Future<void> prefetchChapters({
    required Book book,
    required List<Chapter> chapters,
    required BookDataProvider provider,
    List<Chapter>? allChapters,
    int concurrency = _defaultConcurrency,
  }) async {
    if (chapters.isEmpty || book.bookUrl == null) return;

    final bookUrl = book.bookUrl!;
    final toFetch = <Chapter>[];
    for (final ch in chapters) {
      if (ch.url == null || ch.isVolume) continue;
      final k = _key(bookUrl, ch.url!);
      if (_memoryCache.containsKey(k) || _prefetching.contains(k)) continue;
      toFetch.add(ch);
    }
    if (toFetch.isEmpty) return;

    // 按并发数分批启动，每批内并发
    for (int i = 0; i < toFetch.length; i += concurrency) {
      final batch = toFetch.skip(i).take(concurrency).toList();
      final futures = <Future<void>>[];
      for (final chapter in batch) {
        final k = _key(bookUrl, chapter.url!);
        _prefetching.add(k);
        futures.add(_fetchAndCache(
          book: book,
          chapter: chapter,
          provider: provider,
          allChapters: allChapters,
        ).whenComplete(() => _prefetching.remove(k)));
      }
      // 等待当前批次完成再启动下一批（控制并发压力）
      await Future.wait(futures);
    }
  }

  /// 获取单章内容（优先内存缓存 → 文件缓存 → 网络）
  ///
  /// 与 [BookDataProvider.getContent] 签名对齐，可直接替换调用
  Future<String?> getContent(
    Book book,
    Chapter chapter, {
    List<Chapter>? allChapters,
    BookDataProvider? provider,
  }) async {
    if (chapter.url == null) return null;
    final bookUrl = book.bookUrl;
    if (bookUrl == null) return null;
    final k = _key(bookUrl, chapter.url!);

    // 1. 内存缓存
    final cached = getCachedContent(bookUrl, chapter.url!);
    if (cached != null && cached.isNotEmpty) return cached;

    // 2. 文件缓存
    if (book.originType == BookOriginType.online) {
      final fileCached =
          await ChapterCacheService.instance.readChapterContent(book, chapter);
      if (fileCached != null && fileCached.isNotEmpty) {
        _putMemoryCache(k, fileCached);
        return fileCached;
      }
    }

    // 3. 网络
    if (provider == null) return null;
    final content = await provider.getContent(book, chapter,
        allChapters: allChapters);
    if (content != null && content.isNotEmpty) {
      _putMemoryCache(k, content);
      // 异步写回文件缓存
      if (book.originType == BookOriginType.online) {
        unawaited(
            ChapterCacheService.instance.saveChapterContent(book, chapter, content));
      }
    }
    return content;
  }

  /// 单章获取并缓存
  Future<void> _fetchAndCache({
    required Book book,
    required Chapter chapter,
    required BookDataProvider provider,
    List<Chapter>? allChapters,
  }) async {
    try {
      final content = await provider.getContent(book, chapter,
          allChapters: allChapters);
      if (content != null && content.isNotEmpty) {
        final k = _key(book.bookUrl!, chapter.url!);
        _putMemoryCache(k, content);
        // 异步写回文件缓存
        if (book.originType == BookOriginType.online) {
          unawaited(ChapterCacheService.instance
              .saveChapterContent(book, chapter, content));
        }
      }
    } catch (_) {
      // 预取失败静默处理（用户翻到时会重试）
    }
  }

  /// 写入内存缓存（LRU 淘汰）
  void _putMemoryCache(String key, String content) {
    if (_memoryCache.length >= _maxMemoryCacheSize) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _memoryCache[key] = content;
  }

  /// 计算需要预取的章节索引列表
  ///
  /// 从 [currentIndex] 开始，向后取 [lookahead] 个可读章节
  static List<int> computePrefetchIndices(
    int currentIndex,
    int totalChapters,
    int lookahead, {
    bool Function(int)? isReadable,
  }) {
    final result = <int>[];
    for (int i = currentIndex + 1; i < totalChapters && result.length < lookahead; i++) {
      if (isReadable == null || isReadable(i)) {
        result.add(i);
      }
    }
    return result;
  }

  /// 清除指定书籍的内存缓存
  void clearBook(String bookUrl) {
    final prefix = '$bookUrl|';
    _memoryCache.removeWhere((key, _) => key.startsWith(prefix));
    _prefetching.removeWhere((key) => key.startsWith(prefix));
  }

  /// 清除全部内存缓存
  void clearAll() {
    _memoryCache.clear();
    _prefetching.clear();
  }
}
