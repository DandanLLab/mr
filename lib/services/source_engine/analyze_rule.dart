import 'dart:convert';
import 'dart:typed_data';
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'js_engine.dart';

enum RuleType { xpath, jsonPath, regex, jsoup, js }

class SourceRule {
  final String rule;
  final RuleType type;
  final List<String> steps;

  SourceRule({
    required this.rule,
    required this.type,
    this.steps = const [],
  });

  factory SourceRule.parse(String ruleStr) {
    if (ruleStr.isEmpty) {
      return SourceRule(rule: '', type: RuleType.jsoup);
    }

    List<String> steps = [];
    final parts = ruleStr.split('@');
    
    for (int i = 0; i < parts.length; i++) {
      final part = parts[i].trim();
      if (part.isEmpty) continue;
      
      if (i == parts.length - 1 && _isAttributeOrText(part)) {
        steps.add('@$part');
      } else {
        steps.add(part);
      }
    }

    RuleType type = RuleType.jsoup;

    for (final step in steps) {
      if (step.startsWith('//') || step.startsWith('./')) {
        type = RuleType.xpath;
        break;
      } else if (step.startsWith('\$.')) {
        type = RuleType.jsonPath;
        break;
      } else if (step.startsWith(':')) {
        type = RuleType.js;
        break;
      } else if (RegExp(r'^@css:').hasMatch(step)) {
        type = RuleType.jsoup;
        break;
      }
    }

    return SourceRule(rule: ruleStr, type: type, steps: steps);
  }

  static bool _isAttributeOrText(String part) {
    return ['text', 'html', 'outerHtml', 'href', 'src', 'title', 'alt', 'onclick']
        .contains(part);
  }
}

class AnalyzeRule {
  dynamic _content;
  String? _baseUrl;
  bool _isJson = false;

  AnalyzeRule setContent(dynamic content, {String? baseUrl}) {
    _content = content;
    _baseUrl = baseUrl;

    if (content is String) {
      _isJson = _isJsonContent(content);
    } else {
      _isJson = false;
    }

    return this;
  }

  AnalyzeRule setBaseUrl(String? baseUrl) {
    _baseUrl = baseUrl;
    return this;
  }

