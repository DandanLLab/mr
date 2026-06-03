import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'js_engine.dart';

enum RuleMode { xpath, json, default_, js, regex, webJs }

class AnalyzeRule {
  dynamic _content;
  String? _baseUrl;
  bool _isJson = false;
  final Map<String, dynamic> _variables = {};

  AnalyzeRule setContent(dynamic content, {String? baseUrl}) {
    _content = content;
    _baseUrl = baseUrl ?? _baseUrl;
    _isJson = content is Map ||
        content is List ||
        (content is String && _looksJson(content));
    return this;
  }

  AnalyzeRule setBaseUrl(String? baseUrl) {
    _baseUrl = baseUrl;
    return this;
  }

  AnalyzeRule putVariable(String key, dynamic value) {
    _variables[key] = value;
    return this;
  }

  dynamic getVariable(String key) => _variables[key];

  String? getString(String ruleStr) {
    if (ruleStr.trim().isEmpty) return null;
    final result = _runRules(_content, _parseRules(ruleStr), listMode: false);
    return _toString(result);
  }

  List<String> getStringList(String ruleStr) {
    if (ruleStr.trim().isEmpty) return [];
    final result = _runRules(_content, _parseRules(ruleStr), listMode: true);
    return _toStringList(result);
  }

  List<dynamic> getElements(String ruleStr) {
    if (ruleStr.trim().isEmpty) return [];
    final result = _runRules(
      _content,
      _parseRules(ruleStr, allInOne: true),
      listMode: true,
    );
    if (result is List) return result;
    return result == null ? [] : [result];
  }

