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

/// URL 璇锋眰閫夐」锛堢被浼?OkHttp 鐨?Request.Builder锛?
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
      body: _bodyString(json['body']),
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

/// 瑙ｆ瀽鍚庣殑 URL锛堢被浼?OkHttp 鐨?Request锛?
class ParsedUrl {
  final String url;
  final UrlOption? option;

  ParsedUrl({required this.url, this.option});
}

/// 鍝嶅簲鍖呰绫伙紙绫讳技 OkHttp 鐨?Response锛?
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

/// 缃戠粶璇锋眰瀹㈡埛绔紙绫讳技 OkHttp 鐨?OkHttpClient锛?
class HttpClient {
  static final HttpClient _instance = HttpClient._internal();
  static HttpClient get instance => _instance;
  HttpClient._internal();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 30),
  ));

  /// 鎵ц璇锋眰锛堢被浼?OkHttp 鐨?Call.execute锛?
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
      // Web 绔娇鐢ㄤ唬鐞?
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

      // 闈?Web 绔娇鐢ㄤ唬鐞嗘湇鍔?
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
      debugPrint('鉂?HTTP Error: ${e.type} - ${e.message}');
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

/// 涔︽簮缃戠粶璇锋眰绫伙紙鍙傝€?legados 鐨?WebBook锛?
class WebBook {
  final BookSource source;
  final HttpClient _client;

  // 缂撳瓨鏈€杩戠殑鍝嶅簲婧愮爜
  String? lastSearchHtml;
  String? lastExploreHtml;
  String? lastBookInfoHtml;
  String? lastTocHtml;
  String? lastContentHtml;

  WebBook(this.source) : _client = HttpClient.instance;

  /// 瑙ｆ瀽 URL 鍜岄€夐」
  ParsedUrl _parseUrlWithOption(
    String urlWithOption, {
    String? keyword,
    int? page,
  }) {
    String url = urlWithOption;
    UrlOption? option;

    // 瑙ｆ瀽 URL 鏈熬鐨?JSON 閫夐」
    final optionMatch =
        RegExp(r',\s*(\{[\s\S]*\})\s*$').firstMatch(urlWithOption);
    if (optionMatch != null) {
      url = urlWithOption.substring(0, optionMatch.start).trim();
      try {
        final optionJson =
            json.decode(optionMatch.group(1)!) as Map<String, dynamic>;
        option = UrlOption.fromJson(optionJson);
        debugPrint('馃敡 URL閫夐」: method=${option.method}, body=${option.body}');
      } catch (e) {
        debugPrint('鉂?瑙ｆ瀽URL閫夐」澶辫触: $e');
      }
    }

    // 鏇挎崲鍗犱綅绗?
    if (keyword != null) {
      url = url
          .replaceAll('{{key}}', Uri.encodeComponent(keyword))
          .replaceAll('{{searchKey}}', Uri.encodeComponent(keyword));

      // 鍚屾椂鏇挎崲閫夐」涓殑鍗犱綅绗?
      final currentOption = option;
      if (currentOption != null && currentOption.body != null) {
        option = UrlOption(
          method: currentOption.method,
          headers: currentOption.headers,
          body: currentOption.body!
              .replaceAll('{{key}}', Uri.encodeComponent(keyword))
              .replaceAll('{{searchKey}}', Uri.encodeComponent(keyword)),
          charset: currentOption.charset,
          retry: currentOption.retry,
          useWebView: currentOption.useWebView,
          connectTimeout: currentOption.connectTimeout,
          readTimeout: currentOption.readTimeout,
        );
      }
    }
    if (page != null) {
      url = url.replaceAll('{{page}}', page.toString());
    }
    url = _replaceUrlVariables(url, keyword: keyword, page: page);
    final parsedOption = option;
    if (parsedOption?.body != null) {
      option = UrlOption(
        method: parsedOption!.method,
        headers: parsedOption.headers,
        body: _replaceUrlVariables(
          parsedOption.body!,
          keyword: keyword,
          page: page,
        ),
        charset: parsedOption.charset,
        retry: parsedOption.retry,
        useWebView: parsedOption.useWebView,
        connectTimeout: parsedOption.connectTimeout,
        readTimeout: parsedOption.readTimeout,
      );
    }

    // 澶勭悊鐩稿 URL - 鎷兼帴涔︽簮鍩虹 URL
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      String baseUrl = source.bookSourceUrl;
      // 纭繚鍩虹 URL 浠?/ 缁撳熬
      if (!baseUrl.endsWith('/')) {
        baseUrl += '/';
      }
      // 绉婚櫎鐩稿 URL 寮€澶寸殑 /
      if (url.startsWith('/')) {
        url = url.substring(1);
      }
      url = baseUrl + url;
      debugPrint('馃敆 鎷兼帴鐩稿URL: $url');
    }