  bool _isJsonContent(String content) {
    final trimmed = content.trim();
    return (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'));
  }

  String? getString(String ruleStr) {
    if (ruleStr.isEmpty) return null;

    final rule = SourceRule.parse(ruleStr);
    dynamic result = _content;

    for (final step in rule.steps) {
      result = _applyStep(result, step, rule.type);
      if (result == null) return null;
    }

    return _toString(result);
  }

  List<String> getStringList(String ruleStr) {
    if (ruleStr.isEmpty) return [];

    final rule = SourceRule.parse(ruleStr);
    dynamic result = _content;

    for (final step in rule.steps) {
      result = _applyStep(result, step, rule.type, isList: true);
      if (result == null) return [];
    }

    return _toStringList(result);
  }

  List<dynamic> getElements(String ruleStr) {
    if (ruleStr.isEmpty) return [];

    final rule = SourceRule.parse(ruleStr);
    dynamic result = _content;

    for (final step in rule.steps) {
      result = _applyStep(result, step, rule.type, isList: true);
      if (result == null) return [];
    }

    if (result is List) return result;
    return [result];
  }

  List<Map<String, dynamic>> getMapList(String ruleStr) {
    if (ruleStr.isEmpty) return [];

    final rule = SourceRule.parse(ruleStr);
    dynamic result = _content;

    for (final step in rule.steps) {
      result = _applyStep(result, step, rule.type, isList: true);
      if (result == null) return [];
    }

    return _toMapList(result);
  }

  dynamic _applyStep(dynamic content, String step, RuleType type, {bool isList = false}) {
    if (step.isEmpty) return content;

    if (step.startsWith('@css:')) {
      return _applyCssSelector(content, step.substring(5), isList: isList);
    }

    if (step.startsWith('@xpath:')) {
      return _applyXPath(content, step.substring(7), isList: isList);
    }

    if (step.startsWith('@json:')) {
      return _applyJsonPath(content, step.substring(6), isList: isList);
    }

    if (step.startsWith('@js:')) {
      return _applyJs(content, step.substring(4));
    }

    if (step.startsWith(':')) {
      return _applyJs(content, step.substring(1));
    }

    switch (type) {
      case RuleType.xpath:
        return _applyXPath(content, step, isList: isList);
      case RuleType.jsonPath:
        return _applyJsonPath(content, step, isList: isList);
      case RuleType.jsoup:
        return _applyCssSelector(content, step, isList: isList);
      case RuleType.js:
        return _applyJs(content, step);
      case RuleType.regex:
        return _applyRegex(content, step, isList: isList);
    }
  }

  dynamic _applyCssSelector(dynamic content, String selector, {bool isList = false}) {
    String cssSelector = _convertLegadoRule(selector);

    // 处理属性提取 @href, @src 等（@text 和 @html 特殊处理）
    if (cssSelector.startsWith('@')) {
      final attrName = cssSelector.substring(1);
      
      // @text 特殊处理：返回文本内容
      if (attrName == 'text' || attrName == 'text()') {
        if (content is List) {
          return content.map((e) {
            if (e is dom.Element) return e.text.trim();
            return '';
          }).toList();
        }
        dom.Element? element = _toElement(content);
        if (element == null) return isList ? [] : '';
        return element.text.trim();
      }
      
      // @html 特殊处理：返回内部HTML
      if (attrName == 'html' || attrName == 'html()') {
        if (content is List) {
          return content.map((e) {
            if (e is dom.Element) return e.innerHtml;
            return '';
          }).toList();
        }
        dom.Element? element = _toElement(content);
        if (element == null) return isList ? [] : '';
        return element.innerHtml;
      }
      
      // @outerHtml 特殊处理
      if (attrName == 'outerHtml') {
        if (content is List) {
          return content.map((e) {
            if (e is dom.Element) return e.outerHtml;
            return '';
          }).toList();
        }
        dom.Element? element = _toElement(content);
        if (element == null) return isList ? [] : '';
        return element.outerHtml;
      }
      
      // 普通属性提取 @href, @src 等
      if (content is List) {
        return content.map((e) {
          if (e is dom.Element) {
            return e.attributes[attrName] ?? '';
          }
          return '';
        }).toList();
      }
      dom.Element? element = _toElement(content);
      if (element == null) return isList ? [] : '';
      return element.attributes[attrName] ?? '';
    }

    // 处理文本提取
    if (cssSelector == 'text' || cssSelector == 'text()') {
      if (content is List) {
        return content.map((e) {
          if (e is dom.Element) return e.text.trim();
          return '';
        }).toList();
      }
      dom.Element? element = _toElement(content);
      if (element == null) return isList ? [] : '';
      return element.text.trim();
    }

    // 处理 HTML 提取
    if (cssSelector == 'html' || cssSelector == 'html()') {
      if (content is List) {
        return content.map((e) {
          if (e is dom.Element) return e.innerHtml;
          return '';
        }).toList();
      }
      dom.Element? element = _toElement(content);
      if (element == null) return isList ? [] : '';
      return element.innerHtml;
    }

    if (cssSelector == 'outerHtml') {
      if (content is List) {
        return content.map((e) {
          if (e is dom.Element) return e.outerHtml;
          return '';
        }).toList();
      }
      dom.Element? element = _toElement(content);
      if (element == null) return isList ? [] : '';
      return element.outerHtml;
    }

    // 处理选择器
    if (content is List) {
      final results = <dynamic>[];
      for (final item in content) {
        final element = _toElement(item);
        if (element != null) {
          if (isList) {
            results.addAll(element.querySelectorAll(cssSelector));
          } else {
            final found = element.querySelector(cssSelector);
            if (found != null) results.add(found);
          }
        }
      }
      return results;
    }

    dom.Element? element = _toElement(content);
    if (element == null) return isList ? [] : null;

    if (isList) {
      return element.querySelectorAll(cssSelector).toList();
    }

    return element.querySelector(cssSelector);
  }

  dom.Element? _toElement(dynamic content) {
    if (content is dom.Element) return content;
    if (content is dom.Document) return content.body;
    if (content is String) {
      final doc = html_parser.parse(content);
      return doc.body;
    }
    return null;
  }

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
      return rule;
    }
    return rule;
  }

  dynamic _applyXPath(dynamic content, String xpath, {bool isList = false}) {
    if (content is! String) {
      if (content is dom.Document) {
        content = content.outerHtml;
      } else if (content is dom.Element) {
        content = content.outerHtml;
      } else {
        return null;
      }
    }

    try {
      final results = <String>[];
      final htmlStr = content as String;
      
      if (xpath.contains('@')) {
        final attrMatch = RegExp(r'@(\w+)').firstMatch(xpath);
        if (attrMatch != null) {
          final attrName = attrMatch.group(1)!;
          final pattern = RegExp('$attrName=["\']([^"\']*)["\']', caseSensitive: false);
          final matches = pattern.allMatches(htmlStr);
          for (final m in matches) {
            results.add(m.group(1) ?? '');
          }
        }
      } else if (xpath.contains('text()')) {
        final tagMatch = RegExp(r'/(\w+)\[').firstMatch(xpath);
        if (tagMatch != null) {
          final tagName = tagMatch.group(1)!;
          final pattern = RegExp('<$tagName[^>]*>([^<]*)</$tagName>', caseSensitive: false);
          final matches = pattern.allMatches(htmlStr);
          for (final m in matches) {
            results.add(m.group(1)?.trim() ?? '');
          }
        } else {
          final textPattern = RegExp(r'>([^<]+)<');
          final matches = textPattern.allMatches(htmlStr);
          for (final m in matches) {
            final text = m.group(1)?.trim();
            if (text != null && text.isNotEmpty) {
              results.add(text);
            }
          }
        }
      } else {
        final tagMatch = RegExp(r'/(\w+)').firstMatch(xpath);
        if (tagMatch != null) {
          final tagName = tagMatch.group(1)!;
          final pattern = RegExp('<$tagName[^>]*>(.*?)</$tagName>', caseSensitive: false, dotAll: true);
          final matches = pattern.allMatches(htmlStr);
          for (final m in matches) {
            results.add(m.group(1)?.trim() ?? '');
          }
        }
      }

      if (isList) {
        return results;
      }
      return results.isNotEmpty ? results.first : null;
    } catch (e) {
      return null;
    }
  }

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

    final path = jsonPath.replaceAll('\$.', '').split('.');
    dynamic current = content;

    for (final key in path) {
      if (key.isEmpty) continue;

      if (current is Map) {
        current = current[key];
      } else if (current is List && key == '*') {
        return current;
      } else if (current is List) {
        final index = int.tryParse(key);
        if (index != null && index < current.length) {
          current = current[index];
        } else {
          current = current.map((item) {
            if (item is Map) return item[key];
            return null;
          }).toList();
        }
      } else {
        return null;
      }
    }

    return current;
  }

  dynamic _applyJs(dynamic content, String jsCode) async {
    try {
      final result = await JsEngine.instance.processJsRule(
        content?.toString() ?? '',
        jsCode,
        baseUrl: _baseUrl,
      );
      return result;
    } catch (e) {
      return null;
    }
  }

  dynamic _applyRegex(dynamic content, String pattern, {bool isList = false}) {
    final str = content.toString();
    final regex = RegExp(pattern, multiLine: true, dotAll: true);

    if (isList) {
      return regex.allMatches(str).map((m) {
        if (m.groupCount > 0) {
          return m.group(1) ?? m.group(0) ?? '';
        }
        return m.group(0) ?? '';
      }).toList();
    }

    final match = regex.firstMatch(str);
    if (match != null) {
      if (match.groupCount > 0) {
        return match.group(1) ?? match.group(0) ?? '';
      }
      return match.group(0) ?? '';
    }
    return null;
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
