import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/book_source.dart';
import '../models/rules/book_info_rule.dart';
import '../models/rules/search_rule.dart';
import '../models/rules/explore_rule.dart';
import '../models/rules/toc_rule.dart';
import '../models/rules/content_rule.dart';
import 'storage_service.dart';

typedef SourceTextFetcher = Future<String> Function(
    String url, bool withoutUserAgent);

class BookSourceImportResult {
  final List<BookSource> sources;
  final int added;
  final int updated;
  final int unchanged;

  const BookSourceImportResult({
    required this.sources,
    required this.added,
    required this.updated,
    required this.unchanged,
  });
}

class BookSourceImportService {
  final StorageService storage;
  final SourceTextFetcher _fetchText;

  BookSourceImportService({
    StorageService? storage,
    SourceTextFetcher? fetchText,
  })  : storage = storage ?? StorageService.instance,
        _fetchText = fetchText ?? _defaultFetchText;

  Future<BookSourceImportResult> importText(String text) async {
    final sources = await parseText(text);
    if (sources.isEmpty) {
      throw const FormatException('未找到有效书源');
    }

    var added = 0;
    var updated = 0;
    var unchanged = 0;
    for (final source in sources) {
      final old = storage.getBookSource(source.bookSourceUrl);
      if (old == null) {
        added++;
      } else if (_sameJson(old, source.toJson())) {
        unchanged++;
      } else {
        updated++;
      }
      await storage.saveBookSource(source.toJson());
    }
    return BookSourceImportResult(
      sources: sources,
      added: added,
      updated: updated,
      unchanged: unchanged,
    );
  }

  Future<BookSourceImportResult> importBytes(Uint8List bytes, {String? fileExtension}) {
    final text = utf8.decode(bytes, allowMalformed: true);
    // 根据文件后缀判定格式
    if (fileExtension == 'js') {
      return importJsText(text);
    }
    return importText(text);
  }

