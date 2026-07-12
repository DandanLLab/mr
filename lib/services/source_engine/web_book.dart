import 'dart:convert';
import 'dart:typed_data';
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
import 'charset_utils.dart';
import 'web_proxy.dart';
import '../native/js_advanced_service.dart';
import '../native/js_engine.dart';
/// 每个规则类型只显示一次日志的集合
final Set<String> _loggedRuleTags = {};

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
  final String? type;
  final String? webJs;
  final String? bodyJs;
  final String? js;
  final String? dnsIp;

  UrlOption({
    this.method,
    this.headers,
    this.body,
    this.charset,
    this.retry = 0,
    this.useWebView = false,
    this.connectTimeout,
    this.readTimeout,
    this.type,
    this.webJs,
    this.bodyJs,
    this.js,
    this.dnsIp,
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
      type: json['type']?.toString(),
      webJs: json['webJs']?.toString(),
      bodyJs: json['bodyJs']?.toString(),
      js: json['js']?.toString(),
      dnsIp: json['dnsIp']?.toString(),
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
      if (type != null) 'type': type,
      if (webJs != null) 'webJs': webJs,
      if (bodyJs != null) 'bodyJs': bodyJs,
      if (js != null) 'js': js,
      if (dnsIp != null) 'dnsIp': dnsIp,
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
  HttpClient();

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
        // WebProxy.fetch() 内部会拼接代理前缀，这里只传原始 URL
        final html = await WebProxy.instance.fetch(
          url,
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

      // 降级方案：使用 Dio
      // 当 charset 为非 UTF-8 时，用 ResponseType.bytes 获取原始字节后手动解码，
      // 确保 GBK/GB2312/GB18030 等编码正确转换
      final useBytes = charset != null && charset.trim().toLowerCase() != 'utf-8' && charset.trim().toLowerCase() != 'utf8';
      final options = Options(
        method: method,
        headers: headers,
        responseType: useBytes ? ResponseType.bytes : ResponseType.plain,
        receiveTimeout: readTimeout,
        sendTimeout: connectTimeout,
      );

      if (useBytes) {
        final response = await _dio.request<List<int>>(
          url,
          data: body,
          options: options,
        );
        final rawBytes = response.data ?? <int>[];
        final bodyStr = CharsetUtils.decodeResponse(
          Uint8List.fromList(rawBytes), charset);
        return StrResponse(
          url: response.realUri.toString(),
          body: bodyStr,
          statusCode: response.statusCode ?? 200,
          headers: response.headers.map.map(
            (key, value) => MapEntry(key, value.first),
          ),
          raw: response,
        );
      }

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
  String? lastSearchUrl;  // 搜索链接
  String? lastExploreHtml;
  String? lastExploreUrl;  // 发现链接
  String? lastBookInfoHtml;
  String? lastTocHtml;
  String? lastContentHtml;

  // 缓存原始元素数量（用于调试）
  int lastSearchElementCount = 0;
  int lastExploreElementCount = 0;
  int lastTocElementCount = 0;

  WebBook(this.source, {HttpClient? client})
      : _client = client ?? HttpClient.instance;

  // ===== JS 辅助方法 =====

  /// 判断规则是否包含 JS 代码
  bool _isJsRule(String? rule) {
    if (rule == null || rule.isEmpty) return false;
    return rule.startsWith('@js:') ||
        rule.startsWith('<js>') ||
        rule.contains('<js>') ||
        rule.contains('{{');
  }

  /// 执行 JS 规则并返回字符串结果
  Future<String?> _executeJs(String jsCode,
      {String? result, String? baseUrl, Map<String, dynamic>? extraEnv}) async {
    try {
      AppLogger.instance.logJsExecute('分流', jsCode);
      // 构建完整 env（借鉴 legado 的 evalJS 绑定）
      final env = <String, dynamic>{
        'baseUrl': baseUrl ?? source.bookSourceUrl,
        'source': _sourceToMap(source),
        'cookie': <String, String>{},
      };
      if (extraEnv != null) env.addAll(extraEnv);

      final jsResult = await JsEngine.instance.processJsRule(
        result ?? '',
        jsCode,
        baseUrl: baseUrl ?? source.bookSourceUrl,
        sourceEngine: source.engineType,
        env: env,
      );
      if (_loggedRuleTags.add('flow')) {
        AppLogger.instance.logJsResult('分流', jsResult);
      }
      return jsResult;
    } catch (e) {
      AppLogger.instance.logJsError('分流', e.toString());
      return null;
    }
  }

  /// 解析可能包含 JS 的 URL
  /// 借鉴 legado：先做变量替换，只有真正的 JS 规则才走 JS 执行
  /// 支持 @js: 前缀的动态 URL 生成和 {{key}}/{{page}} 模板替换
  Future<String> _resolveUrl(String url, {String? keyword, int? page}) async {
    // 借鉴 legado：区分真正的 JS 规则和 URL 模板
    // 只有以 @js:/<js> 前缀开头的才是 JS 规则
    // 包含 {{}} 的 URL 模板只做变量替换，不走 JS 执行
    final isRealJsRule = url.startsWith('@js:') ||
        url.startsWith('<js>');

    if (isRealJsRule) {
      final extraEnv = <String, dynamic>{};
      if (keyword != null) extraEnv['key'] = keyword;
      if (page != null) extraEnv['page'] = page;
      final jsResult = await _executeJs(url, baseUrl: source.bookSourceUrl,
          extraEnv: extraEnv.isNotEmpty ? extraEnv : null);
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
      // JS 返回 null/空 → 日志告警 + 返回空，不要用原始 @js: 代码当 URL
      AppLogger.instance.warn(LogCategory.network,
          'JS规则返回空: $url',
          detail: 'JS执行结果=null，书源规则可能有问题');
      return '';
    }

    // URL 模板变量替换（借鉴 legado 的 searchUrl 解析）
    var resolved = url;
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

  /// 将相对链接拼接成绝对链接
  /// 对齐 legado NetworkUtils.getAbsoluteURL
  static String resolveUrl(String? url, String baseUrl) {
    if (url == null || url.trim().isEmpty) return '';
    url = url.trim();

    // 对齐 legado isAbsUrl(): 大小写不敏感
    final lower = url.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return url;
    }
    // 对齐 legado isDataUrl()
    if (lower.startsWith('data:')) return url;
    // 对齐 legado: javascript 前缀返回空
    if (lower.startsWith('javascript')) return '';

    // 以 // 开头，补上协议
    if (url.startsWith('//')) {
      final baseUri = Uri.tryParse(baseUrl);
      return '${baseUri?.scheme ?? 'https'}:$url';
    }

    // 解析 baseUrl
    final baseUri = Uri.tryParse(baseUrl);
    if (baseUri == null) return url;

    // 对齐 legado: 直接用 Uri.resolve 拼接（等价于 Java 的 URL(base, relative)）
    try {
      return baseUri.resolve(url).toString();
    } catch (_) {
      return url;
    }
  }

  /// 解析可能包含 JS 的请求头
  Future<Map<String, String>> _resolveHeaders(String? headerStr) async {
    final headers = <String, String>{};

    if (headerStr == null || headerStr.isEmpty) return headers;

    // 借鉴 legado 的 BaseSource.getHeaderMap()：
    // header 整体支持 @js: 或 <js> 前缀，返回 JSON 格式的 header map
    // header 值也支持 JS 表达式

    // 先检查 header 整体是否是 JS 代码
    if (_isJsRule(headerStr)) {
      try {
        // header 规则可能含 java.getWebViewUA() 等桥接调用，必须走异步路径
        final jsResult = await JsEngine.instance.processJsRule(
          '',
          headerStr,
          baseUrl: source.bookSourceUrl,
          sourceEngine: source.engineType,
          env: {
            'source': _sourceToMap(source),
            'cookie': <String, String>{},
            'baseUrl': source.bookSourceUrl,
          },
        );
        if (jsResult != null) {
          final resultStr = jsResult.toString();
          try {
            final decoded = json.decode(resultStr);
            if (decoded is Map) {
              decoded.forEach((key, value) {
                headers[key.toString()] = value.toString();
              });
              return headers;
            }
          } catch (_) {
            // JS 返回的不是 JSON，忽略
          }
        }
      } catch (e) {
        debugPrint('❌ header JS执行失败: $e');
      }
    }

    // 尝试 JSON 解析
    try {
      final decoded = json.decode(headerStr);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final val = entry.value.toString();
          // 如果值包含 JS 表达式，异步执行它
          if (_isJsRule(val)) {
            final jsResult = await JsEngine.instance.processJsRule(
              '',
              val,
              baseUrl: source.bookSourceUrl,
              sourceEngine: source.engineType,
              env: {
                'source': _sourceToMap(source),
                'cookie': <String, String>{},
                'baseUrl': source.bookSourceUrl,
              },
            );
            headers[entry.key.toString()] = jsResult ?? val;
          } else {
            headers[entry.key.toString()] = val;
          }
        }
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
                baseUrl: source.bookSourceUrl,
                sourceEngine: source.engineType,
                variables: {
                  'source': _sourceToMap(source),
                  'cookie': <String, String>{},
                });
            val = jsResult?.toString() ?? val;
          }
          headers[key] = val;
        }
      }
    }

    return headers;
  }

  /// 加载书源 JS 库（jsLib 字段）
  /// 借鉴 legado 的 SharedJsScope：jsLib 缓存到局部作用域，不污染全局
  Future<void> _loadJsLib() async {
    final jsLib = source.jsLib;
    if (jsLib == null || jsLib.isEmpty) return;
    try {
      // 确保引擎已初始化
      if (!JsEngine.instance.isAvailable) {
        await JsEngine.instance.init();
      }
      // 缓存 jsLib 到书源级局部作用域（不注入全局，避免污染）
      JsEngine.instance.loadJsLib(source.bookSourceUrl, jsLib);
      debugPrint('📚 已缓存书源JS库: ${source.bookSourceName}');
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
                type: option.type,
                webJs: option.webJs,
                bodyJs: option.bodyJs,
                js: option.js,
                dnsIp: option.dnsIp,
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

    var requestUrl = parsed.url;
    final urlJs = parsed.option?.js;
    if (urlJs != null && urlJs.isNotEmpty) {
      requestUrl =
          await _executeJs(urlJs, result: requestUrl, baseUrl: requestUrl) ??
              requestUrl;
    }
    StrResponse response = await _client.execute(
      requestUrl,
      method: method,
      headers: headers,
      body: body,
      charset: parsed.option?.charset,
      connectTimeout: parsed.option?.connectTimeout == null
          ? null
          : Duration(milliseconds: parsed.option!.connectTimeout!),
      readTimeout: parsed.option?.readTimeout == null
          ? null
          : Duration(milliseconds: parsed.option!.readTimeout!),
    );
    for (var attempt = 0;
        attempt < (parsed.option?.retry ?? 0) && !response.isSuccessful;
        attempt++) {
      response = await _client.execute(
        requestUrl,
        method: method,
        headers: headers,
        body: body,
        charset: parsed.option?.charset,
        connectTimeout: parsed.option?.connectTimeout == null
            ? null
            : Duration(milliseconds: parsed.option!.connectTimeout!),
        readTimeout: parsed.option?.readTimeout == null
            ? null
            : Duration(milliseconds: parsed.option!.readTimeout!),
      );
    }
    final bodyJs = parsed.option?.bodyJs;
    if (bodyJs == null || bodyJs.isEmpty) return response;
    final transformed = await _executeJs(
      bodyJs,
      result: response.body,
      baseUrl: response.url,
    );
    return StrResponse(
      url: response.url,
      body: transformed ?? response.body,
      statusCode: response.statusCode,
      headers: response.headers,
      raw: response.raw,
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
      lastSearchUrl = parsed.url;  // 保存搜索链接

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
              result: keyword, baseUrl: source.bookSourceUrl,
              extraEnv: {'key': keyword, 'page': page});
          if (checkResult == null ||
              checkResult.isEmpty ||
              checkResult == 'false') {
            debugPrint('❌ 搜索关键词校验失败: $keyword');
            return [];
          }
        }
      }

      // 使用 AnalyzeRule 引擎解析
      // 预计算 sourceMap，避免在搜索结果循环内重复创建
      final searchSourceMap = _sourceToMap(source);
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: parsed.url)
        ..setRedirectUrl(response.url)
        ..setSourceEngine(source.engineType)
        ..setSourceInfo(searchSourceMap) // 借鉴 legado：注入 source 上下文
        ..putVariable('key', keyword) // 注入搜索关键词
        ..putVariable('page', page); // 注入页码

      final bookListRule = searchRule.bookList ?? '';

      // 借鉴 legado：bookList 规则的 -/+ 前缀处理
      var actualBookListRule = bookListRule;
      var reverseList = false;
      if (actualBookListRule.startsWith('-')) {
        reverseList = true;
        actualBookListRule = actualBookListRule.substring(1);
      } else if (actualBookListRule.startsWith('+')) {
        actualBookListRule = actualBookListRule.substring(1);
      }

      if (_loggedRuleTags.add('搜索列表')) {
        AppLogger.instance.logParse('搜索列表', actualBookListRule);
      }

      var bookElements = await analyzer.getElementsAsync(actualBookListRule);
      if (_loggedRuleTags.add('搜索列表_结果')) {
        AppLogger.instance.logParseResult('搜索列表', bookElements.length);
      }

      // 保存原始元素数量（用于调试）
      lastSearchElementCount = bookElements.length;

      // 调试：记录元素类型
      if (bookElements.isNotEmpty) {
        AppLogger.instance.debug(LogCategory.parse, '搜索列表元素类型',
          detail: '第一个元素类型: ${bookElements.first.runtimeType}, 总数: ${bookElements.length}');
      }

      // 借鉴 legado：列表反转
      if (reverseList && bookElements.isNotEmpty) {
        bookElements = bookElements.reversed.toList();
      }

      if (bookElements.isEmpty) {
        AppLogger.instance.warn(LogCategory.parse, '未找到书籍元素');
        return [];
      }

      // [性能] 全量并发 + 空规则跳过，搜索/发现共用 _extractBookItems
      final results = await _extractBookItems(
        elements: bookElements,
        nameRule: searchRule.name ?? '',
        authorRule: searchRule.author ?? '',
        coverUrlRule: searchRule.coverUrl ?? '',
        bookUrlRule: searchRule.bookUrl ?? '',
        introRule: searchRule.intro ?? '',
        kindRule: searchRule.kind ?? '',
        lastChapterRule: searchRule.lastChapter ?? '',
        wordCountRule: searchRule.wordCount ?? '',
        baseUrl: parsed.url,
        redirectUrl: response.url,
        source: source,
        sourceMap: searchSourceMap,
        extraEnv: {'key': keyword, 'page': page},
      );

      // 借鉴 legado：搜索结果去重
      final seen = <String>{};
      final dedupedResults = <Map<String, dynamic>>[];
      for (final book in results) {
        final key = '${book['name']}_${book['author']}';
        if (!seen.contains(key)) {
          seen.add(key);
          dedupedResults.add(book);
        }
      }

      // 调试：如果元素不为空但结果为空，输出详细诊断
      if (bookElements.isNotEmpty && dedupedResults.isEmpty) {
        final diagInfo = '元素数:${bookElements.length}, 但所有元素name为空!\n'
            'name规则: ${searchRule.name ?? ""}\n'
            '第一个元素类型: ${bookElements.first.runtimeType}\n'
            '第一个元素HTML: ${bookElements.first is dom.Element ? (bookElements.first as dom.Element).outerHtml : "$bookElements.first"}';
        AppLogger.instance.warn(LogCategory.parse, '搜索结果诊断', detail: diagInfo);
        debugPrint('⚠️ $diagInfo');
      }

      debugPrint('📖 最终结果数量: ${dedupedResults.length}');
      return dedupedResults;
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
    final nameRule =
        useSearchFallback ? (searchRule?.name ?? '') : (exploreRule.name ?? '');

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
      lastExploreUrl = parsed.url;  // 保存发现链接

      AppLogger.instance.info(LogCategory.network,
          '发现响应: ${html.length} chars, 状态码: ${response.statusCode}');
      if (html.isEmpty) {
        AppLogger.instance.error(LogCategory.network, '发现响应为空',
            detail: 'URL: ${parsed.url}\n状态码: ${response.statusCode}');
        lastExploreHtml = '<!-- 发现响应为空 -->\n'
            '<!-- URL: ${parsed.url} -->\n'
            '<!-- 状态码: ${response.statusCode} -->';
        return [];
      }

      // 使用 AnalyzeRule 引擎解析
      // 预计算 sourceMap，避免在发现结果循环内重复创建
      final exploreSourceMap = _sourceToMap(source);
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: response.url)
        ..setRedirectUrl(response.url)
        ..setSourceEngine(source.engineType)
        ..setSourceInfo(exploreSourceMap)
        ..putVariable('baseUrl', exploreUrl)
        ..putVariable('url', exploreUrl)
        ..putVariable('page', 1);

      final bookElements = await analyzer.getElementsAsync(bookListRule);

      // 保存原始元素数量（用于调试）
      lastExploreElementCount = bookElements.length;

      if (bookElements.isEmpty) return [];

      // [性能] 全量并发 + 空规则跳过，复用 _extractBookItems
      final nameRule = (useSearchFallback ? (searchRule?.name) : exploreRule.name) ?? '';
      final authorRule = (useSearchFallback ? (searchRule?.author) : exploreRule.author) ?? '';
      final coverUrlRule = (useSearchFallback ? (searchRule?.coverUrl) : exploreRule.coverUrl) ?? '';
      final introRule = (useSearchFallback ? (searchRule?.intro) : exploreRule.intro) ?? '';
      final bookUrlRule = (useSearchFallback ? (searchRule?.bookUrl) : exploreRule.bookUrl) ?? '';
      final kindRule = (useSearchFallback ? (searchRule?.kind) : exploreRule.kind) ?? '';
      final lastChapterRule = (useSearchFallback ? (searchRule?.lastChapter) : exploreRule.lastChapter) ?? '';
      final wordCountRule = (useSearchFallback ? (searchRule?.wordCount) : exploreRule.wordCount) ?? '';

      final results = await _extractBookItems(
        elements: bookElements,
        nameRule: nameRule,
        authorRule: authorRule,
        coverUrlRule: coverUrlRule,
        bookUrlRule: bookUrlRule,
        introRule: introRule,
        kindRule: kindRule,
        lastChapterRule: lastChapterRule,
        wordCountRule: wordCountRule,
        baseUrl: exploreUrl,
        redirectUrl: response.url,
        source: source,
        sourceMap: exploreSourceMap,
      );

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
      final response = await _executeRequest(_parseUrlWithOption(bookUrl));
      var html = response.body;

      AppLogger.instance.info(LogCategory.network,
          '详情响应: ${html.length} chars, 状态码: ${response.statusCode}');
      if (html.isEmpty) {
        AppLogger.instance.error(LogCategory.network, '详情响应为空',
            detail: 'URL: $bookUrl\n状态码: ${response.statusCode}');
        lastBookInfoHtml = '<!-- 详情响应为空 -->\n'
            '<!-- URL: $bookUrl -->\n'
            '<!-- 状态码: ${response.statusCode} -->';
        return null;
      }

      // 使用 AnalyzeRule 引擎解析
      // 对齐 legado BookInfo:43: setContent(body, baseUrl).setRedirectUrl(redirectUrl)
      var analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: bookUrl)
        ..setRedirectUrl(response.url)
        ..setSourceEngine(source.engineType)
        ..setSourceInfo(_sourceToMap(source));
      // 借鉴 legado 的 BookInfo.kt：init 规则用 getElement() 获取元素对象
      // legado: analyzeRule.setContent(analyzeRule.getElement(infoRule.init))
      if (bookInfoRule.init != null && bookInfoRule.init!.isNotEmpty) {
        final initElement = analyzer.getElement(bookInfoRule.init!);
        if (initElement != null) {
          analyzer.setContent(initElement);
          if (_loggedRuleTags.add('详情_init')) {
            AppLogger.instance.logJsResult('init', '元素定位成功，内容已替换');
          }
        }
      }

      // 保存源码
      lastBookInfoHtml = html;

      // [性能] 详情页 8 字段并发提取，替代逐个串行 await
      final detailFields = await Future.wait([
        analyzer.getStringAsync(bookInfoRule.name ?? ''),
        analyzer.getStringAsync(bookInfoRule.author ?? ''),
        analyzer.getStringAsync(bookInfoRule.coverUrl ?? ''),
        analyzer.getStringAsync(bookInfoRule.intro ?? ''),
        analyzer.getStringAsync(bookInfoRule.kind ?? ''),
        analyzer.getStringAsync(bookInfoRule.lastChapter ?? ''),
        analyzer.getStringAsync(bookInfoRule.wordCount ?? ''),
        analyzer.getStringAsync(bookInfoRule.tocUrl ?? ''),
      ]);
      final name = detailFields[0];
      final author = detailFields[1];
      final rawCoverUrl = detailFields[2];
      final intro = detailFields[3];
      final kind = detailFields[4];
      final lastChapter = detailFields[5];
      final wordCount = detailFields[6];
      final rawTocUrl = detailFields[7];

      // 拼接相对链接：用详情页URL作为基准
      final resolvedCoverUrl = resolveUrl(rawCoverUrl, bookUrl);
      final resolvedTocUrl = resolveUrl(rawTocUrl, bookUrl);

      AppLogger.instance.info(
          LogCategory.parse, '详情: 书名=$name, 作者=$author, 目录=$resolvedTocUrl');

      return Book(
        bookUrl: bookUrl,
        name: name ?? '未知书名',
        author: author ?? '',
        coverUrl: resolvedCoverUrl,
        intro: intro ?? '',
        mediaType: source.bookSourceType.mediaType,
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
      AppLogger.instance
          .error(LogCategory.parse, '获取详情失败', detail: e.toString());
      return null;
    }
  }

  /// 获取章节目录
  /// 直接翻译 legado BookChapterList.analyzeChapterList
  Future<List<Chapter>> getChapterList(String tocUrl,
      {Book? book,
      Set<String>? visitedTocUrls,
      int depth = 0}) async {
    final tocRule = source.ruleToc;
    if (tocRule == null) return [];

    await _loadJsLib();

    try {
      // legado: body ?: throw
      final response = await _executeRequest(_parseUrlWithOption(tocUrl));
      var html = response.body;
      if (html.isEmpty) {
        lastTocHtml = '<!-- 目录响应为空 -->';
        return [];
      }

      // preUpdateJs
      if (tocRule.preUpdateJs != null && tocRule.preUpdateJs!.isNotEmpty) {
        final preResult = await _executeJs(tocRule.preUpdateJs!,
            result: html, baseUrl: tocUrl);
        if (preResult != null && preResult.isNotEmpty) {
          html = preResult;
        }
      }
      lastTocHtml = html;

      // legado: val chapterList = ArrayList<BookChapter>()
      var chapterList = <Chapter>[];

      // legado: val nextUrlList = arrayListOf(redirectUrl)
      final nextUrlList = <String>[response.url];

      // legado: var reverse = false; var listRule = tocRule.chapterList ?: ""
      var reverse = false;
      var listRule = tocRule.chapterList ?? '';
      if (listRule.startsWith('-')) {
        reverse = true;
        listRule = listRule.substring(1);
      }
      if (listRule.startsWith('+')) {
        listRule = listRule.substring(1);
      }

      // legado: var chapterData = analyzeChapterList(book, baseUrl, redirectUrl, body, ...)
      // baseUrl = tocUrl (请求URL), redirectUrl = response.url (重定向后URL)
      var chapterData = await _analyzeChapterList(
        baseUrl: tocUrl,
        redirectUrl: response.url,
        body: html,
        tocRule: tocRule,
        listRule: listRule,
        book: book,
      );

      // legado: chapterList.addAll(chapterData.first)
      chapterList.addAll(chapterData.$1);
      lastTocElementCount = chapterData.$1.length;

      // legado: when (chapterData.second.size)
      final nextUrls = chapterData.$2;
      switch (nextUrls.length) {
        case 0:
          break;
        case 1:
          // legado: var nextUrl = chapterData.second[0]
          var nextUrl = nextUrls[0];
          // legado: while (nextUrl.isNotEmpty() && !nextUrlList.contains(nextUrl))
          while (nextUrl.isNotEmpty && !nextUrlList.contains(nextUrl)) {
            nextUrlList.add(nextUrl);
            try {
              final nextResponse =
                  await _executeRequest(_parseUrlWithOption(nextUrl));
              final nextBody = nextResponse.body;
              if (nextBody.isEmpty) break;
              // legado: analyzeChapterList(book, nextUrl, nextUrl, nextBody, ...)
              // 串行翻页: baseUrl=nextUrl, redirectUrl=nextUrl
              chapterData = await _analyzeChapterList(
                baseUrl: nextUrl,
                redirectUrl: nextUrl,
                body: nextBody,
                tocRule: tocRule,
                listRule: listRule,
                book: book,
              );
              // legado: nextUrl = chapterData.second.firstOrNull() ?: ""
              nextUrl =
                  chapterData.$2.isNotEmpty ? chapterData.$2[0] : '';
              chapterList.addAll(chapterData.$1);
            } catch (e) {
              AppLogger.instance.warn(LogCategory.parse,
                  '目录串行翻页失败 [$nextUrl]: $e');
              break;
            }
          }
          break;
        default:
          // legado: 并发模式 flow { for (urlStr in chapterData.second) emit(urlStr) }
          //   .mapAsync { urlStr -> analyzeChapterList(book, urlStr, res.url, res.body!!, ...) }
          AppLogger.instance.info(LogCategory.parse,
              '目录并发抓取 [count=${nextUrls.length}]');
          const concurrency = 8;
          for (int i = 0; i < nextUrls.length; i += concurrency) {
            final batch = nextUrls.skip(i).take(concurrency).toList();
            final batchResults = await Future.wait(
              batch.map((url) async {
                try {
                  final res = await _executeRequest(_parseUrlWithOption(url));
                  if (res.body.isEmpty) return <Chapter>[];
                  final data = await _analyzeChapterList(
                    baseUrl: url,
                    redirectUrl: res.url,
                    body: res.body,
                    tocRule: tocRule,
                    listRule: listRule,
                    book: book,
                    getNextUrl: false,
                  );
                  return data.$1;
                } catch (e) {
                  AppLogger.instance.warn(LogCategory.parse,
                      '目录并发抓取失败 [$url]: $e');
                  return <Chapter>[];
                }
              }),
            );
            for (final chapters in batchResults) {
              chapterList.addAll(chapters);
            }
          }
          break;
      }

      if (chapterList.isEmpty) return [];

      // legado: if (!reverse) chapterList.reverse()
      if (!reverse) {
        chapterList = chapterList.reversed.toList();
      }

      // legado: val lh = LinkedHashSet(chapterList); val list = ArrayList(lh)
      // LinkedHashSet 去重，保留后出现的（因为已反转）
      final seen = <String?>{};
      final deduped = <Chapter>[];
      for (final c in chapterList) {
        if (c.url == null || seen.add(c.url)) {
          deduped.add(c);
        }
      }

      // legado: if (!book.getReverseToc()) list.reverse()
      // 默认 book.getReverseToc() = false，所以默认再反转回来
      var list = deduped.reversed.toList();

      // legado: list.forEachIndexed { index, bookChapter -> bookChapter.index = index }
      for (int i = 0; i < list.length; i++) {
        list[i] = list[i].copyWith(index: i);
      }

      // formatJs: legado 在去重后逐个修改 bookChapter.title
      if (tocRule.formatJs != null && tocRule.formatJs!.isNotEmpty) {
        // [性能] 扩大 formatJs 批次从 8→32，减少 JS 引擎调度开销
        const batchSize = 32;
        for (int i = 0; i < list.length; i += batchSize) {
          final batchEnd = (i + batchSize).clamp(0, list.length);
          final indices = List.generate(batchEnd - i, (j) => i + j);
          final batchResults = await Future.wait(
            indices.map((idx) => _executeJs(tocRule.formatJs!,
              result: jsonEncode({
                'index': idx + 1,
                'title': list[idx].title,
              }),
              baseUrl: tocUrl)),
          );
          for (int j = 0; j < indices.length; j++) {
            final formatResult = batchResults[j];
            if (formatResult != null && formatResult.isNotEmpty) {
              list[indices[j]] = list[indices[j]].copyWith(title: formatResult);
            }
          }
        }
      }

      return list;
    } catch (e) {
      AppLogger.instance
          .error(LogCategory.parse, '获取目录失败', detail: e.toString());
      return [];
    }
  }

  /// 通用列表书籍提取方法：[全量并发] + [空规则跳过] + [批量JS预计算]
  /// 搜索/发现/详情列表共用，减少重复代码
  Future<List<Map<String, dynamic>>> _extractBookItems({
    required List<dynamic> elements,
    required String nameRule,
    required String authorRule,
    required String coverUrlRule,
    required String bookUrlRule,
    required String introRule,
    required String kindRule,
    required String lastChapterRule,
    required String wordCountRule,
    required String baseUrl,
    required String redirectUrl,
    required BookSource source,
    required Map<String, dynamic> sourceMap,
    Map<String, dynamic>? extraEnv,
  }) async {
    // 预计算空规则跳过标志
    final hasName = nameRule.isNotEmpty;
    final hasAuthor = authorRule.isNotEmpty;
    final hasCover = coverUrlRule.isNotEmpty;
    final hasIntro = introRule.isNotEmpty;
    final hasBookUrl = bookUrlRule.isNotEmpty;
    final hasKind = kindRule.isNotEmpty;
    final hasLastChapter = lastChapterRule.isNotEmpty;
    final hasWordCount = wordCountRule.isNotEmpty;

    // [批量JS优化] 预检查每个字段是否为 JS 规则（@js: 或 <js> 开头）
    // JS 规则：一次 batchEvaluate 全部元素，1 次 FFI 替代 N 次 processJsRule
    // 非 JS 规则（CSS/Jsoup/JSON 等）：走逐元素 getStringAsync
    final isNameJs = hasName && (nameRule.startsWith('@js:') || nameRule.startsWith('<js>'));
    final isAuthorJs = hasAuthor && (authorRule.startsWith('@js:') || authorRule.startsWith('<js>'));
    final isCoverJs = hasCover && (coverUrlRule.startsWith('@js:') || coverUrlRule.startsWith('<js>'));
    final isIntroJs = hasIntro && (introRule.startsWith('@js:') || introRule.startsWith('<js>'));
    final isBookUrlJs = hasBookUrl && (bookUrlRule.startsWith('@js:') || bookUrlRule.startsWith('<js>'));
    final isKindJs = hasKind && (kindRule.startsWith('@js:') || kindRule.startsWith('<js>'));
    final isLastChapterJs = hasLastChapter && (lastChapterRule.startsWith('@js:') || lastChapterRule.startsWith('<js>'));
    final isWordCountJs = hasWordCount && (wordCountRule.startsWith('@js:') || wordCountRule.startsWith('<js>'));

    final batchAnalyzer = AnalyzeRule()
      ..setContent(elements.isNotEmpty ? elements[0] : '', baseUrl: baseUrl)
      ..setRedirectUrl(redirectUrl)
      ..setSourceEngine(source.engineType)
      ..setSourceInfo(sourceMap);

    // 并发发射所有 JS batch（非 JS 字段为 null，不参与 await）
    final batchFutures = <Future<List<String?>>?>[];
    if (isNameJs) batchFutures.add(batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(nameRule)));
    if (isAuthorJs) batchFutures.add(batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(authorRule)));
    if (isCoverJs) batchFutures.add(batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(coverUrlRule)));
    if (isIntroJs) batchFutures.add(batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(introRule)));
    if (isBookUrlJs) batchFutures.add(batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(bookUrlRule)));
    if (isKindJs) batchFutures.add(batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(kindRule)));
    if (isLastChapterJs) batchFutures.add(batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(lastChapterRule)));
    if (isWordCountJs) batchFutures.add(batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(wordCountRule)));

    final batchResults = await Future.wait(
      batchFutures.map((f) => f ?? Future.value(null)),
    );

    // 按 batchFutures 添加顺序提取结果
    int bi = 0;
    final batchNames = isNameJs ? batchResults[bi++] : null;
    final batchAuthors = isAuthorJs ? batchResults[bi++] : null;
    final batchCovers = isCoverJs ? batchResults[bi++] : null;
    final batchIntros = isIntroJs ? batchResults[bi++] : null;
    final batchBookUrls = isBookUrlJs ? batchResults[bi++] : null;
    final batchKinds = isKindJs ? batchResults[bi++] : null;
    final batchLastChapters = isLastChapterJs ? batchResults[bi++] : null;
    final batchWordCounts = isWordCountJs ? batchResults[bi++] : null;

    // [性能] 全量并发：所有元素一次性发射
    final allResults = await Future.wait(
      List.generate(elements.length, (i) async {
        var element = elements[i];
        // 处理非 HTML 字符串元素
        if (element is String && element.isNotEmpty && !element.trim().startsWith('<')) {
          element = '<div>$element</div>';
        }

        final itemAnalyzer = AnalyzeRule()
          ..setContent(element, baseUrl: baseUrl)
          ..setRedirectUrl(redirectUrl)
          ..setSourceEngine(source.engineType)
          ..setSourceInfo(sourceMap);
        if (extraEnv != null) {
          for (final entry in extraEnv.entries) {
            itemAnalyzer.putVariable(entry.key, entry.value);
          }
        }

        // JS 规则从预计算结果数组取值，非 JS 规则走逐元素异步
        final futures = <Future<String?>>[];
        if (hasName) {
          if (isNameJs) {
            futures.add(Future.value(batchNames![i]));
          } else {
            futures.add(itemAnalyzer.getStringAsync(nameRule).catchError((_) => null));
          }
        }
        if (hasAuthor) {
          if (isAuthorJs) {
            futures.add(Future.value(batchAuthors![i]));
          } else {
            futures.add(itemAnalyzer.getStringAsync(authorRule).catchError((_) => null));
          }
        }
        if (hasCover) {
          if (isCoverJs) {
            futures.add(Future.value(batchCovers![i]));
          } else {
            futures.add(itemAnalyzer.getStringAsync(coverUrlRule, isUrl: true).catchError((_) => null));
          }
        }
        if (hasIntro) {
          if (isIntroJs) {
            futures.add(Future.value(batchIntros![i]));
          } else {
            futures.add(itemAnalyzer.getStringAsync(introRule).catchError((_) => null));
          }
        }
        if (hasBookUrl) {
          if (isBookUrlJs) {
            futures.add(Future.value(batchBookUrls![i]));
          } else {
            futures.add(itemAnalyzer.getStringAsync(bookUrlRule, isUrl: true).catchError((_) => null));
          }
        }
        if (hasKind) {
          if (isKindJs) {
            futures.add(Future.value(batchKinds![i]));
          } else {
            futures.add(itemAnalyzer.getStringAsync(kindRule).catchError((_) => null));
          }
        }
        if (hasLastChapter) {
          if (isLastChapterJs) {
            futures.add(Future.value(batchLastChapters![i]));
          } else {
            futures.add(itemAnalyzer.getStringAsync(lastChapterRule).catchError((_) => null));
          }
        }
        if (hasWordCount) {
          if (isWordCountJs) {
            futures.add(Future.value(batchWordCounts![i]));
          } else {
            futures.add(itemAnalyzer.getStringAsync(wordCountRule).catchError((_) => null));
          }
        }

        final fields = futures.isNotEmpty ? await Future.wait(futures) : [];
        int fi = 0;

        var name = hasName ? (fields[fi++] ?? '') : '';
        final author = hasAuthor ? (fields[fi++] ?? '') : '';
        final coverUrl = hasCover ? (fields[fi++] ?? '') : '';
        var intro = hasIntro ? (fields[fi++] ?? '') : '';
        final bookUrl = hasBookUrl ? (fields[fi++] ?? '') : '';
        final kind = hasKind ? (fields[fi++] ?? '') : '';
        final lastChapter = hasLastChapter ? (fields[fi++] ?? '') : '';
        final wordCount = hasWordCount ? (fields[fi++] ?? '') : '';

        if (name.isNotEmpty) {
          name = _formatBookName(name);
          if (intro.isNotEmpty) intro = _formatIntro(intro);
          return <String, dynamic>{
            'name': name,
            'author': _formatBookAuthor(author),
            'coverUrl': resolveUrl(coverUrl, source.bookSourceUrl),
            'intro': intro,
            'bookUrl': resolveUrl(bookUrl, source.bookSourceUrl),
            'kind': kind,
            'lastChapter': lastChapter,
            'wordCount': wordCount,
            'sourceUrl': source.bookSourceUrl,
            'sourceName': source.bookSourceName,
            'mediaType': source.bookSourceType.mediaType.index,
            'originType': BookOriginType.online.index,
          };
        }
        return null;
      }),
    );

    final results = <Map<String, dynamic>>[];
    for (final r in allResults) {
      if (r != null) results.add(r);
    }
    return results;
  }

  /// 剥离 JS 规则前缀/标签，返回纯 JS 代码
  static String _stripJsTag(String rule) {
    if (rule.startsWith('@js:')) return rule.substring(4);
    if (rule.startsWith('<js>') && rule.endsWith('</js>')) {
      return rule.substring(4, rule.length - 5);
    }
    return rule;
  }

  /// 对齐 legado BookChapterList.analyzeChapterList (内层)
  /// 返回 (chapterList, nextUrlList)
  Future<(List<Chapter>, List<String>)> _analyzeChapterList({
    required String baseUrl,
    required String redirectUrl,
    required String body,
    required dynamic tocRule,
    required String listRule,
    Book? book,
    bool getNextUrl = true,
  }) async {
    // legado: analyzeRule.setContent(body).setBaseUrl(baseUrl).setRedirectUrl(redirectUrl)
    // 预计算 sourceMap 和 bookMap，避免在 1000+ 章节的循环内重复创建 Map
    final sourceMap = _sourceToMap(source);
    final bookMap = book != null ? _bookToMap(book) : null;

    final analyzeRule = AnalyzeRule()
      ..setContent(body, baseUrl: baseUrl)
      ..setRedirectUrl(redirectUrl)
      ..setSourceEngine(source.engineType)
      ..setSourceInfo(sourceMap)
      ..setBookInfo(bookMap);

    // legado: val chapterList = arrayListOf<BookChapter>()
    final chapterList = <Chapter>[];

    // legado: val elements = analyzeRule.getElements(listRule)
    // 关键修复：必须用 getElementsAsync 走 Native JSoup 引擎！
    // 之前用同步 getElements 走 Dart html 包，和后续 getStringAsync 走的 Kotlin JSoup 不一致！
    final elements = await analyzeRule.getElementsAsync(listRule);

    // legado: val nextUrlList = arrayListOf<String>()
    final nextUrlList = <String>[];

    // legado: if (getNextUrl && !nextTocRule.isNullOrEmpty())
    final nextTocRule = tocRule.nextTocUrl;
    if (getNextUrl && nextTocRule != null && nextTocRule.isNotEmpty) {
      // legado: analyzeRule.getStringList(nextTocRule, isUrl = true)?.let { for (item in it) if (item != redirectUrl) nextUrlList.add(item) }
      final urls = await analyzeRule.getStringListAsync(nextTocRule, isUrl: true);
      for (final item in urls) {
        if (item != redirectUrl) {
          nextUrlList.add(item);
        }
      }
    }

    // legado: if (elements.isNotEmpty)
    if (elements.isNotEmpty) {
      final hasName = (tocRule.chapterName ?? '').isNotEmpty;
      final hasUrl = (tocRule.chapterUrl ?? '').isNotEmpty;
      final hasVolume = (tocRule.isVolume ?? '').isNotEmpty;
      final hasTime = (tocRule.updateTime ?? '').isNotEmpty;
      final hasVip = (tocRule.isVip ?? '').isNotEmpty;
      final hasPay = (tocRule.isPay ?? '').isNotEmpty;

      // [批量JS优化] 预检查每个字段是否为 JS 规则（@js: 或 <js> 开头）
      // JS 规则：一次 batchEvaluate 全部元素，1 次 FFI 替代 N 次
      // 非 JS 规则（CSS/Jsoup/JSON 等）：走逐元素 fast path
      final nameRule = tocRule.chapterName ?? '';
      final urlRule = tocRule.chapterUrl ?? '';
      final volumeRule = tocRule.isVolume ?? '';
      final timeRule = tocRule.updateTime ?? '';
      final vipRule = tocRule.isVip ?? '';
      final payRule = tocRule.isPay ?? '';

      final isNameJs = nameRule.startsWith('@js:') || nameRule.startsWith('<js>');
      final isUrlJs = urlRule.startsWith('@js:') || urlRule.startsWith('<js>');
      final isVolumeJs = hasVolume && (volumeRule.startsWith('@js:') || volumeRule.startsWith('<js>'));
      final isTimeJs = hasTime && (timeRule.startsWith('@js:') || timeRule.startsWith('<js>'));
      final isVipJs = hasVip && (vipRule.startsWith('@js:') || vipRule.startsWith('<js>'));
      final isPayJs = hasPay && (payRule.startsWith('@js:') || payRule.startsWith('<js>'));

      // [性能] 并发批次：所有字段的 batch evaluate 一次性发射
      // 之前：await batchNames → await batchUrls → ... 串行 6 轮
      // 现在：Future.wait 并发 6 个 batch，1 轮等待
      final batchAnalyzer = AnalyzeRule()
        ..setContent(body, baseUrl: baseUrl)
        ..setRedirectUrl(redirectUrl)
        ..setSourceEngine(source.engineType)
        ..setSourceInfo(sourceMap)
        ..setBookInfo(bookMap);

      final batchFutures = <Future<List<String?>>?>[];
      batchFutures.add(isNameJs ? batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(nameRule)) : null);
      batchFutures.add(isUrlJs ? batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(urlRule)) : null);
      batchFutures.add(isVolumeJs ? batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(volumeRule)) : null);
      batchFutures.add(isTimeJs ? batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(timeRule)) : null);
      batchFutures.add(isVipJs ? batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(vipRule)) : null);
      batchFutures.add(isPayJs ? batchAnalyzer.batchApplyJsAsync(elements, _stripJsTag(payRule)) : null);

      // 并发发射所有 JS batch（非 JS 字段为 null，不参与 await）
      final batchResults = await Future.wait(
        batchFutures.map((f) => f ?? Future.value(null)),
      );

      final batchNames = batchResults[0];
      final batchUrls = batchResults[1];
      final batchVolumes = batchResults[2];
      final batchTimes = batchResults[3];
      final batchVips = batchResults[4];
      final batchPays = batchResults[5];

      final allResults = await Future.wait(
        List.generate(elements.length, (idx) async {
          final item = elements[idx];
          final itemAnalyzer = AnalyzeRule()
            ..setContent(item, baseUrl: baseUrl)
            ..setRedirectUrl(redirectUrl)
            ..setSourceEngine(source.engineType)
            ..setSourceInfo(sourceMap)
            ..setBookInfo(bookMap);

          // JS 规则从预计算结果数组取值，非 JS 规则走逐元素异步
          final futures = <Future<String?>>[];
          if (hasName) {
            if (isNameJs) {
              // 从批量结果取值，零 FFI 调用
              futures.add(Future.value(batchNames![idx]));
            } else {
              futures.add(itemAnalyzer.getStringAsync(nameRule).catchError((_) => null));
            }
          }
          if (hasUrl) {
            if (isUrlJs) {
              futures.add(Future.value(batchUrls![idx]));
            } else {
              futures.add(itemAnalyzer.getStringAsync(urlRule).catchError((_) => null));
            }
          }
          if (hasVolume) {
            if (isVolumeJs) {
              futures.add(Future.value(batchVolumes![idx]));
            } else {
              futures.add(itemAnalyzer.getStringAsync(volumeRule).catchError((_) => null));
            }
          }
          if (hasTime) {
            if (isTimeJs) {
              futures.add(Future.value(batchTimes![idx]));
            } else {
              futures.add(itemAnalyzer.getStringAsync(timeRule).catchError((_) => null));
            }
          }
          if (hasVip) {
            if (isVipJs) {
              futures.add(Future.value(batchVips![idx]));
            } else {
              futures.add(itemAnalyzer.getStringAsync(vipRule).catchError((_) => null));
            }
          }
          if (hasPay) {
            if (isPayJs) {
              futures.add(Future.value(batchPays![idx]));
            } else {
              futures.add(itemAnalyzer.getStringAsync(payRule).catchError((_) => null));
            }
          }

          final fields = futures.isNotEmpty ? await Future.wait(futures) : [];
          int fi = 0;
          final title = hasName ? (fields[fi++] ?? '') : '';
          final url = hasUrl ? (fields[fi++] ?? '') : '';
          final isVolume = hasVolume ? _isRuleTrue(fields[fi++]) : false;
          final info = hasTime ? (fields[fi++] ?? '') : '';
          final isVip = hasVip ? _isRuleTrue(fields[fi++]) : false;
          final isPay = hasPay ? _isRuleTrue(fields[fi++]) : false;

          var resolvedUrl = url;
          if (resolvedUrl.isEmpty) {
            resolvedUrl = isVolume ? '$title$idx' : baseUrl;
          } else {
            resolvedUrl = resolveUrl(url, redirectUrl);
          }

          // legado: if (bookChapter.title.isNotEmpty)
          final finalTitle = title;
          if (finalTitle.isNotEmpty) {
            return Chapter(
              id: '${baseUrl}_$idx',
              bookId: book?.bookUrl ?? baseUrl,
              title: finalTitle,
              index: idx,
              url: resolvedUrl,
              isVolume: isVolume,
              isVip: isVip,
              isPay: isPay,
              tag: isVolume ? info : info,
            );
          }
          return null;
        }),
      );
      for (final chapter in allResults) {
        if (chapter != null) chapterList.add(chapter);
      }
    }

    // legado: return Pair(chapterList, nextUrlList)
    return (chapterList, nextUrlList);
  }

  /// 获取章节正文
  static bool _isRuleTrue(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty || normalized == 'null') {
      return false;
    }
    return !const {'false', 'no', 'not', '0', '0.0'}.contains(normalized);
  }

  Future<String?> getContent(String chapterUrl,
      {Book? book, Chapter? chapter,
      String? nextChapterUrl,
      Set<String>? visitedUrls,
      int depth = 0}) async {
    final contentRule = source.ruleContent;
    if (contentRule == null) return null;

    AppLogger.instance.debug(LogCategory.parse,
        'getContent 入口: chapterUrl=$chapterUrl, nextChapterUrl=$nextChapterUrl, hasAllChapters=${nextChapterUrl != null}');

    // 加载书源 JS 库
    await _loadJsLib();

    // 防死循环：记录已访问的 URL
    final visited = visitedUrls ?? <String>{};
    visited.add(chapterUrl);
    // legado 默认最多 10 页（防止某些书源无限翻页）
    if (depth >= 10) {
      AppLogger.instance.warn(LogCategory.parse, '正文翻页超过 10 层，强制终止',
          detail: 'URL: $chapterUrl');
      return null;
    }

    try {
      final response = await _executeRequest(_parseUrlWithOption(chapterUrl));
      var html = response.body;

      AppLogger.instance.info(LogCategory.network,
          '正文响应: ${html.length} chars, 状态码: ${response.statusCode}');
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

      // If webJs is set, use WebView to render the page
      if (contentRule.webJs != null && contentRule.webJs!.isNotEmpty) {
        try {
          final webJsResult = await JsAdvancedService.instance.executeWebJs(
            url: response.url,
            webJs: contentRule.webJs!,
            source: source,
            sourceRegex: contentRule.sourceRegex,
            html: html,
          );
          if (webJsResult != null && webJsResult.isNotEmpty) {
            html = webJsResult;
            lastContentHtml = html;
          }
        } catch (e) {
          debugPrint('❌ webJs执行失败: $e');
        }
      }

      // 使用 AnalyzeRule 引擎解析正文
      // 对齐 legado BookContent:63: analyzeRule.setContent(body, baseUrl)
      // baseUrl = 请求 URL (chapterUrl), redirectUrl = 重定向后的 URL (response.url)
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: chapterUrl)
        ..setRedirectUrl(response.url)
        ..setSourceEngine(source.engineType)
        ..setSourceInfo(_sourceToMap(source))
        ..setBookInfo(book != null ? _bookToMap(book) : null)
        ..setChapterInfo(chapter != null ? _chapterToMap(chapter) : null);
      // 对齐 legado BookContent.kt：先不 unescape，格式化后再 unescape
      // legado: getString(contentRule.content, unescape = false) → formatKeepImg → unescapeHtml4
      var content = await analyzer.getStringAsync(contentRule.content ?? '', unescape: false);
      // #region debug-point H3: 正文规则解析返回的原始 HTML 长度
      AppLogger.instance.info(LogCategory.parse,
          '[DBG-H3] 正文规则解析: rawLen=${content?.length ?? 0}',
          detail: 'rule: ${contentRule.content}\nfullContent: ${content ?? ""}');
      // #endregion
      // 正文 HTML 格式化（对齐 legado HtmlFormatter.formatKeepImg）
      // 将 <p>/<div>/<br> 等块级标签替换为换行符，移除非 img 标签，补全 img URL
      if (content != null && content.isNotEmpty) {
        final _beforeFmtLen = content.length;
        content = _formatContentHtml(content, response.url);
        // #region debug-point H4: 格式化前后长度对比
        AppLogger.instance.info(LogCategory.parse,
            '[DBG-H4] 正文格式化: $_beforeFmtLen → ${content.length}',
            detail: 'fullContent: $content');
        // #endregion
        // 对齐 legado：格式化后再 unescape HTML 实体
        if (content.contains('&')) {
          content = _unescapeHtml(content);
        }
      }
      // 诊断日志：正文规则执行结果（空时打印规则便于排查）
      if (content == null || content.isEmpty) {
        AppLogger.instance.warn(LogCategory.parse,
            '正文规则提取为空',
            detail: 'rule: ${contentRule.content}\nhtml length: ${html.length}\nurl: $chapterUrl');
      } else {
        debugPrint('✅ 正文提取成功: ${content.length} chars (rule: ${contentRule.content})');
      }
      final subContent = await analyzer.getStringAsync(contentRule.subContent ?? '');
      if (subContent != null && subContent.isNotEmpty) {
        content = '${content ?? ''}\n$subContent'.trim();
      }

      if (_loggedRuleTags.add('正文')) {
        AppLogger.instance.logParseResult('正文', content != null ? 1 : 0);
      }

      // 处理 nextContentUrl（正文下一页）
      // 对齐 legado BookContent.kt:257-259: nextUrlList.addAll(it)
      // legado 不过滤当前页 URL，靠 nextUrlList.contains(nextUrl) 去重
      if (contentRule.nextContentUrl != null &&
          contentRule.nextContentUrl!.isNotEmpty) {
        final rawNextUrls = await analyzer.getStringListAsync(
            contentRule.nextContentUrl!, isUrl: true);

        // 对齐 legado: 直接 addAll，不过滤
        final nextUrls = <String>[];
        for (final raw in rawNextUrls) {
          if (raw.isNotEmpty && !nextUrls.contains(raw)) {
            nextUrls.add(raw);
          }
        }

        if (nextUrls.isEmpty) {
          AppLogger.instance.warn(LogCategory.parse,
              '正文下页规则提取为空',
              detail: 'rule: ${contentRule.nextContentUrl}\nhtml length: ${html.length}\nurl: $chapterUrl');
        } else if (nextUrls.length == 1) {
          // ===== 串行翻页模式（legado: size == 1）=====
          // 对齐 legado BookContent:76: while (nextUrl.isNotEmpty && !nextUrlList.contains(nextUrl))
          var nextUrl = nextUrls[0];
          final nextUrlList = <String>[response.url]; // 对齐 legado: nextUrlList = arrayListOf(redirectUrl)
          final contentList = <String>[];
          if (content != null && content.isNotEmpty) contentList.add(content);
          const maxPages = 100;
          int pageCount = 0;

          while (nextUrl.isNotEmpty && !nextUrlList.contains(nextUrl) && pageCount < maxPages) {
            // 对齐 legado BookContent:77-80: 熔断
            // NetworkUtils.getAbsoluteURL(redirectUrl, nextUrl) == NetworkUtils.getAbsoluteURL(redirectUrl, mNextChapterUrl)
            if (nextChapterUrl != null && nextChapterUrl.isNotEmpty) {
              final absNextUrl = resolveUrl(nextUrl, response.url);
              final absNextChapterUrl = resolveUrl(nextChapterUrl, response.url);
              AppLogger.instance.debug(LogCategory.parse,
                  '熔断检查: nextUrl=$absNextUrl vs nextChapterUrl=$absNextChapterUrl');
              if (absNextUrl == absNextChapterUrl) {
                AppLogger.instance.info(LogCategory.parse,
                    '正文串行翻页命中下一章，熔断终止: $nextUrl');
                break;
              }
            } else {
              AppLogger.instance.warn(LogCategory.parse,
                  '熔断器未生效: nextChapterUrl 为空，无法熔断！'
                  '（请检查 getContent 调用时是否传了 allChapters）');
            }
            nextUrlList.add(nextUrl);
            pageCount++;
            try {
              final nextResponse = await _executeRequest(_parseUrlWithOption(nextUrl));
              final nextHtml = nextResponse.body;
              if (nextHtml.isEmpty) break;

              // 对齐 legado BookContent:91-92: analyzeContent(book, nextUrl, res.url, ...)
              final nextAnalyzer = AnalyzeRule()
                ..setContent(nextHtml, baseUrl: nextUrl)
                ..setRedirectUrl(nextResponse.url)
                ..setSourceEngine(source.engineType)
                ..setSourceInfo(_sourceToMap(source))
                ..setBookInfo(book != null ? _bookToMap(book) : null)
                ..setChapterInfo(chapter != null ? _chapterToMap(chapter) : null);

              // 提取正文（对齐 legado：先不 unescape，格式化后再 unescape）
              var nextContent = await nextAnalyzer.getStringAsync(contentRule.content ?? '', unescape: false);
              if (nextContent != null && nextContent.isNotEmpty) {
                nextContent = _formatContentHtml(nextContent, nextResponse.url);
                if (nextContent.contains('&')) {
                  nextContent = _unescapeHtml(nextContent);
                }
                contentList.add(nextContent);
              }

              // 对齐 legado: 从下一页重新提取 nextContentUrl
              final newNextUrls = await nextAnalyzer.getStringListAsync(
                  contentRule.nextContentUrl!, isUrl: true);
              // 对齐 legado BookContent:96-97: nextUrl = if (contentData.second.isNotEmpty) contentData.second[0] else ""
              nextUrl = newNextUrls.isNotEmpty ? newNextUrls[0] : '';
            } catch (e) {
              AppLogger.instance.warn(LogCategory.parse,
                  '正文串行翻页失败 [$nextUrl]: $e');
              break;
            }
          }
          if (pageCount >= maxPages) {
            AppLogger.instance.warn(LogCategory.parse,
                '正文串行翻页达到上限 $maxPages 页，强制终止');
          }
          if (contentList.length > 1) {
            content = contentList.join('\n');
            AppLogger.instance.info(LogCategory.parse,
                '正文串行翻页合并: ${contentList.length}页, ${content.length} chars');
          }
        } else {
          // ===== 并发批量获取模式（legado: size > 1）=====
          // 对齐 legado: 并发模式不做熔断，直接并发获取所有页
          AppLogger.instance.info(LogCategory.parse,
              '正文并发抓取 [count=${nextUrls.length}]');
          const concurrency = 4;
          final allParts = <String?>[];
          for (int i = 0; i < nextUrls.length; i += concurrency) {
            final batch = nextUrls.skip(i).take(concurrency).toList();
            final batchResults = await Future.wait(batch.map((u) =>
                _fetchContentPage(u, book: book, chapter: chapter)
                    .catchError((e) {
                  AppLogger.instance.warn(LogCategory.parse,
                      '正文并发页失败 [$u]: $e');
                  return null;
                })));
            allParts.addAll(batchResults);
          }
          final sb = StringBuffer(content ?? '');
          for (final part in allParts) {
            if (part != null && part.isNotEmpty) {
              if (sb.isNotEmpty) sb.write('\n');
              sb.write(part);
            }
          }
          content = sb.toString();
        }
      }

      // 执行 js 脚本（正文加载后执行的 JS）
      if (contentRule.replaceRegex != null &&
          contentRule.replaceRegex!.isNotEmpty &&
          content != null) {
        content = content.split(RegExp(r'\n')).map((l) => l.trim()).join('\n');
        content = await _applyContentReplaceNative(content, contentRule.replaceRegex!);
      }

      if (contentRule.js != null && contentRule.js!.isNotEmpty) {
        final jsResult = await _executeJs(contentRule.js!,
            result: content ?? '', baseUrl: chapterUrl);
        if (jsResult != null && jsResult.isNotEmpty) {
          content = jsResult;
          if (_loggedRuleTags.add('正文_js')) {
            AppLogger.instance
                .logJsResult('content.js', '${jsResult.length} chars');
          }
        }
      }

      // 执行 callBackJs（内容加载完成后的回调 JS）
      if (contentRule.callBackJs != null &&
          contentRule.callBackJs!.isNotEmpty) {
        final callBackResult = await _executeJs(contentRule.callBackJs!,
            result: content ?? '', baseUrl: chapterUrl);
        if (callBackResult != null && callBackResult.isNotEmpty) {
          content = callBackResult;
          if (_loggedRuleTags.add('正文_callBackJs')) {
            AppLogger.instance
                .logJsResult('callBackJs', '${callBackResult.length} chars');
          }
        }
      }

      // Apply imageDecode if set
      if (contentRule.imageDecode != null &&
          contentRule.imageDecode!.isNotEmpty &&
          content != null) {
        try {
          // Find all image URLs in content and decode them
          final imgPattern = RegExp(
              r'(https?://[^\s"<>]+\.(?:jpg|jpeg|png|gif|webp))',
              caseSensitive: false);
          content = content.replaceAllMapped(imgPattern, (match) {
            final url = match.group(1)!;
            // imageDecode will be called per-image by the reader
            // For now, mark the URL for later processing
            return url;
          });
        } catch (e) {
          debugPrint('❌ imageDecode处理失败: $e');
        }
      }

      return content;
    } catch (e) {
      AppLogger.instance
          .error(LogCategory.parse, '获取正文失败', detail: e.toString());
      return null;
    }
  }

  /// 获取单页正文内容（并发/串行翻页用，不递归提取 nextContentUrl）
  /// 借鉴 legado：并发模式下 getNextPageUrl = false
  Future<String?> _fetchContentPage(String url,
      {Book? book, Chapter? chapter}) async {
    final contentRule = source.ruleContent;
    if (contentRule == null) return null;

    await _loadJsLib();

    try {
      final response = await _executeRequest(_parseUrlWithOption(url));
      var html = response.body;
      if (html.isEmpty) return null;

      if (contentRule.webJs != null && contentRule.webJs!.isNotEmpty) {
        try {
          final webJsResult = await JsAdvancedService.instance.executeWebJs(
            url: response.url,
            webJs: contentRule.webJs!,
            source: source,
            sourceRegex: contentRule.sourceRegex,
            html: html,
          );
          if (webJsResult != null && webJsResult.isNotEmpty) {
            html = webJsResult;
          }
        } catch (_) {}
      }

      // 对齐 legado BookContent:118: analyzeContent(book, urlStr, res.url, ...)
      // baseUrl = 请求 URL (url), redirectUrl = 重定向后的 URL (response.url)
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: url)
        ..setRedirectUrl(response.url)
        ..setSourceEngine(source.engineType)
        ..setSourceInfo(_sourceToMap(source))
        ..setBookInfo(book != null ? _bookToMap(book) : null)
        ..setChapterInfo(chapter != null ? _chapterToMap(chapter) : null);
      var content = await analyzer.getStringAsync(contentRule.content ?? '', unescape: false);
      if (content != null && content.isNotEmpty) {
        content = _formatContentHtml(content, response.url);
        if (content.contains('&')) {
          content = _unescapeHtml(content);
        }
      }
      final subContent = await analyzer.getStringAsync(contentRule.subContent ?? '');
      if (subContent != null && subContent.isNotEmpty) {
        content = '${content ?? ''}\n$subContent'.trim();
      }
      return content;
    } catch (e) {
      AppLogger.instance.warn(LogCategory.parse, '获取正文页失败', detail: '$url: $e');
      return null;
    }
  }

  /// 应用正文替换规则（走 Kotlin AnalyzeRule 引擎）
  /// 借鉴 legado BookContent.kt：replaceRegex 通过 AnalyzeRule.getString 执行
  /// 支持多组 \n 分隔，每组 ## 分隔 pattern##replacement
  /// 优先走 Kotlin 原生引擎（支持 @js: 替换等复杂规则），fallback 到 Dart 简单正则
  Future<String> _applyContentReplaceNative(String content, String replaceRegex) async {
    var result = content;
    final lines = replaceRegex.split('\n');
    for (final line in lines) {
      if (line.isEmpty) continue;

      // Dart 端正则替换
      result = _applyContentReplaceLine(result, line);
    }
    return result;
  }

  /// 单行替换规则的 Dart fallback
  String _applyContentReplaceLine(String content, String line) {
    String pattern;
    String replacement;
    final idx = line.indexOf('##');
    if (idx < 0) {
      pattern = line;
      replacement = '';
    } else if (idx == 0) {
      pattern = line.substring(2);
      replacement = '';
    } else {
      pattern = line.substring(0, idx);
      final rest = line.substring(idx + 2);
      final jsIdx = rest.indexOf('##');
      replacement = jsIdx < 0 ? rest : rest.substring(0, jsIdx);
    }
    if (pattern.isEmpty) return content;

    try {
      final regex = RegExp(pattern, multiLine: true, dotAll: true);
      return content.replaceAll(regex, replacement);
    } catch (e) {
      debugPrint('❌ 替换规则执行失败: $pattern → $e');
      return content;
    }
  }

  // ================== 借鉴 legado 的辅助方法 ==================

  /// 将 BookSource 转为 Map（用于注入 JS 上下文）
  Map<String, dynamic> _sourceToMap(BookSource source) {
    // 注意：不包含 jsLib 字段。jsLib 已通过 _loadJsLib() 加载到 QuickJS 全局作用域，
    // 每次执行 JS 时不需要在 env 中重复序列化 jsLib（可达数十 KB），避免 1000+ 章节
    // 解析时 6000 次 jsonEncode(source) 导致内存峰值过高 OOM 闪退。
    return {
      'bookSourceUrl': source.bookSourceUrl,
      'bookSourceName': source.bookSourceName,
      'bookSourceGroup': source.bookSourceGroup ?? '',
      'bookSourceType': source.bookSourceType.index,
      'header': source.header ?? '',
      'loginUrl': source.loginUrl ?? '',
      'loginCheckJs': source.loginCheckJs ?? '',
      'enabledCookieJar': source.enabledCookieJar,
      'concurrentRate': source.concurrentRate ?? '',
      'variable': source.variable ?? '',
    };
  }

  /// 将 Book 转为 Map（用于注入 JS 上下文）
  Map<String, dynamic> _bookToMap(Book book) {
    return book.toJson();
  }

  /// 将 Chapter 转为 Map（用于注入 JS 上下文）
  Map<String, dynamic> _chapterToMap(Chapter chapter) {
    return chapter.toJson();
  }

  /// 执行 loginCheckJs 检测（借鉴 legado 的登录检测流程）
  /// 返回 true 表示需要登录，false 表示不需要
  // ignore: unused_element
  Future<bool> _checkLoginNeeded(String html) async {
    final checkJs = source.loginCheckJs;
    if (checkJs == null || checkJs.isEmpty) return false;

    try {
      final result = await _executeJs(checkJs,
          result: html, baseUrl: source.bookSourceUrl);
      if (result == null ||
          result.isEmpty ||
          result == 'false' ||
          result == 'null') {
        return false;
      }
      return result == 'true' || result.toLowerCase() == 'needlogin';
    } catch (_) {
      return false;
    }
  }

  /// 书名格式化（借鉴 legado 的 BookHelp.formatBookName）
  static String _formatBookName(String name) {
    var result = name.trim();
    // 去除常见前缀
    for (final prefix in ['《', '「', '【', '『']) {
      if (result.startsWith(prefix)) {
        result = result.substring(1);
      }
    }
    // 去除常见后缀
    for (final suffix in ['》', '」', '】', '』']) {
      if (result.endsWith(suffix)) {
        result = result.substring(0, result.length - 1);
      }
    }
    // 去除多余空白
    result = result.replaceAll(RegExp(r'\s+'), ' ').trim();
    return result;
  }

  /// 作者格式化（借鉴 legado 的 BookHelp.formatBookAuthor）
  static String _formatBookAuthor(String author) {
    var result = author.trim();
    // 去除常见前缀
    for (final prefix in ['作者：', '作者:', '著：', '著:', '文：', '文:']) {
      if (result.startsWith(prefix)) {
        result = result.substring(prefix.length);
      }
    }
    // 去除常见后缀
    for (final suffix in [' 著', '著', ' 编', '编', ' 撰', '撰']) {
      if (result.endsWith(suffix)) {
        result = result.substring(0, result.length - suffix.length);
      }
    }
    result = result.replaceAll(RegExp(r'\s+'), ' ').trim();
    return result;
  }

  /// HTML 实体解码（对齐 legado 的 StringEscapeUtils.unescapeHtml4）
  static String _unescapeHtml(String value) {
    return value
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&ensp;', ' ')
        .replaceAll('&emsp;', ' ')
        .replaceAllMapped(
          RegExp(r'&#(\d+);'),
          (match) => String.fromCharCode(int.parse(match.group(1)!)),
        )
        .replaceAllMapped(
          RegExp(r'&#x([0-9a-fA-F]+);'),
          (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
        );
  }

  /// 简介 HTML 格式化（借鉴 legado 的 HtmlFormatter.format）
  /// 核心逻辑：
  /// - <usehtml>/<md>/<useweb> 前缀：保留原始内容
  /// - 内容中包含有意义的HTML标签：保留HTML（供详情页Html widget渲染）
  /// - 纯文本：清除残留HTML标签 + 实体解码
  static String _formatIntro(String intro) {
    var result = intro.trim();
    // 检测特殊标签（借鉴 legado：<usehtml>/<md>/<useweb> 保留原始内容）
    if (result.startsWith('<usehtml>') ||
        result.startsWith('<md>') ||
        result.startsWith('<useweb>')) {
      return result;
    }
    // 检测内容中是否包含有意义的HTML标签（如<dd>,<div>,<span>,<a>,<p>,<img>等）
    // 如果包含，保留HTML供详情页Html widget渲染
    if (_containsHtmlTag(result)) {
      return result;
    }
    // 纯文本：清理残留HTML标签
    result = result.replaceAll(RegExp(r'<[^>]+>'), '');
    // HTML 实体解码
    result = result
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
    // 数字实体解码
    result = result.replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (match) => String.fromCharCode(int.parse(match.group(1)!)),
    );
    result = result.replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]+);'),
      (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
    );
    // 压缩空白
    result = result.replaceAll(RegExp(r'\s+'), ' ').trim();
    return result;
  }

  /// 检测字符串中是否包含有意义的HTML标签
  /// 排除自闭合标签如<br/>,<hr/>等纯格式标签
  static final RegExp _htmlTagRegex = RegExp(
    r'<(dd|div|span|a|p|img|table|tr|td|th|ul|ol|li|h[1-6]|section|article|main|header|footer|nav|dl|dt|em|strong|b|i|u|pre|code|blockquote|figure|figcaption|details|summary)\b[^>]*>',
    caseSensitive: false,
  );
  static bool _containsHtmlTag(String text) => _htmlTagRegex.hasMatch(text);

  /// 正文 HTML 格式化（对齐 legado HtmlFormatter.formatKeepImg）
  /// 核心逻辑：块级标签 → 换行符，移除非 img 标签，补全 img URL，段落缩进
  static String _formatContentHtml(String content, String? baseUrl) {
    var result = content;

    // 1. 保护 <img> 标签（避免后续被误删）
    final imgPlaceholders = <String, String>{};
    result = result.replaceAllMapped(
      RegExp(r'<img\s[^>]*>', caseSensitive: false),
      (match) {
        final img = match.group(0)!;
        // 补全 img 中的相对 URL
        var processedImg = img;
        if (baseUrl != null && baseUrl.isNotEmpty) {
          processedImg = processedImg.replaceAllMapped(
            RegExp(r'''(src=["'])([^"']+)(["'])''', caseSensitive: false),
            (m) {
              final src = m.group(2)!;
              if (src.startsWith('http') || src.startsWith('data:')) return m.group(0)!;
              return '${m.group(1)}${resolveUrl(src, baseUrl)}${m.group(3)}';
            },
          );
          processedImg = processedImg.replaceAllMapped(
            RegExp(r'''(data-src=["'])([^"']+)(["'])''', caseSensitive: false),
            (m) {
              final src = m.group(2)!;
              if (src.startsWith('http') || src.startsWith('data:')) return m.group(0)!;
              return '${m.group(1)}${resolveUrl(src, baseUrl)}${m.group(3)}';
            },
          );
        }
        final key = '{IMG_${imgPlaceholders.length}}';
        imgPlaceholders[key] = processedImg;
        return key;
      },
    );

    // 2. 块级标签 → 换行符（对齐 legado wrapHtmlRegex）
    // legado: </?(?:div|p|br|hr|h\d|article|dd|dl)[^>]*>
    result = result.replaceAllMapped(
      RegExp(r'</?(?:div|p|br|hr|h[1-9]|article|dd|dl|section|aside|header|footer|main|ul|ol|li|table|tr|td|th|blockquote|pre|figcaption|figure)[^>]*>', caseSensitive: false),
      (match) => '\n',
    );

    // 3. 移除 HTML 注释
    result = result.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

    // 4. 移除剩余 HTML 标签（保留 img 占位符）
    result = result.replaceAll(RegExp(r'<[^>]+>'), '');

    // 5. 还原 <img> 标签
    imgPlaceholders.forEach((key, img) {
      result = result.replaceAll(key, img);
    });

    // 6. HTML 实体解码
    if (result.contains('&')) {
      result = result
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&ensp;', ' ')
          .replaceAll('&emsp;', ' ');
      result = result.replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (match) => String.fromCharCode(int.parse(match.group(1)!)),
      );
      result = result.replaceAllMapped(
        RegExp(r'&#x([0-9a-fA-F]+);'),
        (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
      );
    }

    // 7. 规范化换行 + 段落缩进（对齐 legado indent1Regex/indent2Regex）
    // 连续换行+空白 → 单换行+缩进
    result = result.replaceAll(RegExp(r'\s*\n+\s*'), '\n\u3000\u3000');
    // 行首缩进
    result = result.replaceFirst(RegExp(r'^[\n\s]+'), '\u3000\u3000');
    // 去掉尾部空白
    result = result.replaceFirst(RegExp(r'[\n\s]+$'), '');

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
