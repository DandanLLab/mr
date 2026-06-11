import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/book_source.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import 'source_engine/source_engine.dart';

/// 调试状态码（与 Legado 保持一致）
enum DebugState {
  error(-1),        // 错误
  warn(0),          // 警告
  normal(1),        // 正常
  searchSrc(10),    // 搜索源码
  exploreSrc(15),   // 发现源码
  bookSrc(20),      // 详情源码
  tocSrc(30),       // 目录源码
  contentSrc(40),   // 正文源码
  success(1000);    // 成功完成

  final int code;
  const DebugState(this.code);
}

/// 调试日志条目
class DebugLogEntry {
  final String message;
  final int state;
  final DateTime timestamp;
  final String? sourceHtml;

  DebugLogEntry({
    required this.message,
    required this.state,
    required this.timestamp,
    this.sourceHtml,
  });
}

/// 调试回调接口（参考 Legado 的 Debug.Callback）
abstract class DebugCallback {
  /// 打印日志
  /// [state] 状态码
  /// [msg] 日志消息
  void printLog(int state, String msg);
}

/// 书源调试服务（参考 Legado 的 Debug 单例对象）
/// 
/// 主要优化点：
/// 1. 单例模式，全局统一管理调试状态
/// 2. 支持调试取消
/// 3. 支持源码缓存
/// 4. 统一的日志格式
class SourceDebugService {
  static final SourceDebugService _instance = SourceDebugService._internal();
  static SourceDebugService get instance => _instance;
  SourceDebugService._internal();

  /// 当前调试回调
  DebugCallback? callback;

  /// 当前调试的书源 URL
  String? _debugSourceUrl;

  /// 调试任务
  Completer<void>? _debugTask;

  /// 是否已取消
  bool _isCancelled = false;

  /// 调试开始时间
  DateTime? _startTime;

  /// 源码缓存
  String _searchSrc = '';
  String _bookSrc = '';
  String _tocSrc = '';
  String _contentSrc = '';

  /// 获取源码
  String get searchSrc => _searchSrc;
  String get bookSrc => _bookSrc;
  String get tocSrc => _tocSrc;
  String get contentSrc => _contentSrc;

  /// 是否正在调试
  bool get isDebugging => _debugTask != null && !_debugTask!.isCompleted;

  /// 格式化时间戳
  String _formatTimestamp() {
    if (_startTime == null) return '';
    final elapsed = DateTime.now().difference(_startTime!);
    final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    final millis = (elapsed.inMilliseconds % 1000).toString().padLeft(3, '0');
    return '[$minutes:$seconds.$millis] ';
  }

  /// 记录日志
  void log(String message, {int state = 1, String? sourceHtml}) {
    if (_isCancelled && state > 0 && state != DebugState.success.code) return;

    // 保存源码
    if (sourceHtml != null && sourceHtml.isNotEmpty) {
      switch (state) {
        case 10:
          _searchSrc = sourceHtml;
          break;
        case 20:
          _bookSrc = sourceHtml;
          break;
        case 30:
          _tocSrc = sourceHtml;
          break;
        case 40:
          _contentSrc = sourceHtml;
          break;
      }
    }

    // 格式化日志（参考 Legado 格式）
    final timestamp = _formatTimestamp();
    final formattedMessage = '$timestamp$message';

    // 回调输出
    callback?.printLog(state, formattedMessage);

    // 调试输出
    if (kDebugMode) {
      debugPrint('[$state] $message');
    }
  }

  /// 取消调试
  void cancelDebug({bool destroy = false}) {
    _isCancelled = true;
    _debugTask?.complete();
    _debugTask = null;

    if (destroy) {
      _debugSourceUrl = null;
      callback = null;
    }
  }

