import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../models/book_source.dart';
import '../../models/book.dart';
import '../../models/chapter.dart';
import 'analyze_rule.dart';
import 'web_proxy.dart';
import 'proxy_service.dart';
import 'js_engine.dart';

/// URL请求选项
class UrlOption {
  final String? method;
  final Map<String, String>? headers;
  final String? body;
  final String? charset;
  final int retry;
  final bool useWebView;
  final int? connectTimeout;
  final int? readTimeout;
  final String? webJs;

  const UrlOption({
    this.method,
    this.headers,
    this.body,
    this.charset,
    this.retry = 0,
    this.useWebView = false,
    this.connectTimeout,
    this.readTimeout,
    this.webJs,
  });

  factory UrlOption.fromJson(Map<String, dynamic> json) {
    return UrlOption(
      method: json['method']?.toString(),
      headers: json['headers'] != null
          ? Map<String, String>.from(json['headers'] as Map)
          : null,
      body: _bodyString(json['body']),
      charset: json['charset']?.toString(),
      retry: json['retry'] as int? ?? 0,
      useWebView: json['webView'] == true || json['webView'] == 'true',
      connectTimeout: json['connectTimeout'] as int?,
      readTimeout: json['readTimeout'] as int?,
      webJs: json['webJs']?.toString(),
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
      if (webJs != null) 'webJs': webJs,
    };
  }

  static String? _bodyString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is Map || value is List) return jsonEncode(value);
    return value.toString();
  }
}

/// 解析后的URL
class ParsedUrl {
  final String url;
  final UrlOption? option;

  const ParsedUrl({required this.url, this.option});
}

/// 响应包装类
class StrResponse {
  final String url;
  final String body;
  final int statusCode;
  final Map<String, String> headers;
  final Response? raw;

  const StrResponse({
    required this.url,
    required this.body,
    this.statusCode = 200,
    this.headers = const {},
    this.raw,
  });

  bool get isSuccessful => statusCode >= 200 && statusCode < 300;
  String? header(String name) => headers[name];
}

