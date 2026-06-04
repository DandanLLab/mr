import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import '../../models/book_source.dart';
import '../../models/book.dart';
import '../../models/chapter.dart';
import '../app_logger.dart';
import 'analyze_rule.dart';
import 'analyze_url.dart' as legado_url;
import 'web_proxy.dart';
import 'proxy_service.dart';
import '../native/js_engine.dart';
import '../native/platform_channel.dart';

/// URL 请求选项（类似 OkHttp 的 Request.Builder）
class UrlOption {
  final String? method;
  final Map<String, String>? headers;
  final String? body;
  final String? charset;
  final int retry;
  final bool useWebView;
  final int? connectTimeout;
  final int? readTimeout;

  UrlOption({
    this.method,
    this.headers,
    this.body,
    this.charset,
    this.retry = 0,
    this.useWebView = false,
    this.connectTimeout,
    this.readTimeout,
  });

  factory UrlOption.fromJson(Map<String, dynamic> json) {
    return UrlOption(
      method: json['method']?.toString(),
      headers: json['headers'] != null
          ? Map<String, String>.from(json['headers'] as Map)
          : null,
      body: json['body']?.toString(),
      charset: json['charset']?.toString(),
      retry: json['retry'] as int? ?? 0,
      useWebView: json['webView'] == true || json['webView'] == 'true',
      connectTimeout: json['connectTimeout'] as int?,
      readTimeout: json['readTimeout'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (method != null) 'method': method,
      if (headers != null) 'headers': headers,
      if (body != null) 'body': body,
      if (charset != null) 'charset': charset,
      if (retry > 0) 'retry': retry,
      if (useWebView) 'webView': useWebView,
      if (connectTimeout != null) 'connectTimeout': connectTimeout,
      if (readTimeout != null) 'readTimeout': readTimeout,
    };
  }
}

/// 解析后的 URL（类似 OkHttp 的 Request）
class ParsedUrl {
  final String url;
  final UrlOption? option;

  ParsedUrl({required this.url, this.option});
}

/// 响应包装类（类似 OkHttp 的 Response）
class StrResponse {
  final String url;
  final String body;
  final int statusCode;
  final Map<String, String> headers;
  final Response? raw;

  StrResponse({
    required this.url,
    required this.body,
    this.statusCode = 200,
    this.headers = const {},
    this.raw,
  });

  bool get isSuccessful => statusCode >= 200 && statusCode < 300;
  String? header(String name) => headers[name];
}

/// 网络请求客户端（类似 OkHttp 的 OkHttpClient）
class HttpClient {
  static final HttpClient _instance = HttpClient._internal();
  static HttpClient get instance => _instance;
  HttpClient._internal();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 30),
    // 接受所有状态码，不抛异常（书源网站可能返回 301/302/403/503 等）
    validateStatus: (status) => status != null && status < 600,
    // 跟随重定向
    followRedirects: true,
    maxRedirects: 5,
    // 响应类型默认 plain
    responseType: ResponseType.plain,
  ));

  /// 执行请求（类似 OkHttp 的 Call.execute）
  ///
  /// Android 端优先使用 OkHttp（NativeChannel），更可靠：
  /// - OkHttp 原生支持 HTTP/2、连接池、自动重试
  /// - 不受 Dart VM 网络栈限制
  /// - 正确处理编码和重定向
  Future<StrResponse> execute(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    String? charset,
    Duration? connectTimeout,
    Duration? readTimeout,
  }) async {
    try {
      // Web 端受 CORS 限制，必须走代理
      if (kIsWeb) {
        final requestUrl =
            'http://localhost:${ProxyService.instance.port}/$url';
        final html = await WebProxy.instance.fetch(
          requestUrl,
          method: method,
          headers: headers,
          body: body,
        );
        return StrResponse(
          url: url,
          body: html,
          statusCode: 200,
          headers: {},
        );
      }

      // Android/iOS 原生端：优先使用 OkHttp（NativeChannel）
      if (!kIsWeb) {
        try {
          final timeoutMs =
              (connectTimeout ?? const Duration(seconds: 15)).inMilliseconds;
          String? okResult;

          debugPrint('🔵 [OkHttp] $method $url');
          AppLogger.instance.logRequest(method, url, headers: headers);
          if (method.toUpperCase() == 'POST') {
            okResult = await NativeChannel.instance.httpPost(
              url,
              body: body,
              headers: headers,
              timeoutMs: timeoutMs,
            );
          } else {
            okResult = await NativeChannel.instance.httpGet(
              url,
              headers: headers,
              timeoutMs: timeoutMs,
            );
          }

          debugPrint(
              '🔵 [OkHttp] 响应: ${okResult != null ? "${okResult.length} chars" : "null"}');
          AppLogger.instance.logResponse(url, 200, okResult?.length ?? 0);
          if (okResult != null && okResult.isNotEmpty) {
            return StrResponse(
              url: url,
              body: okResult,
              statusCode: 200,
              headers: headers ?? {},
            );
          }

          // OkHttp 返回 null 或空字符串，降级到 Dio
          debugPrint('⚠️ OkHttp 返回空，降级到 Dio: $url');
        } catch (e) {
          debugPrint('⚠️ OkHttp 异常，降级到 Dio: $e');
        }
      }

      // 降级方案：使用 Dio
      final options = Options(
        method: method,
        headers: headers,
        responseType: ResponseType.plain,
        receiveTimeout: readTimeout,
        sendTimeout: connectTimeout,
      );

      final response = await _dio.request<String>(
        url,
        data: body,
        options: options,
      );

      return StrResponse(
        url: response.realUri.toString(),
        body: response.data ?? '',
        statusCode: response.statusCode ?? 200,
        headers: response.headers.map.map(
          (key, value) => MapEntry(key, value.first),
        ),
        raw: response,
      );
    } on DioException catch (e) {
      debugPrint('❌ HTTP Error: ${e.type} - ${e.message}');
      if (e.response != null) {
        return StrResponse(
          url: url,
          body: e.response?.data?.toString() ?? '',
          statusCode: e.response?.statusCode ?? 500,
          headers: {},
        );
      }
      // 网络错误（连接超时、DNS解析失败等），返回空响应而不是抛异常
      debugPrint('❌ 网络请求失败: ${e.type} - ${e.message}');
      return StrResponse(
        url: url,
        body: '',
        statusCode: 0,
        headers: {},
      );
    } catch (e) {
      debugPrint('❌ 请求异常: $e');
      return StrResponse(
        url: url,
        body: '',
        statusCode: 0,
        headers: {},
      );
    }
  }
}