  /// 导入 JS 格式书源文件
  Future<BookSourceImportResult> importJsText(String jsCode) async {
    final jsCodeTrimmed = jsCode.trim();
    if (jsCodeTrimmed.isEmpty) {
      throw const FormatException('JS书源内容为空');
    }

    // 从JS代码注释中提取元数据（支持注释格式和 JS 变量格式）
    String name = '';
    String url = '';
    String group = 'JS书源';

    final nameMatch = RegExp(r'@name\s+(.+)', caseSensitive: false).firstMatch(jsCodeTrimmed);
    if (nameMatch != null) {
      name = nameMatch.group(1)?.trim() ?? '';
    } else {
      final jsVarMatch = RegExp(r'''var\s+(?:bookSource)?[Nn]ame\s*=\s*["']([^"']+)["']''').firstMatch(jsCodeTrimmed);
      if (jsVarMatch != null) name = jsVarMatch.group(1) ?? '';
    }
    final urlMatch = RegExp(r'@url\s+(.+)', caseSensitive: false).firstMatch(jsCodeTrimmed);
    if (urlMatch != null) {
      url = urlMatch.group(1)?.trim() ?? '';
    } else {
      final jsVarMatch = RegExp(r'''var\s+(?:bookSource)?[Uu]rl\s*=\s*["']([^"']+)["']''').firstMatch(jsCodeTrimmed);
      if (jsVarMatch != null) url = jsVarMatch.group(1) ?? '';
    }
    final groupMatch = RegExp(r'@group\s+(.+)', caseSensitive: false).firstMatch(jsCodeTrimmed);
    if (groupMatch != null) {
      group = groupMatch.group(1)?.trim() ?? 'JS书源';
    } else {
      final jsVarMatch = RegExp(r'''var\s+(?:bookSource)?[Gg]roup\s*=\s*["']([^"']+)["']''').firstMatch(jsCodeTrimmed);
      if (jsVarMatch != null) group = jsVarMatch.group(1) ?? 'JS书源';
    }

    // 自动生成缺失的元数据
    if (name.isEmpty) name = 'JS书源_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    if (url.isEmpty) url = 'js_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

    // 检测代码中定义了哪些函数
    final hasSearch = RegExp(r'function\s+search\s*\(').hasMatch(jsCodeTrimmed);
    final hasExplore = RegExp(r'function\s+explore\s*\(').hasMatch(jsCodeTrimmed);
    final hasBookInfo = RegExp(r'function\s+bookInfo\s*\(').hasMatch(jsCodeTrimmed);
    final hasToc = RegExp(r'function\s+toc\s*\(').hasMatch(jsCodeTrimmed);
    final hasContent = RegExp(r'function\s+content\s*\(').hasMatch(jsCodeTrimmed);
    final hasNextTocUrl = RegExp(r'function\s+nextTocUrl\s*\(').hasMatch(jsCodeTrimmed);
    final hasNextContentUrl = RegExp(r'function\s+nextContentUrl\s*\(').hasMatch(jsCodeTrimmed);

    // 提取元数据（支持注释格式和 JS 变量格式）
    final searchUrlMeta = _extractMeta(jsCodeTrimmed, 'searchUrl') ?? _extractJsVar(jsCodeTrimmed, 'searchUrl');
    final exploreUrlMeta = _extractMeta(jsCodeTrimmed, 'exploreUrl') ?? _extractJsVar(jsCodeTrimmed, 'exploreUrl');
    final headerMeta = _extractMeta(jsCodeTrimmed, 'header') ?? _extractJsVar(jsCodeTrimmed, 'header');

    final source = BookSource(
      bookSourceUrl: url,
      bookSourceName: name,
      bookSourceGroup: group,
      jsLib: jsCodeTrimmed,
      engine: 'quickjs',
      sourceFormat: 'js',
      header: headerMeta,
      searchUrl: searchUrlMeta ?? '',
      exploreUrl: exploreUrlMeta ?? '',
      ruleSearch: hasSearch ? SearchRule(
        bookList: '<js>search(key, page, result)</js>',
        name: '\$.name',
        author: '\$.author',
        bookUrl: '\$.bookUrl',
        coverUrl: '\$.coverUrl',
        kind: '\$.kind',
        lastChapter: '\$.lastChapter',
        intro: '\$.intro',
      ) : null,
      ruleExplore: hasExplore ? ExploreRule(
        bookList: '<js>explore(baseUrl, result)</js>',
        name: '\$.name',
        author: '\$.author',
        bookUrl: '\$.bookUrl',
        coverUrl: '\$.coverUrl',
        kind: '\$.kind',
        lastChapter: '\$.lastChapter',
        intro: '\$.intro',
      ) : null,
      ruleBookInfo: hasBookInfo ? BookInfoRule(
        init: '<js>bookInfo(result)</js>',
        name: '\$.name',
        author: '\$.author',
        coverUrl: '\$.coverUrl',
        intro: '\$.intro',
        kind: '\$.kind',
        lastChapter: '\$.lastChapter',
        tocUrl: '\$.tocUrl',
        wordCount: '\$.wordCount',
      ) : null,
      ruleToc: hasToc ? TocRule(
        chapterList: '<js>toc(result)</js>',
        chapterName: '\$.name',
        chapterUrl: '\$.url',
        isVolume: '\$.isVolume',
        nextTocUrl: hasNextTocUrl ? '<js>nextTocUrl(result)</js>' : null,
      ) : null,
      ruleContent: hasContent ? ContentRule(
        content: '<js>content(result)</js>',
        nextContentUrl: hasNextContentUrl ? '<js>nextContentUrl(result)</js>' : null,
      ) : null,
    );

    var added = 0;
    var updated = 0;
    var unchanged = 0;
    final old = storage.getBookSource(source.bookSourceUrl);
    if (old == null) {
      added++;
    } else if (_sameJson(old, source.toJson())) {
      unchanged++;
    } else {
      updated++;
    }
    await storage.saveBookSource(source.toJson());

    return BookSourceImportResult(
      sources: [source],
      added: added,
      updated: updated,
      unchanged: unchanged,
    );
  }

  Future<List<BookSource>> parseText(String text,
      {Set<String>? visitedUrls}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return [];
    if (_isHttpUrl(trimmed)) {
      return _parseUrl(trimmed, visitedUrls ?? <String>{});
    }

    final decoded = jsonDecode(trimmed);
    return _parseDecoded(decoded, visitedUrls ?? <String>{});
  }

  Future<List<BookSource>> _parseUrl(
      String rawUrl, Set<String> visitedUrls) async {
    final withoutUserAgent = rawUrl.endsWith('#requestWithoutUA');
    final url = withoutUserAgent
        ? rawUrl.substring(0, rawUrl.length - '#requestWithoutUA'.length)
        : rawUrl;
    if (!visitedUrls.add(url)) return [];
    final text = await _fetchText(url, withoutUserAgent);
    return parseText(text, visitedUrls: visitedUrls);
  }

