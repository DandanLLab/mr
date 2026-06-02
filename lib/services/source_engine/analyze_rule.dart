import 'dart:convert';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:flutter/foundation.dart';
import 'js_engine.dart';

/// 规则模式（与原版 legados 一致）
enum RuleMode {
  xpath,     // XPath 模式
  json,      // JSONPath 模式
  default_,  // 默认 CSS 选择器模式
  js,        // JavaScript 模式
  regex,     // 正则表达式模式
  webJs,     // WebView JS 模式
}

/// 规则解析器（参考 legados 的 AnalyzeRule）
class AnalyzeRule {
  dynamic _content;
  String? _baseUrl;
  bool _isJson = false;

  // 变量存储
  final Map<String, dynamic> _variables = {};

  AnalyzeRule setContent(dynamic content, {String? baseUrl}) {
    _content = content;
    _baseUrl = baseUrl;

    if (content is String) {
      _isJson = _isJsonContent(content);
    } else if (content is Map || content is List) {
      _isJson = true;
    } else {
      _isJson = false;
    }

    return this;
  }

  AnalyzeRule setBaseUrl(String? baseUrl) {
    _baseUrl = baseUrl;
    return this;
  }

  /// 设置变量
  AnalyzeRule putVariable(String key, dynamic value) {
    _variables[key] = value;
    return this;
  }

  /// 获取变量
  dynamic getVariable(String key) {
    return _variables[key];
  }

