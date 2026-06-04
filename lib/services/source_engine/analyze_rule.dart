import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:html/src/query_selector.dart' as html_query;
import 'package:xml/xml.dart' as xml;

import '../app_logger.dart';
import 'js_engine.dart';
import 'legado_json_path.dart';
import 'legado_xpath.dart';

/// 规则模式枚举
enum RuleMode { xpath, json, default_, js, regex, webJs }

/// 规则解析器
/// 参考 legados AnalyzeRule.kt 实现
class AnalyzeRule {
  dynamic _content;
  String? _baseUrl;
  String? _redirectUrl;
  bool _isJson = false;
  bool _isRegex = false;
  final Map<String, dynamic> _variables = {};
  final Map<String, String> _variableMap = {}; // 持久化变量存储
  JsEngineType? _sourceEngine; // 书源级引擎声明

  // 规则缓存
  static final Map<String, List<_SourceRule>> _stringRuleCache = {};
  static final Map<String, RegExp?> _regexCache = {};
  static const int _maxCacheSize = 16;

  AnalyzeRule setContent(dynamic content, {String? baseUrl}) {
    _content = content;
    _baseUrl = baseUrl ?? _baseUrl;
    _isJson = _detectJson(content);
    return this;
  }

  AnalyzeRule setBaseUrl(String? baseUrl) {
    _baseUrl = baseUrl;
    return this;
  }

  AnalyzeRule setRedirectUrl(String? url) {
    _redirectUrl = url;
    return this;
  }

  /// 设置书源级引擎声明
  AnalyzeRule setSourceEngine(JsEngineType? engine) {
    _sourceEngine = engine;
    return this;
  }

  /// 检测内容是否为JSON
  bool _detectJson(dynamic content) {
    if (content is Map || content is List) return true;
    if (content is String) {
      final text = content.trim();
      return (text.startsWith('{') && text.endsWith('}')) ||
          (text.startsWith('[') && text.endsWith(']'));
    }
    if (content is dom.Node) return false;
    return false;
  }

  /// 保存变量
  AnalyzeRule putVariable(String key, dynamic value) {
    _variables[key] = value;
    _variableMap[key] = value.toString();
    return this;
  }

  /// 获取变量
  dynamic getVariable(String key) {
    return _variables[key] ?? _variableMap[key];
  }

  /// 获取字符串结果
  /// [ruleStr] 规则字符串
  /// [content] 可选的内容，如果提供则对此内容执行规则
  /// [isUrl] 是否为URL
  /// [unescape] 是否反转义HTML
  String? getString(String? ruleStr,
      {dynamic content, bool isUrl = false, bool unescape = true}) {
    if (ruleStr == null || ruleStr.trim().isEmpty) return null;

    final ruleList = _splitSourceRuleCacheString(ruleStr);
    debugPrint('📝 getString: 规则="$ruleStr", 拆分为${ruleList.length}段');
    return _getString(ruleList,
        mContent: content, isUrl: isUrl, unescape: unescape);
  }

  /// 获取字符串列表
  List<String> getStringList(String? ruleStr, {bool isUrl = false}) {
    if (ruleStr == null || ruleStr.trim().isEmpty) return [];

    final ruleList = _splitSourceRuleCacheString(ruleStr);
    return _getStringList(ruleList, isUrl: isUrl);
  }

  /// 获取元素列表
  List<dynamic> getElements(String? ruleStr) {
    if (ruleStr == null || ruleStr.trim().isEmpty) return [];

    final ruleList = _splitSourceRule(ruleStr, allInOne: true);
    return _getElements(ruleList);
  }

  /// 获取单个元素
  dynamic getElement(String? ruleStr) {
    if (ruleStr == null || ruleStr.trim().isEmpty) return null;

    final ruleList = _splitSourceRule(ruleStr, allInOne: true);
    return _getElement(ruleList);
  }