  Future<List<BookSource>> _parseDecoded(
      dynamic decoded, Set<String> visitedUrls) async {
    if (decoded is List) {
      final result = <BookSource>[];
      for (final item in decoded) {
        if (item is Map) {
          result.add(_sourceFromMap(item));
        } else if (item is String && _isHttpUrl(item)) {
          result.addAll(await _parseUrl(item, visitedUrls));
        }
      }
      return _deduplicate(result);
    }

    if (decoded is Map) {
      final sourceUrls = decoded['sourceUrls'];
      if (sourceUrls is List) {
        final result = <BookSource>[];
        for (final url in sourceUrls.whereType<String>()) {
          result.addAll(await _parseUrl(url, visitedUrls));
        }
        return _deduplicate(result);
      }
      return [_sourceFromMap(decoded)];
    }
    throw const FormatException('书源必须是 JSON 对象、数组或网络地址');
  }

  BookSource _sourceFromMap(Map<dynamic, dynamic> value) {
    final source = BookSource.fromJson(
      value.map((key, item) => MapEntry('$key', item)),
    );
    if (source.bookSourceUrl.trim().isEmpty ||
        source.bookSourceName.trim().isEmpty) {
      throw const FormatException('书源缺少 bookSourceUrl 或 bookSourceName');
    }
    return source;
  }

  List<BookSource> _deduplicate(List<BookSource> sources) {
    final result = <String, BookSource>{};
    for (final source in sources) {
      result[source.bookSourceUrl] = source;
    }
    return result.values.toList();
  }

  static bool _sameJson(
          Map<String, dynamic> left, Map<String, dynamic> right) =>
      jsonEncode(left) == jsonEncode(right);

  static bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  static Future<String> _defaultFetchText(
      String url, bool withoutUserAgent) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.plain,
      followRedirects: true,
    ));
    final response = await dio.get<String>(
      url,
      options: Options(
        headers: withoutUserAgent ? {'User-Agent': ''} : null,
        responseType: ResponseType.plain,
      ),
    );
    return response.data ?? '';
  }

  /// 从 JS 书源代码中提取 @key 元数据注释
  /// 支持多行：从 @key 行开始，收集后续以 // 开头的连续注释行
  static String? _extractMeta(String code, String key) {
    final lines = code.split('\n');
    final buffer = StringBuffer();
    bool collecting = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (!collecting) {
        final m = RegExp('^//\\s*@' + key + r'\s+(.*)$').firstMatch(trimmed);
        if (m != null) {
          collecting = true;
          final rest = m.group(1)?.trim() ?? '';
          if (rest.isNotEmpty) buffer.write(rest);
        }
      } else {
        // 继续收集以 // 开头的连续注释行
        if (trimmed.startsWith('//')) {
          final content = trimmed.substring(2).trim();
          // 遇到新的 @key 标记则停止
          if (RegExp(r'^@\w+').hasMatch(content)) break;
          buffer.writeln();
          buffer.write(content);
        } else {
          // 非注释行，停止收集
          break;
        }
      }
    }

    final result = buffer.toString().trim();
    return result.isEmpty ? null : result;
  }

  /// 从 JS 变量声明中提取元数据
  /// 支持：var searchUrl = "xxx" 或 var searchUrl = 'xxx'
  /// 对于 JS 表达式（如 JSON.stringify(...)），自动添加 @js: 前缀
  static String? _extractJsVar(String code, String key) {
    // 简单字符串赋值：var xxx = "value" 或 var xxx = 'value'
    final simpleMatch = RegExp('''var\\s+$key\\s*=\\s*["']([^"']+)["']''').firstMatch(code);
    if (simpleMatch != null) return simpleMatch.group(1);

    // JS 表达式赋值：var xxx = JSON.stringify({...}) 等
    // 提取到下一个 var/function/@注释 为止
    final multiLineMatch = RegExp('var\\s+$key\\s*=\\s*(.*?)(?=\\nvar\\s|\\nfunction\\s|\\n//\\s*@)', dotAll: true).firstMatch(code);
    if (multiLineMatch != null) {
      var value = multiLineMatch.group(1)?.trim() ?? '';
      if (value.isNotEmpty) {
        // JS 表达式需要 @js: 前缀，运行时才知道要执行
        return '@js:$value';
      }
    }

    return null;
  }
}