/// 书源网络请求类（参考 legados 的 WebBook）
class WebBook {
  final BookSource source;
  final HttpClient _client;

  // 缓存最近的响应源码
  String? lastSearchHtml;
  String? lastExploreHtml;
  String? lastBookInfoHtml;
  String? lastTocHtml;
  String? lastContentHtml;

  WebBook(this.source) : _client = HttpClient.instance;

  // ===== JS 辅助方法 =====

  /// 判断规则是否包含 JS 代码
  bool _isJsRule(String? rule) {
    if (rule == null || rule.isEmpty) return false;
    return rule.startsWith('@js:') ||
        rule.startsWith('<js>') ||
        rule.startsWith('@rhino:') ||
        rule.startsWith('@quickjs:') ||
        rule.startsWith('@java:') ||
        rule.startsWith('@ts:') ||
        rule.contains('<js>') ||
        rule.contains('{{');
  }

  /// 执行 JS 规则并返回字符串结果
  Future<String?> _executeJs(String jsCode,
      {String? result, String? baseUrl}) async {
    try {
      AppLogger.instance.logJsExecute('分流', jsCode);
      final jsResult = await JsEngine.instance.processJsRule(
        result ?? '',
        jsCode,
        baseUrl: baseUrl ?? source.bookSourceUrl,
        sourceEngine: source.engineType,
      );
      AppLogger.instance.logJsResult('分流', jsResult);
      return jsResult;
    } catch (e) {
      AppLogger.instance.logJsError('分流', e.toString());
      return null;
    }
  }

  /// 执行 JS 规则（带书籍上下文）
  Future<String?> _executeJsWithBook(
    String jsCode, {
    String? result,
    String? baseUrl,
    Map<String, dynamic>? book,
    Map<String, dynamic>? chapter,
  }) async {
    try {
      return await JsEngine.instance.processJsWithBook(
        jsCode,
        book: book,
        chapter: chapter,
        content: result,
        sourceEngine: source.engineType,
      );
    } catch (e) {
      debugPrint('❌ JS执行失败(带上下文): $e');
      return null;
    }
  }

  /// 解析可能包含 JS 的 URL
  /// 支持 @js: 前缀的动态 URL 生成
  Future<String> _resolveUrl(String url, {String? keyword, int? page}) async {
    if (_isJsRule(url)) {
      final jsResult = await _executeJs(url, baseUrl: source.bookSourceUrl);
      if (jsResult != null && jsResult.isNotEmpty) {
        // JS 返回的 URL 可能还需要替换占位符
        var resolved = jsResult;
        if (keyword != null) {
          resolved = resolved
              .replaceAll('{{key}}', Uri.encodeComponent(keyword))
              .replaceAll('{{searchKey}}', Uri.encodeComponent(keyword));
        }
        if (page != null) {
          resolved = resolved.replaceAll('{{page}}', page.toString());
        }
        return resolved;
      }
    }
    return url;
  }

  /// 将相对链接拼接成绝对链接
  /// [url] 待拼接的链接（可能是相对路径如 /book/123.html）
  /// [baseUrl] 基准链接（当前页面的完整 URL）
  /// 拼接规则：
  ///   - 已经是绝对路径（http/https开头）→ 直接返回
  ///   - 以 // 开头 → 补上协议
  ///   - 以 / 开头 → 拼接 baseUrl 的 origin
  ///   - 以 ./ 或 ../ 开头 → 相对于 baseUrl 路径解析
  ///   - 其他 → 相对于 baseUrl 路径拼接
  static String resolveUrl(String? url, String baseUrl) {
    if (url == null || url.trim().isEmpty) return '';
    url = url.trim();

    // 已经是绝对路径
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }

    // 以 // 开头，补上协议
    if (url.startsWith('//')) {
      final baseUri = Uri.tryParse(baseUrl);
      return '${baseUri?.scheme ?? 'https'}:$url';
    }

    // 解析 baseUrl
    final baseUri = Uri.tryParse(baseUrl);
    if (baseUri == null) return url;

    if (url.startsWith('/')) {
      // 以 / 开头，拼接 origin
      return '${baseUri.scheme}://${baseUri.host}${baseUri.hasPort ? ':${baseUri.port}' : ''}$url';
    }

    // 相对路径（./ ../ 或其他），相对于 baseUrl 的路径解析
    final basePath = baseUri.path;
    final lastSlash = basePath.lastIndexOf('/');
    final dir = lastSlash >= 0 ? basePath.substring(0, lastSlash + 1) : '/';
    final resolvedPath = _normalizePath('$dir$url');

