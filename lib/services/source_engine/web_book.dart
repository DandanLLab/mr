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
import '../native/js_advanced_service.dart';
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
        rule.startsWith('@rhino:') ||
        rule.startsWith('@quickjs:') ||
        rule.startsWith('@java:') ||
        rule.startsWith('@ts:') ||
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
      AppLogger.instance.logJsResult('分流', jsResult);
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
    // 只有以 @js:/<js>/@rhino: 等前缀开头的才是 JS 规则
    // 包含 {{}} 的 URL 模板只做变量替换，不走 JS 执行
    final isRealJsRule = url.startsWith('@js:') ||
        url.startsWith('@rhino:') ||
        url.startsWith('@quickjs:') ||
        url.startsWith('@java:') ||
        url.startsWith('@ts:') ||
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

    // 借鉴 legado 的 BaseSource.getHeaderMap()：
    // header 整体支持 @js: 或 <js> 前缀，返回 JSON 格式的 header map
    // header 值也支持 JS 表达式

    // 先检查 header 整体是否是 JS 代码
    if (_isJsRule(headerStr)) {
      try {
        final jsResult = JsEngine.instance.executeSync(
          headerStr,
          null,
          baseUrl: source.bookSourceUrl,
          sourceEngine: source.engineType,
          variables: {
            'source': _sourceToMap(source),
            'cookie': <String, String>{},
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
        decoded.forEach((key, value) {
          final val = value.toString();
          // 如果值包含 JS 表达式，执行它
          if (_isJsRule(val)) {
            final jsResult = JsEngine.instance.executeSync(val, null,
                baseUrl: source.bookSourceUrl,
                sourceEngine: source.engineType,
                variables: {
                  'source': _sourceToMap(source),
                  'cookie': <String, String>{},
                });
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
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: response.url)
        ..setSourceEngine(source.engineType)
        ..setSourceInfo(_sourceToMap(source)) // 借鉴 legado：注入 source 上下文
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

      AppLogger.instance.logParse('搜索列表', actualBookListRule);

      var bookElements = analyzer.getElements(actualBookListRule);
      AppLogger.instance.logParseResult('搜索列表', bookElements.length);

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

      final results = <Map<String, dynamic>>[];

      for (int i = 0; i < bookElements.length; i++) {
        var element = bookElements[i];

        // 关键修复：如果 bookList 返回的是 String 而非 Element，说明规则可能直接指向了文本内容
        // 这种情况下，我们需要将其包装回 Element，或者在后续解析中做特殊处理
        if (element is String && element.isNotEmpty && !element.trim().startsWith('<')) {
          // 如果字符串不包含 HTML 标签，说明它可能就是我们想要的字段之一
          // 为了兼容 AnalyzeRule 的逻辑，我们将其包装为简单的 HTML
          element = '<div>$element</div>';
        }

        final itemAnalyzer = AnalyzeRule()
          ..setContent(element, baseUrl: response.url)
          ..setSourceEngine(source.engineType)
          ..setSourceInfo(_sourceToMap(source))
          ..putVariable('key', keyword)
          ..putVariable('page', page);

        var name = itemAnalyzer.getString(searchRule.name ?? '');
        var author = itemAnalyzer.getString(searchRule.author ?? '');

        // 调试日志：记录字段提取结果
        if (name == null || name.isEmpty) {
          AppLogger.instance.warn(LogCategory.parse, '第${i + 1}个元素书名为空',
            detail: 'name规则: ${searchRule.name ?? ""}, 元素类型: ${element.runtimeType}, 元素文本: ${element is dom.Element ? (element.text.length > 100 ? "${element.text.substring(0, 100)}..." : element.text) : "$element"}');
        }
        final coverUrl =
            itemAnalyzer.getString(searchRule.coverUrl ?? '', isUrl: true);
        var intro = itemAnalyzer.getString(searchRule.intro ?? '');
        final bookUrl =
            itemAnalyzer.getString(searchRule.bookUrl ?? '', isUrl: true);
        final kind = itemAnalyzer.getString(searchRule.kind ?? '');
        final lastChapter =
            itemAnalyzer.getString(searchRule.lastChapter ?? '');
        final wordCount = itemAnalyzer.getString(searchRule.wordCount ?? '');

        if (name != null && name.isNotEmpty) {
          // 借鉴 legado：书名/作者格式化
          name = _formatBookName(name);
          author = _formatBookAuthor(author ?? '');

          // 借鉴 legado：简介 HTML 格式化
          if (intro != null && intro.isNotEmpty) {
            intro = _formatIntro(intro);
          }

          // 拼接相对链接：用书源URL作为基准
          final resolvedBookUrl = resolveUrl(bookUrl, source.bookSourceUrl);
          final resolvedCoverUrl = resolveUrl(coverUrl, source.bookSourceUrl);

          results.add({
            'name': name,
            'author': author,
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
            '第一个元素HTML: ${bookElements.first is dom.Element ? (bookElements.first as dom.Element).outerHtml.length > 500 ? (bookElements.first as dom.Element).outerHtml.substring(0, 500) + "..." : (bookElements.first as dom.Element).outerHtml : "$bookElements.first"}';
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
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: response.url)
        ..setSourceEngine(source.engineType)
        ..setSourceInfo(_sourceToMap(source))
        ..putVariable('baseUrl', exploreUrl)
        ..putVariable('url', exploreUrl)
        ..putVariable('page', 1);

      final results = <Map<String, dynamic>>[];
      final bookElements = analyzer.getElements(bookListRule);

      // 保存原始元素数量（用于调试）
      lastExploreElementCount = bookElements.length;

      for (var element in bookElements) {
        // 关键修复：处理非 HTML 字符串元素
        if (element is String && element.isNotEmpty && !element.trim().startsWith('<')) {
          element = '<div>$element</div>';
        }

        final itemAnalyzer = AnalyzeRule()
          ..setContent(element, baseUrl: response.url)
          ..setSourceEngine(source.engineType)
          ..setSourceInfo(_sourceToMap(source));
        final name = itemAnalyzer.getString(
            useSearchFallback ? (searchRule?.name ?? '') : exploreRule.name);
        if (name == null || name.isEmpty) continue;
        results.add({
          'name': name,
          'author': itemAnalyzer.getString(useSearchFallback
                  ? (searchRule?.author ?? '')
                  : exploreRule.author) ??
              '',
          'coverUrl': itemAnalyzer.getString(
                  useSearchFallback
                      ? (searchRule?.coverUrl ?? '')
                      : exploreRule.coverUrl,
                  isUrl: true) ??
              '',
          'intro': itemAnalyzer.getString(useSearchFallback
                  ? (searchRule?.intro ?? '')
                  : exploreRule.intro) ??
              '',
          'bookUrl': itemAnalyzer.getString(
                  useSearchFallback
                      ? (searchRule?.bookUrl ?? '')
                      : exploreRule.bookUrl,
                  isUrl: true) ??
              '',
          'kind': itemAnalyzer.getString(useSearchFallback
                  ? (searchRule?.kind ?? '')
                  : exploreRule.kind) ??
              '',
          'lastChapter': itemAnalyzer.getString(useSearchFallback
                  ? (searchRule?.lastChapter ?? '')
                  : exploreRule.lastChapter) ??
              '',
          'wordCount': itemAnalyzer.getString(useSearchFallback
                  ? (searchRule?.wordCount ?? '')
                  : exploreRule.wordCount) ??
              '',
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
      var analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: response.url)
        ..setSourceEngine(source.engineType)
        ..setSourceInfo(_sourceToMap(source));
      // 借鉴 legado 的 BookInfo.kt：init 规则用 getElement() 获取元素对象
      // legado: analyzeRule.setContent(analyzeRule.getElement(infoRule.init))
      if (bookInfoRule.init != null && bookInfoRule.init!.isNotEmpty) {
        final initElement = analyzer.getElement(bookInfoRule.init!);
        if (initElement != null) {
          analyzer.setContent(initElement);
          AppLogger.instance.logJsResult('init', '元素定位成功，内容已替换');
        }
      }

      // 保存源码
      lastBookInfoHtml = html;

      // 直接使用 init 处理后的 analyzer（无需重新创建）
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

      AppLogger.instance.info(
          LogCategory.parse, '详情: 书名=$name, 作者=$author, 目录=$resolvedTocUrl');

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
      AppLogger.instance
          .error(LogCategory.parse, '获取详情失败', detail: e.toString());
      return null;
    }
  }

  /// 获取章节目录
  Future<List<Chapter>> getChapterList(String tocUrl, {Book? book}) async {
    final tocRule = source.ruleToc;
    if (tocRule == null) return [];

    // 加载书源 JS 库
    await _loadJsLib();

    try {
      final response = await _executeRequest(_parseUrlWithOption(tocUrl));
      var html = response.body;

      AppLogger.instance.info(LogCategory.network,
          '目录响应: ${html.length} chars, 状态码: ${response.statusCode}');
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
          AppLogger.instance
              .logJsResult('preUpdateJs', '${preResult.length} chars');
        }
      }

      // 保存源码（preUpdateJs 处理后的）
      lastTocHtml = html;

      // 使用 AnalyzeRule 引擎解析
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: response.url)
        ..setSourceEngine(source.engineType)
        ..setSourceInfo(_sourceToMap(source))
        ..setBookInfo(book != null ? _bookToMap(book) : null);

      // 借鉴 legado 的 BookChapterList.kt：- 前缀表示不反转，+ 前缀表示反转（默认反转）
      var chapterListRule = tocRule.chapterList ?? '';
      var reverse = false; // legado: reverse=true 表示保持原始顺序（不反转）
      if (chapterListRule.startsWith('-')) {
        reverse = true;
        chapterListRule = chapterListRule.substring(1);
      }
      if (chapterListRule.startsWith('+')) {
        chapterListRule = chapterListRule.substring(1);
      }

      final chapterElements = analyzer.getElements(chapterListRule);

      // 保存原始元素数量（用于调试）
      lastTocElementCount = chapterElements.length;

      var chapterNames = <String>[];
      var chapterUrls = <String>[];
      final chapterVolumes = <bool>[];
      final chapterVip = <bool>[];
      final chapterPay = <bool>[];
      final chapterTags = <String?>[];
      for (final element in chapterElements) {
        final itemAnalyzer = AnalyzeRule()
          ..setContent(element, baseUrl: response.url)
          ..setSourceEngine(source.engineType)
          ..setSourceInfo(_sourceToMap(source))
          ..setBookInfo(book != null ? _bookToMap(book) : null);
        chapterNames
            .add(itemAnalyzer.getString(tocRule.chapterName ?? '') ?? '');
        chapterUrls.add(itemAnalyzer.getString(tocRule.chapterUrl ?? '') ?? '');
        chapterVolumes.add(
          _isRuleTrue(itemAnalyzer.getString(tocRule.isVolume ?? '')),
        );
        chapterVip
            .add(_isRuleTrue(itemAnalyzer.getString(tocRule.isVip ?? '')));
        chapterPay
            .add(_isRuleTrue(itemAnalyzer.getString(tocRule.isPay ?? '')));
        chapterTags.add(itemAnalyzer.getString(tocRule.updateTime ?? ''));
      }

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
          bookId: book?.bookUrl ?? tocUrl,
          title: name,
          index: i,
          url: resolvedUrl.isEmpty ? null : resolvedUrl,
          isVolume: i < chapterVolumes.length ? chapterVolumes[i] : false,
          isVip: i < chapterVip.length ? chapterVip[i] : false,
          isPay: i < chapterPay.length ? chapterPay[i] : false,
          tag: i < chapterTags.length ? chapterTags[i] : null,
        ));
      }

      // 借鉴 legado 的 BookChapterList.kt：默认反转章节列表
      // reverse=true（-前缀）表示保持原始顺序，不反转
      // reverse=false（无前缀或+前缀）表示反转列表
      if (!reverse && chapters.isNotEmpty) {
        final reversed = chapters.reversed.toList();
        chapters.clear();
        for (int i = 0; i < reversed.length; i++) {
          chapters.add(reversed[i].copyWith(index: i));
        }
      }

      // 处理 nextTocUrl（目录下一页，支持 JS）
      if (tocRule.nextTocUrl != null && tocRule.nextTocUrl!.isNotEmpty) {
        final rawNextUrl = analyzer.getString(tocRule.nextTocUrl!, isUrl: true);
        final nextUrl = resolveUrl(rawNextUrl, tocUrl);
        if (nextUrl.isNotEmpty && nextUrl != tocUrl) {
          AppLogger.instance.info(LogCategory.parse, '目录下一页: $nextUrl');
          final nextChapters = await getChapterList(nextUrl, book: book);
          chapters.addAll(nextChapters);
        }
      }

      return chapters;
    } catch (e) {
      AppLogger.instance
          .error(LogCategory.parse, '获取目录失败', detail: e.toString());
      return [];
    }
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
      {Book? book, Chapter? chapter}) async {
    final contentRule = source.ruleContent;
    if (contentRule == null) return null;

    // 加载书源 JS 库
    await _loadJsLib();

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
      final analyzer = AnalyzeRule()
        ..setContent(html, baseUrl: response.url)
        ..setSourceEngine(source.engineType)
        ..setSourceInfo(_sourceToMap(source))
        ..setBookInfo(book != null ? _bookToMap(book) : null)
        ..setChapterInfo(chapter != null ? _chapterToMap(chapter) : null);
      var content = analyzer.getString(contentRule.content ?? '');
      final subContent = analyzer.getString(contentRule.subContent ?? '');
      if (subContent != null && subContent.isNotEmpty) {
        content = '${content ?? ''}\n$subContent'.trim();
      }

      AppLogger.instance.logParseResult('正文', content != null ? 1 : 0);

      // 执行 replaceRegex（正文替换规则，支持 JS 替换逻辑）
      if (contentRule.replaceRegex != null &&
          contentRule.replaceRegex!.isNotEmpty) {
        content = _applyContentReplace(content, contentRule.replaceRegex!);
      }

      // 处理 nextContentUrl（正文下一页，支持 JS）
      if (contentRule.nextContentUrl != null &&
          contentRule.nextContentUrl!.isNotEmpty) {
        final nextUrl =
            analyzer.getString(contentRule.nextContentUrl!, isUrl: true);
        if (nextUrl != null && nextUrl.isNotEmpty && nextUrl != chapterUrl) {
          debugPrint('📖 发现正文下一页: $nextUrl');
          final nextContent =
              await getContent(nextUrl, book: book, chapter: chapter);
          if (nextContent != null && nextContent.isNotEmpty) {
            content = (content ?? '') + '\n' + nextContent;
          }
        }
      }

      // 执行 js 脚本（正文加载后执行的 JS）
      if (contentRule.js != null && contentRule.js!.isNotEmpty) {
        final jsResult = await _executeJs(contentRule.js!,
            result: content ?? '', baseUrl: chapterUrl);
        if (jsResult != null && jsResult.isNotEmpty) {
          content = jsResult;
          AppLogger.instance
              .logJsResult('content.js', '${jsResult.length} chars');
        }
      }

      // 执行 callBackJs（内容加载完成后的回调 JS）
      if (contentRule.callBackJs != null &&
          contentRule.callBackJs!.isNotEmpty) {
        final callBackResult = await _executeJs(contentRule.callBackJs!,
            result: content ?? '', baseUrl: chapterUrl);
        if (callBackResult != null && callBackResult.isNotEmpty) {
          content = callBackResult;
          AppLogger.instance
              .logJsResult('callBackJs', '${callBackResult.length} chars');
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

  // ================== 借鉴 legado 的辅助方法 ==================

  /// 将 BookSource 转为 Map（用于注入 JS 上下文）
  Map<String, dynamic> _sourceToMap(BookSource source) {
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
      'jsLib': source.jsLib ?? '',
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

  /// 简介 HTML 格式化（借鉴 legado 的 HtmlFormatter.format）
  static String _formatIntro(String intro) {
    var result = intro.trim();
    // 检测特殊标签（借鉴 legado：<usehtml>/<md>/<useweb> 保留原始内容）
    if (result.startsWith('<usehtml>') ||
        result.startsWith('<md>') ||
        result.startsWith('<useweb>')) {
      return result;
    }
    // 清理 HTML 标签
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

  /// 正文 HTML 格式化（借鉴 legado 的 HtmlFormatter.formatKeepImg）
  // ignore: unused_element
  static String _formatContent(String content, String? baseUrl) {
    var result = content;

    // HTML 实体解码
    if (result.contains('&')) {
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
    }

    // 将相对图片URL转为绝对URL
    if (baseUrl != null && baseUrl.isNotEmpty) {
      result = result.replaceAllMapped(
        RegExp(r'''(src=["'])([^"']+)(["'])''', caseSensitive: false),
        (match) {
          final src = match.group(2)!;
          if (src.startsWith('http') || src.startsWith('data:')) {
            return match.group(0)!;
          }
          final absoluteUrl = resolveUrl(src, baseUrl);
          return '${match.group(1)}$absoluteUrl${match.group(3)}';
        },
      );
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
