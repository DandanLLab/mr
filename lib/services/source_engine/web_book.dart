import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../models/book_source.dart';
import '../../models/book.dart';
import '../../models/chapter.dart';
import 'analyze_rule.dart';
import 'web_proxy.dart';
import 'proxy_service.dart';

class UrlOption {
  final String? method;
  final Map<String, String>? headers;
  final String? body;
  final String? charset;
  final int retry;
  final bool useWebView;

  UrlOption({
    this.method,
    this.headers,
    this.body,
    this.charset,
    this.retry = 0,
    this.useWebView = false,
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
    );
  }
}

class ParsedUrl {
  final String url;
  final UrlOption? option;

  ParsedUrl({required this.url, this.option});
}

class WebBook {
  final BookSource source;
  final Dio _dio;

  WebBook(this.source) : _dio = Dio(BaseOptions(
    headers: _parseHeaders(source.header),
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));

  String _getProxyUrl() {
    if (kIsWeb) {
      return 'http://localhost:8888/';
    }
    return 'http://localhost:${ProxyService.instance.port}/';
  }

  String _proxifyUrl(String url) {
    final proxyUrl = _getProxyUrl();
    if (!url.contains('localhost:8888') && 
        !url.contains('localhost:${ProxyService.instance.port}') &&
        !url.contains('allorigins.win')) {
      return '$proxyUrl$url';
    }
    return url;
  }

  static Map<String, String> _parseHeaders(String? headerStr) {
    final headers = <String, String>{};
    if (headerStr == null || headerStr.isEmpty) return headers;

    try {
      final decoded = json.decode(headerStr);
      if (decoded is Map) {
        decoded.forEach((key, value) {
          headers[key.toString()] = value.toString();
        });
      }
    } catch (_) {
      final lines = headerStr.split('\n');
      for (final line in lines) {
        final parts = line.split(':');
        if (parts.length >= 2) {
          headers[parts[0].trim()] = parts.sublist(1).join(':').trim();
        }
      }
    }

    if (!headers.containsKey('User-Agent')) {
      headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    }

    return headers;
  }

  ParsedUrl _parseUrlWithOption(String urlWithOption, {String? keyword, int? page}) {
    String url = urlWithOption;
    UrlOption? option;

    final optionMatch = RegExp(r',\s*(\{[\s\S]*\})\s*$').firstMatch(urlWithOption);
    if (optionMatch != null) {
      url = urlWithOption.substring(0, optionMatch.start).trim();
      try {
        final optionJson = json.decode(optionMatch.group(1)!) as Map<String, dynamic>;
        option = UrlOption.fromJson(optionJson);
      } catch (_) {}
    }

    if (keyword != null) {
      url = url
          .replaceAll('{{key}}', Uri.encodeComponent(keyword))
          .replaceAll('{{searchKey}}', Uri.encodeComponent(keyword));
    }
    if (page != null) {
      url = url.replaceAll('{{page}}', page.toString());
    }

    return ParsedUrl(url: url, option: option);
  }

  Future<Response> _makeRequest(
    String url, 
    UrlOption? option, 
    String? keyword,
  ) async {
    final headers = <String, String>{};
    _dio.options.headers.forEach((key, value) {
      headers[key] = value.toString();
    });
    if (option?.headers != null) {
      headers.addAll(option!.headers!);
    }

    final method = option?.method?.toUpperCase() ?? 'GET';
    
    String? body;
    if (method == 'POST') {
      body = option?.body;
      
      // 替换 body 中的占位符
      if (body != null) {
        if (keyword != null) {
          body = body.replaceAll('{{key}}', Uri.encodeComponent(keyword));
        }
        debugPrint('📝 POST body: $body');
      }
    }

    // 在 Web 端使用 WebProxy
    if (kIsWeb) {
      // 使用代理 URL
      final proxyUrl = 'http://localhost:8888/$url';
      debugPrint('🔍 Requesting: $proxyUrl');
      debugPrint('📦 Method: $method, Body: $body');
      final html = await WebProxy.instance.fetch(
        proxyUrl,
        method: method,
        headers: headers,
        body: body,
      );
      debugPrint('📄 Response length: ${html.length}');
      return Response(
        requestOptions: RequestOptions(path: url),
        data: html,
        statusCode: 200,
      );
    }
    
    // 在其他平台使用 Dio
    final proxiedUrl = _proxifyUrl(url);
    
    if (method == 'POST') {
      return _dio.post(proxiedUrl, data: body, options: Options(headers: headers));
    } else {
      return _dio.get(proxiedUrl, options: Options(headers: headers));
    }
  }