    return '${baseUri.scheme}://${baseUri.host}${baseUri.hasPort ? ':${baseUri.port}' : ''}$resolvedPath';
  }

  /// 规范化路径（处理 ./ 和 ../）
  static String _normalizePath(String path) {
    final segments = path.split('/');
    final result = <String>[];

    for (final seg in segments) {
      if (seg == '..') {
        if (result.isNotEmpty && result.last != '..') {
          result.removeLast();
        }
      } else if (seg != '.' && seg.isNotEmpty) {
        result.add(seg);
      }
    }

    return '/${result.join('/')}';
  }

  /// 解析可能包含 JS 的请求头
  Future<Map<String, String>> _resolveHeaders(String? headerStr) async {
    final headers = <String, String>{};

    if (headerStr == null || headerStr.isEmpty) return headers;

    // 尝试 JSON 解析
    try {
      final decoded = json.decode(headerStr);
      if (decoded is Map) {
        decoded.forEach((key, value) {
          final val = value.toString();
          // 如果值包含 JS 表达式，执行它
          if (_isJsRule(val)) {
            final jsResult = JsEngine.instance.executeSync(val, null,
                baseUrl: source.bookSourceUrl, sourceEngine: source.engineType);
            headers[key.toString()] = jsResult?.toString() ?? val;
          } else {
            headers[key.toString()] = val;
          }
        });
        return headers;
      }
    } catch (_) {
      // 非 JSON 格式，按行解析
      for (final line in headerStr.split('\n')) {
        final parts = line.split(':');
        if (parts.length >= 2) {
          final key = parts[0].trim();
          var val = parts.sublist(1).join(':').trim();
          if (_isJsRule(val)) {
            final jsResult = JsEngine.instance.executeSync(val, null,
                baseUrl: source.bookSourceUrl, sourceEngine: source.engineType);
            val = jsResult?.toString() ?? val;
          }
          headers[key] = val;
        }
      }
    }

    return headers;
  }

  /// 加载书源 JS 库（jsLib 字段）
  Future<void> _loadJsLib() async {
    final jsLib = source.jsLib;
    if (jsLib == null || jsLib.isEmpty) return;
    try {
      // jsLib 是一段 JS 代码，注入到引擎中
      JsEngine.instance.evaluate(jsLib);
      debugPrint('📚 已加载书源JS库: ${source.bookSourceName}');
    } catch (e) {
      debugPrint('❌ 加载书源JS库失败: $e');
    }
  }

  // ===== URL 解析 =====

  /// 解析 URL 和选项
  ParsedUrl _parseUrlWithOption(
    String urlWithOption, {
    String? keyword,
    int? page,
  }) {
    try {
      final parsed = legado_url.AnalyzeUrl.parse(
        urlWithOption,
        baseUrl: source.bookSourceUrl,
        keyword: keyword,
        page: page,
      );
      final option = parsed.option;
      return ParsedUrl(
        url: parsed.url,
        option: option == null
            ? null
            : UrlOption(
                method: option.method,
                headers: option.headers,
                body: option.body,
                charset: option.charset,
                retry: option.retry,
                useWebView: option.useWebView,
                connectTimeout: option.connectTimeout,
                readTimeout: option.readTimeout,
              ),
      );
    } catch (e) {
      debugPrint('URL option parse failed: $e');
      return ParsedUrl(
        url: legado_url.AnalyzeUrl.resolve(source.bookSourceUrl, urlWithOption),
      );
    }
  }

  /// 构建请求头（支持 JS 表达式）
  Future<Map<String, String>> _buildHeaders(
      {Map<String, String>? extraHeaders}) async {
    final headers = await _resolveHeaders(source.header);

    // 添加默认 User-Agent
    if (!headers.containsKey('User-Agent')) {
      headers['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    }

    // 合并额外请求头
    if (extraHeaders != null) {
      headers.addAll(extraHeaders);
    }

    return headers;
  }

  /// 执行网络请求
  Future<StrResponse> _executeRequest(
    ParsedUrl parsed, {
    String? keyword,
  }) async {
    final headers = await _buildHeaders(
      extraHeaders: parsed.option?.headers,
    );

    final method = parsed.option?.method?.toUpperCase() ?? 'GET';
    String? body = parsed.option?.body;

    // 替换 body 中的占位符
    if (body != null && keyword != null) {
      body = body.replaceAll('{{key}}', Uri.encodeComponent(keyword));
    }

    // POST 请求设置默认 Content-Type
    if (method == 'POST' && !headers.containsKey('Content-Type')) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }

    debugPrint('🌐 请求: $method ${parsed.url}');
    if (body != null) {
      debugPrint('📦 Body: $body');
    }

    return _client.execute(
      parsed.url,
      method: method,
      headers: headers,
      body: body,
      charset: parsed.option?.charset,
    );
  }

  /// 搜索书籍
  Future<List<Map<String, dynamic>>> searchBook(String keyword,
      {int page = 1}) async {
    if (source.searchUrl == null || source.searchUrl!.isEmpty) {
      AppLogger.instance.warn(LogCategory.parse, '搜索地址为空');
      return [];
    }

    final searchRule = source.ruleSearch;
    if (searchRule == null) {
      AppLogger.instance.warn(LogCategory.parse, '搜索规则为空');
      return [];
    }

    // 加载书源 JS 库
    await _loadJsLib();

    // 支持 JS 动态生成搜索 URL
    final resolvedSearchUrl =
        await _resolveUrl(source.searchUrl!, keyword: keyword, page: page);
    final parsed =
        _parseUrlWithOption(resolvedSearchUrl, keyword: keyword, page: page);
    AppLogger.instance.info(LogCategory.network, '搜索URL: ${parsed.url}');

    try {
      final response = await _executeRequest(parsed, keyword: keyword);
      final html = response.body;

      lastSearchHtml = html;

      AppLogger.instance
          .info(LogCategory.network, '搜索响应: ${html.length} chars');
      if (html.isEmpty) {
        AppLogger.instance.error(LogCategory.network, '搜索响应为空',
          detail: 'URL: ${parsed.url}\n状态码: ${response.statusCode}');
        // 保存诊断信息，方便调试页面查看
        lastSearchHtml = '<!-- 搜索响应为空 -->\n'
            '<!-- URL: ${parsed.url} -->\n'
            '<!-- 状态码: ${response.statusCode} -->\n'
            '<!-- 请求方式: ${parsed.option?.method ?? "GET"} -->\n'
            '<!-- 书源: ${source.bookSourceName} -->';
        return [];
      }

      // 执行 checkKeyWord JS（校验搜索关键词）
      if (searchRule.checkKeyWord != null &&
          searchRule.checkKeyWord!.isNotEmpty) {
        if (_isJsRule(searchRule.checkKeyWord)) {
          final checkResult = await _executeJs(searchRule.checkKeyWord!,
              result: keyword, baseUrl: source.bookSourceUrl);
          if (checkResult == null ||
              checkResult.isEmpty ||
              checkResult == 'false') {
            debugPrint('❌ 搜索关键词校验失败: $keyword');
            return [];
          }
        }
      }

      // 使用 AnalyzeRule 引擎解析
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: source.bookSourceUrl)
        ..setSourceEngine(source.engineType);

      final bookListRule = searchRule.bookList ?? '';
      AppLogger.instance.logParse('搜索列表', bookListRule);

      final bookElements = analyzer.getElements(bookListRule);
      AppLogger.instance.logParseResult('搜索列表', bookElements.length);

      if (bookElements.isEmpty) {
        AppLogger.instance.warn(LogCategory.parse, '未找到书籍元素');
        return [];
      }

      final results = <Map<String, dynamic>>[];

      for (int i = 0; i < bookElements.length; i++) {
        final element = bookElements[i];
        final itemAnalyzer = AnalyzeRule()
          ..setContent(element, baseUrl: source.bookSourceUrl)
          ..setSourceEngine(source.engineType);

        final name = itemAnalyzer.getString(searchRule.name ?? '');
        final author = itemAnalyzer.getString(searchRule.author ?? '');
        final coverUrl = itemAnalyzer.getString(searchRule.coverUrl ?? '');
        final intro = itemAnalyzer.getString(searchRule.intro ?? '');
        final bookUrl = itemAnalyzer.getString(searchRule.bookUrl ?? '');
        final kind = itemAnalyzer.getString(searchRule.kind ?? '');
        final lastChapter =
            itemAnalyzer.getString(searchRule.lastChapter ?? '');
        final wordCount = itemAnalyzer.getString(searchRule.wordCount ?? '');

        debugPrint('📖 [$i] 书名: $name, 作者: $author');
        AppLogger.instance
            .debug(LogCategory.parse, '[$i] 书名: $name, 作者: $author');

        if (name != null && name.isNotEmpty) {
          // 拼接相对链接：用书源URL作为基准
          final resolvedBookUrl = resolveUrl(bookUrl, source.bookSourceUrl);
          final resolvedCoverUrl = resolveUrl(coverUrl, source.bookSourceUrl);

          results.add({
            'name': name,
            'author': author ?? '',
            'coverUrl': resolvedCoverUrl,
            'intro': intro ?? '',
            'bookUrl': resolvedBookUrl,
            'kind': kind ?? '',
            'lastChapter': lastChapter ?? '',
            'wordCount': wordCount ?? '',
            'sourceUrl': source.bookSourceUrl,
            'sourceName': source.bookSourceName,
          });
        }
      }

      debugPrint('📖 最终结果数量: ${results.length}');
      return results;
    } catch (e, stackTrace) {
      debugPrint('❌ 搜索失败: $e');
      debugPrint('❌ 堆栈: $stackTrace');
      return [];
    }
  }

  /// 发现书籍
  /// 当发现规则为空或 bookList 为空时，退回使用搜索规则
  Future<List<Map<String, dynamic>>> exploreBook(String exploreUrl) async {
    // 加载书源 JS 库
    await _loadJsLib();

    // 发现规则回退逻辑：ruleExplore 为空或 bookList 为空时，使用 ruleSearch
    final exploreRule = source.ruleExplore;
    final searchRule = source.ruleSearch;
    final useSearchFallback = exploreRule == null ||
        (exploreRule.bookList == null || exploreRule.bookList!.trim().isEmpty);

    // 确定要使用的规则字段
    final bookListRule = useSearchFallback
        ? (searchRule?.bookList ?? '')
        : (exploreRule.bookList ?? '');
    final nameRule = useSearchFallback
        ? (searchRule?.name ?? '')
        : (exploreRule.name ?? '');
    final authorRule = useSearchFallback
        ? (searchRule?.author ?? '')
        : (exploreRule.author ?? '');
    final coverUrlRule = useSearchFallback
        ? (searchRule?.coverUrl ?? '')
        : (exploreRule.coverUrl ?? '');
    final introRule = useSearchFallback
        ? (searchRule?.intro ?? '')
        : (exploreRule.intro ?? '');
    final bookUrlRule = useSearchFallback
        ? (searchRule?.bookUrl ?? '')
        : (exploreRule.bookUrl ?? '');
    final kindRule = useSearchFallback
        ? (searchRule?.kind ?? '')
        : (exploreRule.kind ?? '');
    final lastChapterRule = useSearchFallback
        ? (searchRule?.lastChapter ?? '')
        : (exploreRule.lastChapter ?? '');
    final wordCountRule = useSearchFallback
        ? (searchRule?.wordCount ?? '')
        : (exploreRule.wordCount ?? '');

    if (useSearchFallback && searchRule != null) {
      AppLogger.instance.info(LogCategory.parse, '发现规则为空，退回搜索规则');
    }

    if (bookListRule.isEmpty && nameRule.isEmpty) return [];

    // 支持 JS 动态生成发现 URL
    final resolvedExploreUrl = await _resolveUrl(exploreUrl);
    final parsed = _parseUrlWithOption(resolvedExploreUrl);

    try {
      final response = await _executeRequest(parsed);
      final html = response.body;

      lastExploreHtml = html;

      AppLogger.instance.info(LogCategory.network, '发现响应: ${html.length} chars, 状态码: ${response.statusCode}');
      if (html.isEmpty) {
        AppLogger.instance.error(LogCategory.network, '发现响应为空',
          detail: 'URL: ${parsed.url}\n状态码: ${response.statusCode}');
        lastExploreHtml = '<!-- 发现响应为空 -->\n'
            '<!-- URL: ${parsed.url} -->\n'
            '<!-- 状态码: ${response.statusCode} -->';
        return [];
      }

      // 使用 AnalyzeRule 引擎解析
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: source.bookSourceUrl)
        ..setSourceEngine(source.engineType);

      final nameList = analyzer.getStringList(exploreRule.name ?? '');
      final authorList = analyzer.getStringList(exploreRule.author ?? '');
      final coverList = analyzer.getStringList(exploreRule.coverUrl ?? '');
      final introList = analyzer.getStringList(exploreRule.intro ?? '');
      final bookUrlList = analyzer.getStringList(exploreRule.bookUrl ?? '');
      final kindList = analyzer.getStringList(exploreRule.kind ?? '');
      final lastChapterList =
          analyzer.getStringList(exploreRule.lastChapter ?? '');
      final wordCountList = analyzer.getStringList(exploreRule.wordCount ?? '');

      final results = <Map<String, dynamic>>[];

      for (int i = 0; i < nameList.length; i++) {
        results.add({
          'name': nameList[i],
          'author': i < authorList.length ? authorList[i] : '',
          'coverUrl': i < coverList.length ? coverList[i] : '',
          'intro': i < introList.length ? introList[i] : '',
          'bookUrl': i < bookUrlList.length ? bookUrlList[i] : '',
          'kind': i < kindList.length ? kindList[i] : '',
          'lastChapter': i < lastChapterList.length ? lastChapterList[i] : '',
          'wordCount': i < wordCountList.length ? wordCountList[i] : '',
          'sourceUrl': source.bookSourceUrl,
          'sourceName': source.bookSourceName,
        });
      }

      return results;
    } catch (e) {
      AppLogger.instance.error(LogCategory.parse, '发现失败', detail: e.toString());
      return [];
    }
  }

  /// 获取书籍详情
  Future<Book?> getBookInfo(String bookUrl) async {
    final bookInfoRule = source.ruleBookInfo;
    if (bookInfoRule == null) return null;

    // 加载书源 JS 库
    await _loadJsLib();

    try {
      final headers = await _buildHeaders();
      final response = await _client.execute(bookUrl, headers: headers);
      var html = response.body;

      AppLogger.instance.info(LogCategory.network, '详情响应: ${html.length} chars, 状态码: ${response.statusCode}');
      if (html.isEmpty) {
        AppLogger.instance.error(LogCategory.network, '详情响应为空',
          detail: 'URL: $bookUrl\n状态码: ${response.statusCode}');
        lastBookInfoHtml = '<!-- 详情响应为空 -->\n'
            '<!-- URL: $bookUrl -->\n'
            '<!-- 状态码: ${response.statusCode} -->';
        return null;
      }

      // 执行 init JS 预处理脚本
      if (bookInfoRule.init != null && bookInfoRule.init!.isNotEmpty) {
        final initResult = await _executeJs(bookInfoRule.init!,
            result: html, baseUrl: bookUrl);
        if (initResult != null && initResult.isNotEmpty) {
          html = initResult;
          AppLogger.instance.logJsResult('init', '${initResult.length} chars');
        }
      }

      // 保存源码（init 处理后的）
      lastBookInfoHtml = html;

      // 使用 AnalyzeRule 引擎解析
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: bookUrl)
        ..setSourceEngine(source.engineType);

      final name = analyzer.getString(bookInfoRule.name ?? '');
      final author = analyzer.getString(bookInfoRule.author ?? '');
      final rawCoverUrl = analyzer.getString(bookInfoRule.coverUrl ?? '');
      final intro = analyzer.getString(bookInfoRule.intro ?? '');
      final kind = analyzer.getString(bookInfoRule.kind ?? '');
      final lastChapter = analyzer.getString(bookInfoRule.lastChapter ?? '');
      final wordCount = analyzer.getString(bookInfoRule.wordCount ?? '');
      final rawTocUrl = analyzer.getString(bookInfoRule.tocUrl ?? '');

      // 拼接相对链接：用详情页URL作为基准
      final resolvedCoverUrl = resolveUrl(rawCoverUrl, bookUrl);
      final resolvedTocUrl = resolveUrl(rawTocUrl, bookUrl);

      AppLogger.instance.info(LogCategory.parse, '详情: 书名=$name, 作者=$author, 目录=$resolvedTocUrl');

      return Book(
        bookUrl: bookUrl,
        name: name ?? '未知书名',
        author: author ?? '',
        coverUrl: resolvedCoverUrl,
        intro: intro ?? '',
        mediaType: MediaType.novel,
        originType: BookOriginType.online,
        sourceUrl: source.bookSourceUrl,
        sourceName: source.bookSourceName,
        kind: kind,
        lastChapter: lastChapter,
        wordCount: wordCount,
        tocUrl: resolvedTocUrl,
        canUpdate: true,
        addedTime: DateTime.now(),
      );
    } catch (e) {
      AppLogger.instance.error(LogCategory.parse, '获取详情失败', detail: e.toString());
      return null;
    }
  }

  /// 获取章节目录
  Future<List<Chapter>> getChapterList(String tocUrl) async {
    final tocRule = source.ruleToc;
    if (tocRule == null) return [];

    // 加载书源 JS 库
    await _loadJsLib();

    try {
      final headers = await _buildHeaders();
      final response = await _client.execute(tocUrl, headers: headers);
      var html = response.body;

      AppLogger.instance.info(LogCategory.network, '目录响应: ${html.length} chars, 状态码: ${response.statusCode}');
      if (html.isEmpty) {
        AppLogger.instance.error(LogCategory.network, '目录响应为空',
          detail: 'URL: $tocUrl\n状态码: ${response.statusCode}');
        lastTocHtml = '<!-- 目录响应为空 -->\n'
            '<!-- URL: $tocUrl -->\n'
            '<!-- 状态码: ${response.statusCode} -->';
        return [];
      }

      // 执行 preUpdateJs（目录更新前 JS 脚本）
      if (tocRule.preUpdateJs != null && tocRule.preUpdateJs!.isNotEmpty) {
        final preResult = await _executeJs(tocRule.preUpdateJs!,
            result: html, baseUrl: tocUrl);
        if (preResult != null && preResult.isNotEmpty) {
          html = preResult;
          AppLogger.instance.logJsResult('preUpdateJs', '${preResult.length} chars');
        }
      }

      // 保存源码（preUpdateJs 处理后的）
      lastTocHtml = html;

      // 使用 AnalyzeRule 引擎解析
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: tocUrl)
        ..setSourceEngine(source.engineType);

      var chapterNames = analyzer.getStringList(tocRule.chapterName ?? '');
      var chapterUrls = analyzer.getStringList(tocRule.chapterUrl ?? '');

      AppLogger.instance.logParseResult('目录', chapterNames.length);

      // 执行 formatJs（格式化章节列表的 JS 脚本）
      if (tocRule.formatJs != null && tocRule.formatJs!.isNotEmpty) {
        final formatResult = await _executeJs(tocRule.formatJs!,
            result: jsonEncode({
              'names': chapterNames,
              'urls': chapterUrls,
            }),
            baseUrl: tocUrl);
        if (formatResult != null && formatResult.isNotEmpty) {
          try {
            final decoded = jsonDecode(formatResult);
            if (decoded is Map) {
              if (decoded['names'] is List) {
                chapterNames = (decoded['names'] as List)
                    .map((e) => e.toString())
                    .toList();
              }
              if (decoded['urls'] is List) {
                chapterUrls =
                    (decoded['urls'] as List).map((e) => e.toString()).toList();
              }
            }
          } catch (_) {
            // formatJs 可能直接返回格式化后的文本
          }
        }
      }

      final chapters = <Chapter>[];

      for (int i = 0; i < chapterNames.length; i++) {
        final name = chapterNames[i];
        final rawUrl = i < chapterUrls.length ? chapterUrls[i] : null;
        // 拼接相对链接：用目录页URL作为基准
        final resolvedUrl = resolveUrl(rawUrl, tocUrl);

        chapters.add(Chapter(
          id: '${tocUrl}_$i',
          bookId: tocUrl,
          title: name,
          index: i,
          url: resolvedUrl.isEmpty ? null : resolvedUrl,
        ));
      }

      // 处理 nextTocUrl（目录下一页，支持 JS）
      if (tocRule.nextTocUrl != null && tocRule.nextTocUrl!.isNotEmpty) {
        final rawNextUrl = analyzer.getString(tocRule.nextTocUrl!, isUrl: true);
        final nextUrl = resolveUrl(rawNextUrl, tocUrl);
        if (nextUrl.isNotEmpty && nextUrl != tocUrl) {
          AppLogger.instance.info(LogCategory.parse, '目录下一页: $nextUrl');
          final nextChapters = await getChapterList(nextUrl);
          chapters.addAll(nextChapters);
        }
      }

      return chapters;
    } catch (e) {
      AppLogger.instance.error(LogCategory.parse, '获取目录失败', detail: e.toString());
      return [];
    }
  }

  /// 获取章节正文
  Future<String?> getContent(String chapterUrl) async {
    final contentRule = source.ruleContent;
    if (contentRule == null) return null;

    // 加载书源 JS 库
    await _loadJsLib();

    try {
      final headers = await _buildHeaders();
      final response = await _client.execute(chapterUrl, headers: headers);
      var html = response.body;

      AppLogger.instance.info(LogCategory.network, '正文响应: ${html.length} chars, 状态码: ${response.statusCode}');
      if (html.isEmpty) {
        AppLogger.instance.error(LogCategory.network, '正文响应为空',
          detail: 'URL: $chapterUrl\n状态码: ${response.statusCode}');
        lastContentHtml = '<!-- 正文响应为空 -->\n'
            '<!-- URL: $chapterUrl -->\n'
            '<!-- 状态码: ${response.statusCode} -->';
        return null;
      }

      // 保存原始源码
      lastContentHtml = html;

      // 使用 AnalyzeRule 引擎解析正文
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: chapterUrl)
        ..setSourceEngine(source.engineType);
      var content = analyzer.getString(contentRule.content ?? '');

      AppLogger.instance.logParseResult('正文', content != null ? 1 : 0);

      // 执行 js 脚本（正文加载后执行的 JS）
      if (contentRule.js != null && contentRule.js!.isNotEmpty) {
        final jsResult = await _executeJs(contentRule.js!,
            result: content ?? '', baseUrl: chapterUrl);
        if (jsResult != null && jsResult.isNotEmpty) {
          content = jsResult;
          AppLogger.instance.logJsResult('content.js', '${jsResult.length} chars');
        }
      }

      // 执行 replaceRegex（正文替换规则，支持 JS 替换逻辑）
      if (contentRule.replaceRegex != null &&
          contentRule.replaceRegex!.isNotEmpty) {
        content = _applyContentReplace(content, contentRule.replaceRegex!);
      }

      // 执行 callBackJs（内容加载完成后的回调 JS）
      if (contentRule.callBackJs != null &&
          contentRule.callBackJs!.isNotEmpty) {
        final callBackResult = await _executeJs(contentRule.callBackJs!,
            result: content ?? '', baseUrl: chapterUrl);
        if (callBackResult != null && callBackResult.isNotEmpty) {
          content = callBackResult;
          AppLogger.instance.logJsResult('callBackJs', '${callBackResult.length} chars');
        }
      }

      // 处理 nextContentUrl（正文下一页，支持 JS）
      if (contentRule.nextContentUrl != null &&
          contentRule.nextContentUrl!.isNotEmpty) {
        final nextUrl =
            analyzer.getString(contentRule.nextContentUrl!, isUrl: true);
        if (nextUrl != null && nextUrl.isNotEmpty && nextUrl != chapterUrl) {
          debugPrint('📖 发现正文下一页: $nextUrl');
          final nextContent = await getContent(nextUrl);
          if (nextContent != null && nextContent.isNotEmpty) {
            content = (content ?? '') + '\n' + nextContent;
          }
        }
      }

      return content;
    } catch (e) {
      AppLogger.instance.error(LogCategory.parse, '获取正文失败', detail: e.toString());
      return null;
    }
  }

  /// 应用正文替换规则
  /// 支持多组 ## 分隔的替换规则
  String? _applyContentReplace(String? content, String replaceRegex) {
    if (content == null || replaceRegex.isEmpty) return content;

    // 按 ## 分割多组替换规则
    final parts = replaceRegex.split('##');
    if (parts.isEmpty) return content;

    var result = content;
    for (int i = 0; i < parts.length; i += 2) {
      final pattern = parts[i];
      final replacement = i + 1 < parts.length ? parts[i + 1] : '';

      if (pattern.isEmpty) continue;

      try {
        final regex = RegExp(pattern, multiLine: true, dotAll: true);
        result = result.replaceAll(regex, replacement);
      } catch (e) {
        debugPrint('❌ 替换规则执行失败: $pattern → $e');
      }
    }

    return result;
  }
}