  /// 开始调试
  /// [bookSource] 书源对象
  /// [key] 调试关键字
  Future<void> startDebug(BookSource bookSource, String key) async {
    // 重置状态
    cancelDebug();
    _isCancelled = false;
    _debugSourceUrl = bookSource.bookSourceUrl;
    _startTime = DateTime.now();
    _debugTask = Completer<void>();

    // 清空源码缓存
    _searchSrc = '';
    _bookSrc = '';
    _tocSrc = '';
    _contentSrc = '';

    // 清除规则解析缓存
    AnalyzeRule.clearCache();

    try {
      // 根据 key 格式判断调试类型
      if (key.startsWith('++')) {
        // 目录页调试
        final url = _extractUrl(key);
        log('⇒开始访问目录页:$url');
        await _debugToc(bookSource, url);
      } else if (key.startsWith('--')) {
        // 正文页调试
        final url = _extractUrl(key);
        log('⇒开始访问正文页:$url');
        await _debugContent(bookSource, url);
      } else if (key.contains('::') && !_looksLikeUrl(key)) {
        // 发现页调试
        final url = _extractUrl(key);
        log('⇒开始访问发现页:$url');
        await _debugExplore(bookSource, url);
      } else if (_looksLikeUrl(key)) {
        // 详情页调试
        log('⇒开始访问详情页:$key');
        await _debugBookInfo(bookSource, key);
      } else {
        // 搜索调试
        log('⇒开始搜索关键字:$key');
        await _debugSearch(bookSource, key);
      }
    } catch (e) {
      log('⇒错误: $e', state: DebugState.error.code);
    } finally {
      _debugTask?.complete();
      _debugTask = null;
    }
  }

  /// 提取 URL
  String _extractUrl(String key) {
    var url = key.trim();
    if (url.startsWith('++') || url.startsWith('--')) {
      url = url.substring(2).trim();
    }
    if (url.contains('::')) {
      url = url.split('::').last.trim();
    }
    return url;
  }

  /// 判断是否为 URL
  bool _looksLikeUrl(String key) {
    return key.startsWith('http://') ||
        key.startsWith('https://') ||
        key.startsWith('//') ||
        key.contains('://');
  }

  /// 搜索调试
  Future<void> _debugSearch(BookSource bookSource, String keyword) async {
    if (_isCancelled) return;

    log('︾开始解析搜索页');
    final webBook = WebBook(bookSource);

    try {
      final results = await webBook.searchBook(keyword);
      if (_isCancelled) return;

      final searchHtml = webBook.lastSearchHtml ?? '';
      final searchUrl = webBook.lastSearchUrl ?? '';
      final elementCount = webBook.lastSearchElementCount;

      log('≡获取成功:${searchUrl.isNotEmpty ? searchUrl : ""}',
          state: DebugState.searchSrc.code, sourceHtml: searchHtml);

      log('┌获取书籍列表');
      log('└列表大小:$elementCount');

      if (results.isEmpty) {
        log('︽未获取到书籍', state: DebugState.error.code);
        return;
      }

      // 输出第一条结果详情
      final item = results.first;
      _logBookItem(item);

      log('◇书籍总数:${results.length}');
      log('︽搜索页解析完成');

      // 继续调试详情页
      final bookUrl = '${item['bookUrl'] ?? ''}'.trim();
      if (bookUrl.isEmpty) {
        log('≡详情页链接为空，无法继续', state: DebugState.error.code);
        return;
      }
      await _debugBookInfo(bookSource, bookUrl, webBook: webBook);
    } catch (e) {
      log('⇒搜索失败: $e', state: DebugState.error.code);
    }
  }

