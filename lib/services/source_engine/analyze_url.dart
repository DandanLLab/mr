import 'dart:convert';

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

  const UrlOption({
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
    final rawHeaders = json['headers'];
    return UrlOption(
      method: json['method']?.toString(),
      headers: rawHeaders is Map
          ? rawHeaders.map((key, value) => MapEntry('$key', '$value'))
          : null,
      body: _bodyToString(json['body']),
      charset: json['charset']?.toString(),
      retry: _toInt(json['retry']),
      useWebView: _toBool(json['webView']),
      connectTimeout: _toNullableInt(json['connectTimeout']),
      readTimeout: _toNullableInt(json['readTimeout']),
      type: json['type']?.toString(),
      webJs: json['webJs']?.toString(),
      bodyJs: json['bodyJs']?.toString(),
      js: json['js']?.toString(),
      dnsIp: json['dnsIp']?.toString(),
    );
  }

  UrlOption replaceVariables({String? keyword, int? page}) {
    return UrlOption(
      method: method,
      headers: headers?.map(
        (key, value) => MapEntry(key,
            AnalyzeUrl.replaceVariables(value, keyword: keyword, page: page)),
      ),
      body: body == null
          ? null
          : AnalyzeUrl.replaceVariables(body!, keyword: keyword, page: page),
      charset: charset,
      retry: retry,
      useWebView: useWebView,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      type: type,
      webJs: webJs,
      bodyJs: bodyJs,
      js: js,
      dnsIp: dnsIp,
    );
  }

  static String? _bodyToString(dynamic value) {
    if (value == null) return null;
    return value is String ? value : jsonEncode(value);
  }

  static int _toInt(dynamic value) => _toNullableInt(value) ?? 0;
  static int? _toNullableInt(dynamic value) =>
      value is int ? value : int.tryParse('$value');
  static bool _toBool(dynamic value) =>
      value == true || '$value'.toLowerCase() == 'true';
}

class ParsedUrl {
  final String url;
  final UrlOption? option;

  const ParsedUrl({required this.url, this.option});
}

/// Parses the URL syntax used by Legado book sources.
class AnalyzeUrl {
  static final RegExp _optionStart = RegExp(r'\s*,\s*(?=\{)');
  static final RegExp _pageRule = RegExp(r'<(.*?)>');

  static ParsedUrl parse(
    String ruleUrl, {
    String? baseUrl,
    String? keyword,
    int? page,
  }) {
    final optionMatch = _optionStart.firstMatch(ruleUrl);
    var urlPart = optionMatch == null
        ? ruleUrl.trim()
        : ruleUrl.substring(0, optionMatch.start).trim();
    UrlOption? option;

    if (optionMatch != null) {
      final optionText = ruleUrl.substring(optionMatch.end).trim();
      final decoded = jsonDecode(optionText);
      if (decoded is! Map) {
        throw const FormatException('URL option must be a JSON object');
      }
      option = UrlOption.fromJson(Map<String, dynamic>.from(decoded));
    }

    urlPart = replaceVariables(urlPart, keyword: keyword, page: page);
    option = option?.replaceVariables(keyword: keyword, page: page);
    return ParsedUrl(url: resolve(baseUrl, urlPart), option: option);
  }

  static String replaceVariables(String value, {String? keyword, int? page}) {
    var result = value;
    if (keyword != null) {
      final encoded = Uri.encodeComponent(keyword);
      result = result
          .replaceAll('{{key}}', encoded)
          .replaceAll('{{searchKey}}', encoded)
          .replaceAll('searchKey', encoded);
    }
    if (page != null) {
      result = result
          .replaceAll('{{page}}', '$page')
          .replaceAll('{{searchPage}}', '$page')
          .replaceAll('searchPage', '$page');
      result = result.replaceAllMapped(
        RegExp(r'\{\{page\s*([+-])\s*(\d+)\}\}', caseSensitive: false),
        (match) {
          final amount = int.parse(match.group(2)!);
          return '${match.group(1) == '+' ? page + amount : page - amount}';
        },
      );
      result = result.replaceAllMapped(_pageRule, (match) {
        final pages =
            match.group(1)!.split(',').map((item) => item.trim()).toList();
        if (pages.isEmpty) return '';
        final index = page <= 1 ? 0 : page - 1;
        return pages[index < pages.length ? index : pages.length - 1];
      });
    }
    return result;
  }

  static String resolve(String? baseUrl, String value) {
    if (value.isEmpty || baseUrl == null || baseUrl.isEmpty) return value;
    try {
      return Uri.parse(baseUrl).resolve(value).toString();
    } catch (_) {
      return value;
    }
  }
}