  List<Map<String, dynamic>> getMapList(String ruleStr) {
    return getElements(ruleStr)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  dynamic _runRules(
    dynamic content,
    List<_SourceRule> rules, {
    required bool listMode,
  }) {
    dynamic result = content;
    for (final rule in rules) {
      if (result == null) return null;
      final appliedRule = rule.applyVariables(_variables);
      result = _applyRule(result, appliedRule, listMode: listMode);
      result = _applyPostRegex(result, appliedRule);
    }
    return result;
  }

  dynamic _applyRule(dynamic content, _SourceRule rule,
      {required bool listMode}) {
    switch (rule.mode) {
      case RuleMode.json:
        return _applyJsonPath(content, rule.rule, listMode: listMode);
      case RuleMode.xpath:
        return _applyXPath(content, rule.rule, listMode: listMode);
      case RuleMode.js:
        return _applyJs(content, rule.rule);
      case RuleMode.regex:
        return _applyRegex(content, rule.rule, listMode: listMode);
      case RuleMode.webJs:
        debugPrint('WebJs rule is not supported yet');
        return null;
      case RuleMode.default_:
        return listMode
            ? _jsoupElements(content, rule.rule)
            : _jsoupString(content, rule.rule);
    }
  }

  List<_SourceRule> _parseRules(String? ruleStr, {bool allInOne = false}) {
    if (ruleStr == null || ruleStr.trim().isEmpty) return [];
    final list = <_SourceRule>[];
    var start = 0;
    final jsPattern = RegExp(r'@js:([\s\S]*)', caseSensitive: false);
    final match = jsPattern.firstMatch(ruleStr);
    if (match != null) {
      final before = ruleStr.substring(0, match.start).trim();
      if (before.isNotEmpty)
        list.add(_SourceRule.parse(before, isJson: _isJson));
      list.add(_SourceRule(match.group(1) ?? '', RuleMode.js));
      return list;
    }
    var mode = RuleMode.default_;
    if (allInOne && ruleStr.startsWith(':')) {
      mode = RuleMode.regex;
      start = 1;
    }
    final rest = ruleStr.substring(start).trim();
    if (rest.isNotEmpty)
      list.add(_SourceRule.parse(rest, isJson: _isJson, mode: mode));
    return list;
  }

  List<dynamic> _jsoupElements(dynamic content, String rule) {
    final element = _toElement(content);
    if (element == null || rule.trim().isEmpty) return [];

    final analyzer = _RuleAnalyzer(rule);
    final groups = analyzer.splitRule('&&', '||', '%%');
    final collected = <List<dom.Element>>[];
    for (final group in groups) {
      final elements = _selectChain(element, group);
      collected.add(elements);
      if (elements.isNotEmpty && analyzer.elementsType == '||') break;
    }
    if (analyzer.elementsType == '%%' && collected.isNotEmpty) {
      final result = <dom.Element>[];
      for (var i = 0; i < collected.first.length; i++) {
        for (final list in collected) {
          if (i < list.length) result.add(list[i]);
        }
      }
      return result;
    }
    return collected.expand((e) => e).toList();
  }

  String? _jsoupString(dynamic content, String rule) {
    final element = _toElement(content);
    if (element == null || rule.trim().isEmpty) return null;

    final sourceRule = _JsoupSourceRule(rule);
    final analyzer = _RuleAnalyzer(sourceRule.elementsRule);
    final groups = analyzer.splitRule('&&', '||', '%%');
    final results = <List<String>>[];

    for (final group in groups) {
      final values = sourceRule.isCss
          ? _cssLast(element, group)
          : _chainLast(element, group);
      if (values.isNotEmpty) {
        results.add(values);
        if (analyzer.elementsType == '||') break;
      }
    }

    final text = <String>[];
    if (analyzer.elementsType == '%%' && results.isNotEmpty) {
      for (var i = 0; i < results.first.length; i++) {
        for (final item in results) {
          if (i < item.length) text.add(item[i]);
        }
      }
    } else {
      for (final item in results) {
        text.addAll(item);
      }
    }
    if (text.isEmpty) return null;
    return text.length == 1 ? text.first : text.join('\n');
  }

  List<dom.Element> _selectChain(dom.Element root, String rule) {
    final parts = _RuleAnalyzer(rule)..trim();
    var current = <dom.Element>[root];
    for (final part in parts.splitRule('@')) {
      final next = <dom.Element>[];
      for (final element in current) {
        next.addAll(_selectSingle(element, part));
      }
      current = next;
      if (current.isEmpty) break;
    }
    return current;
  }

  List<String> _chainLast(dom.Element root, String rule) {
    final parts = _RuleAnalyzer(rule)..trim();
    final rules = parts.splitRule('@');
    if (rules.isEmpty) return [];
    var current = <dom.Element>[root];
    for (var i = 0; i < rules.length - 1; i++) {
      final next = <dom.Element>[];
      for (final element in current) {
        next.addAll(_selectSingle(element, rules[i]));
      }
      current = next;
      if (current.isEmpty) return [];
    }
    return _extractLast(current, rules.last);
  }

  List<String> _cssLast(dom.Element root, String rule) {
    final lastAt = rule.lastIndexOf('@');
    if (lastAt < 0) return [];
    return _extractLast(root.querySelectorAll(rule.substring(0, lastAt)),
        rule.substring(lastAt + 1));
  }

  List<dom.Element> _selectSingle(dom.Element root, String rawRule) {
    final parsed = _ElementSelector.parse(rawRule);
    List<dom.Element> elements;
    final beforeRule = parsed.beforeRule;
    if (beforeRule.isEmpty || beforeRule == 'children') {
      elements = root.children.toList();
    } else {
      final rules = beforeRule.split('.');
      switch (rules.first) {
        case 'class':
          elements =
              rules.length > 1 ? root.getElementsByClassName(rules[1]) : [];
          break;
        case 'tag':
          elements =
              rules.length > 1 ? root.getElementsByTagName(rules[1]) : [];
          break;
        case 'id':
          elements = rules.length > 1
              ? root.querySelectorAll('#${_cssEscape(rules[1])}')
              : [];
          break;
        case 'text':
          elements = rules.length > 1
              ? root
                  .querySelectorAll('*')
                  .where(
                      (e) => e.text.trim().contains(rules.sublist(1).join('.')))
                  .toList()
              : [];
          break;
        default:
          try {
            elements = root.querySelectorAll(beforeRule);
          } catch (e) {
            debugPrint('CSS selector failed: $beforeRule $e');
            elements = [];
          }
      }
    }
    return parsed.apply(elements);
  }

  List<String> _extractLast(Iterable<dom.Element> elements, String lastRule) {
    final result = <String>[];
    switch (lastRule) {
      case 'text':
        for (final element in elements) {
          final text = element.text.trim();
          if (text.isNotEmpty) result.add(text);
        }
        break;
      case 'ownText':
      case 'textNodes':
        for (final element in elements) {
          final text = element.nodes
              .whereType<dom.Text>()
              .map((e) => e.text.trim())
              .where((e) => e.isNotEmpty)
              .join('\n');
          if (text.isNotEmpty) result.add(text);
        }
        break;
      case 'html':
        for (final element in elements) {
          element.querySelectorAll('script,style').forEach((e) => e.remove());
          if (element.outerHtml.isNotEmpty) result.add(element.outerHtml);
        }
        break;
      case 'all':
        final html = elements.map((e) => e.outerHtml).join();
        if (html.isNotEmpty) result.add(html);
        break;
      default:
        for (final element in elements) {
          final value = _attribute(element, lastRule);
          if (value.isNotEmpty && !result.contains(value)) result.add(value);
        }
    }
    return result;
  }

  String _attribute(dom.Element element, String attr) {
    final key = attr.startsWith('@') ? attr.substring(1) : attr;
    switch (key.toLowerCase()) {
      case 'href':
      case 'hrefurl':
        return _absUrl(element.attributes['href'] ?? '');
      case 'src':
      case 'srcurl':
        return _absUrl(element.attributes['src'] ?? '');
      default:
        return element.attributes[key] ?? '';
    }
  }

  dynamic _applyJsonPath(dynamic content, String jsonPath,
      {required bool listMode}) {
    dynamic data = content;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {
        return null;
      }
    }
    final tokens = _jsonTokens(jsonPath);
    dynamic current = data;
    for (final token in tokens) {
      current = _jsonStep(current, token);
      if (current == null) return null;
    }
    return current;
  }