    return ParsedUrl(url: url, option: option);
  }

  /// 鏋勫缓璇锋眰澶?
  Map<String, String> _buildHeaders({Map<String, String>? extraHeaders}) {
    final headers = <String, String>{};

    // 瑙ｆ瀽涔︽簮鑷畾涔夎姹傚ご
    if (source.header != null && source.header!.isNotEmpty) {
      try {
        final decoded = json.decode(source.header!);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            headers[key.toString()] = value.toString();
          });
        }
      } catch (_) {
        // 灏濊瘯鎸夎瑙ｆ瀽
        for (final line in source.header!.split('\n')) {
          final parts = line.split(':');
          if (parts.length >= 2) {
            headers[parts[0].trim()] = parts.sublist(1).join(':').trim();
          }
        }
      }
    }

    // 娣诲姞榛樿 User-Agent
    if (!headers.containsKey('User-Agent')) {
      headers['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    }

    // 鍚堝苟棰濆璇锋眰澶?
    if (extraHeaders != null) {
      headers.addAll(extraHeaders);
    }

    return headers;
  }

  /// 鎵ц缃戠粶璇锋眰
  Future<StrResponse> _executeRequest(
    ParsedUrl parsed, {
    String? keyword,
  }) async {
    final headers = _buildHeaders(
      extraHeaders: parsed.option?.headers,
    );

    final method = parsed.option?.method?.toUpperCase() ?? 'GET';
    String? body = parsed.option?.body;

    // 鏇挎崲 body 涓殑鍗犱綅绗?
    if (body != null && keyword != null) {
      body = body.replaceAll('{{key}}', Uri.encodeComponent(keyword));
    }

    // POST 璇锋眰璁剧疆榛樿 Content-Type
    if (method == 'POST' && !headers.containsKey('Content-Type')) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }

    debugPrint('馃寪 璇锋眰: $method ${parsed.url}');
    if (body != null) {
      debugPrint('馃摝 Body: $body');
    }

    return _client.execute(
      parsed.url,
      method: method,
      headers: headers,
      body: body,
      charset: parsed.option?.charset,
    );
  }

  /// 鎼滅储涔︾睄
  Future<List<Map<String, dynamic>>> searchBook(String keyword,
      {int page = 1}) async {
    if (source.searchUrl == null || source.searchUrl!.isEmpty) {
      debugPrint('鉂?鎼滅储鍦板潃涓虹┖');
      return [];
    }

    final searchRule = source.ruleSearch;
    if (searchRule == null) {
      debugPrint('鉂?鎼滅储瑙勫垯涓虹┖');
      return [];
    }

    final parsed =
        _parseUrlWithOption(source.searchUrl!, keyword: keyword, page: page);
    debugPrint('馃攳 鎼滅储URL: ${parsed.url}');

    try {
      final response = await _executeRequest(parsed, keyword: keyword);
      final html = response.body;

      // 淇濆瓨鍘熷 HTML
      lastSearchHtml = html;

      debugPrint('馃摉 鍝嶅簲闀垮害: ${html.length}');
      if (html.isEmpty) {
        debugPrint('鉂?鍝嶅簲涓虹┖');
        return [];
      }

      // 浣跨敤 Jsoup 椋庢牸鐨勮В鏋愬櫒
      // 鑾峰彇涔︾睄鍒楄〃鍏冪礌
      final bookListRule = searchRule.bookList ?? '';
      debugPrint('馃摎 涔︾睄鍒楄〃瑙勫垯: $bookListRule');

      final bookElements = AnalyzeRule()
          .setContent(html, baseUrl: parsed.url)
          .getElements(bookListRule);
      debugPrint('馃摎 涔︾睄鍏冪礌鏁伴噺: ${bookElements.length}');

      if (bookElements.isEmpty) {
        debugPrint('未找到书籍元素');
        return [];
      }

      final results = <Map<String, dynamic>>[];

      for (int i = 0; i < bookElements.length; i++) {
        final analyzer =
            AnalyzeRule().setContent(bookElements[i], baseUrl: parsed.url);

        // 鍦ㄦ瘡涓厓绱犱笂鎵ц瑙勫垯
        final name = analyzer.getString(searchRule.name ?? '')?.trim();
        final author = analyzer.getString(searchRule.author ?? '')?.trim();
        final coverUrl = analyzer.getString(searchRule.coverUrl ?? '')?.trim();
        final intro = analyzer.getString(searchRule.intro ?? '')?.trim();
        final bookUrl = analyzer.getString(searchRule.bookUrl ?? '')?.trim();
        final kind = analyzer.getString(searchRule.kind ?? '')?.trim();
        final lastChapter =
            analyzer.getString(searchRule.lastChapter ?? '')?.trim();

        debugPrint('馃摉 [$i] 涔﹀悕: $name, 浣滆€? $author');

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

      debugPrint('馃摉 鏈€缁堢粨鏋滄暟閲? ${results.length}');
      return results;
    } catch (e, stackTrace) {
      debugPrint('鉂?鎼滅储澶辫触: $e');
      debugPrint('鉂?鍫嗘爤: $stackTrace');
      return [];
    }
  }

  /// 鍙戠幇涔︾睄
  Future<List<Map<String, dynamic>>> exploreBook(String exploreUrl) async {
    final exploreRule = source.ruleExplore;
    if (exploreRule == null) return [];

    final parsed = _parseUrlWithOption(exploreUrl);

    try {
      final response = await _executeRequest(parsed);
      final html = response.body;

      // 淇濆瓨鍘熷 HTML
      lastExploreHtml = html;

      final doc = Jsoup.parse(html, baseUrl: source.bookSourceUrl);

      final nameList =
          doc.select(exploreRule.name ?? '').map((e) => e.text()).toList();
      final authorList =
          doc.select(exploreRule.author ?? '').map((e) => e.text()).toList();
      final coverList = doc
          .select(exploreRule.coverUrl ?? '')
          .map((e) => e.absUrl())
          .toList();
      final introList =
          doc.select(exploreRule.intro ?? '').map((e) => e.text()).toList();
      final bookUrlList =
          doc.select(exploreRule.bookUrl ?? '').map((e) => e.absUrl()).toList();

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
      debugPrint('鉂?鍙戠幇澶辫触: $e');
      return [];
    }
  }

  /// 鑾峰彇涔︾睄璇︽儏
  Future<Book?> getBookInfo(String bookUrl) async {
    final bookInfoRule = source.ruleBookInfo;
    if (bookInfoRule == null) return null;

    try {
      final headers = _buildHeaders();
      final response = await _client.execute(bookUrl, headers: headers);
      final html = response.body;

      // 淇濆瓨鍘熷 HTML
      lastBookInfoHtml = html;

      final analyzer = AnalyzeRule().setContent(html, baseUrl: bookUrl);
      final name = analyzer.getString(bookInfoRule.name ?? '')?.trim();
      final tocUrl = analyzer.getString(bookInfoRule.tocUrl ?? '')?.trim();

      // 鎵ц棰勫鐞嗚鍒?
      if (bookInfoRule.init != null && bookInfoRule.init!.isNotEmpty) {
        // TODO: 鎵ц JS 棰勫鐞?
      }

      final safeName = name == null || name.isEmpty ? '鏈煡涔﹀悕' : name;
      return Book(
        bookUrl: bookUrl,
        name: safeName,
        author: analyzer.getString(bookInfoRule.author ?? '')?.trim() ?? '',
        coverUrl: analyzer.getString(bookInfoRule.coverUrl ?? '')?.trim() ?? '',
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
      debugPrint('鉂?鑾峰彇璇︽儏澶辫触: $e');
      return null;
    }
  }

  /// 鑾峰彇绔犺妭鐩綍
  Future<List<Chapter>> getChapterList(String tocUrl) async {
    final tocRule = source.ruleToc;
    if (tocRule == null) return [];

    try {
      final headers = _buildHeaders();
      final response = await _client.execute(tocUrl, headers: headers);
      final html = response.body;

      // 淇濆瓨鍘熷 HTML
      lastTocHtml = html;

      final chapters = <Chapter>[];
      final chapterElements = AnalyzeRule()
          .setContent(html, baseUrl: tocUrl)
          .getElements(tocRule.chapterList ?? '');
      if (chapterElements.isNotEmpty) {
        for (int i = 0; i < chapterElements.length; i++) {
          final analyzer =
              AnalyzeRule().setContent(chapterElements[i], baseUrl: tocUrl);
          final name = analyzer.getString(tocRule.chapterName ?? '')?.trim();
          final url = analyzer.getString(tocRule.chapterUrl ?? '')?.trim();
          if (name == null || name.isEmpty) continue;
          chapters.add(Chapter(
            id: '${tocUrl}_$i',
            bookId: tocUrl,
            title: name,
            index: chapters.length,
            url: url,
          ));
        }
        return chapters;
      }

      final analyzer = AnalyzeRule().setContent(html, baseUrl: tocUrl);
      final names = analyzer.getStringList(tocRule.chapterName ?? '');
      final urls = analyzer.getStringList(tocRule.chapterUrl ?? '');
      for (int i = 0; i < names.length; i++) {
        chapters.add(Chapter(
          id: '${tocUrl}_$i',
          bookId: tocUrl,
          title: names[i],
          index: i,
          url: i < urls.length ? urls[i] : null,
        ));
      }

      return chapters;
    } catch (e) {
      debugPrint('鉂?鑾峰彇鐩綍澶辫触: $e');
      return [];
    }
  }

  /// 鑾峰彇绔犺妭姝ｆ枃
  Future<String?> getContent(String chapterUrl) async {
    final contentRule = source.ruleContent;
    if (contentRule == null) return null;

    try {
      final headers = _buildHeaders();
      final response = await _client.execute(chapterUrl, headers: headers);
      final html = response.body;

      // 淇濆瓨鍘熷 HTML
      lastContentHtml = html;

      final analyzer = AnalyzeRule().setContent(html, baseUrl: chapterUrl);
      final parts = [
        analyzer.getString(contentRule.content ?? '')?.trim(),
        analyzer.getString(contentRule.subContent ?? '')?.trim(),
      ].where((e) => e != null && e.isNotEmpty).cast<String>().toList();
      if (parts.isEmpty) return null;
      var content = parts.join('\n');
      final replaceRegex = contentRule.replaceRegex;
      if (replaceRegex != null && replaceRegex.isNotEmpty) {
        content = _replaceByRule(content, replaceRegex);
      }
      return content;
    } catch (e) {
      debugPrint('鉂?鑾峰彇姝ｆ枃澶辫触: $e');
      return null;
    }
  }
}

/// Jsoup 椋庢牸鐨?HTML 瑙ｆ瀽鍣?
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

String? _bodyString(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is Map || value is List) return jsonEncode(value);
  return value.toString();
}

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
          ? ''
          : match.group(0)!.replaceFirst(regex, replacement);
    }
    return value.replaceAll(regex, replacement);
  } catch (_) {
    return value;
  }
}