  /// 获取Map列表
  List<Map<String, dynamic>> getMapList(String ruleStr) {
    return getElements(ruleStr)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  // ================== 规则缓存 ==================

  List<_SourceRule> _splitSourceRuleCacheString(String ruleStr) {
    if (ruleStr.isEmpty) return [];

    // 检查缓存
    if (_stringRuleCache.containsKey(ruleStr)) {
      return _stringRuleCache[ruleStr]!;
    }

    // 限制缓存大小
    if (_stringRuleCache.length >= _maxCacheSize) {
      _stringRuleCache.remove(_stringRuleCache.keys.first);
    }

    final rules = _splitSourceRule(ruleStr);
    _stringRuleCache[ruleStr] = rules;
    return rules;
  }

  /// 分解规则生成规则列表
  List<_SourceRule> _splitSourceRule(String? ruleStr, {bool allInOne = false}) {
    if (ruleStr == null || ruleStr.isEmpty) return [];

    final ruleList = <_SourceRule>[];
    var mode = RuleMode.default_;
    var start = 0;

    // 检查是否为正则模式（以:开头）
    if (allInOne && ruleStr.startsWith(':')) {
      mode = RuleMode.regex;
      _isRegex = true;
      start = 1;
    } else if (_isRegex) {
      mode = RuleMode.regex;
    }

    // 解析 @js: / @rhino: / @quickjs: / @java: / @ts: 和 <js></js> 规则
    final jsPattern = RegExp(
        r'@(?:webjs|js|rhino|quickjs|java|ts):([\s\S]*?)(?=@(?:webjs|js|rhino|quickjs|java|ts):|$)',
        caseSensitive: false);
    final jsTagPattern = RegExp(r'<js>([\s\S]*?)</js>', caseSensitive: false);

    // 先处理 <js></js> 标签 → 替换为 @js:
    String processedRule = ruleStr;
    final jsTagMatches = jsTagPattern.allMatches(processedRule).toList();

    if (jsTagMatches.isNotEmpty) {
      for (final match in jsTagMatches.reversed) {
        processedRule = processedRule.replaceRange(
            match.start, match.end, '@js:${match.group(1)}');
      }
    }

    // 处理带前缀的 JS 规则
    final jsMatches = jsPattern.allMatches(processedRule).toList();

    if (jsMatches.isNotEmpty) {
      var lastEnd = start;
      for (final match in jsMatches) {
        // 添加匹配之前的部分
        if (match.start > lastEnd) {
          final before = processedRule.substring(lastEnd, match.start).trim();
          if (before.isNotEmpty) {
            ruleList
                .add(_SourceRule.parse(before, isJson: _isJson, mode: mode));
          }
        }
        // 添加 JS 规则（保留完整前缀，让 JsEngine._resolveEngine 处理分流）
        final matchedText = match.group(0)?.trim() ?? '';
        if (matchedText.isNotEmpty) {
          ruleList.add(_SourceRule(
            matchedText,
            matchedText.toLowerCase().startsWith('@webjs:')
                ? RuleMode.webJs
                : RuleMode.js,
          ));
        }
        lastEnd = match.end;
      }
      // 添加最后剩余的部分
      if (lastEnd < processedRule.length) {
        final remaining = processedRule.substring(lastEnd).trim();
        if (remaining.isNotEmpty) {
          ruleList
              .add(_SourceRule.parse(remaining, isJson: _isJson, mode: mode));
        }
      }
    } else {
      // 没有 JS 规则，直接解析
      final rest = processedRule.substring(start).trim();
      if (rest.isNotEmpty) {
        ruleList.add(_SourceRule.parse(rest, isJson: _isJson, mode: mode));
      }
    }

    return ruleList;
  }

  // ================== 字符串获取 ==================

  String? _getString(List<_SourceRule> ruleList,
      {dynamic mContent, bool isUrl = false, bool unescape = true}) {
    dynamic result = mContent ?? _content;

    for (final rule in ruleList) {
      if (result == null) continue;

      // 执行 @put 规则
      _executePutRule(rule.putMap);

      // 应用变量替换
      final appliedRule = _applyVariables(rule, result);

      // 执行规则
      result = _applyRule(result, appliedRule, listMode: false);

      // 应用正则替换
      if (result != null && rule.replaceRegex.isNotEmpty) {
        result = _applyReplaceRegex(result.toString(), rule);
      }
    }

    if (result == null) return null;

    String resultStr = _toString(result) ?? '';

    // HTML反转义
    if (unescape && resultStr.contains('&')) {
      resultStr = _unescapeHtml(resultStr);
    }

    // URL处理
    if (isUrl) {
      if (resultStr.isEmpty) {
        return null; // 空字符串不返回baseUrl
      }
      return _getAbsoluteUrl(resultStr);
    }

    return resultStr.isEmpty ? null : resultStr;
  }

  List<String> _getStringList(List<_SourceRule> ruleList,
      {bool isUrl = false}) {
    dynamic result = _content;

    for (final rule in ruleList) {
      if (result == null) continue;

      _executePutRule(rule.putMap);
      final appliedRule = _applyVariables(rule, result);
      result = appliedRule.mode == RuleMode.default_
          ? _jsoupGetStringList(result, appliedRule.rule)
          : _applyRule(result, appliedRule, listMode: true);

      if (result != null && rule.replaceRegex.isNotEmpty) {
        if (result is List) {
          result = result
              .map((e) => _applyReplaceRegex(e.toString(), rule))
              .toList();
        } else {
          result = _applyReplaceRegex(result.toString(), rule);
        }
      }
    }

    if (result == null) return [];

    List<String> resultList;
    if (result is List) {
      resultList = result
          .map((e) => _toString(e) ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    } else {
      final str = _toString(result);
      resultList = str != null && str.isNotEmpty ? [str] : [];
    }

    if (isUrl) {
      return resultList
          .map((url) => _getAbsoluteUrl(url))
          .where((e) => e.isNotEmpty)
          .toList();
    }

    return resultList;
  }

  // ================== 元素获取 ==================

  List<dynamic> _getElements(List<_SourceRule> ruleList) {
    dynamic result = _content;

    for (final rule in ruleList) {
      if (result == null) continue;

      _executePutRule(rule.putMap);
      final appliedRule = _applyVariables(rule, result);
      result = _applyRule(result, appliedRule, listMode: true);

      if (result != null && rule.replaceRegex.isNotEmpty) {
        if (result is List) {
          result = result
              .map((e) => _applyReplaceRegex(e.toString(), rule))
              .toList();
        } else {
          result = _applyReplaceRegex(result.toString(), rule);
        }
      }
    }

    if (result == null) return [];
    if (result is List) return result;
    return [result];
  }

  dynamic _getElement(List<_SourceRule> ruleList) {
    final elements = _getElements(ruleList);
    return elements.isNotEmpty ? elements.first : null;
  }

  // ================== 规则应用 ==================

  dynamic _applyRule(dynamic content, _SourceRule rule,
      {required bool listMode}) {
    final ruleStr = rule.rule;
    if (ruleStr.isEmpty) return content;
    if (rule.literal) return ruleStr;

    switch (rule.mode) {
      case RuleMode.json:
        return _applyJsonPath(content, ruleStr, listMode: listMode);
      case RuleMode.xpath:
        return _applyXPath(content, ruleStr, listMode: listMode);
      case RuleMode.js:
        return _applyJs(content, ruleStr);
      case RuleMode.regex:
        return _applyRegex(content, ruleStr, listMode: listMode);
      case RuleMode.webJs:
        return _applyJs(content, ruleStr.substring(7));
      case RuleMode.default_:
        return listMode
            ? _jsoupGetElements(content, ruleStr)
            : _jsoupGetString(content, ruleStr);
    }
  }

  // ================== JSoup 解析 ==================

  List<dynamic> _jsoupGetElements(dynamic content, String rule) {
    final element = _toElement(content);
    if (element == null || rule.isEmpty) return [];

    final analyzer = _RuleAnalyzer(rule);
    final groups = analyzer.splitRule('&&', '||', '%%');
    final collected = <List<dynamic>>[];

    for (final group in groups) {
      final elements = _selectElementsChain(element, group);
      collected.add(elements);
      if (elements.isNotEmpty && analyzer.elementsType == '||') break;
    }

    // %% 交错合并
    if (analyzer.elementsType == '%%' && collected.isNotEmpty) {
      final result = <dynamic>[];
      final maxLen =
          collected.map((e) => e.length).reduce((a, b) => a > b ? a : b);
      for (var i = 0; i < maxLen; i++) {
        for (final list in collected) {
          if (i < list.length) result.add(list[i]);
        }
      }
      return result;
    }

    return collected.expand((e) => e).toList();
  }

  String? _jsoupGetString(dynamic content, String rule) {
    final text = _jsoupGetStringList(content, rule);
    if (text.isEmpty) return null;
    return text.length == 1 ? text.first : text.join('\n');
  }

  List<String> _jsoupGetStringList(dynamic content, String rule) {
    final element = _toElement(content);
    if (element == null || rule.isEmpty) {
      debugPrint('📝 _jsoupGetString: element=${element != null}, rule为空');
      return [];
    }

    debugPrint('📝 _jsoupGetString: rule="$rule"');
    final sourceRule = _JsoupSourceRule(rule);
    final analyzer = _RuleAnalyzer(sourceRule.elementsRule);
    final groups = analyzer.splitRule('&&', '||', '%%');
    debugPrint('📝 分组数: ${groups.length}, 类型: ${analyzer.elementsType}');

    final results = <List<String>>[];

    for (final group in groups) {
      debugPrint('📝 处理分组: "$group"');
      final values = sourceRule.isCss
          ? _cssLast(element, group)
          : _chainLast(element, group);
      debugPrint('📝 分组结果: ${values.length}个');
      if (values.isNotEmpty) {
        results.add(values);
        if (analyzer.elementsType == '||') break;
      }
    }

    final text = <String>[];
    if (analyzer.elementsType == '%%' && results.isNotEmpty) {
      final maxLen =
          results.map((e) => e.length).reduce((a, b) => a > b ? a : b);
      for (var i = 0; i < maxLen; i++) {
        for (final item in results) {
          if (i < item.length) text.add(item[i]);
        }
      }
    } else {
      for (final item in results) {
        text.addAll(item);
      }
    }

    debugPrint('📝 最终结果: ${text.length}个文本段');
    return text;
  }

  /// 链式选择元素
  List<dynamic> _selectElementsChain(dom.Element root, String rule) {
    final parts = _RuleAnalyzer(rule)..trim();
    var current = <dynamic>[root];

    for (final part in parts.splitRule('@')) {
      final next = <dynamic>[];
      for (final element in current) {
        if (element is dom.Element) {
          next.addAll(_selectElementsSingle(element, part));
        }
      }
      current = next;
      if (current.isEmpty) break;
    }

    return current;
  }

  /// 选择单个规则对应的元素
  List<dynamic> _selectElementsSingle(dom.Element root, String rawRule) {
    final parsed = _ElementSelector.parse(rawRule);
    List<dom.Element> elements;
    var beforeRule = parsed.beforeRule;

    // 处理 legados 特殊语法: #xxx 等同于 id.xxx
    if (beforeRule.startsWith('#') &&
        !beforeRule.contains('[') &&
        !beforeRule.contains('.')) {
      // #ettt 格式，转换为 id.ettt 处理
      final idValue = beforeRule.substring(1);
      beforeRule = 'id.$idValue';
    }

    if (beforeRule.isEmpty || beforeRule == 'children') {
      elements = root.children.toList();
    } else {
      final rules = beforeRule.split('.');
      switch (rules.first) {
        case 'class':
          elements = rules.length > 1
              ? _withSelf(
                  root,
                  root.getElementsByClassName(rules[1]).toList(),
                  root.classes.contains(rules[1]),
                )
              : [];
          break;
        case 'tag':
          elements = rules.length > 1
              ? _withSelf(
                  root,
                  root.getElementsByTagName(rules[1]).toList(),
                  root.localName?.toLowerCase() == rules[1].toLowerCase(),
                )
              : [];
          break;
        case 'id':
          elements = rules.length > 1
              ? _withSelf(
                  root,
                  root.querySelectorAll('#${_cssEscape(rules[1])}').toList(),
                  root.id == rules[1],
                )
              : [];
          break;
        case 'text':
          elements = rules.length > 1
              ? _withSelf(
                  root,
                  root.querySelectorAll('*').where((e) {
                    return _ownText(e).contains(rules.sublist(1).join('.'));
                  }).toList(),
                  _ownText(root).contains(rules.sublist(1).join('.')),
                )
              : [];
          break;
        default:
          try {
            elements = _withSelf(
              root,
              root.querySelectorAll(beforeRule).toList(),
              html_query.matches(root, beforeRule),
            );
          } catch (e) {
            debugPrint('CSS选择器失败: $beforeRule $e');
            elements = [];
          }
      }
    }

    return parsed.apply(elements);
  }

  List<dom.Element> _withSelf(
    dom.Element root,
    List<dom.Element> descendants,
    bool includeSelf,
  ) {
    if (!includeSelf) return descendants;
    return <dom.Element>[root, ...descendants];
  }

  String _ownText(dom.Element element) {
    return element.nodes
        .whereType<dom.Text>()
        .map((node) => node.text)
        .join()
        .trim();
  }

  /// 链式获取最后结果
  List<String> _chainLast(dom.Element root, String rule) {
    final parts = _RuleAnalyzer(rule)..trim();
    final rules = parts.splitRule('@');
    if (rules.isEmpty) return [];

    // 如果只有一个规则部分
    if (rules.length == 1) {
      final singleRule = rules.first;

      // 检查是否是提取规则（text, html, 属性等）
      final lowerRule = singleRule.toLowerCase();
      if (lowerRule == 'text' ||
          lowerRule == 'text()' ||
          lowerRule == 'html' ||
          lowerRule == 'html()' ||
          lowerRule == 'owntext' ||
          lowerRule == 'textnodes' ||
          lowerRule == 'all' ||
          lowerRule == 'href' ||
          lowerRule == 'src' ||
          lowerRule == 'hrefurl' ||
          lowerRule == 'srcurl' ||
          singleRule.startsWith('@')) {
        // 直接在根元素上提取
        return _extractLast([root], singleRule);
      }

      // 否则先选择元素，再提取文本
      final elements = _selectElementsSingle(root, singleRule);
      if (elements.isEmpty) return [];

      // 如果选择结果是元素列表，提取文本
      final elementList = elements.whereType<dom.Element>().toList();
      if (elementList.isNotEmpty) {
        return elementList
            .map((e) => e.text.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }

      return [];
    }

    // 多步规则：前面的选择元素，最后一步提取内容
    var current = <dom.Element>[root];
    for (var i = 0; i < rules.length - 1; i++) {
      final next = <dom.Element>[];
      for (final element in current) {
        next.addAll(
            _selectElementsSingle(element, rules[i]).whereType<dom.Element>());
      }
      current = next;
      if (current.isEmpty) return [];
    }

    return _extractLast(current, rules.last);
  }

  /// CSS选择器获取最后结果
  List<String> _cssLast(dom.Element root, String rule) {
    final lastAt = rule.lastIndexOf('@');

    // 如果没有 @，直接选择元素并返回文本
    if (lastAt < 0) {
      try {
        final elements = root.querySelectorAll(rule).toList();
        return elements
            .map((e) => e.text.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      } catch (e) {
        debugPrint('CSS selector failed: $rule $e');
        return [];
      }
    }

    final selector = rule.substring(0, lastAt);
    final lastRule = rule.substring(lastAt + 1);

    try {
      final elements = root.querySelectorAll(selector).toList();
      return _extractLast(elements, lastRule);
    } catch (e) {
      debugPrint('CSS selector failed: $selector $e');
      return [];
    }
  }

  /// 提取最后结果
  List<String> _extractLast(List<dom.Element> elements, String lastRule) {
    final result = <String>[];

    switch (lastRule.toLowerCase()) {
      case 'text':
      case 'text()':
        for (final element in elements) {
          final text = element.text.trim();
          if (text.isNotEmpty) result.add(text);
        }
        break;

      case 'owntext':
        for (final element in elements) {
          // ownText 只获取直接子文本
          final ownText = element.nodes
              .whereType<dom.Text>()
              .map((e) => e.text.trim())
              .where((e) => e.isNotEmpty)
              .join(' ');
          if (ownText.isNotEmpty) result.add(ownText);
        }
        break;

      case 'textnodes':
        for (final element in elements) {
          final texts = element.nodes
              .whereType<dom.Text>()
              .map((e) => e.text.trim())
              .where((e) => e.isNotEmpty)
              .join('\n');
          if (texts.isNotEmpty) result.add(texts);
        }
        break;

      case 'html':
      case 'html()':
        for (final element in elements) {
          // 先复制元素，避免修改原始DOM
          final clone = element.clone(true);
          clone.querySelectorAll('script,style').forEach((e) => e.remove());
          final html = clone.outerHtml;
          if (html.isNotEmpty) result.add(html);
        }
        break;

      case 'all':
        final html = elements.map((e) => e.outerHtml).join();
        if (html.isNotEmpty) result.add(html);
        break;

      default:
        for (final element in elements) {
          final value = _getAttribute(element, lastRule);
          if (value.isNotEmpty && !result.contains(value)) result.add(value);
        }
    }

    return result;
  }

  /// 获取属性值
  String _getAttribute(dom.Element element, String attr) {
    final key = attr.startsWith('@') ? attr.substring(1) : attr;

    switch (key.toLowerCase()) {
      case 'href':
      case 'src':
        return _getAbsoluteUrl(element.attributes[key.toLowerCase()] ?? '');
      case 'hrefurl':
        return _getAbsoluteUrl(element.attributes['href'] ?? '');
      case 'srcurl':
        return _getAbsoluteUrl(element.attributes['src'] ?? '');
      case 'text':
      case 'text()':
        return element.text.trim();
      case 'html':
      case 'html()':
        return element.innerHtml;
      default:
        return element.attributes[key] ??
            element.attributes[key.toLowerCase()] ??
            '';
    }
  }

  // ================== JSONPath 解析 ==================

  dynamic _applyJsonPath(dynamic content, String jsonPath,
      {required bool listMode}) {
    final analyzer = _RuleAnalyzer(jsonPath);
    final rules = analyzer.splitRule('&&', '||', '%%');
    final results = <List<dynamic>>[];
    for (final rule in rules) {
      try {
        var processed = rule;
        processed = processed.replaceAllMapped(
          RegExp(r'\{(\$\.[^{}]+)\}'),
          (match) => '${LegadoJsonPath.read(content, match.group(1)!)}',
        );
        final values = LegadoJsonPath.readList(content, processed);
        if (values.isNotEmpty) {
          results.add(values);
          if (analyzer.elementsType == '||') break;
        }
      } catch (_) {}
    }
    final merged = _mergeRuleResults(results, analyzer.elementsType);
    if (listMode) return merged;
    if (merged.isEmpty) return null;
    return merged.length == 1 ? merged.first : merged.join('\n');
  }

  // ================== XPath 解析 ==================

  dynamic _applyXPath(dynamic content, String xpath, {required bool listMode}) {
    final analyzer = _RuleAnalyzer(xpath);
    final rules = analyzer.splitRule('&&', '||', '%%');
    final results = <List<dynamic>>[];
    for (final rule in rules) {
      final value = LegadoXPath.read(content, rule, listMode: true);
      final values = value is List ? value : <dynamic>[];
      if (values.isNotEmpty) {
        results.add(values);
        if (analyzer.elementsType == '||') break;
      }
    }
    final merged = _mergeRuleResults(results, analyzer.elementsType);
    if (listMode) return merged;
    if (merged.isEmpty) return null;
    return merged.map((item) => LegadoXPath.stringValue(item)).join('\n');
  }

  // ================== JS 执行 ==================

  dynamic _applyJs(dynamic content, String jsCode) {
    try {
      return JsEngine.instance.executeSync(jsCode, content,
          baseUrl: _baseUrl, sourceEngine: _sourceEngine);
    } catch (e) {
      AppLogger.instance.logJsError('AnalyzeRule', e.toString());
      return null;
    }
  }

  // ================== 正则解析 ==================

  dynamic _applyRegex(dynamic content, String pattern,
      {required bool listMode}) {
    final chained = _RuleAnalyzer(pattern).splitRule('&&');
    if (chained.length > 1) {
      var current = content.toString();
      for (var index = 0; index < chained.length - 1; index++) {
        final regex = _compileRegex(chained[index]);
        if (regex == null) return listMode ? <dynamic>[] : null;
        current = regex
            .allMatches(current)
            .map((match) => match.group(0) ?? '')
            .join();
      }
      return _applyRegex(current, chained.last, listMode: listMode);
    }
    final regex = _compileRegex(pattern);
    if (regex == null) return null;

    final text = content.toString();

    if (listMode) {
      return regex.allMatches(text).map((m) {
        return [
          for (var index = 0; index <= m.groupCount; index++)
            m.group(index) ?? ''
        ];
      }).toList();
    }

    final match = regex.firstMatch(text);
    if (match == null) return null;
    return match.groupCount > 0 ? match.group(1) : match.group(0);
  }

  RegExp? _compileRegex(String pattern) {
    return _regexCache.putIfAbsent(pattern, () {
      try {
        return RegExp(pattern, multiLine: true, dotAll: true);
      } catch (e) {
        debugPrint('Invalid regex pattern: $pattern');
        return null;
      }
    });
  }

  List<dynamic> _mergeRuleResults(List<List<dynamic>> results, String type) {
    if (type != '%%') return results.expand((items) => items).toList();
    final merged = <dynamic>[];
    final maxLength = results.fold<int>(
      0,
      (max, items) => items.length > max ? items.length : max,
    );
    for (var index = 0; index < maxLength; index++) {
      for (final items in results) {
        if (index < items.length) merged.add(items[index]);
      }
    }
    return merged;
  }

  // ================== 变量处理 ==================

  /// 执行 @put 规则
  void _executePutRule(Map<String, String> putMap) {
    for (final entry in putMap.entries) {
      final value = getString(entry.value) ?? '';
      putVariable(entry.key, value);
    }
  }

  /// 应用变量替换
  _SourceRule _applyVariables(_SourceRule rule, dynamic result) {
    var next = rule.rule;
    var literal = rule.literal;
    final original = rule.rule.trim();
    final expressionOnly = RegExp(
      r'^(?:\{\{[\s\S]*\}\}|@get:\{[^}]+\}|\$\d{1,2})$',
      caseSensitive: false,
    ).hasMatch(original);

    next = next.replaceAllMapped(RegExp(r'\$(\d{1,2})'), (match) {
      final index = int.parse(match.group(1)!);
      if (result is List && index >= 0 && index < result.length) {
        literal = true;
        return '${result[index] ?? ''}';
      }
      return match.group(0)!;
    });
    literal = literal || expressionOnly;

    // 替换 @get:{key}
    next = next.replaceAllMapped(
      RegExp(r'@get:\{([^}]+)\}', caseSensitive: false),
      (match) {
        final key = match.group(1) ?? '';
        return getVariable(key)?.toString() ?? '';
      },
    );

    // 替换 {{variable}}
    next = next.replaceAllMapped(
      RegExp(r'\{\{([\s\S]*?)\}\}'),
      (match) {
        final expr = match.group(1)?.trim() ?? '';
        // 检查是否为变量名
        final value = getVariable(expr);
        if (value != null) return value.toString();
        if (expr.startsWith('@') ||
            expr.startsWith(r'$.') ||
            expr.startsWith(r'$[') ||
            expr.startsWith('//')) {
          return getString(expr)?.toString() ?? '';
        }
        // 否则尝试作为JS执行
        try {
          return JsEngine.instance
                  .executeSync(expr, _content,
                      baseUrl: _baseUrl, sourceEngine: _sourceEngine)
                  ?.toString() ??
              '';
        } catch (_) {
          return '';
        }
      },
    );

    // 替换 $1, $2 等正则捕获组引用
    // 这部分在 makeUpRule 中处理

    return _SourceRule(
      next,
      rule.mode,
      replaceRegex: rule.replaceRegex,
      replacement: rule.replacement,
      replaceFirst: rule.replaceFirst,
      putMap: rule.putMap,
      literal: literal,
    );
  }

  /// 应用正则替换
  String _applyReplaceRegex(String value, _SourceRule rule) {
    if (rule.replaceRegex.isEmpty) return value;

    try {
      final regex = _compileRegex(rule.replaceRegex);
      if (regex == null) return value;

      if (rule.replaceFirst) {
        final match = regex.firstMatch(value);
        if (match == null) return '';
        return match.group(0)!.replaceFirst(regex, rule.replacement);
      }

      return value.replaceAll(regex, rule.replacement);
    } catch (e) {
      return value;
    }
  }

  // ================== 工具方法 ==================

  dom.Element? _toElement(dynamic content) {
    if (content is dom.Element) return content;
    if (content is dom.Document) return content.body;
    if (content is xml.XmlNode) {
      return html_parser
          .parseFragment(content.toXmlString())
          .children
          .firstOrNull;
    }
    if (content is String) {
      try {
        return html_parser.parse(content).body;
      } catch (e) {
        debugPrint('Parse HTML failed: $e');
        return null;
      }
    }
    return null;
  }

  String? _toString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is dom.Element) return value.text.trim();
    if (value is xml.XmlNode) return LegadoXPath.stringValue(value);
    if (value is List) return value.isEmpty ? null : _toString(value.first);
    return value.toString();
  }

  String _getAbsoluteUrl(String value) {
    if (value.isEmpty) return '';
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }

    final base = _redirectUrl ?? _baseUrl;
    if (base == null || base.isEmpty) return value;

    try {
      return Uri.parse(base).resolve(value).toString();
    } catch (_) {
      return value;
    }
  }

  String _unescapeHtml(String value) {
    return value
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
  }

  String _cssEscape(String value) {
    return value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  }
}

// ================== SourceRule 类 ==================

class _SourceRule {
  final String rule;
  final RuleMode mode;
  final String replaceRegex;
  final String replacement;
  final bool replaceFirst;
  final Map<String, String> putMap;
  final bool literal;

