import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/book_source.dart';
import '../models/rules/book_info_rule.dart';
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

    // 从JS代码注释中提取元数据
    String name = '';
    String url = '';
    String group = 'JS书源';

    final nameMatch = RegExp(r'@name\s+(.+)', caseSensitive: false).firstMatch(jsCodeTrimmed);
    if (nameMatch != null) name = nameMatch.group(1)?.trim() ?? '';
    final urlMatch = RegExp(r'@url\s+(.+)', caseSensitive: false).firstMatch(jsCodeTrimmed);
    if (urlMatch != null) url = urlMatch.group(1)?.trim() ?? '';
    final groupMatch = RegExp(r'@group\s+(.+)', caseSensitive: false).firstMatch(jsCodeTrimmed);
    if (groupMatch != null) group = groupMatch.group(1)?.trim() ?? 'JS书源';

    // 自动生成缺失的元数据
    if (name.isEmpty) name = 'JS书源_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    if (url.isEmpty) url = 'js_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

    // 检测代码中定义了哪些函数
    final hasSearch = RegExp(r'function\s+search\s*\(').hasMatch(jsCodeTrimmed);
    final hasExplore = RegExp(r'function\s+explore\s*\(').hasMatch(jsCodeTrimmed);
    final hasBookInfo = RegExp(r'function\s+bookInfo\s*\(').hasMatch(jsCodeTrimmed);
    final hasToc = RegExp(r'function\s+toc\s*\(').hasMatch(jsCodeTrimmed);
    final hasContent = RegExp(r'function\s+content\s*\(').hasMatch(jsCodeTrimmed);

    final source = BookSource(
      bookSourceUrl: url,
      bookSourceName: name,
      bookSourceGroup: group,
      jsLib: jsCodeTrimmed,
      engine: 'quickjs',
      sourceFormat: 'js',
      searchUrl: hasSearch ? '<js>search(result)</js>' : null,
      exploreUrl: hasExplore ? '<js>explore(result)</js>' : null,
      ruleBookInfo: hasBookInfo ? BookInfoRule(init: '<js>bookInfo(result)</js>') : null,
      ruleToc: hasToc ? TocRule(chapterList: '<js>toc(result)</js>') : null,
      ruleContent: hasContent ? ContentRule(content: '<js>content(result)</js>') : null,
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
}