class Jsoup {
  /// 瑙ｆ瀽 HTML 鏂囨。
  static JsoupDocument parse(String html, {String? baseUrl}) {
    final doc = html_parser.parse(html);
    return JsoupDocument(doc, baseUrl: baseUrl);
  }
}

/// Jsoup 椋庢牸鐨勬枃妗ｅ璞?
class JsoupDocument {
  final dom.Document _doc;
  final String? baseUrl;

  JsoupDocument(this._doc, {this.baseUrl});

  /// 閫夋嫨鍏冪礌锛堢被浼?Jsoup 鐨?select锛?
  List<JsoupElement> select(String cssSelector) {
    if (cssSelector.isEmpty) return [];

    final converted = _convertLegadoRule(cssSelector);
    final elements = _doc.querySelectorAll(converted);
    return elements.map((e) => JsoupElement(e, baseUrl: baseUrl)).toList();
  }

  /// 閫夋嫨绗竴涓厓绱狅紙绫讳技 Jsoup 鐨?selectFirst锛?
  JsoupElement? selectFirst(String cssSelector) {
    if (cssSelector.isEmpty) return null;

    final converted = _convertLegadoRule(cssSelector);
    final element = _doc.querySelector(converted);
    if (element == null) return null;
    return JsoupElement(element, baseUrl: baseUrl);
  }