  const _SourceRule(
    this.rule,
    this.mode, {
    this.replaceRegex = '',
    this.replacement = '',
    this.replaceFirst = false,
    this.putMap = const {},
    this.literal = false,
  });

  factory _SourceRule.parse(
    String input, {
    required bool isJson,
    RuleMode mode = RuleMode.default_,
  }) {
    var rule = input.trim();
    var currentMode = mode;

    // 模式识别
    if (currentMode != RuleMode.js && currentMode != RuleMode.regex) {
      if (rule.startsWith('@CSS:') || rule.startsWith('@css:')) {
        currentMode = RuleMode.default_;
        rule = rule.substring(5).trim();
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
      } else if (rule.toLowerCase().startsWith('@webjs:')) {
        currentMode = RuleMode.webJs;
        rule = rule.substring(7);
      } else if (rule.startsWith('/')) {
        currentMode = RuleMode.xpath;
      }
    }

    // 解析 @put 规则
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

    // 解析 ## 分割的正则替换
    var replaceRegex = '';
    var replacement = '';
    var replaceFirst = false;

    final sharpIndex = rule.indexOf('##');
    if (sharpIndex >= 0) {
      final mainRule = rule.substring(0, sharpIndex);
      final parts = rule.substring(sharpIndex + 2).split('##');

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
}

// ================== JsoupSourceRule 类 ==================

class _JsoupSourceRule {
  final bool isCss;
  final String elementsRule;

  _JsoupSourceRule(String rule)
      : isCss = rule.startsWith('@CSS:') || rule.startsWith('@css:'),
        elementsRule = (rule.startsWith('@CSS:') || rule.startsWith('@css:'))
            ? rule.substring(5).trim()
            : rule;
}

// ================== RuleAnalyzer 类 ==================

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
      if (ch == ']' || ch == ')' || ch == '}') {
        depth = depth > 0 ? depth - 1 : 0;
      }

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

// ================== ElementSelector 类 ==================

class _ElementSelector {
  final String beforeRule;
  final List<int> indexes;
  final bool exclude;
  final String? rangeExpression;

  const _ElementSelector(
    this.beforeRule,
    this.indexes,
    this.exclude, {
    this.rangeExpression,
  });

  factory _ElementSelector.parse(String rawRule) {
    var rule = rawRule.trim();
    var exclude = false;
    final indexes = <int>[];

    // 支持 [!0,1,2] 或 [0,1,2] 格式
    final bracketMatch = RegExp(r'^(.*)\[(!?)([-\d,:\s]+)\]$').firstMatch(rule);
    if (bracketMatch != null) {
      rule = bracketMatch.group(1)!.trim();
      exclude = bracketMatch.group(2) == '!';
      return _ElementSelector(
        rule,
        indexes,
        exclude,
        rangeExpression: bracketMatch.group(3),
      );
    }

    // 支持 .0 或 .!0 或 :0:1:2 格式
    final dotMatch = RegExp(r'^(.*)([.!])(-?\d+)(?::(-?\d+))?(?::(-?\d+))?$')
        .firstMatch(rule);
    if (dotMatch != null) {
      rule = dotMatch.group(1)!.trim();
      exclude = dotMatch.group(2) == '!';

      final start = int.tryParse(dotMatch.group(3) ?? '');
      final end = int.tryParse(dotMatch.group(4) ?? '');
      final step = int.tryParse(dotMatch.group(5) ?? '');

      if (start != null) {
        if (end != null) {
          // 范围选择
          final s = start;
          final e = end;
          final st = step ?? 1;
          if (st > 0) {
            for (var i = s; i <= e; i += st) {
              indexes.add(i);
            }
          } else {
            for (var i = s; i >= e; i += st) {
              indexes.add(i);
            }
          }
        } else {
          indexes.add(start);
        }
      }

      return _ElementSelector(rule, indexes, exclude);
    }

    return _ElementSelector(rule, indexes, exclude);
  }

  List<dynamic> apply(List<dom.Element> elements) {
    if (elements.isEmpty) return [];
    if (indexes.isEmpty && rangeExpression == null) return elements.toList();

    final selected = <int>[];
    for (final index in indexes) {
      final fixed = index < 0 ? elements.length + index : index;
      if (fixed >= 0 && fixed < elements.length) {
        if (!selected.contains(fixed)) selected.add(fixed);
      }
    }
    if (rangeExpression != null) {
      for (final item in rangeExpression!.split(',')) {
        final parts = item.trim().split(':');
        if (parts.length == 1) {
          final raw = int.tryParse(parts.first);
          if (raw == null) continue;
          final fixed = raw < 0 ? elements.length + raw : raw;
          if (fixed >= 0 &&
              fixed < elements.length &&
              !selected.contains(fixed)) {
            selected.add(fixed);
          }
          continue;
        }
        var start = parts.first.isEmpty ? 0 : int.tryParse(parts.first) ?? 0;
        var end = parts[1].isEmpty
            ? elements.length - 1
            : int.tryParse(parts[1]) ?? elements.length - 1;
        var step = parts.length > 2 ? int.tryParse(parts[2]) ?? 1 : 1;
        if (start < 0) start += elements.length;
        if (end < 0) end += elements.length;
        start = start.clamp(0, elements.length - 1);
        end = end.clamp(0, elements.length - 1);
        if (step == 0) step = 1;
        if (end < start && step > 0) {
          for (var index = start; index >= end; index -= step) {
            if (!selected.contains(index)) selected.add(index);
          }
        } else {
          for (var index = start;
              step > 0 ? index <= end : index >= end;
              index += step) {
            if (!selected.contains(index)) selected.add(index);
          }
        }
      }
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
