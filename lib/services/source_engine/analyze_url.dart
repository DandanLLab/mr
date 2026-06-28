import 'dart:convert';
import '../app_logger.dart';
import '../native/js_engine.dart';
import 'charset_utils.dart';

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
  final int? webViewDelayTime; // 借鉴 legado 的 webViewDelayTime

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
    this.webViewDelayTime,
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
      webViewDelayTime: _toNullableInt(json['webViewDelayTime']),
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
      webViewDelayTime: webViewDelayTime,
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

/// 解析 Legado 书源使用的 URL 语法
/// 借鉴 legado 的 AnalyzeUrl，支持 JS 动态 URL、{{js}} 替换、charset 编码
class AnalyzeUrl {
  static final RegExp _optionStart = RegExp(r'\s*,\s*(?=\{)');
  static final RegExp _pageRule = RegExp(r'<(.*?)>');

  static ParsedUrl parse(
    String ruleUrl, {
    String? baseUrl,
    String? keyword,
    int? page,
    String? body, // 借鉴 legado：外部传入的 body
  }) {
    var urlPart = ruleUrl.trim();

    // 1. 执行嵌入的 JS（借鉴 legado 的 analyzeJs）
    // 支持 @js:xxx 和 <js>xxx</js> 格式
    urlPart = _analyzeJs(urlPart, keyword: keyword, page: page);

    // 2. 解析 URL 和选项
    String? extractedUrl;
    UrlOption? option;

    // 2a. 尝试纯 JSON 对象格式：{url: "/path", body: "...", method: "POST"}
    if (urlPart.startsWith('{')) {
      try {
        final decoded = jsonDecode(urlPart);
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          if (map.containsKey('url')) {
            extractedUrl = map.remove('url').toString();
          }
          option = UrlOption.fromJson(map);
        }
      } catch (_) {
        // 不是合法 JSON，走原始逻辑
      }
    }

    // 2b. 原始 legado 格式：URL,{options}
    if (extractedUrl == null && option == null) {
      final optionMatch = _optionStart.firstMatch(urlPart);
      extractedUrl = optionMatch == null
          ? urlPart.trim()
          : urlPart.substring(0, optionMatch.start).trim();

      if (optionMatch != null) {
        // 注意：必须用 urlPart（JS 执行后的结果），不能用 ruleUrl
        // 因为 optionMatch 是在 urlPart 上匹配的，位置对应 urlPart 而非 ruleUrl
        // 之前用 ruleUrl.substring(optionMatch.end) 会导致位置错位，
        // 把 JS 代码尾部的字符（如 ';）混入选项文本，引发 FormatException
        final optionText = urlPart.substring(optionMatch.end).trim();
        try {
          final decoded = jsonDecode(optionText);
          if (decoded is! Map) {
            throw const FormatException('URL option must be a JSON object');
          }
          option = UrlOption.fromJson(Map<String, dynamic>.from(decoded));
        } catch (e) {
          AppLogger.instance.logJsError('AnalyzeUrl', '选项解析失败: $e');
        }
      }
    }

    urlPart = extractedUrl ?? urlPart;

    // 3. 替换变量（包括 {{js表达式}}）
    urlPart = replaceVariables(urlPart, keyword: keyword, page: page);
    option = option?.replaceVariables(keyword: keyword, page: page);

    // 4. 合并外部 body
    if (body != null && body.isNotEmpty) {
      option ??= const UrlOption();
      option = UrlOption(
        method: option.method ?? 'POST',
        headers: option.headers,
        body: body,
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
        webViewDelayTime: option.webViewDelayTime,
      );
    }

    // 5. charset 编码处理（借鉴 legado 的 encodeParams）
    final charset = option?.charset ?? option?.type;
    if (charset != null && charset.isNotEmpty) {
      urlPart = _encodeWithCharset(urlPart, charset, keyword: keyword);
    }