  /// 杞崲 legados 瑙勫垯璇硶
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
      // 澶勭悊灞炴€ч€夋嫨鍣?
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

/// Jsoup 椋庢牸鐨勫厓绱犲璞?
class JsoupElement {
  final dom.Element _element;
  final String? baseUrl;

  JsoupElement(this._element, {this.baseUrl});

  /// 鑾峰彇鏂囨湰鍐呭锛堢被浼?Jsoup 鐨?text()锛?
  String text() => _element.text.trim();

  /// 鑾峰彇 HTML 鍐呭锛堢被浼?Jsoup 鐨?html()锛?
  String html() => _element.innerHtml;

  /// 鑾峰彇澶栭儴 HTML锛堢被浼?Jsoup 鐨?outerHtml()锛?
  String outerHtml() => _element.outerHtml;

  /// 鑾峰彇灞炴€у€硷紙绫讳技 Jsoup 鐨?attr()锛?
  String? attr(String name) => _element.attributes[name];

  /// 鑾峰彇缁濆 URL锛堢被浼?Jsoup 鐨?absUrl()锛?
  String? absUrl([String attrName = 'href']) {
    final value = _element.attributes[attrName];
    if (value == null) return null;

    // 澶勭悊鐩稿 URL
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }

    if (baseUrl != null) {
      final base = Uri.parse(baseUrl!);
      return base.resolve(value).toString();
    }