  /// 发现调试
  Future<void> _debugExplore(BookSource bookSource, String exploreUrl) async {
    if (_isCancelled) return;

    log('︾开始解析发现页');
    final webBook = WebBook(bookSource);

    try {
      final results = await webBook.exploreBook(exploreUrl);
      if (_isCancelled) return;

      final exploreHtml = webBook.lastExploreHtml ?? '';
      final exploreResultUrl = webBook.lastExploreUrl ?? '';
      final elementCount = webBook.lastExploreElementCount;

      log('≡获取成功:${exploreResultUrl.isNotEmpty ? exploreResultUrl : ""}',
          state: DebugState.exploreSrc.code, sourceHtml: exploreHtml);

      log('┌获取书籍列表');
      log('└列表大小:$elementCount');

      if (results.isEmpty) {
        log('︽未获取到书籍', state: DebugState.error.code);
        return;
      }

      // 输出第一条结果详情
      final item = results.first;
      _logBookItem(item);

      log('◇书籍总数:${results.length}');
      log('︽发现页解析完成');

      // 继续调试详情页
      final bookUrl = '${item['bookUrl'] ?? ''}'.trim();
      if (bookUrl.isEmpty) {
        log('≡详情页链接为空，无法继续', state: DebugState.error.code);
        return;
      }
      await _debugBookInfo(bookSource, bookUrl, webBook: webBook);
    } catch (e) {
      log('⇒发现失败: $e', state: DebugState.error.code);
    }
  }

  /// 详情页调试
  Future<void> _debugBookInfo(
    BookSource bookSource,
    String bookUrl, {
    WebBook? webBook,
  }) async {
    if (_isCancelled) return;

    log('︾开始解析详情页');
    webBook ??= WebBook(bookSource);

    try {
      final Book? book = await webBook.getBookInfo(bookUrl);
      if (_isCancelled) return;

      final bookHtml = webBook.lastBookInfoHtml ?? '';
      log('≡获取成功:$bookUrl',
          state: DebugState.bookSrc.code, sourceHtml: bookHtml);

      if (book == null) {
        log('≡详情页解析失败', state: DebugState.error.code);
        return;
      }

      // 输出详情信息
      log('┌获取书名');
      log('└${book.name}');
      log('┌获取作者');
      log('└${book.author}');
      log('┌获取分类');
      final kind = '${book.kind ?? ''}'.trim();
      log(kind.isNotEmpty ? '└$kind' : '└<空>');
      log('┌获取字数');
      final wordCount = '${book.wordCount ?? ''}'.trim();
      log(wordCount.isNotEmpty ? '└$wordCount' : '└<空>');
      log('┌获取最新章节');
      final lastChapter = '${book.lastChapter ?? ''}'.trim();
      log(lastChapter.isNotEmpty ? '└$lastChapter' : '└<空>');
      log('┌获取简介');
      final intro = book.intro.trim();
      log(intro.isNotEmpty
          ? '└${intro.length > 200 ? '${intro.substring(0, 200)}...' : intro}'
          : '└<空>');
      log('┌获取封面链接');
      log('└${book.coverUrl}');
      log('┌获取目录链接');
      log('└${book.tocUrl ?? ''}');

      log('︽详情页解析完成');

      // 继续调试目录页
      final tocUrl = book.tocUrl?.trim();
      final effectiveTocUrl =
          (tocUrl != null && tocUrl.isNotEmpty) ? tocUrl : bookUrl;

      if (tocUrl == null || tocUrl.isEmpty) {
        log('≡目录链接为空，使用详情页作为目录页');
      }
      await _debugToc(bookSource, effectiveTocUrl, book: book, webBook: webBook);
    } catch (e) {
      log('⇒详情页解析失败: $e', state: DebugState.error.code);
    }
  }

