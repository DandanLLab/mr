import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import '../../models/book_source.dart';
import '../../models/book.dart';
import '../../models/chapter.dart';
import 'analyze_rule.dart';
import 'web_proxy.dart';
import 'proxy_service.dart';

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
  ));

  /// 执行请求（类似 OkHttp 的 Call.execute）
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
      // Web 端使用代理
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

      // 非 Web 端使用代理服务
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

  /// 解析 URL 和选项
  ParsedUrl _parseUrlWithOption(
    String urlWithOption, {
    String? keyword,
    int? page,
  }) {
    String url = urlWithOption;
    UrlOption? option;

    // 解析 URL 末尾的 JSON 选项
    final optionMatch = RegExp(r',\s*(\{[\s\S]*\})\s*$').firstMatch(urlWithOption);
    if (optionMatch != null) {
      url = urlWithOption.substring(0, optionMatch.start).trim();
      try {
        final optionJson = json.decode(optionMatch.group(1)!) as Map<String, dynamic>;
        option = UrlOption.fromJson(optionJson);
        debugPrint('🔧 URL选项: method=${option.method}, body=${option.body}');
      } catch (e) {
        debugPrint('❌ 解析URL选项失败: $e');
      }
    }

    // 替换占位符
    if (keyword != null) {
      url = url
          .replaceAll('{{key}}', Uri.encodeComponent(keyword))
          .replaceAll('{{searchKey}}', Uri.encodeComponent(keyword));
      
      // 同时替换选项中的占位符
      if (option?.body != null) {
        final opt = option!;
        option = UrlOption(
          method: opt.method,
          headers: opt.headers,
          body: opt.body!
              .replaceAll('{{key}}', Uri.encodeComponent(keyword))
              .replaceAll('{{searchKey}}', Uri.encodeComponent(keyword)),
          charset: opt.charset,
          retry: opt.retry,
          useWebView: opt.useWebView,
          connectTimeout: opt.connectTimeout,
          readTimeout: opt.readTimeout,
        );
      }
    }
    if (page != null) {
      url = url.replaceAll('{{page}}', page.toString());
    }

    // 处理相对 URL - 拼接书源基础 URL
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      String baseUrl = source.bookSourceUrl;
      // 确保基础 URL 以 / 结尾
      if (!baseUrl.endsWith('/')) {
        baseUrl += '/';
      }
      // 移除相对 URL 开头的 /
      if (url.startsWith('/')) {
        url = url.substring(1);
      }
      url = baseUrl + url;
      debugPrint('🔗 拼接相对URL: $url');
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
        // 尝试按行解析
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
      headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
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
  Future<List<Map<String, dynamic>>> searchBook(String keyword, {int page = 1}) async {
    if (source.searchUrl == null || source.searchUrl!.isEmpty) {
      debugPrint('❌ 搜索地址为空');
      return [];
    }

    final searchRule = source.ruleSearch;
    if (searchRule == null) {
      debugPrint('❌ 搜索规则为空');
      return [];
    }

    final parsed = _parseUrlWithOption(source.searchUrl!, keyword: keyword, page: page);
    debugPrint('🔍 搜索URL: ${parsed.url}');

    try {
      final response = await _executeRequest(parsed, keyword: keyword);
      final html = response.body;

      lastSearchHtml = html;

      debugPrint('📖 响应长度: ${html.length}');
      if (html.isEmpty) {
        debugPrint('❌ 响应为空');
        return [];
      }

      // 使用 AnalyzeRule 引擎解析
      final analyzer = AnalyzeRule()..setContent(html, baseUrl: source.bookSourceUrl);

      final bookListRule = searchRule.bookList ?? '';
      debugPrint('📚 书籍列表规则: $bookListRule');

      final bookElements = analyzer.getElements(bookListRule);
      debugPrint('📚 书籍元素数量: ${bookElements.length}');

      if (bookElements.isEmpty) {
        debugPrint('❌ 未找到书籍元素');
        return [];
      }

      final results = <Map<String, dynamic>>[];

      for (int i = 0; i < bookElements.length; i++) {
        final element = bookElements[i];
        final itemAnalyzer = AnalyzeRule()..setContent(element, baseUrl: source.bookSourceUrl);

        final name = itemAnalyzer.getString(searchRule.name ?? '');
        final author = itemAnalyzer.getString(searchRule.author ?? '');
        final coverUrl = itemAnalyzer.getString(searchRule.coverUrl ?? '');
        final intro = itemAnalyzer.getString(searchRule.intro ?? '');
        final bookUrl = itemAnalyzer.getString(searchRule.bookUrl ?? '');
        final kind = itemAnalyzer.getString(searchRule.kind ?? '');
        final lastChapter = itemAnalyzer.getString(searchRule.lastChapter ?? '');

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
  Future<List<Map<String, dynamic>>> exploreBook(String exploreUrl) async {
    final exploreRule = source.ruleExplore;
    if (exploreRule == null) return [];

    final parsed = _parseUrlWithOption(exploreUrl);

    try {
      final response = await _executeRequest(parsed);
      final html = response.body;

      lastExploreHtml = html;

      // 使用 AnalyzeRule 引擎解析
      final analyzer = AnalyzeRule()..setContent(html, baseUrl: source.bookSourceUrl);

      final nameList = analyzer.getStringList(exploreRule.name ?? '');
      final authorList = analyzer.getStringList(exploreRule.author ?? '');
      final coverList = analyzer.getStringList(exploreRule.coverUrl ?? '');
      final introList = analyzer.getStringList(exploreRule.intro ?? '');
      final bookUrlList = analyzer.getStringList(exploreRule.bookUrl ?? '');

      final results = <Map<String, dynamic>>[];

      for (int i = 0; i < nameList.length; i++) {
        results.add({
          'name': nameList[i],
          'author': i < authorList.length ? authorList[i] : '',
          'coverUrl': i < coverList.length ? coverList[i] : '',
          'intro': i < introList.length ? introList[i] : '',
          'bookUrl': i < bookUrlList.length ? bookUrlList[i] : '',
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
    final bookInfoRule = source.ruleBookInfo;
    if (bookInfoRule == null) return null;

    try {
      final headers = _buildHeaders();
      final response = await _client.execute(bookUrl, headers: headers);
      final html = response.body;

      lastBookInfoHtml = html;

      // 使用 AnalyzeRule 引擎解析
      final analyzer = AnalyzeRule()..setContent(html, baseUrl: bookUrl);

      // 执行预处理规则
      if (bookInfoRule.init != null && bookInfoRule.init!.isNotEmpty) {
        // TODO: 执行 JS 预处理
      }

      return Book(
        bookUrl: bookUrl,
        name: analyzer.getString(bookInfoRule.name ?? '') ?? '未知书名',
        author: analyzer.getString(bookInfoRule.author ?? '') ?? '',
        coverUrl: analyzer.getString(bookInfoRule.coverUrl ?? '') ?? '',
        intro: analyzer.getString(bookInfoRule.intro ?? '') ?? '',
        mediaType: MediaType.novel,
        originType: BookOriginType.online,
        sourceUrl: source.bookSourceUrl,
        sourceName: source.bookSourceName,
        kind: analyzer.getString(bookInfoRule.kind ?? ''),
        lastChapter: analyzer.getString(bookInfoRule.lastChapter ?? ''),
        wordCount: analyzer.getString(bookInfoRule.wordCount ?? ''),
        tocUrl: analyzer.getString(bookInfoRule.tocUrl ?? ''),
        canUpdate: true,
        addedTime: DateTime.now(),
      );
    } catch (e) {
      debugPrint('❌ 获取详情失败: $e');
      return null;
    }
  }

  /// 获取章节目录
  Future<List<Chapter>> getChapterList(String tocUrl) async {
    final tocRule = source.ruleToc;
    if (tocRule == null) return [];

    try {
      final headers = _buildHeaders();
      final response = await _client.execute(tocUrl, headers: headers);
      final html = response.body;

      lastTocHtml = html;

      // 使用 AnalyzeRule 引擎解析
      final analyzer = AnalyzeRule()..setContent(html, baseUrl: tocUrl);

      final chapterNames = analyzer.getStringList(tocRule.chapterName ?? '');
      final chapterUrls = analyzer.getStringList(tocRule.chapterUrl ?? '');

      final chapters = <Chapter>[];

      for (int i = 0; i < chapterNames.length; i++) {
        final name = chapterNames[i];
        final url = i < chapterUrls.length ? chapterUrls[i] : null;

        chapters.add(Chapter(
          id: '${tocUrl}_$i',
          bookId: tocUrl,
          title: name,
          index: i,
          url: url,
        ));
      }

      return chapters;
    } catch (e) {
      debugPrint('❌ 获取目录失败: $e');
      return [];
    }
  }

  /// 获取章节正文
  Future<String?> getContent(String chapterUrl) async {
    final contentRule = source.ruleContent;
    if (contentRule == null) return null;

    try {
      final headers = _buildHeaders();
      final response = await _client.execute(chapterUrl, headers: headers);
      final html = response.body;

      lastContentHtml = html;

      // 使用 AnalyzeRule 引擎解析
      final analyzer = AnalyzeRule()..setContent(html, baseUrl: chapterUrl);
      return analyzer.getString(contentRule.content ?? '');
    } catch (e) {
      debugPrint('❌ 获取正文失败: $e');
      return null;
    }
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
        return JsoupElement(doc.body!.firstChild as dom.Element, baseUrl: baseUrl);
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
      return JsoupElement(doc.body!.firstChild as dom.Element, baseUrl: baseUrl);
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
          while (j < rule.length && RegExp(r'[a-zA-Z0-9()]').hasMatch(rule[j])) {
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