    return value;
  }

  /// 閫夋嫨瀛愬厓绱狅紙鏀寔澶氭楠よ鍒欙級
  List<JsoupElement> select(String rule) {
    if (rule.isEmpty) return [this];

    // 鎸?@ 鍒嗗壊瑙勫垯姝ラ
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
        // 杩斿洖涓€涓寘鍚枃鏈殑铏氭嫙鍏冪礌
        final doc = html_parser.parse('<root>$e</root>');
        return JsoupElement(doc.body!.firstChild as dom.Element,
            baseUrl: baseUrl);
      }
      return JsoupElement(_element, baseUrl: baseUrl);
    }).toList();
  }

  /// 閫夋嫨绗竴涓瓙鍏冪礌锛堟敮鎸佸姝ラ瑙勫垯锛?
  JsoupElement? selectFirst(String rule) {
    if (rule.isEmpty) return this;

    // 鎸?@ 鍒嗗壊瑙勫垯姝ラ
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

  /// 鍒嗗壊瑙勫垯姝ラ
  List<String> _splitSteps(String rule) {
    final steps = <String>[];
    int start = 0;
    int i = 0;

    while (i < rule.length) {
      if (rule[i] == '@') {
        // 妫€鏌ユ槸鍚︽槸灞炴€ч€夋嫨鍣?(@text, @href 绛?
        if (i + 1 < rule.length && RegExp(r'[a-zA-Z]').hasMatch(rule[i + 1])) {
          // 鏌ユ壘灞炴€у悕缁撴潫浣嶇疆
          int j = i + 1;
          while (
              j < rule.length && RegExp(r'[a-zA-Z0-9()]').hasMatch(rule[j])) {
            j++;
          }
          // 濡傛灉鍚庨潰杩樻湁 @锛屽垯鍒嗗壊
          if (j < rule.length && rule[j] == '@') {
            steps.add(rule.substring(start, j));
            start = j;
            i = j;
            continue;
          }
          // 鍚﹀垯浣滀负鏈€鍚庝竴涓楠?
          if (j == rule.length) {
            steps.add(rule.substring(start));
            return steps;
          }
          // 灞炴€у悗闈㈣窡鐫€鍏朵粬瀛楃锛岀户缁?
          i++;
          continue;
        }
        // 鍒嗗壊
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

  /// 搴旂敤鍗曚釜瑙勫垯姝ラ
  dynamic _applyStep(dynamic content, String step, {bool isList = false}) {
    if (step.isEmpty) return content;

    // 澶勭悊灞炴€ф彁鍙?
    if (step.startsWith('@')) {
      final attrName = step.substring(1);
      if (content is List) {
        return content.map((e) => _extractAttr(e, attrName)).toList();
      }
      return _extractAttr(content, attrName);
    }

    // 澶勭悊 text() 鍜?html()
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

    // 杞崲 legados 璇硶
    String cssSelector = _convertLegadoRule(step);

    // 澶勭悊绱㈠紩璇硶锛堝湪 CSS 閫夋嫨鍚庯級
    int? index;
    final indexMatch = RegExp(r'\.(\d+)$').firstMatch(cssSelector);
    if (indexMatch != null) {
      index = int.parse(indexMatch.group(1)!);
      cssSelector = cssSelector.substring(0, indexMatch.start);
    }

    // 鎵ц閫夋嫨
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

  /// 杞崲 legados 瑙勫垯璇硶
  String _convertLegadoRule(String rule) {
    if (rule.isEmpty) return rule;

    // 澶勭悊 class. 鈫?.
    if (rule.startsWith('class.')) {
      rule = '.${rule.substring(6)}';
    }
    // 澶勭悊 tag. 鈫?鐩存帴鏍囩鍚?
    else if (rule.startsWith('tag.')) {
      rule = rule.substring(4);
    }
    // 澶勭悊 id. 鈫?#
    else if (rule.startsWith('id.')) {
      rule = '#${rule.substring(3)}';
    }

    // 澶勭悊绱㈠紩璇硶: .0, .1 绛夛紙浣嗕繚鐣欏湪杩斿洖鍓嶅鐞嗭級
    // 杩欓噷鍙浆鎹㈤€夋嫨鍣ㄩ儴鍒?

    return rule;
  }

  /// 鎻愬彇灞炴€?
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

  /// 鎻愬彇鏂囨湰
  String _extractText(dynamic content) {
    dom.Element? element = _toElement(content);
    return element?.text.trim() ?? '';
  }

  /// 鎻愬彇 HTML
  String _extractHtml(dynamic content) {
    dom.Element? element = _toElement(content);
    return element?.innerHtml ?? '';
  }

  /// 鑾峰彇缁濆 URL
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

  /// 杞崲涓?Element
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