  dynamic _jsonStep(dynamic value, String token) {
    if (token == '*') {
      if (value is Map) return value.values.toList();
      if (value is List) return value;
      return null;
    }
    final index = int.tryParse(token);
    if (index != null) {
      if (value is List) {
        final fixed = index < 0 ? value.length + index : index;
        return fixed >= 0 && fixed < value.length ? value[fixed] : null;
      }
      return null;
    }
    if (value is Map) return value[token];
    if (value is List) {
      return value
          .map((item) => item is Map ? item[token] : null)
          .where((item) => item != null)
          .expand((item) => item is List ? item : [item])
          .toList();
    }
    return null;
  }

  List<String> _jsonTokens(String path) {
    var p = path.trim();
    if (p.startsWith(r'$.')) p = p.substring(2);
    if (p.startsWith(r'$')) p = p.substring(1);
    final tokens = <String>[];
    final re = RegExp(r'([^\.\[\]]+)|\[([^\]]+)\]');
    for (final match in re.allMatches(p)) {
      final value = match.group(1) ?? match.group(2);
      if (value == null || value.isEmpty) continue;
      tokens.add(
          value == '*' ? '*' : value.replaceAll("'", '').replaceAll('"', ''));
    }
    return tokens;
  }

  dynamic _applyXPath(dynamic content, String xpath, {required bool listMode}) {
    debugPrint('XPath is only partially supported: $xpath');
    return listMode ? <dynamic>[] : null;
  }

  dynamic _applyJs(dynamic content, String jsCode) {
    try {
      return JsEngine.instance.executeSync(jsCode, content, baseUrl: _baseUrl);
    } catch (e) {
      debugPrint('JS failed: $e');
      return null;
    }
  }

  dynamic _applyRegex(dynamic content, String pattern,
      {required bool listMode}) {
    final regex = RegExp(pattern, multiLine: true, dotAll: true);
    final text = content.toString();
    if (listMode) {
      return regex
          .allMatches(text)
          .map((m) => m.groupCount > 0 ? m.group(1) ?? '' : m.group(0) ?? '')
          .toList();
    }
    final match = regex.firstMatch(text);
    if (match == null) return null;
    return match.groupCount > 0 ? match.group(1) : match.group(0);
  }

  dynamic _applyPostRegex(dynamic result, _SourceRule rule) {
    if (rule.replaceRegex.isEmpty || result == null) return result;
    if (result is List) {
      return result.map((e) => _replace(_toString(e) ?? '', rule)).toList();
    }
    return _replace(_toString(result) ?? '', rule);
  }