    // 6. 解析 URL
    return ParsedUrl(url: resolve(baseUrl, urlPart), option: option);
  }

  /// 执行嵌入的 JS（借鉴 legado 的 analyzeJs）
  /// 支持 @js:xxx 和 <js>xxx</js> 格式
  static String _analyzeJs(String url, {String? keyword, int? page}) {
    // 处理 <js>xxx</js> 格式
    final jsTagPattern = RegExp(r'<js>([\s\S]*?)</js>', caseSensitive: false);
    if (jsTagPattern.hasMatch(url)) {
      url = url.replaceAllMapped(jsTagPattern, (match) {
        final jsCode = match.group(1)!;
        return _evalUrlJs(jsCode, keyword: keyword, page: page);
      });
    }

    // 处理 @js:xxx 格式（到字符串末尾）
    final jsPrefixPattern = RegExp(r'@js:(.+)$', caseSensitive: false);
    final jsMatch = jsPrefixPattern.firstMatch(url);
    if (jsMatch != null) {
      final jsCode = jsMatch.group(1)!;
      final jsResult = _evalUrlJs(jsCode, keyword: keyword, page: page);
      if (jsResult.isNotEmpty) return jsResult;
    }

    return url;
  }

  /// 执行 URL 中的 JS 代码
  static String _evalUrlJs(String jsCode, {String? keyword, int? page}) {
    try {
      // 注入常用变量
      var code = jsCode.trim();
      if (keyword != null) {
        code = 'var key = ${jsonEncode(keyword)}; var searchKey = ${jsonEncode(keyword)}; $code';
      }
      if (page != null) {
        code = 'var page = $page; var searchPage = $page; $code';
      }

      final result = JsEngine.instance.evaluate(code);
      if (result != null) {
        var str = result.toString();
        if (str == 'undefined' || str == 'null') return '';
        return str;
      }
    } catch (e) {
      AppLogger.instance.logJsError('AnalyzeUrl', 'JS执行失败: $e');
    }
    return '';
  }

  /// 替换变量（借鉴 legado 的 replaceKeyPageJs）
  /// 支持 {{key}}、{{page}}、{{js表达式}}、<page,page,...> 等
  static String replaceVariables(String value, {String? keyword, int? page}) {
    var result = value;

    // 1. 替换 {{js表达式}}（借鉴 legado 的 innerRule）
    result = _replaceJsExpressions(result, keyword: keyword, page: page);

    // 2. 替换固定变量
    if (keyword != null) {
      final encoded = Uri.encodeComponent(keyword);
      result = result
          .replaceAll('{{key}}', encoded)
          .replaceAll('{{searchKey}}', encoded);
      // 注意：不再裸替换 searchKey，避免误伤
    }
    if (page != null) {
      result = result
          .replaceAll('{{page}}', '$page')
          .replaceAll('{{searchPage}}', '$page');
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
        // 借鉴 legado：page < pages.size 取 pages[page-1]，否则取 last
        final index = page <= 0 ? 0 : page - 1;
        return pages[index < pages.length ? index : pages.length - 1];
      });
    }

    return result;
  }

  /// 替换 {{js表达式}}（借鉴 legado 的 RuleAnalyzer.innerRule）
  static String _replaceJsExpressions(String value, {String? keyword, int? page}) {
    // 只处理包含 {{ 的字符串
    if (!value.contains('{{')) return value;

    return _innerRule(value, '{{', '}}', (expr) {
      // 判断是否为固定变量（不需要 JS 执行）
      if (expr == 'key' || expr == 'searchKey' || expr == 'page' || expr == 'searchPage') {
        return '{{$expr}}'; // 保留给后续替换
      }

      // 执行 JS 表达式
      try {
        var code = expr;
        if (keyword != null) {
          code = 'var key = ${jsonEncode(keyword)}; var searchKey = ${jsonEncode(keyword)}; $code';
        }
        if (page != null) {
          code = 'var page = $page; var searchPage = $page; $code';
        }
        final result = JsEngine.instance.evaluate(code);
        if (result != null) {
          var str = result.toString();
          if (str == 'undefined' || str == 'null') return '';
          // Double 格式化（借鉴 legado：1.0 → 1）
          if (str.endsWith('.0') && double.tryParse(str) != null) {
            str = int.parse(str.substring(0, str.length - 2)).toString();
          }
          return str;
        }
      } catch (_) {}
      return '';
    });
  }

  /// 内嵌规则替换（平衡组版本）
  static String _innerRule(
    String value,
    String startStr,
    String endStr,
    String Function(String expr) replaceFn,
  ) {
    final result = StringBuffer();
    var searchStart = 0;

    while (searchStart < value.length) {
      final startIdx = value.indexOf(startStr, searchStart);
      if (startIdx < 0) {
        result.write(value.substring(searchStart));
        break;
      }

      result.write(value.substring(searchStart, startIdx));

      final contentStart = startIdx + startStr.length;
      final endIdx = _findBalancedEnd(value, contentStart, startStr, endStr);

      if (endIdx < 0) {
        result.write(value.substring(startIdx));
        break;
      }

      final innerContent = value.substring(contentStart, endIdx);
      try {
        result.write(replaceFn(innerContent.trim()));
      } catch (_) {
        result.write(innerContent);
      }

      searchStart = endIdx + endStr.length;
    }

    return result.toString();
  }

  /// 找到平衡的结束位置
  static int _findBalancedEnd(
    String value,
    int start,
    String startStr,
    String endStr,
  ) {
    var depth = 1;
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var i = start;

    while (i < value.length && depth > 0) {
      final ch = value[i];
      if (ch == '\\' && i + 1 < value.length) { i += 2; continue; }
      if (ch == "'" && !inDoubleQuote) inSingleQuote = !inSingleQuote;
      if (ch == '"' && !inSingleQuote) inDoubleQuote = !inDoubleQuote;
      if (!inSingleQuote && !inDoubleQuote) {
        if (value.startsWith(startStr, i)) { depth++; i += startStr.length; continue; }
        if (value.startsWith(endStr, i)) { depth--; if (depth == 0) return i; i += endStr.length; continue; }
      }
      i++;
    }
    return -1;
  }

  /// charset 编码处理（借鉴 legado 的 encodeParams）
  /// 对非 UTF-8 编码的搜索关键词进行字符集转码
  static String _encodeWithCharset(String url, String charset, {String? keyword}) {
    // 支持 charset=escape 使用 escape 编码
    if (charset.toLowerCase() == 'escape' && keyword != null) {
      return url;
    }

    if (keyword != null && keyword.isNotEmpty) {
      final cs = charset.trim().toLowerCase();
      if (cs != 'utf-8' && cs != 'utf8' && cs != '' && cs != 'escape') {
        // 非 UTF-8 编码（如 GBK/GB2312）：重新编码搜索词
        // 之前 _resolveUrl 已经用 Uri.encodeComponent (UTF-8) 编码了 keyword
        // 这里替换为指定字符集的 percent-encoding
        final utf8Encoded = Uri.encodeComponent(keyword);
        final csEncoded = CharsetUtils.urlEncode(keyword, charset);
        if (utf8Encoded != csEncoded) {
          return url.replaceFirst(utf8Encoded, csEncoded);
        }
      }
    }

    return url;
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