/// 网络请求客户端
class HttpClient {
  static final HttpClient _instance = HttpClient._internal();
  static HttpClient get instance => _instance;
  HttpClient._internal();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 30),
  ));

  /// 执行请求
  Future<StrResponse> execute(
    String url, {
    String method = 'GET',
    Map<String, String>? headers,
    String? body,
    String? charset,
    Duration? connectTimeout,
    Duration? readTimeout,
  }) async {
    final options = Options(
      method: method,
      headers: headers,
      responseType: ResponseType.plain,
      receiveTimeout: readTimeout,
      sendTimeout: connectTimeout,
    );

    try {
      // Web端使用代理
      String requestUrl = url;
      if (kIsWeb) {
        requestUrl = 'http://localhost:8888/$url';
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

      // 非Web端使用代理服务
      if (ProxyService.instance.isRunning) {
        requestUrl = 'http://localhost:${ProxyService.instance.port}/$url';
      }

      final response = await _dio.request<String>(
        requestUrl,
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
      rethrow;
    }
  }
}

/// 书源网络请求类
/// 参考 legados 的 WebBook.kt
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

  /// 解析URL和选项
  ParsedUrl _parseUrlWithOption(
    String urlWithOption, {
    String? keyword,
    int? page,
  }) {
    String url = urlWithOption;
    UrlOption? option;

    // 解析URL末尾的JSON选项
    final optionMatch =
        RegExp(r',\s*(\{[\s\S]*\})\s*$').firstMatch(urlWithOption);
    if (optionMatch != null) {
      url = urlWithOption.substring(0, optionMatch.start).trim();
      try {
        final optionJson =
            json.decode(optionMatch.group(1)!) as Map<String, dynamic>;
        option = UrlOption.fromJson(optionJson);
        debugPrint('🔧 URL选项: method=${option.method}, body=${option.body}');
      } catch (e) {
        debugPrint('❌ 解析URL选项失败: $e');
      }
    }

    // 替换占位符
    url = _replaceUrlVariables(url, keyword: keyword, page: page);
    
    final parsedOption = option;
    if (parsedOption != null) {
      option = UrlOption(
        method: parsedOption.method,
        headers: parsedOption.headers,
        body: parsedOption.body != null
            ? _replaceUrlVariables(parsedOption.body!, keyword: keyword, page: page)
            : null,
        charset: parsedOption.charset,
        retry: parsedOption.retry,
        useWebView: parsedOption.useWebView,
        connectTimeout: parsedOption.connectTimeout,
        readTimeout: parsedOption.readTimeout,
        webJs: parsedOption.webJs,
      );
    }

    // 处理相对URL
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      String baseUrl = source.bookSourceUrl;
      if (!baseUrl.endsWith('/')) {
        baseUrl += '/';
      }
      if (url.startsWith('/')) {
        url = url.substring(1);
      }
      url = baseUrl + url;
    }

    return ParsedUrl(url: url, option: option);
  }

  /// 构建请求头
  Map<String, String> _buildHeaders({Map<String, String>? extraHeaders}) {
    final headers = <String, String>{};

    // 解析书源自定义请求头
    if (source.header != null && source.header!.isNotEmpty) {
      try {
        final decoded = json.decode(source.header!);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            headers[key.toString()] = value.toString();
          });
        }
      } catch (_) {
        for (final line in source.header!.split('\n')) {
          final parts = line.split(':');
          if (parts.length >= 2) {
            headers[parts[0].trim()] = parts.sublist(1).join(':').trim();
          }
        }
      }
    }

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
    final headers = _buildHeaders(
      extraHeaders: parsed.option?.headers,
    );

    final method = parsed.option?.method?.toUpperCase() ?? 'GET';
    String? body = parsed.option?.body;

    // POST请求设置默认Content-Type
    if (method == 'POST' && !headers.containsKey('Content-Type')) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }

    debugPrint('🌐 请求: $method ${parsed.url}');
    if (body != null) {
      debugPrint('📋 Body: $body');
    }

    return _client.execute(
      parsed.url,
      method: method,
      headers: headers,
      body: body,
      charset: parsed.option?.charset,
    );
  }

  /// 检查是否需要登录
  Future<bool> checkLogin() async {
    if (source.loginCheckJs == null || source.loginCheckJs!.isEmpty) {
      return true; // 无需登录
    }

    try {
      final result = await JsEngine.instance.executeAsync(
        source.loginCheckJs!,
        null,
        baseUrl: source.bookSourceUrl,
      );
      return result == true || result == 'true';
    } catch (e) {
      debugPrint('❌ 登录检查失败: $e');
      return false;
    }
  }

  /// 检查URL是否匹配bookUrlPattern
  bool _matchBookUrlPattern(String url) {
    if (source.bookUrlPattern == null || source.bookUrlPattern!.isEmpty) {
      return false;
    }

    try {
      final pattern = source.bookUrlPattern!;
      if (pattern.startsWith('/')) {
        // 正则匹配
        final regex = RegExp(pattern.substring(1));
        return regex.hasMatch(url);
      }
      // 字符串包含匹配
      return url.contains(pattern);
    } catch (e) {
      return false;
    }
  }

  /// 搜索书籍
  Future<List<Map<String, dynamic>>> searchBook(String keyword,
      {int page = 1}) async {
    if (source.searchUrl == null || source.searchUrl!.isEmpty) {
      debugPrint('❌ 搜索地址为空');
      return [];
    }

    final searchRule = source.getSearchRule();
    final parsed =
        _parseUrlWithOption(source.searchUrl!, keyword: keyword, page: page);
    debugPrint('🔍 搜索URL: ${parsed.url}');

    try {
      final response = await _executeRequest(parsed, keyword: keyword);
      final html = response.body;

      lastSearchHtml = html;

      debugPrint('📄 响应长度: ${html.length}');
      if (html.isEmpty) {
        debugPrint('❌ 响应为空');
        return [];
      }

      // 检查是否直接跳转到详情页
      if (_matchBookUrlPattern(response.url)) {
        debugPrint('📖 搜索直接跳转到详情页');
        return _parseBookInfoFromSearch(html, response.url);
      }

      // 获取书籍列表元素
      final bookListRule = searchRule.bookList ?? '';
      debugPrint('📚 书籍列表规则: $bookListRule');

      final bookElements = AnalyzeRule()
          .setContent(html, baseUrl: parsed.url)
          .getElements(bookListRule);
      debugPrint('📚 书籍元素数量: ${bookElements.length}');

      if (bookElements.isEmpty) {
        debugPrint('未找到书籍元素');
        return [];
      }

      final results = <Map<String, dynamic>>[];

      for (int i = 0; i < bookElements.length; i++) {
        final analyzer =
            AnalyzeRule().setContent(bookElements[i], baseUrl: parsed.url);

        final name = analyzer.getString(searchRule.name ?? '')?.trim();
        final author = analyzer.getString(searchRule.author ?? '')?.trim();
        final coverUrl = analyzer.getString(searchRule.coverUrl ?? '', isUrl: true)?.trim();
        final intro = analyzer.getString(searchRule.intro ?? '')?.trim();
        final bookUrl = analyzer.getString(searchRule.bookUrl ?? '', isUrl: true)?.trim();
        final kind = analyzer.getString(searchRule.kind ?? '')?.trim();
        final lastChapter =
            analyzer.getString(searchRule.lastChapter ?? '')?.trim();
        final wordCount = analyzer.getString(searchRule.wordCount ?? '')?.trim();

        debugPrint('📖 [$i] 书名: $name, 作者: $author');

        if (name != null && name.isNotEmpty) {
          results.add({
            'name': name,
            'author': author ?? '',
            'coverUrl': coverUrl ?? '',
            'intro': intro ?? '',
            'bookUrl': bookUrl ?? '',
            'kind': kind ?? '',
            'lastChapter': lastChapter ?? '',
            'wordCount': wordCount ?? '',
            'sourceUrl': source.bookSourceUrl,
            'sourceName': source.bookSourceName,
          });
        }
      }

      debugPrint('📚 最终结果数量: ${results.length}');
      return results;
    } catch (e, stackTrace) {
      debugPrint('❌ 搜索失败: $e');
      debugPrint('❌ 堆栈: $stackTrace');
      return [];
    }
  }

  /// 从搜索结果解析书籍详情（当搜索直接跳转到详情页时）
  List<Map<String, dynamic>> _parseBookInfoFromSearch(String html, String url) {
    final bookInfoRule = source.getBookInfoRule();
    final analyzer = AnalyzeRule().setContent(html, baseUrl: url);

    final name = analyzer.getString(bookInfoRule.name ?? '')?.trim();
    if (name == null || name.isEmpty) {
      return [];
    }

    return [{
      'name': name,
      'author': analyzer.getString(bookInfoRule.author ?? '')?.trim() ?? '',
      'coverUrl': analyzer.getString(bookInfoRule.coverUrl ?? '', isUrl: true)?.trim() ?? '',
      'intro': analyzer.getString(bookInfoRule.intro ?? '')?.trim() ?? '',
      'bookUrl': url,
      'kind': analyzer.getString(bookInfoRule.kind ?? '')?.trim() ?? '',
      'lastChapter': analyzer.getString(bookInfoRule.lastChapter ?? '')?.trim() ?? '',
      'wordCount': analyzer.getString(bookInfoRule.wordCount ?? '')?.trim() ?? '',
      'sourceUrl': source.bookSourceUrl,
      'sourceName': source.bookSourceName,
    }];
  }

  /// 发现书籍
  Future<List<Map<String, dynamic>>> exploreBook(String exploreUrl) async {
    final exploreRule = source.getExploreRule();
    final parsed = _parseUrlWithOption(exploreUrl);

    try {
      final response = await _executeRequest(parsed);
      final html = response.body;

      lastExploreHtml = html;

      final bookElements = AnalyzeRule()
          .setContent(html, baseUrl: parsed.url)
          .getElements(exploreRule.bookList ?? '');

      final results = <Map<String, dynamic>>[];

      for (final element in bookElements) {
        final analyzer = AnalyzeRule().setContent(element, baseUrl: parsed.url);

        final name = analyzer.getString(exploreRule.name ?? '')?.trim();
        if (name == null || name.isEmpty) continue;

        results.add({
          'name': name,
          'author': analyzer.getString(exploreRule.author ?? '')?.trim() ?? '',
          'coverUrl': analyzer.getString(exploreRule.coverUrl ?? '', isUrl: true)?.trim() ?? '',
          'intro': analyzer.getString(exploreRule.intro ?? '')?.trim() ?? '',
          'bookUrl': analyzer.getString(exploreRule.bookUrl ?? '', isUrl: true)?.trim() ?? '',
          'kind': analyzer.getString(exploreRule.kind ?? '')?.trim() ?? '',
          'lastChapter': analyzer.getString(exploreRule.lastChapter ?? '')?.trim() ?? '',
          'wordCount': analyzer.getString(exploreRule.wordCount ?? '')?.trim() ?? '',
          'sourceUrl': source.bookSourceUrl,
          'sourceName': source.bookSourceName,
        });
      }

      return results;
    } catch (e) {
      debugPrint('❌ 发现失败: $e');
      return [];
    }
  }

  /// 获取书籍详情
  Future<Book?> getBookInfo(String bookUrl) async {
    final bookInfoRule = source.getBookInfoRule();

    try {
      final headers = _buildHeaders();
      final response = await _client.execute(bookUrl, headers: headers);
      final html = response.body;

      lastBookInfoHtml = html;

      final analyzer = AnalyzeRule().setContent(html, baseUrl: bookUrl);

      // 执行预处理规则
      if (bookInfoRule.init != null && bookInfoRule.init!.isNotEmpty) {
        try {
          await JsEngine.instance.executeAsync(
            bookInfoRule.init!,
            html,
            baseUrl: bookUrl,
          );
        } catch (e) {
          debugPrint('❌ 预处理规则执行失败: $e');
        }
      }

      final name = analyzer.getString(bookInfoRule.name ?? '')?.trim();
      final tocUrl = analyzer.getString(bookInfoRule.tocUrl ?? '', isUrl: true)?.trim();

      final safeName = name == null || name.isEmpty ? '未知书名' : name;
      return Book(
        bookUrl: bookUrl,
        name: safeName,
        author: analyzer.getString(bookInfoRule.author ?? '')?.trim() ?? '',
        coverUrl: analyzer.getString(bookInfoRule.coverUrl ?? '', isUrl: true)?.trim() ?? '',
        intro: analyzer.getString(bookInfoRule.intro ?? '')?.trim() ?? '',
        mediaType: MediaType.novel,
        originType: BookOriginType.online,
        sourceUrl: source.bookSourceUrl,
        sourceName: source.bookSourceName,
        kind: analyzer.getString(bookInfoRule.kind ?? '')?.trim(),
        lastChapter: analyzer.getString(bookInfoRule.lastChapter ?? '')?.trim(),
        wordCount: analyzer.getString(bookInfoRule.wordCount ?? '')?.trim(),
        tocUrl: tocUrl == null || tocUrl.isEmpty ? null : tocUrl,
        canUpdate: true,
        addedTime: DateTime.now(),
      );
    } catch (e) {
      debugPrint('❌ 获取详情失败: $e');
      return null;
    }
  }

  /// 获取章节目录（支持多页）
  Future<List<Chapter>> getChapterList(String tocUrl) async {
    final tocRule = source.getTocRule();
    final chapters = <Chapter>[];
    final visitedUrls = <String>{};
    var currentUrl = tocUrl;

    try {
      while (currentUrl.isNotEmpty && !visitedUrls.contains(currentUrl)) {
        visitedUrls.add(currentUrl);

        final headers = _buildHeaders();
        final response = await _client.execute(currentUrl, headers: headers);
        final html = response.body;

        lastTocHtml = html;

        final analyzer = AnalyzeRule().setContent(html, baseUrl: currentUrl);

        // 执行预处理JS
        if (tocRule.preUpdateJs != null && tocRule.preUpdateJs!.isNotEmpty) {
          try {
            await JsEngine.instance.executeAsync(
              tocRule.preUpdateJs!,
              html,
              baseUrl: currentUrl,
            );
          } catch (e) {
            debugPrint('❌ 目录预处理JS执行失败: $e');
          }
        }

        // 获取章节列表
        final chapterElements = analyzer.getElements(tocRule.chapterList ?? '');
        
        for (int i = 0; i < chapterElements.length; i++) {
          final chapterAnalyzer =
              AnalyzeRule().setContent(chapterElements[i], baseUrl: currentUrl);
          final name = chapterAnalyzer.getString(tocRule.chapterName ?? '')?.trim();
          // 章节URL：如果规则为空，尝试获取a标签的href
          String? url;
          final chapterUrlRule = tocRule.chapterUrl ?? '';
          if (chapterUrlRule.isNotEmpty) {
            url = chapterAnalyzer.getString(chapterUrlRule, isUrl: true)?.trim();
          } else {
            // 默认获取第一个a标签的href
            url = chapterAnalyzer.getString('tag.a.0@href', isUrl: true)?.trim();
          }
          
          if (name == null || name.isEmpty) continue;
          
          chapters.add(Chapter(
            id: '${tocUrl}_${chapters.length}',
            bookId: tocUrl,
            title: name,
            index: chapters.length,
            url: url,
          ));
        }

        // 检查是否有下一页目录
        final nextTocUrl = analyzer.getString(tocRule.nextTocUrl ?? '', isUrl: true)?.trim();
        if (nextTocUrl == null || nextTocUrl.isEmpty || nextTocUrl == currentUrl) {
          break;
        }
        currentUrl = nextTocUrl;
        
        // 限制最多10页目录
        if (visitedUrls.length >= 10) {
          debugPrint('⚠️ 目录页数超过限制');
          break;
        }
      }

      // 如果规则以-开头，反转章节列表
      if (tocRule.chapterList != null && tocRule.chapterList!.startsWith('-')) {
        return chapters.reversed.toList();
      }

      return chapters;
    } catch (e) {
      debugPrint('❌ 获取目录失败: $e');
      return chapters;
    }
  }

  /// 获取章节正文（支持多页）
  Future<String?> getContent(String chapterUrl) async {
    final contentRule = source.getContentRule();
    final contentParts = <String>[];
    final contentHtmlParts = <String>[];
    final visitedUrls = <String>{};
    var currentUrl = chapterUrl;

    debugPrint('📖 开始获取正文: $chapterUrl');
    debugPrint('📖 正文规则: ${contentRule.content}');
    debugPrint('📖 下一页规则: ${contentRule.nextContentUrl}');

    try {
      while (currentUrl.isNotEmpty && !visitedUrls.contains(currentUrl)) {
        visitedUrls.add(currentUrl);

        final headers = _buildHeaders();
        final response = await _client.execute(currentUrl, headers: headers);
        final html = response.body;

        contentHtmlParts.add(html);
        debugPrint('📖 响应长度: ${html.length}');

        final analyzer = AnalyzeRule().setContent(html, baseUrl: currentUrl);

        // 获取正文内容
        final contentRuleStr = contentRule.content ?? '';
        debugPrint('📖 执行正文规则: $contentRuleStr');
        final content = analyzer.getString(contentRuleStr)?.trim();
        debugPrint('📖 正文结果: ${content != null ? "${content.length}字符" : "null"}');
        if (content != null && content.isNotEmpty) {
          contentParts.add(content);
        }

        // 获取补充正文
        final subContentRuleStr = contentRule.subContent ?? '';
        if (subContentRuleStr.isNotEmpty) {
          final subContent = analyzer.getString(subContentRuleStr)?.trim();
          if (subContent != null && subContent.isNotEmpty) {
            contentParts.add(subContent);
          }
        }

        // 检查是否有下一页正文
        final nextUrlRuleStr = contentRule.nextContentUrl ?? '';
        if (nextUrlRuleStr.isNotEmpty) {
          final nextContentUrl = analyzer.getString(nextUrlRuleStr, isUrl: true)?.trim();
          debugPrint('📖 下一页URL: $nextContentUrl');
          if (nextContentUrl == null || nextContentUrl.isEmpty || nextContentUrl == currentUrl) {
            break;
          }
          currentUrl = nextContentUrl;
        } else {
          break;
        }

        // 限制最多10页正文
        if (visitedUrls.length >= 10) {
          debugPrint('正文页数超过限制');
          break;
        }
      }

      // 保存所有页的源码
      lastContentHtml = contentHtmlParts.join('\n<!-- ========= 下一页 ======== -->\n');
      debugPrint('📖 源码页数: ${contentHtmlParts.length}');

      debugPrint('📖 正文总段数: ${contentParts.length}');
      if (contentParts.isEmpty) return null;

      var content = contentParts.join('\n');

      debugPrint('📖 合并后正文长度: ${content.length}');

      // 应用正则替换（使用AnalyzeRule处理）
      final replaceRegex = contentRule.replaceRegex;
      debugPrint('📖 replaceRegex规则: "$replaceRegex"');
      if (replaceRegex != null && replaceRegex.isNotEmpty) {
        debugPrint('📖 执行正则替换前长度: ${content.length}');
        final analyzer = AnalyzeRule().setContent(content, baseUrl: chapterUrl);
        final replaced = analyzer.getString(replaceRegex, content: content);
        if (replaced != null) {
          content = replaced;
        }
        debugPrint('📖 执行正则替换后长度: ${content.length}');
      }

      // 应用JS处理
      if (contentRule.js != null && contentRule.js!.isNotEmpty) {
        try {
          final result = await JsEngine.instance.executeAsync(
            contentRule.js!,
            content,
            baseUrl: chapterUrl,
          );
          if (result is String) {
            content = result;
            debugPrint('📖 JS处理后正文长度: ${content.length}');
          }
        } catch (e) {
          debugPrint('正文JS处理失败: $e');
        }
      }

      debugPrint('📖 最终正文长度: ${content.length}');
      return content;
    } catch (e) {
      debugPrint('获取正文失败: $e');
      return null;
    }
  }
}