/// Jsoup 风格的 HTML 解析器
class Jsoup {
  /// 解析 HTML 文档
  static JsoupDocument parse(String html, {String? baseUrl}) {
    final doc = html_parser.parse(html);
    return JsoupDocument(doc, baseUrl: baseUrl);
  }
}

/// Jsoup 风格的文档对象
class JsoupDocument {
  final dom.Document _doc;
  final String? baseUrl;

  JsoupDocument(this._doc, {this.baseUrl});

  /// 选择元素（类似 Jsoup 的 select）
  List<JsoupElement> select(String cssSelector) {
    if (cssSelector.isEmpty) return [];

    final converted = _convertLegadoRule(cssSelector);
    final elements = _doc.querySelectorAll(converted);
    return elements.map((e) => JsoupElement(e, baseUrl: baseUrl)).toList();
  }

  /// 选择第一个元素（类似 Jsoup 的 selectFirst）
  JsoupElement? selectFirst(String cssSelector) {
    if (cssSelector.isEmpty) return null;

    final converted = _convertLegadoRule(cssSelector);
    final element = _doc.querySelector(converted);
    if (element == null) return null;
    return JsoupElement(element, baseUrl: baseUrl);
  }

  /// 转换 legados 规则语法
  String _convertLegadoRule(String rule) {
    if (rule.startsWith('class.')) {
      return '.${rule.substring(6)}';
    }
    if (rule.startsWith('tag.')) {
      return rule.substring(4);
    }
    if (rule.startsWith('id.')) {
      return '#${rule.substring(3)}';
    }
    if (rule.startsWith('@')) {
      // 处理属性选择器
      final attr = rule.substring(1);
      if (attr == 'text' || attr == 'text()') {
        return ':root';
      }
      if (attr == 'html' || attr == 'html()') {
        return ':root';
      }
    }
    return rule;
  }
}