  /// 目录页调试
  Future<void> _debugToc(
    BookSource bookSource,
    String tocUrl, {
    Book? book,
    WebBook? webBook,
  }) async {
    if (_isCancelled) return;

    log('︾开始解析目录页');
    webBook ??= WebBook(bookSource);

    try {
      final List<Chapter> chapters = await webBook.getChapterList(tocUrl, book: book);
      if (_isCancelled) return;

      final tocHtml = webBook.lastTocHtml ?? '';
      final elementCount = webBook.lastTocElementCount;
      log('≡获取成功:$tocUrl',
          state: DebugState.tocSrc.code, sourceHtml: tocHtml);

      log('┌获取目录列表');
      log('└列表大小:$elementCount');

      if (chapters.isEmpty) {
        log('◇章节列表为空', state: DebugState.error.code);
        return;
      }

      log('┌解析目录列表');
      log('└目录列表解析完成');

      // 过滤卷名，获取正文章节
      final contentChapters = chapters.where((c) => !c.isVolume).toList();
      final effectiveChapters =
          contentChapters.isNotEmpty ? contentChapters : chapters;

      if (effectiveChapters.isEmpty) {
        log('≡没有正文章节', state: DebugState.error.code);
        return;
      }

      // 输出首章信息
      final firstContent = effectiveChapters.first;
      log('≡首章信息');
      log('◇章节名称:${firstContent.title}');
      log('◇章节链接:${firstContent.url ?? ""}');
      if (firstContent.wordCount != null) {
        log('◇章节信息:${firstContent.tag ?? ""} ${firstContent.wordCount}');
        log('⇒已识别到章节信息中的字数');
      } else if (firstContent.tag != null && firstContent.tag!.isNotEmpty) {
        log('◇章节信息:${firstContent.tag}');
      }
      log('◇是否VIP:${firstContent.isVip}');
      log('◇是否购买:${firstContent.isPay}');

      log('◇目录总数:${chapters.length}');
      log('︽目录页解析完成');

      // 继续调试正文页
      final chapterUrl = firstContent.url?.trim();
      if (chapterUrl != null && chapterUrl.isNotEmpty) {
        await _debugContent(bookSource, chapterUrl,
            book: book, chapter: firstContent, webBook: webBook);
      } else {
        log('≡首章链接为空，无法跳转正文', state: DebugState.error.code);
      }
    } catch (e) {
      log('⇒目录页解析失败: $e', state: DebugState.error.code);
    }
  }

  /// 正文页调试
  Future<void> _debugContent(
    BookSource bookSource,
    String chapterUrl, {
    Book? book,
    Chapter? chapter,
    WebBook? webBook,
  }) async {
    if (_isCancelled) return;

    log('︾开始解析正文页');
    webBook ??= WebBook(bookSource);

    try {
      final String? content = await webBook.getContent(
        chapterUrl,
        book: book,
        chapter: chapter,
      );
      if (_isCancelled) return;

      final contentHtml = webBook.lastContentHtml ?? '';
      log('≡获取成功:$chapterUrl',
          state: DebugState.contentSrc.code, sourceHtml: contentHtml);

      if (content == null) {
        log('≡正文解析失败: 返回null', state: DebugState.error.code);
        return;
      }

      final trimmedContent = content.trim();
      if (trimmedContent.isEmpty) {
        log('≡正文解析失败: 内容为空', state: DebugState.error.code);
        return;
      }

      log('┌获取章节名称');
      log('└${chapter?.title ?? ""}');
      log('┌获取正文内容');
      log('└\n$trimmedContent');
      log('︽正文页解析完成');
      log('≡解析完成', state: DebugState.success.code);
    } catch (e) {
      log('⇒正文页解析失败: $e', state: DebugState.error.code);
    }
  }

  /// 输出书籍项信息
  void _logBookItem(Map<String, dynamic> item) {
    log('┌获取书名');
    log('└${item['name'] ?? ''}');
    log('┌获取作者');
    log('└${item['author'] ?? ''}');
    log('┌获取分类');
    final kind = '${item['kind'] ?? ''}'.trim();
    log(kind.isNotEmpty ? '└$kind' : '└<空>');
    log('┌获取字数');
    final wordCount = '${item['wordCount'] ?? ''}'.trim();
    log(wordCount.isNotEmpty ? '└$wordCount' : '└<空>');
    log('┌获取最新章节');
    final lastChapter = '${item['lastChapter'] ?? ''}'.trim();
    log(lastChapter.isNotEmpty ? '└$lastChapter' : '└<空>');
    log('┌获取简介');
    final intro = '${item['intro'] ?? ''}'.trim();
    log(intro.isNotEmpty
        ? '└${intro.length > 100 ? '${intro.substring(0, 100)}...' : intro}'
        : '└<空>');
    log('┌获取封面链接');
    log('└${item['coverUrl'] ?? ''}');
    log('┌获取详情页链接');
    log('└${item['bookUrl'] ?? ''}');
  }
}