  String _replace(String value, _SourceRule rule) {
    try {
      final regex = RegExp(rule.replaceRegex, multiLine: true, dotAll: true);
      if (rule.replaceFirst) {
        final match = regex.firstMatch(value);
        return match == null
            ? ''
            : match.group(0)!.replaceFirst(regex, rule.replacement);
      }
      return value.replaceAll(regex, rule.replacement);
    } catch (_) {
      return value;
    }
  }

  dom.Element? _toElement(dynamic content) {
    if (content is dom.Element) return content;
    if (content is dom.Document) return content.body;
    if (content is String) return html_parser.parse(content).body;
    return null;
  }

  String _absUrl(String value) {
    if (value.isEmpty) return '';
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    final baseUrl = _baseUrl;
    if (baseUrl == null || baseUrl.isEmpty) return value;
    try {
      return Uri.parse(baseUrl).resolve(value).toString();
    } catch (_) {
      return value;
    }
  }

  String? _toString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is dom.Element) return value.text.trim();
    if (value is List) return value.isEmpty ? null : _toString(value.first);
    return value.toString();
  }

  List<String> _toStringList(dynamic value) {
    if (value == null) return [];
    if (value is List) {
      return value
          .map((e) => _toString(e) ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    }
    final text = _toString(value);
    return text == null || text.isEmpty ? [] : [text];
  }
}

class _SourceRule {
  final String rule;
  final RuleMode mode;
  final String replaceRegex;
  final String replacement;
  final bool replaceFirst;
  final Map<String, String> putMap;

  const _SourceRule(
    this.rule,
    this.mode, {
    this.replaceRegex = '',
    this.replacement = '',
    this.replaceFirst = false,
    this.putMap = const {},
  });

  factory _SourceRule.parse(
    String input, {
    required bool isJson,
    RuleMode mode = RuleMode.default_,
  }) {
    var rule = input.trim();
    var currentMode = mode;
    if (currentMode != RuleMode.js && currentMode != RuleMode.regex) {
      if (rule.startsWith('@CSS:') || rule.startsWith('@css:')) {
        currentMode = RuleMode.default_;
      } else if (rule.startsWith('@@')) {
        currentMode = RuleMode.default_;
        rule = rule.substring(2);
      } else if (rule.startsWith('@XPath:') || rule.startsWith('@xpath:')) {
        currentMode = RuleMode.xpath;
        rule = rule.substring(7);
      } else if (rule.startsWith('@Json:') || rule.startsWith('@json:')) {
        currentMode = RuleMode.json;
        rule = rule.substring(6);
      } else if (isJson || rule.startsWith(r'$.') || rule.startsWith(r'$[')) {
        currentMode = RuleMode.json;
      } else if (rule.startsWith('/')) {
        currentMode = RuleMode.xpath;
      }
    }

    final putMap = <String, String>{};
    rule = rule.replaceAllMapped(
      RegExp(r'@put:\s*(\{[^}]+?\})', caseSensitive: false),
      (match) {
        try {
          final decoded = jsonDecode(match.group(1)!);
          if (decoded is Map) {
            putMap.addAll(decoded.map((k, v) => MapEntry('$k', '$v')));
          }
        } catch (_) {}
        return '';
      },
    );

    var replaceRegex = '';
    var replacement = '';
    var replaceFirst = false;
    final sharp = rule.indexOf('##');
    if (sharp >= 0) {
      final mainRule = rule.substring(0, sharp);
      final parts = rule.substring(sharp + 2).split('##');
      replaceRegex = parts.isNotEmpty ? parts[0] : '';
      replacement = parts.length > 1 ? parts[1] : '';
      replaceFirst = parts.length > 2;
      rule = mainRule;
    }
    return _SourceRule(
      rule.trim(),
      currentMode,
      replaceRegex: replaceRegex,
      replacement: replacement,
      replaceFirst: replaceFirst,
      putMap: putMap,
    );
  }