  bool _isJsonContent(String content) {
    final trimmed = content.trim();
    return (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'));
  }

  /// 获取字符串结果
  String? getString(String ruleStr) {
    if (ruleStr.isEmpty) return null;

    final rules = _parseRules(ruleStr);
    dynamic result = _content;

    for (final rule in rules) {
      result = _applyRule(result, rule);
      if (result == null) return null;
    }

    return _toString(result);
  }

  /// 获取字符串列表
  List<String> getStringList(String ruleStr) {
    if (ruleStr.isEmpty) return [];

    final rules = _parseRules(ruleStr);
    dynamic result = _content;

    for (final rule in rules) {
      result = _applyRule(result, rule, isList: true);
      if (result == null) return [];
    }

    return _toStringList(result);
  }

  /// 获取元素列表
  List<dynamic> getElements(String ruleStr) {
    if (ruleStr.isEmpty) return [];

    final rules = _parseRules(ruleStr);
    dynamic result = _content;

    for (final rule in rules) {
      result = _applyRule(result, rule, isList: true);
      if (result == null) return [];
    }

    if (result is List) return result;
    if (result != null) return [result];
    return [];
  }

  /// 获取 Map 列表
  List<Map<String, dynamic>> getMapList(String ruleStr) {
    if (ruleStr.isEmpty) return [];

    final rules = _parseRules(ruleStr);
    dynamic result = _content;

    for (final rule in rules) {
      result = _applyRule(result, rule, isList: true);
      if (result == null) return [];
    }

    return _toMapList(result);
  }

  /// 解析规则字符串为规则列表
  List<_SourceRule> _parseRules(String ruleStr) {
    final rules = <_SourceRule>[];
    int start = 0;
    String remaining = ruleStr;

    // 1. 分离 @put:{...} 规则
    remaining = _splitPutRule(remaining);

    // 2. 按 @ 分割规则步骤（但要跳过 @CSS:, @XPath: 等前缀和 @get:, @put:）
    final parts = _splitByAt(remaining);

    for (final part in parts) {
      if (part.isEmpty) continue;
      rules.add(_SourceRule.parse(part, isJson: _isJson));
    }

    return rules;
  }

  /// 分离 @put 规则
  String _splitPutRule(String ruleStr) {
    final putPattern = RegExp(r'@put:\s*(\{[^}]+?\})', caseSensitive: false);
    return ruleStr.replaceAllMapped(putPattern, (match) {
      final jsonStr = match.group(1);
      if (jsonStr != null) {
        try {
          final map = json.decode(jsonStr) as Map<String, dynamic>;
          _variables.addAll(map);
        } catch (_) {}
      }
      return '';
    });
  }

  /// 按 @ 分割规则（智能分割，跳过前缀）
  List<String> _splitByAt(String ruleStr) {
    final result = <String>[];
    int start = 0;
    int i = 0;

    while (i < ruleStr.length) {
      if (ruleStr[i] == '@') {
        // 检查是否是前缀
        final remaining = ruleStr.substring(i).toLowerCase();
        if (remaining.startsWith('@css:') ||
            remaining.startsWith('@xpath:') ||
            remaining.startsWith('@json:') ||
            remaining.startsWith('@js:') ||
            remaining.startsWith('@get:') ||
            remaining.startsWith('@put:')) {
          i++;
          continue;
        }

        // 检查是否是属性选择器 (@href, @src, @text 等)
        if (i + 1 < ruleStr.length) {
          final nextChar = ruleStr[i + 1];
          if (RegExp(r'[a-zA-Z]').hasMatch(nextChar)) {
            // 可能是属性，检查后面是否跟着 @
            int j = i + 1;
            while (j < ruleStr.length && ruleStr[j] != '@') {
              j++;
            }
            // 如果后面还有 @，则分割
            if (j < ruleStr.length) {
              result.add(ruleStr.substring(start, j).trim());
              start = j;
              i = j;
              continue;
            }
          }
        }

        // 分割
        if (i > start) {
          result.add(ruleStr.substring(start, i).trim());
        }
        start = i + 1;
      }
      i++;
    }

    if (start < ruleStr.length) {
      result.add(ruleStr.substring(start).trim());
    }

    return result.where((s) => s.isNotEmpty).toList();
  }

  /// 应用规则
  dynamic _applyRule(dynamic content, _SourceRule rule, {bool isList = false}) {
    // 先替换变量
    String processedRule = _replaceVariables(rule.rule);

    // 根据模式处理
    switch (rule.mode) {
      case RuleMode.xpath:
        return _applyXPath(content, processedRule, isList: isList);
      case RuleMode.json:
        return _applyJsonPath(content, processedRule, isList: isList);
      case RuleMode.js:
        return _applyJs(content, processedRule);
      case RuleMode.regex:
        return _applyRegex(content, processedRule, isList: isList);
      case RuleMode.webJs:
        return _applyWebJs(content, processedRule);
      case RuleMode.default_:
        return _applyCssSelector(content, processedRule, isList: isList);
    }
  }

  /// 替换变量
  String _replaceVariables(String rule) {
    // 替换 @get:{key}
    final getPattern = RegExp(r'@get:\s*\{([^}]+)\}', caseSensitive: false);
    rule = rule.replaceAllMapped(getPattern, (match) {
      final key = match.group(1);
      if (key != null) {
        return getVariable(key)?.toString() ?? '';
      }
      return '';
    });

    // 替换 {{key}}
    final varPattern = RegExp(r'\{\{([^}]+)\}\}');
    rule = rule.replaceAllMapped(varPattern, (match) {
      final key = match.group(1);
      if (key != null) {
        return getVariable(key)?.toString() ?? '';
      }
      return '';
    });

    return rule;
  }

  /// 应用 CSS 选择器
  dynamic _applyCssSelector(dynamic content, String selector, {bool isList = false}) {
    // 转换 legados 语法
    String cssSelector = _convertLegadoRule(selector);

    // 处理属性提取 @href, @src, @text 等
    if (cssSelector.startsWith('@')) {
      final attrName = cssSelector.substring(1);

      if (content is List) {
        return content.map((e) => _extractAttribute(e, attrName)).toList();
      }
      return _extractAttribute(content, attrName);
    }

    // 处理 text() 和 html()
    if (cssSelector == 'text' || cssSelector == 'text()') {
      if (content is List) {
        return content.map((e) => _extractText(e)).toList();
      }
      return _extractText(content);
    }

    if (cssSelector == 'html' || cssSelector == 'html()') {
      if (content is List) {
        return content.map((e) => _extractHtml(e)).toList();
      }
      return _extractHtml(content);
    }

    if (cssSelector == 'outerHtml') {
      if (content is List) {
        return content.map((e) => _extractOuterHtml(e)).toList();
      }
      return _extractOuterHtml(content);
    }

    // 处理选择器
    if (content is List) {
      final results = <dynamic>[];
      for (final item in content) {
        final elements = _selectElements(item, cssSelector);
        if (isList) {
          results.addAll(elements);
        } else if (elements.isNotEmpty) {
          results.add(elements.first);
        }
      }
      return results;
    }

    final elements = _selectElements(content, cssSelector);
    if (isList) {
      return elements;
    }
    return elements.isNotEmpty ? elements.first : null;
  }

  /// 转换 legados 规则语法
  String _convertLegadoRule(String rule) {
    if (rule.isEmpty) return rule;

    // 处理 class. → .
    if (rule.startsWith('class.')) {
      rule = '.${rule.substring(6)}';
    }

    // 处理 tag. → 直接标签名
    if (rule.startsWith('tag.')) {
      rule = rule.substring(4);
    }

    // 处理 id. → #
    if (rule.startsWith('id.')) {
      rule = '#${rule.substring(3)}';
    }

    // 处理索引语法: .0, .1 等 → :nth-child(1), :nth-child(2)
    final indexPattern = RegExp(r'\.(\d+)(?=[.\[#@]|$)');
    rule = rule.replaceAllMapped(indexPattern, (match) {
      final index = int.parse(match.group(1)!);
      return ':nth-child(${index + 1})';
    });

    return rule;
  }

  /// 选择元素
  List<dom.Element> _selectElements(dynamic content, String cssSelector) {
    if (cssSelector.isEmpty) return [];

    try {
      dom.Element? element = _toElement(content);
      if (element == null) return [];
      return element.querySelectorAll(cssSelector).toList();
    } catch (e) {
      debugPrint('❌ CSS选择器错误: $e');
      return [];
    }
  }

  /// 提取属性
  String _extractAttribute(dynamic content, String attrName) {
    dom.Element? element = _toElement(content);
    if (element == null) return '';

    // 特殊属性处理
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

  /// 提取外部 HTML
  String _extractOuterHtml(dynamic content) {
    dom.Element? element = _toElement(content);
    return element?.outerHtml ?? '';
  }

  /// 获取绝对 URL
  String _getAbsUrl(dom.Element element, String attrName) {
    final value = element.attributes[attrName];
    if (value == null) return '';

    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }

    if (_baseUrl != null) {
      try {
        final base = Uri.parse(_baseUrl!);
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

  /// 应用 XPath（简化实现）
  dynamic _applyXPath(dynamic content, String xpath, {bool isList = false}) {
    // XPath 需要专业库支持，这里用简化的正则实现
    String htmlStr = content.toString();

    try {
      final results = <String>[];

      // 简单的 XPath 解析
      if (xpath.contains('/@')) {
        // 提取属性: //a/@href
        final parts = xpath.split('/@');
        final tagPart = parts[0];
        final attrName = parts.length > 1 ? parts[1] : '';

        final tagMatch = RegExp(r'//(\w+)').firstMatch(tagPart);
        if (tagMatch != null) {
          final tagName = tagMatch.group(1)!;
          final pattern = RegExp('<$tagName[^>]*$attrName=["\']([^"\']*)["\']', caseSensitive: false);
          for (final m in pattern.allMatches(htmlStr)) {
            results.add(m.group(1) ?? '');
          }
        }
      } else if (xpath.contains('text()')) {
        // 提取文本: //a/text()
        final tagMatch = RegExp(r'//(\w+)').firstMatch(xpath);
        if (tagMatch != null) {
          final tagName = tagMatch.group(1)!;
          final pattern = RegExp('<$tagName[^>]*>([^<]*)</$tagName>', caseSensitive: false);
          for (final m in pattern.allMatches(htmlStr)) {
            final text = m.group(1)?.trim() ?? '';
            if (text.isNotEmpty) results.add(text);
          }
        }
      } else if (xpath.startsWith('//')) {
        // 提取元素: //div
        final tagMatch = RegExp(r'//(\w+)').firstMatch(xpath);
        if (tagMatch != null) {
          final tagName = tagMatch.group(1)!;
          final pattern = RegExp('<$tagName[^>]*>(.*?)</$tagName>', caseSensitive: false, dotAll: true);
          for (final m in pattern.allMatches(htmlStr)) {
            results.add(m.group(1)?.trim() ?? '');
          }
        }
      }

      if (isList) return results;
      return results.isNotEmpty ? results.first : null;
    } catch (e) {
      return null;
    }
  }

  /// 应用 JSONPath
  dynamic _applyJsonPath(dynamic content, String jsonPath, {bool isList = false}) {
    if (content is String) {
      try {
        content = json.decode(content);
      } catch (_) {
        return null;
      }
    }

    if (content is! Map && content is! List) {
      return null;
    }

    // 解析 JSONPath: $.data.list 或 $[0].name
    String path = jsonPath;
    if (path.startsWith('\$.')) {
      path = path.substring(2);
    } else if (path.startsWith('\$[')) {
      path = path.substring(1);
    }

    dynamic current = content;

    // 按 . 和 [] 分割路径
    final parts = <String>[];
    final partPattern = RegExp(r'([^\.\[\]]+)|\[(\d+)\]');
    for (final match in partPattern.allMatches(path)) {
      if (match.group(1) != null) {
        parts.add(match.group(1)!);
      } else if (match.group(2) != null) {
        parts.add('[${match.group(2)}]');
      }
    }

    for (final part in parts) {
      if (part.startsWith('[') && part.endsWith(']')) {
        // 数组索引
        final index = int.parse(part.substring(1, part.length - 1));
        if (current is List && index < current.length) {
          current = current[index];
        } else {
          return null;
        }
      } else if (part == '*') {
        // 通配符
        if (current is List) {
          return current;
        }
      } else {
        // 对象属性
        if (current is Map) {
          current = current[part];
        } else if (current is List) {
          current = current.map((item) {
            if (item is Map) return item[part];
            return null;
          }).toList();
        } else {
          return null;
        }
      }
    }

    return current;
  }

  /// 应用 JavaScript
  dynamic _applyJs(dynamic content, String jsCode) {
    try {
      // 同步调用 JS 引擎
      return JsEngine.instance.executeSync(jsCode, content, baseUrl: _baseUrl);
    } catch (e) {
      debugPrint('❌ JS执行失败: $e');
      return null;
    }
  }

  /// 应用 WebView JS
  dynamic _applyWebJs(dynamic content, String jsCode) {
    // TODO: 实现 WebView JS
    debugPrint('⚠️ WebView JS 暂不支持');
    return null;
  }

  /// 应用正则表达式
  dynamic _applyRegex(dynamic content, String pattern, {bool isList = false}) {
    final str = content.toString();

    try {
      // 处理正则替换 ##regex##replacement##flags
      final parts = pattern.split('##');
      String regex = parts.isNotEmpty ? parts[0] : '';
      String replacement = parts.length > 1 ? parts[1] : '';
      bool replaceFirst = parts.length > 3;

      // 如果只是正则匹配
      if (parts.length == 1) {
        final regExp = RegExp(regex, multiLine: true, dotAll: true);

        if (isList) {
          return regExp.allMatches(str).map((m) {
            // 返回第一个捕获组或整个匹配
            if (m.groupCount > 0) {
              return m.group(1) ?? m.group(0) ?? '';
            }
            return m.group(0) ?? '';
          }).toList();
        }

        final match = regExp.firstMatch(str);
        if (match != null) {
          if (match.groupCount > 0) {
            return match.group(1) ?? match.group(0) ?? '';
          }
          return match.group(0) ?? '';
        }
        return null;
      }

      // 正则替换
      final regExp = RegExp(regex, multiLine: true, dotAll: true);
      if (replaceFirst) {
        return str.replaceFirst(regExp, replacement);
      }
      return str.replaceAll(regExp, replacement);
    } catch (e) {
      debugPrint('❌ 正则执行失败: $e');
      return null;
    }
  }

  String? _toString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is dom.Element) return value.text.trim();
    if (value is List) return value.isNotEmpty ? _toString(value.first) : null;
    return value.toString();
  }

  List<String> _toStringList(dynamic value) {
    if (value == null) return [];
    if (value is String) return [value];
    if (value is List) {
      return value.map((e) => _toString(e) ?? '').where((e) => e.isNotEmpty).toList();
    }
    return [];
  }

  List<Map<String, dynamic>> _toMapList(dynamic value) {
    if (value == null) return [];
    if (value is Map) return [Map<String, dynamic>.from(value)];
    if (value is List) {
      return value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return [];
  }
}

/// 内部规则类
class _SourceRule {
  final String rule;
  final RuleMode mode;
  final String replaceRegex;
  final String replacement;
  final bool replaceFirst;
  final Map<String, String> putMap;

  _SourceRule({
    required this.rule,
    required this.mode,
    this.replaceRegex = '',
    this.replacement = '',
    this.replaceFirst = false,
    this.putMap = const {},
  });

  /// 解析规则字符串
  factory _SourceRule.parse(String ruleStr, {bool isJson = false}) {
    if (ruleStr.isEmpty) {
      return _SourceRule(rule: '', mode: RuleMode.default_);
    }

    String rule = ruleStr;
    RuleMode mode = RuleMode.default_;
    String replaceRegex = '';
    String replacement = '';
    bool replaceFirst = false;
    final putMap = <String, String>{};

    // 1. 解析模式前缀
    if (rule.startsWith('@CSS:') || rule.startsWith('@css:')) {
      mode = RuleMode.default_;
      rule = rule.substring(5);
    } else if (rule.startsWith('@@')) {
      mode = RuleMode.default_;
      rule = rule.substring(2);
    } else if (rule.startsWith('@XPath:') || rule.startsWith('@xpath:')) {
      mode = RuleMode.xpath;
      rule = rule.substring(7);
    } else if (rule.startsWith('@Json:') || rule.startsWith('@json:')) {
      mode = RuleMode.json;
      rule = rule.substring(6);
    } else if (rule.startsWith('@JS:') || rule.startsWith('@js:')) {
      mode = RuleMode.js;
      rule = rule.substring(4);
    } else if (rule.startsWith(':')) {
      // : 简写为 JS
      mode = RuleMode.js;
      rule = rule.substring(1);
    } else if (isJson || rule.startsWith('\$.') || rule.startsWith('\$[')) {
      // 自动识别 JSON
      mode = RuleMode.json;
    } else if (rule.startsWith('//') || rule.startsWith('/') || rule.startsWith('./')) {
      // 自动识别 XPath
      mode = RuleMode.xpath;
    }

    // 2. 分离 @put 规则
    final putPattern = RegExp(r'@put:\s*(\{[^}]+?\})', caseSensitive: false);
    rule = rule.replaceAllMapped(putPattern, (match) {
      final jsonStr = match.group(1);
      if (jsonStr != null) {
        try {
          final map = json.decode(jsonStr) as Map<String, dynamic>;
          putMap.addAll(map.map((k, v) => MapEntry(k, v.toString())));
        } catch (_) {}
      }
      return '';
    });

    // 3. 分离正则替换 ##
    final sharpIndex = rule.indexOf('##');
    if (sharpIndex > 0) {
      final mainRule = rule.substring(0, sharpIndex);
      final replacePart = rule.substring(sharpIndex + 2);

      final parts = replacePart.split('##');
      replaceRegex = parts.isNotEmpty ? parts[0] : '';
      replacement = parts.length > 1 ? parts[1] : '';
      replaceFirst = parts.length > 2;

      rule = mainRule;

      // 如果有正则替换，切换到正则模式
      if (replaceRegex.isNotEmpty && mode == RuleMode.default_) {
        mode = RuleMode.regex;
      }
    }

    return _SourceRule(
      rule: rule.trim(),
      mode: mode,
      replaceRegex: replaceRegex,
      replacement: replacement,
      replaceFirst: replaceFirst,
      putMap: putMap,
    );
  }
}