/// 替换URL变量
String _replaceUrlVariables(String value, {String? keyword, int? page}) {
  var result = value;
  if (keyword != null) {
    final encoded = Uri.encodeComponent(keyword);
    result = result
        .replaceAll('{{key}}', encoded)
        .replaceAll('{{searchKey}}', encoded)
        .replaceAll('{{keyword}}', encoded)
        .replaceAll('{key}', encoded)
        .replaceAll('{searchKey}', encoded)
        .replaceAll('{keyword}', encoded);
  }
  if (page != null) {
    result = result
        .replaceAll('{{page}}', '$page')
        .replaceAll('{{searchPage}}', '$page')
        .replaceAll('{page}', '$page')
        .replaceAll('{searchPage}', '$page');
  }
  return result;
}

/// 按规则替换文本
String _replaceByRule(String value, String rule) {
  final normalized = rule.startsWith('##') ? rule.substring(2) : rule;
  final parts = normalized.split('##');
  if (parts.isEmpty || parts.first.isEmpty) return value;
  try {
    final regex = RegExp(parts.first, multiLine: true, dotAll: true);
    final replacement = parts.length > 1 ? parts[1] : '';
    if (parts.length > 2) {
      final match = regex.firstMatch(value);
      return match == null
          ? value
          : match.group(0)!.replaceFirst(regex, replacement);
    }
    return value.replaceAll(regex, replacement);
  } catch (_) {
    return value;
  }
}