  _SourceRule applyVariables(Map<String, dynamic> variables) {
    var next = rule;
    next = next.replaceAllMapped(RegExp(r'@get:\{([^}]+)\}'), (match) {
      return variables[match.group(1)]?.toString() ?? '';
    });
    next = next.replaceAllMapped(RegExp(r'\{\{([\s\S]*?)\}\}'), (match) {
      return variables[match.group(1)]?.toString() ?? '';
    });
    return _SourceRule(
      next,
      mode,
      replaceRegex: replaceRegex,
      replacement: replacement,
      replaceFirst: replaceFirst,
      putMap: putMap,
    );
  }
}

class _JsoupSourceRule {
  final bool isCss;
  final String elementsRule;

  _JsoupSourceRule(String rule)
      : isCss = rule.startsWith('@CSS:') || rule.startsWith('@css:'),
        elementsRule = (rule.startsWith('@CSS:') || rule.startsWith('@css:'))
            ? rule.substring(5).trim()
            : rule;
}

class _RuleAnalyzer {
  String rule;
  String elementsType = '&&';

  _RuleAnalyzer(this.rule);

  void trim() {
    rule = rule.trim();
    while (rule.startsWith('@')) {
      rule = rule.substring(1).trim();
    }
  }

  List<String> splitRule(String first, [String? second, String? third]) {
    final types = [first, second, third].whereType<String>().toList();
    for (final type in types) {
      final parts = _splitOutside(rule, type);
      if (parts.length > 1) {
        elementsType = type;
        return parts
            .where((e) => e.trim().isNotEmpty)
            .map((e) => e.trim())
            .toList();
      }
    }
    return [rule.trim()].where((e) => e.isNotEmpty).toList();
  }

  List<String> _splitOutside(String value, String delimiter) {
    final result = <String>[];
    var depth = 0;
    var start = 0;
    for (var i = 0; i <= value.length - delimiter.length; i++) {
      final ch = value[i];
      if (ch == '[' || ch == '(' || ch == '{') depth++;
      if (ch == ']' || ch == ')' || ch == '}')
        depth = depth > 0 ? depth - 1 : 0;
      if (depth == 0 && value.startsWith(delimiter, i)) {
        result.add(value.substring(start, i));
        start = i + delimiter.length;
        i = start - 1;
      }
    }
    if (start == 0) return [value];
    result.add(value.substring(start));
    return result;
  }
}

class _ElementSelector {
  final String beforeRule;
  final List<int> indexes;
  final bool exclude;

  const _ElementSelector(this.beforeRule, this.indexes, this.exclude);

  factory _ElementSelector.parse(String rawRule) {
    var rule = rawRule.trim();
    var exclude = false;
    final indexes = <int>[];

    final bracket = RegExp(r'^(.*)\[(!?)([-\d,\s]+)\]$').firstMatch(rule);
    if (bracket != null) {
      rule = bracket.group(1)!.trim();
      exclude = bracket.group(2) == '!';
      indexes.addAll(bracket
          .group(3)!
          .split(',')
          .map((e) => int.tryParse(e.trim()))
          .whereType<int>());
      return _ElementSelector(rule, indexes, exclude);
    }

    final dot = RegExp(r'^(.*)([.!])(-?\d+)$').firstMatch(rule);
    if (dot != null) {
      rule = dot.group(1)!.trim();
      exclude = dot.group(2) == '!';
      indexes.add(int.parse(dot.group(3)!));
      return _ElementSelector(rule, indexes, exclude);
    }

    return _ElementSelector(rule, indexes, exclude);
  }

  List<dom.Element> apply(List<dom.Element> elements) {
    if (indexes.isEmpty) return elements;
    final selected = <int>{};
    for (final index in indexes) {
      final fixed = index < 0 ? elements.length + index : index;
      if (fixed >= 0 && fixed < elements.length) selected.add(fixed);
    }
    if (exclude) {
      return [
        for (var i = 0; i < elements.length; i++)
          if (!selected.contains(i)) elements[i],
      ];
    }
    return [for (final i in selected) elements[i]];
  }
}

bool _looksJson(String content) {
  final text = content.trim();
  return (text.startsWith('{') && text.endsWith('}')) ||
      (text.startsWith('[') && text.endsWith(']'));
}

String _cssEscape(String value) {
  return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}