  Future<List<Map<String, dynamic>>> searchBook(String keyword, {int page = 1}) async {
    if (source.searchUrl == null || source.searchUrl!.isEmpty) {
      return [];
    }

    final searchRule = source.ruleSearch;
    if (searchRule == null) return [];

    final parsed = _parseUrlWithOption(source.searchUrl!, keyword: keyword, page: page);

    try {
      final response = await _makeRequest(parsed.url, parsed.option, keyword);
      final html = response.data.toString();
      
      debugPrint('📖 HTML preview: ${html.substring(0, html.length > 500 ? 500 : html.length)}');

      final rule = AnalyzeRule()..setContent(html, baseUrl: source.bookSourceUrl);

      final bookList = rule.getStringList(searchRule.bookList ?? '');
      debugPrint('📚 Book list count: ${bookList.length}');
      
      final nameList = rule.getStringList(searchRule.name ?? '');
      final authorList = rule.getStringList(searchRule.author ?? '');
      final coverList = rule.getStringList(searchRule.coverUrl ?? '');
      final introList = rule.getStringList(searchRule.intro ?? '');
      final bookUrlList = rule.getStringList(searchRule.bookUrl ?? '');

      debugPrint('📖 Names: $nameList');

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
      debugPrint('搜索失败: $e');
      return [];
    }
  }

  Future<Book?> getBookInfo(String bookUrl) async {
    final bookInfoRule = source.ruleBookInfo;
    if (bookInfoRule == null) return null;

    try {
      final response = await _dio.get(_proxifyUrl(bookUrl));
      final html = response.data.toString();

      final rule = AnalyzeRule()..setContent(html, baseUrl: bookUrl);

      return Book(
        bookUrl: bookUrl,
        name: rule.getString(bookInfoRule.name ?? '') ?? '未知书名',
        author: rule.getString(bookInfoRule.author ?? '') ?? '',
        coverUrl: rule.getString(bookInfoRule.coverUrl ?? '') ?? '',
        intro: rule.getString(bookInfoRule.intro ?? '') ?? '',
        mediaType: MediaType.novel,
        originType: BookOriginType.online,
        sourceUrl: source.bookSourceUrl,
        sourceName: source.bookSourceName,
        canUpdate: true,
        addedTime: DateTime.now(),
      );
    } catch (e) {
      return null;
    }
  }

  Future<List<Chapter>> getChapterList(String bookUrl) async {
    final tocRule = source.ruleToc;
    if (tocRule == null) return [];

    try {
      final response = await _dio.get(_proxifyUrl(bookUrl));
      final html = response.data.toString();

      final rule = AnalyzeRule()..setContent(html, baseUrl: bookUrl);

      final nameList = rule.getStringList(tocRule.chapterName ?? '');
      final urlList = rule.getStringList(tocRule.chapterUrl ?? '');

      final chapters = <Chapter>[];

      for (int i = 0; i < nameList.length; i++) {
        chapters.add(Chapter(
          id: '${bookUrl}_$i',
          bookId: bookUrl,
          title: nameList[i],
          index: i,
          url: i < urlList.length ? urlList[i] : null,
        ));
      }

      return chapters;
    } catch (e) {
      return [];
    }
  }

  Future<String?> getContent(String bookUrl, Chapter chapter) async {
    final contentRule = source.ruleContent;
    if (contentRule == null) return null;

    final chapterUrl = chapter.url ?? bookUrl;

    try {
      final response = await _dio.get(_proxifyUrl(chapterUrl));
      final html = response.data.toString();

      final rule = AnalyzeRule()..setContent(html, baseUrl: chapterUrl);
      return rule.getString(contentRule.content ?? '');
    } catch (e) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> exploreBook(String exploreUrl) async {
    final exploreRule = source.ruleExplore;
    if (exploreRule == null) return [];

    final parsed = _parseUrlWithOption(exploreUrl);

    try {
      final response = await _makeRequest(parsed.url, parsed.option, null);
      final html = response.data.toString();

      final rule = AnalyzeRule()..setContent(html, baseUrl: source.bookSourceUrl);

      final nameList = rule.getStringList(exploreRule.name ?? '');
      final authorList = rule.getStringList(exploreRule.author ?? '');
      final coverList = rule.getStringList(exploreRule.coverUrl ?? '');
      final introList = rule.getStringList(exploreRule.intro ?? '');
      final bookUrlList = rule.getStringList(exploreRule.bookUrl ?? '');

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
      return [];
    }
  }
}