/// Jsoup 风格的元素对象
class JsoupElement {
  final dom.Element _element;
  final String? baseUrl;

  JsoupElement(this._element, {this.baseUrl});

  /// 获取文本内容（类似 Jsoup 的 text()）
  String text() => _element.text.trim();

  /// 获取 HTML 内容（类似 Jsoup 的 html()）
  String html() => _element.innerHtml;

  /// 获取外部 HTML（类似 Jsoup 的 outerHtml()）
  String outerHtml() => _element.outerHtml;

  /// 获取属性值（类似 Jsoup 的 attr()）
  String? attr(String name) => _element.attributes[name];

  /// 获取绝对 URL（类似 Jsoup 的 absUrl()）
  String? absUrl([String attrName = 'href']) {
    final value = _element.attributes[attrName];
    if (value == null) return null;

    // 处理相对 URL
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }

    if (baseUrl != null) {
      final base = Uri.parse(baseUrl!);
      return base.resolve(value).toString();
    }

    return value;
  }

  /// 选择子元素（支持多步骤规则）
  List<JsoupElement> select(String rule) {
    if (rule.isEmpty) return [this];

    // 按 @ 分割规则步骤
    final steps = _splitSteps(rule);
    List<dynamic> current = [_element];

    for (final step in steps) {
      final nextResults = <dynamic>[];
      for (final item in current) {
        final result = _applyStep(item, step, isList: true);
        if (result is List) {
          nextResults.addAll(result);
        } else if (result != null) {
          nextResults.add(result);
        }
      }
      current = nextResults;
      if (current.isEmpty) return [];
    }

    return current.map((e) {
      if (e is dom.Element) return JsoupElement(e, baseUrl: baseUrl);
      if (e is String) {
        // 返回一个包含文本的虚拟元素
        final doc = html_parser.parse('<root>$e</root>');
        return JsoupElement(doc.body!.firstChild as dom.Element,
            baseUrl: baseUrl);
      }
      return JsoupElement(_element, baseUrl: baseUrl);
    }).toList();
  }

  /// 选择第一个子元素（支持多步骤规则）
  JsoupElement? selectFirst(String rule) {
    if (rule.isEmpty) return this;

    // 按 @ 分割规则步骤
    final steps = _splitSteps(rule);
    dynamic current = _element;

    for (final step in steps) {
      current = _applyStep(current, step, isList: false);
      if (current == null) return null;
    }

    if (current is dom.Element) {
      return JsoupElement(current, baseUrl: baseUrl);
    }
    if (current is String) {
      final doc = html_parser.parse('<root>$current</root>');
      return JsoupElement(doc.body!.firstChild as dom.Element,
          baseUrl: baseUrl);
    }
    return null;
  }

  /// 分割规则步骤
  List<String> _splitSteps(String rule) {
    final steps = <String>[];
    int start = 0;
    int i = 0;

    while (i < rule.length) {
      if (rule[i] == '@') {
        // 检查是否是属性选择器 (@text, @href 等)
        if (i + 1 < rule.length && RegExp(r'[a-zA-Z]').hasMatch(rule[i + 1])) {
          // 查找属性名结束位置
          int j = i + 1;
          while (
              j < rule.length && RegExp(r'[a-zA-Z0-9()]').hasMatch(rule[j])) {
            j++;
          }
          // 如果后面还有 @，则分割
          if (j < rule.length && rule[j] == '@') {
            steps.add(rule.substring(start, j));
            start = j;
            i = j;
            continue;
          }
          // 否则作为最后一个步骤
          if (j == rule.length) {
            steps.add(rule.substring(start));
            return steps;
          }
          // 属性后面跟着其他字符，继续
          i++;
          continue;
        }
        // 分割
        if (i > start) {
          steps.add(rule.substring(start, i));
        }
        start = i + 1;
      }
      i++;
    }

    if (start < rule.length) {
      steps.add(rule.substring(start));
    }

    return steps.where((s) => s.isNotEmpty).toList();
  }

  /// 应用单个规则步骤
  dynamic _applyStep(dynamic content, String step, {bool isList = false}) {
    if (step.isEmpty) return content;

    // 处理属性提取
    if (step.startsWith('@')) {
      final attrName = step.substring(1);
      if (content is List) {
        return content.map((e) => _extractAttr(e, attrName)).toList();
      }
      return _extractAttr(content, attrName);
    }

    // 处理 text() 和 html()
    if (step == 'text' || step == 'text()') {
      if (content is List) {
        return content.map((e) => _extractText(e)).toList();
      }
      return _extractText(content);
    }
    if (step == 'html' || step == 'html()') {
      if (content is List) {
        return content.map((e) => _extractHtml(e)).toList();
      }
      return _extractHtml(content);
    }

    // 转换 legados 语法
    String cssSelector = _convertLegadoRule(step);

    // 处理索引语法（在 CSS 选择后）
    int? index;
    final indexMatch = RegExp(r'\.(\d+)$').firstMatch(cssSelector);
    if (indexMatch != null) {
      index = int.parse(indexMatch.group(1)!);
      cssSelector = cssSelector.substring(0, indexMatch.start);
    }

    // 执行选择
    if (content is List) {
      final results = <dom.Element>[];
      for (final item in content) {
        if (item is dom.Element) {
          results.addAll(item.querySelectorAll(cssSelector));
        }
      }
      if (index != null) {
        if (index < results.length) {
          return results[index];
        }
        return null;
      }
      return results;
    }

    dom.Element? element = _toElement(content);
    if (element == null) return null;

    final results = element.querySelectorAll(cssSelector).toList();

    if (index != null) {
      if (index < results.length) {
        return results[index];
      }
      return null;
    }

    if (isList) {
      return results;
    }
    return results.isNotEmpty ? results.first : null;
  }

  /// 转换 legados 规则语法
  String _convertLegadoRule(String rule) {
    if (rule.isEmpty) return rule;

    // 处理 class. → .
    if (rule.startsWith('class.')) {
      rule = '.${rule.substring(6)}';
    }
    // 处理 tag. → 直接标签名
    else if (rule.startsWith('tag.')) {
      rule = rule.substring(4);
    }
    // 处理 id. → #
    else if (rule.startsWith('id.')) {
      rule = '#${rule.substring(3)}';
    }

    // 处理索引语法: .0, .1 等（但保留在返回前处理）
    // 这里只转换选择器部分

    return rule;
  }

  /// 提取属性
  String _extractAttr(dynamic content, String attrName) {
    dom.Element? element = _toElement(content);
    if (element == null) return '';

    switch (attrName.toLowerCase()) {
      case 'text':
      case 'text()':
        return element.text.trim();
      case 'html':
      case 'html()':
        return element.innerHtml;
      case 'outerhtml':
        return element.outerHtml;
      case 'hrefurl':
        return _getAbsUrl(element, 'href');
      case 'srcurl':
        return _getAbsUrl(element, 'src');
      default:
        return element.attributes[attrName] ?? '';
    }
  }

  /// 提取文本
  String _extractText(dynamic content) {
    dom.Element? element = _toElement(content);
    return element?.text.trim() ?? '';
  }

  /// 提取 HTML
  String _extractHtml(dynamic content) {
    dom.Element? element = _toElement(content);
    return element?.innerHtml ?? '';
  }

  /// 获取绝对 URL
  String _getAbsUrl(dom.Element element, String attrName) {
    final value = element.attributes[attrName];
    if (value == null) return '';

    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }

    if (baseUrl != null) {
      try {
        final base = Uri.parse(baseUrl!);
        return base.resolve(value).toString();
      } catch (_) {}
    }

    return value;
  }

  /// 转换为 Element
  dom.Element? _toElement(dynamic content) {
    if (content is dom.Element) return content;
    if (content is dom.Document) return content.body;
    if (content is String) {
      final doc = html_parser.parse(content);
      return doc.body;
    }
    return null;
  }
}
