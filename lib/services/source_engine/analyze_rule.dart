import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:html/src/query_selector.dart' as html_query;
import 'package:xml/xml.dart' as xml;

import '../app_logger.dart';
import '../native/js_engine.dart';
import '../native/platform_channel.dart';
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
  // 注意：_isRegex 不再作为实例级全局状态
  // 修复 legado 对比发现的 bug：_isRegex 一旦设置就影响后续所有规则
  // 现在正则模式只作用于当前规则（通过 _SourceRule 传递）
  final Map<String, dynamic> _variables = {};
  final Map<String, String> _variableMap = {}; // 持久化变量存储
  JsEngineType? _sourceEngine; // 书源级引擎声明

  // ===== 书源上下文（借鉴 legado 的 evalJS 绑定）=====
  /// 书源元数据，在 JS 执行时注入 source 变量
  /// 由 WebBook 调用 setSourceInfo() 设置
  Map<String, dynamic>? _sourceInfo;  // 书源元数据
  Map<String, dynamic>? _bookInfo;    // 书籍信息
  Map<String, dynamic>? _chapterInfo; // 章节信息
  String? _nextChapterUrl;            // 下一章URL（JS中可用）

  // 规则缓存
  static final Map<String, List<_SourceRule>> _stringRuleCache = {};
  static final Map<String, RegExp?> _regexCache = {};
  static const int _maxCacheSize = 64; // 稍微加大缓存上限

  /// 清除所有规则缓存，确保调试时使用最新解析逻辑
  static void clearCache() {
    _stringRuleCache.clear();
    _regexCache.clear();
    debugPrint('♻️ AnalyzeRule 缓存已清空');
  }

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

  /// 设置书源上下文（借鉴 legado 的 evalJS 绑定）
  /// 在 JS 执行时注入 source/book/chapter/cookie 等变量
  AnalyzeRule setSourceInfo(Map<String, dynamic>? source) {
    _sourceInfo = source;
    return this;
  }

  AnalyzeRule setBookInfo(Map<String, dynamic>? book) {
    _bookInfo = book;
    return this;
  }

  AnalyzeRule setChapterInfo(Map<String, dynamic>? chapter) {
    _chapterInfo = chapter;
    return this;
  }

  AnalyzeRule setNextChapterUrl(String? url) {
    _nextChapterUrl = url;
    return this;
  }

  /// 检测内容是否为JSON
  /// 对齐 legado：检查首尾是否匹配 JSON 格式
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

  /// 获取变量（借鉴 legado 的多级变量查找链）
  /// 查找顺序：_variables → _variableMap → _sourceInfo → _bookInfo → _chapterInfo
  dynamic getVariable(String key) {
    // 1. 本地变量
    if (_variables.containsKey(key)) return _variables[key];
    if (_variableMap.containsKey(key)) return _variableMap[key];

    // 2. 书源变量（借鉴 legado 的 source.put/get）
    if (_sourceInfo != null) {
      final sourceVars = _sourceInfo!['variable'];
      if (sourceVars is Map && sourceVars.containsKey(key)) {
        return sourceVars[key];
      }
      // 常用书源属性快捷访问
      switch (key) {
        case 'bookSourceUrl':
          return _sourceInfo!['bookSourceUrl'];
        case 'bookSourceName':
          return _sourceInfo!['bookSourceName'];
        case 'bookSourceGroup':
          return _sourceInfo!['bookSourceGroup'];
      }
    }

    // 3. 书籍变量（借鉴 legado 的 book.put/get）
    if (_bookInfo != null) {
      switch (key) {
        case 'bookName':
        case 'name':
          return _bookInfo!['name'];
        case 'bookAuthor':
        case 'author':
          return _bookInfo!['author'];
        case 'bookUrl':
        case 'bookUrlPattern':
          return _bookInfo!['bookUrl'];
        case 'coverUrl':
          return _bookInfo!['coverUrl'];
        case 'intro':
          return _bookInfo!['intro'];
        case 'kind':
          return _bookInfo!['kind'];
        case 'lastChapter':
          return _bookInfo!['lastChapter'];
        case 'tocUrl':
          return _bookInfo!['tocUrl'];
        case 'wordCount':
          return _bookInfo!['wordCount'];
      }
    }

    // 4. 章节变量（借鉴 legado 的 chapter.put/get）
    if (_chapterInfo != null) {
      switch (key) {
        case 'title':
          return _chapterInfo!['title'];
        case 'chapterUrl':
          return _chapterInfo!['url'];
        case 'chapterIndex':
          return _chapterInfo!['index'];
        case 'isVolume':
          return _chapterInfo!['isVolume'];
      }
    }

    return null;
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

  // ===== 原生桥接异步版本（Android 优先 + Dart fallback）=====

  /// 异步获取字符串 — Android 优先走 Kotlin 原生 AnalyzeRule 引擎
  /// 支持全部 6 种 Mode：Default(CSS/JSoup) / Json / XPath / Js / Regex / WebJs
  /// [content] 可选覆盖 content
  /// [isUrl] 结果是否为 URL（自动拼接为绝对路径）
  /// [unescape] 是否反转义 HTML
  Future<String?> getStringAsync(String? ruleStr,
      {dynamic content, bool isUrl = false, bool unescape = true}) async {
    if (ruleStr == null || ruleStr.trim().isEmpty) return null;

    // 对齐 legado：@js: 规则走 QuickJS（ES6+），不走 Native Rhino
    // 混合规则（如 class.item@js:xxx）也走 Dart 端，因为 JS 部分需要 QuickJS
    final hasJs = _containsJsRule(ruleStr);

    if (!hasJs && defaultTargetPlatform == TargetPlatform.android) {
      final contentStr = _anyToString(content ?? _content);
      final result = await NativeChannel.instance.analyzeRuleGetString(
        contentStr, ruleStr,
        baseUrl: _baseUrl, redirectUrl: _redirectUrl, isUrl: isUrl, unescape: unescape,
        sourceInfo: _sourceInfo, bookInfo: _bookInfo, chapterInfo: _chapterInfo,
        nextChapterUrl: _nextChapterUrl,
      );
      if (result != null) return result;
      // fallback 到 Dart
    }

    // 含 JS 的规则走异步路径（含预缓存桥接数据）
    final ruleList = _splitSourceRuleCacheString(ruleStr);
    return _getStringAsync(ruleList, mContent: content, isUrl: isUrl, unescape: unescape);
  }

  /// 异步获取字符串列表
  Future<List<String>> getStringListAsync(String? ruleStr, {bool isUrl = false}) async {
    if (ruleStr == null || ruleStr.trim().isEmpty) return [];

    final hasJs = _containsJsRule(ruleStr);

    if (!hasJs && defaultTargetPlatform == TargetPlatform.android) {
      final contentStr = _anyToString(_content);
      final result = await NativeChannel.instance.analyzeRuleGetStringList(
        contentStr, ruleStr,
        baseUrl: _baseUrl, redirectUrl: _redirectUrl, isUrl: isUrl,
        sourceInfo: _sourceInfo, bookInfo: _bookInfo, chapterInfo: _chapterInfo,
        nextChapterUrl: _nextChapterUrl,
      );
      if (result != null) return result;
    }

    // 含 JS 的规则走异步路径
    final ruleList = _splitSourceRuleCacheString(ruleStr);
    return _getStringListAsync(ruleList, isUrl: isUrl);
  }

  /// 异步获取元素列表（返回 outerHtml 字符串列表，兼容后续二次解析）
  Future<List<dynamic>> getElementsAsync(String? ruleStr) async {
    if (ruleStr == null || ruleStr.trim().isEmpty) return [];

    final hasJs = _containsJsRule(ruleStr);

    if (!hasJs && defaultTargetPlatform == TargetPlatform.android) {
      final contentStr = _anyToString(_content);
      final result = await NativeChannel.instance.analyzeRuleGetElements(
        contentStr, ruleStr,
        baseUrl: _baseUrl, redirectUrl: _redirectUrl,
        sourceInfo: _sourceInfo, bookInfo: _bookInfo, chapterInfo: _chapterInfo,
        nextChapterUrl: _nextChapterUrl,
      );
      if (result != null) return result;
    }

    // 含 JS 的规则走异步路径
    final ruleList = _splitSourceRuleCacheString(ruleStr);
    return _getElementsAsync(ruleList);
  }

  /// 检测规则是否包含 JS 部分（@js: / <js>...</js>）
  /// 含 JS 的规则走 Dart 端 QuickJS，不含 JS 的走 Native JSoup
  static final _jsPattern = RegExp(r'@js:|<js>', caseSensitive: false);
  bool _containsJsRule(String ruleStr) => _jsPattern.hasMatch(ruleStr);

  /// 将 content 转为字符串（Element → outerHtml，其他 → toString）
  String _anyToString(dynamic any) {
    if (any == null) return '';
    if (any is dom.Element) return any.outerHtml;
    if (any is String) return any;
    return any.toString();
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

    // 缓存键包含 _isJson 状态，避免 JSON/JSoup 模式冲突
    final cacheKey = '${_isJson ? 'J' : 'H'}$ruleStr';

    // 检查缓存
    if (_stringRuleCache.containsKey(cacheKey)) {
      return _stringRuleCache[cacheKey]!;
    }

    // 限制缓存大小
    if (_stringRuleCache.length >= _maxCacheSize) {
      _stringRuleCache.remove(_stringRuleCache.keys.first);
    }

    final rules = _splitSourceRule(ruleStr);
    _stringRuleCache[cacheKey] = rules;
    return rules;
  }

  /// 分解规则生成规则列表
  List<_SourceRule> _splitSourceRule(String? ruleStr, {bool allInOne = false}) {
    if (ruleStr == null || ruleStr.isEmpty) return [];

    final ruleList = <_SourceRule>[];
    var mode = RuleMode.default_;
    var start = 0;

    // 检查是否为正则模式（以:开头）
    // 修复：正则模式只作用于当前规则，不再设置全局 _isRegex
    if (allInOne && ruleStr.startsWith(':')) {
      mode = RuleMode.regex;
      start = 1;
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

    // 追踪树：开始规则链追踪
    JsTracer.instance.clear();

    for (var i = 0; i < ruleList.length; i++) {
      final rule = ruleList[i];
      if (result == null) continue;

      // 执行 @put 规则
      _executePutRule(rule.putMap);

      // 应用变量替换
      final appliedRule = _applyVariables(rule, result);

      // 构建步骤描述
      final stepDesc = '步骤${i + 1}/${ruleList.length} mode=${appliedRule.mode}';
      final rulePreview = appliedRule.rule.length > 60
          ? '${appliedRule.rule.substring(0, 60)}...'
          : appliedRule.rule;
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] $stepDesc',
        detail: 'rule=$rulePreview, inputLen=${result?.toString().length ?? 0}');

      // 执行规则（传递 stepDesc 给追踪器）
      result = _applyRule(result, appliedRule, listMode: false, ruleStep: stepDesc);

      // 记录步骤输出
      final resultType = result?.runtimeType;
      final resultLen = result?.toString().length ?? 0;
      final resultPreview = result?.toString();
      final resultShort = resultPreview != null && resultPreview.length > 100
          ? '${resultPreview.substring(0, 100)}...' : resultPreview;
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] $stepDesc 完成',
        detail: 'resultType=$resultType, resultLen=$resultLen, preview=$resultShort');

      // 应用正则替换
      if (result != null && rule.replaceRegex.isNotEmpty) {
        result = _applyReplaceRegex(result.toString(), rule);
      }
    }

    // 输出完整 JS 执行树
    final treeStr = JsTracer.instance.getTreeString();
    if (treeStr.isNotEmpty && treeStr != '(no trace)') {
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] JS执行树',
        detail: treeStr);
    }

    if (result == null) return null;

    String resultStr = _toString(result) ?? '';

    // HTML反转义
    if (unescape && resultStr.contains('&')) {
      resultStr = _unescapeHtml(resultStr);
    }

    // URL处理（借鉴 legado：isUrl 时只取第一个结果，避免多行文本）
    if (isUrl) {
      if (resultStr.isEmpty) {
        return null; // 空字符串不返回baseUrl
      }
      // 借鉴 legado 的 getString0：URL 模式只取第一行
      if (resultStr.contains('\n')) {
        resultStr = resultStr.split('\n').first.trim();
      }
      return _getAbsoluteUrl(resultStr);
    }

    return resultStr.isEmpty ? null : resultStr;
  }

  /// 异步版 _getString：JS 步骤走异步路径（含预缓存），非 JS 步骤走同步路径
  Future<String?> _getStringAsync(List<_SourceRule> ruleList,
      {dynamic mContent, bool isUrl = false, bool unescape = true}) async {
    dynamic result = mContent ?? _content;

    // 追踪树：开始规则链追踪
    JsTracer.instance.clear();

    for (var i = 0; i < ruleList.length; i++) {
      final rule = ruleList[i];
      if (result == null) continue;

      // 执行 @put 规则
      _executePutRule(rule.putMap);

      // 应用变量替换
      final appliedRule = _applyVariables(rule, result);

      // 构建步骤描述
      final stepDesc = '步骤${i + 1}/${ruleList.length} mode=${appliedRule.mode}';
      final rulePreview = appliedRule.rule.length > 60
          ? '${appliedRule.rule.substring(0, 60)}...'
          : appliedRule.rule;
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] $stepDesc (async)',
        detail: 'rule=$rulePreview, inputLen=${result?.toString().length ?? 0}');

      // JS 步骤走异步路径，非 JS 步骤走同步路径
      if (appliedRule.mode == RuleMode.js || appliedRule.mode == RuleMode.webJs) {
        // 异步 JS 执行（含预缓存桥接数据）
        final jsCode = appliedRule.mode == RuleMode.webJs
            ? appliedRule.rule.substring(7) : appliedRule.rule;
        result = await _applyJsAsync(result, jsCode, ruleStep: stepDesc);
      } else {
        // 非 JS 步骤走同步路径
        result = _applyRule(result, appliedRule, listMode: false, ruleStep: stepDesc);
      }

      // 记录步骤输出
      final resultType = result?.runtimeType;
      final resultLen = result?.toString().length ?? 0;
      final resultPreview = result?.toString();
      final resultShort = resultPreview != null && resultPreview.length > 100
          ? '${resultPreview.substring(0, 100)}...' : resultPreview;
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] $stepDesc 完成 (async)',
        detail: 'resultType=$resultType, resultLen=$resultLen, preview=$resultShort');

      // 应用正则替换
      if (result != null && rule.replaceRegex.isNotEmpty) {
        result = _applyReplaceRegex(result.toString(), rule);
      }
    }

    // 输出完整 JS 执行树
    final treeStr = JsTracer.instance.getTreeString();
    if (treeStr.isNotEmpty && treeStr != '(no trace)') {
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] JS执行树',
        detail: treeStr);
    }

    if (result == null) return null;

    String resultStr = _toString(result) ?? '';

    // HTML反转义
    if (unescape && resultStr.contains('&')) {
      resultStr = _unescapeHtml(resultStr);
    }

    // URL处理
    if (isUrl) {
      if (resultStr.isEmpty) return null;
      if (resultStr.contains('\n')) {
        resultStr = resultStr.split('\n').first.trim();
      }
      return _getAbsoluteUrl(resultStr);
    }

    return resultStr.isEmpty ? null : resultStr;
  }

  /// 异步 JS 执行（含预缓存桥接数据）
  Future<dynamic> _applyJsAsync(dynamic content, String jsCode, {String? ruleStep}) async {
    try {
      // 收集上下文变量
      final env = <String, dynamic>{
        'baseUrl': _baseUrl ?? '',
      };
      env.addAll(_variableMap);
      env.addAll(_variables);
      if (_sourceInfo != null) {
        env['source'] = _sourceInfo;
        final sourceVars = _sourceInfo!['variable'];
        if (sourceVars is Map) {
          env['sourceVars'] = sourceVars;
        }
        final headerStr = _sourceInfo!['header'];
        if (headerStr is String && headerStr.isNotEmpty) {
          try {
            final parsed = jsonDecode(headerStr);
            if (parsed is Map) {
              env['headers'] = Map<String, String>.from(parsed);
            }
          } catch (_) {}
        }
      }
      if (_bookInfo != null) env['book'] = _bookInfo;
      if (_chapterInfo != null) env['chapter'] = _chapterInfo;
      env['cookie'] = <String, String>{};

      // 正确序列化 content：List/Map 用 jsonEncode，String 直接传
      // 对齐 _executeQuickJSSync 的序列化逻辑
      String contentStr;
      if (content is List || content is Map) {
        contentStr = jsonEncode(content);
      } else if (content is String) {
        contentStr = content;
      } else {
        contentStr = content?.toString() ?? '';
      }

      final codePreview = jsCode.length > 200 ? '${jsCode.substring(0, 200)}...' : jsCode;
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] 异步JS执行',
        detail: 'content=${contentStr.length}chars, contentType=${content?.runtimeType}, code=$codePreview');

      // 追踪树：创建节点
      JsTraceNode? traceNode;
      if (JsTracer.instance.enabled) {
        final tracer = JsTracer.instance;
        final inputPreview = contentStr.length > 200 ? '${contentStr.substring(0, 200)}...' : contentStr;
        if (tracer.isStackEmpty) {
          traceNode = tracer.beginRoot('_applyJsAsync', 'QuickJS(async)', codePreview,
            inputPreview: inputPreview, ruleStep: ruleStep);
        } else {
          traceNode = tracer.addChild('_applyJsAsync', 'QuickJS(async)', codePreview,
            inputPreview: inputPreview, ruleStep: ruleStep);
        }
        tracer.push(traceNode);
      }

      // 传递原始 content（dynamic 类型）给 processJsRule，
      // 让 _executeQuickJSRule 根据类型正确序列化
      final result = await JsEngine.instance.processJsRule(
        contentStr,
        jsCode,
        baseUrl: _baseUrl,
        sourceEngine: _sourceEngine,
        env: env,
        dynamicContent: content,  // 保留原始类型：List/Map/String
      );

      // 追踪树：记录输出
      if (traceNode != null) {
        final outputStr = result?.toString();
        final outputShort = outputStr != null && outputStr.length > 200
            ? '${outputStr.substring(0, 200)}...' : outputStr;
        JsTracer.instance.pop(
          outputPreview: outputShort,
          outputType: result?.runtimeType.toString(),
        );
      }

      // processJsRule 返回 String?，需要解析
      if (result == null) return null;
      if (result.isEmpty) return '';
      // 尝试 JSON 解析（可能是数组或对象）
      try {
        final decoded = jsonDecode(result);
        return decoded;
      } catch (_) {}
      return result;
    } catch (e) {
      AppLogger.instance.logJsError('AnalyzeRule', e.toString());
      return null;
    }
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

  /// 异步版 _getStringList：JS 步骤走异步路径（含预缓存）
  Future<List<String>> _getStringListAsync(List<_SourceRule> ruleList,
      {bool isUrl = false}) async {
    dynamic result = _content;

    // 追踪树：开始规则链追踪
    JsTracer.instance.clear();

    for (var i = 0; i < ruleList.length; i++) {
      final rule = ruleList[i];
      if (result == null) continue;

      _executePutRule(rule.putMap);
      final appliedRule = _applyVariables(rule, result);

      final stepDesc = '步骤${i + 1}/${ruleList.length} mode=${appliedRule.mode} (list)';
      final rulePreview = appliedRule.rule.length > 60
          ? '${appliedRule.rule.substring(0, 60)}...' : appliedRule.rule;
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] $stepDesc (async)',
        detail: 'rule=$rulePreview, inputLen=${result?.toString().length ?? 0}');

      // JS 步骤走异步，非 JS 走同步
      if (appliedRule.mode == RuleMode.js || appliedRule.mode == RuleMode.webJs) {
        final jsCode = appliedRule.mode == RuleMode.webJs
            ? appliedRule.rule.substring(7) : appliedRule.rule;
        result = await _applyJsAsync(result, jsCode, ruleStep: stepDesc);
      } else if (appliedRule.mode == RuleMode.default_) {
        result = _jsoupGetStringList(result, appliedRule.rule);
      } else {
        result = _applyRule(result, appliedRule, listMode: true, ruleStep: stepDesc);
      }

      final resultType = result?.runtimeType;
      final resultLen = result is List ? result.length : result?.toString().length ?? 0;
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] $stepDesc 完成 (async)',
        detail: 'resultType=$resultType, resultLen=$resultLen');

      if (result != null && rule.replaceRegex.isNotEmpty) {
        if (result is List) {
          result = result.map((e) => _applyReplaceRegex(e.toString(), rule)).toList();
        } else {
          result = _applyReplaceRegex(result.toString(), rule);
        }
      }
    }

    // 输出完整 JS 执行树
    final treeStr = JsTracer.instance.getTreeString();
    if (treeStr.isNotEmpty && treeStr != '(no trace)') {
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] JS执行树',
        detail: treeStr);
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

      // 借鉴 legado：多步规则中，如果上一步返回元素列表，
      // 需要对每个元素分别执行规则，然后合并结果
      if (result is List && appliedRule.mode == RuleMode.default_) {
        final merged = <dynamic>[];
        for (final item in result) {
          final itemResult = _applyRule(item, appliedRule, listMode: true);
          if (itemResult is List) {
            merged.addAll(itemResult);
          } else if (itemResult != null) {
            merged.add(itemResult);
          }
        }
        result = merged;
      } else {
        result = _applyRule(result, appliedRule, listMode: true);
      }

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

  /// 异步版 _getElements：JS 步骤走异步路径（含预缓存）
  Future<List<dynamic>> _getElementsAsync(List<_SourceRule> ruleList) async {
    dynamic result = _content;

    // 追踪树：开始规则链追踪
    JsTracer.instance.clear();

    for (var i = 0; i < ruleList.length; i++) {
      final rule = ruleList[i];
      if (result == null) continue;

      _executePutRule(rule.putMap);
      final appliedRule = _applyVariables(rule, result);

      final stepDesc = '步骤${i + 1}/${ruleList.length} mode=${appliedRule.mode} (elements)';
      final rulePreview = appliedRule.rule.length > 60
          ? '${appliedRule.rule.substring(0, 60)}...' : appliedRule.rule;
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] $stepDesc (async)',
        detail: 'rule=$rulePreview, inputLen=${result?.toString().length ?? 0}');

      // JS 步骤走异步
      if (appliedRule.mode == RuleMode.js || appliedRule.mode == RuleMode.webJs) {
        final jsCode = appliedRule.mode == RuleMode.webJs
            ? appliedRule.rule.substring(7) : appliedRule.rule;
        result = await _applyJsAsync(result, jsCode, ruleStep: stepDesc);
      } else if (result is List && appliedRule.mode == RuleMode.default_) {
        // 借鉴 legado：多步规则中，如果上一步返回元素列表，
        // 需要对每个元素分别执行规则，然后合并结果
        final merged = <dynamic>[];
        for (final item in result) {
          final itemResult = _applyRule(item, appliedRule, listMode: true, ruleStep: stepDesc);
          if (itemResult is List) {
            merged.addAll(itemResult);
          } else if (itemResult != null) {
            merged.add(itemResult);
          }
        }
        result = merged;
      } else {
        result = _applyRule(result, appliedRule, listMode: true, ruleStep: stepDesc);
      }

      final resultType = result?.runtimeType;
      final resultLen = result is List ? result.length : result?.toString().length ?? 0;
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] $stepDesc 完成 (async)',
        detail: 'resultType=$resultType, resultLen=$resultLen');

      if (result != null && rule.replaceRegex.isNotEmpty) {
        if (result is List) {
          result = result.map((e) => _applyReplaceRegex(e.toString(), rule)).toList();
        } else {
          result = _applyReplaceRegex(result.toString(), rule);
        }
      }
    }

    // 输出完整 JS 执行树
    final treeStr = JsTracer.instance.getTreeString();
    if (treeStr.isNotEmpty && treeStr != '(no trace)') {
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] JS执行树',
        detail: treeStr);
    }

    if (result == null) return [];
    if (result is List) return result;
    return [result];
  }

  // ================== 规则应用 ==================

  dynamic _applyRule(dynamic content, _SourceRule rule,
      {required bool listMode, String? ruleStep}) {
    final ruleStr = rule.rule;
    if (ruleStr.isEmpty) return content;
    if (rule.literal) return ruleStr;

    switch (rule.mode) {
      case RuleMode.json:
        return _applyJsonPath(content, ruleStr, listMode: listMode);
      case RuleMode.xpath:
        return _applyXPath(content, ruleStr, listMode: listMode);
      case RuleMode.js:
        return _applyJs(content, ruleStr, ruleStep: ruleStep);
      case RuleMode.regex:
        return _applyRegex(content, ruleStr, listMode: listMode);
      case RuleMode.webJs:
        return _applyJs(content, ruleStr.substring(7), ruleStep: ruleStep);
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
    List<dom.Element> elements = [];
    var beforeRule = parsed.beforeRule;

    // 处理 css: 前缀（legado 风格，trim() 可能去掉了 @ 前缀）
    if (beforeRule.toLowerCase().startsWith('css:')) {
      final selector = beforeRule.substring(4).trim();
      try {
        elements = root.querySelectorAll(selector).toList();
      } catch (e) {
        debugPrint('CSS选择器失败: $selector $e');
        elements = [];
      }
      return parsed.apply(elements);
    }

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
          if (rules.length > 1) {
            // 借鉴 legado：class.xxx.yyy 表示匹配同时包含 xxx 和 yyy 的元素
            // 用 CSS 选择器 .xxx.yyy 实现多 class 匹配
            final selector = rules.sublist(1).map((c) => '.$c').join('');
            elements = _withSelf(
              root,
              root.querySelectorAll(selector).toList(),
              rules.sublist(1).every((c) => root.classes.contains(c)),
            );
          } else {
            elements = [];
          }
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
            // 借鉴 legado：html 包的 querySelectorAll 可能不支持 :nth-child(n+X) 公式
            // 如果结果为空且选择器包含 :nth-child，手动解析并过滤
            if (elements.isEmpty && beforeRule.contains(':nth-child')) {
              elements = _selectNthChild(root, beforeRule);
            }
          } catch (e) {
            debugPrint('CSS选择器失败: $beforeRule $e');
            // fallback: 尝试手动处理 :nth-child
            if (beforeRule.contains(':nth-child')) {
              try {
                elements = _selectNthChild(root, beforeRule);
              } catch (_) {}
            }
            // fallback: 手动处理属性选择器 [attr$=xxx] [attr~=xxx] [attr^=xxx] [attr*=xxx]
            if (beforeRule.contains('[') && beforeRule.contains('=')) {
              try {
                elements = _selectByAttribute(root, beforeRule);
              } catch (_) {}
            }
          }
          // html 包可能不支持属性选择器，手动 fallback
          if (elements.isEmpty && beforeRule.contains('[') && beforeRule.contains('=')) {
            try {
              elements = _selectByAttribute(root, beforeRule);
            } catch (_) {}
          }
      }
    }

    return parsed.apply(elements);
  }

  /// 手动处理 :nth-child(n+X) 等 CSS 伪类选择器
  /// html 包的 querySelectorAll 不支持 :nth-child 的 n+ 公式语法
  /// 借鉴 legado：拆分选择器，先选基础元素，再按 nth-child 过滤
  List<dom.Element> _selectNthChild(dom.Element root, String selector) {
    // 解析 :nth-child 公式
    final nthPattern = RegExp(r':nth-child\(([^)]+)\)');
    final matches = nthPattern.allMatches(selector).toList();
    if (matches.isEmpty) return [];

    // 移除所有 :nth-child(...) 得到基础选择器
    var baseSelector = selector.replaceAll(nthPattern, '').trim();
    // 清理尾部多余空格和伪类分隔符
    baseSelector = baseSelector.replaceAll(RegExp(r'\s+$'), '');

    // 获取基础元素
    List<dom.Element> baseElements;
    try {
      baseElements = root.querySelectorAll(baseSelector).whereType<dom.Element>().toList();
    } catch (e) {
      // 基础选择器也失败，尝试用标签名
      final tagMatch = RegExp(r'^([a-zA-Z][\w-]*)').firstMatch(baseSelector);
      if (tagMatch != null) {
        baseElements = root.getElementsByTagName(tagMatch.group(1)!).toList();
      } else {
        baseElements = root.children.toList();
      }
    }

    if (baseElements.isEmpty) return [];

    // 对每个 :nth-child 公式进行过滤
    var current = baseElements;
    for (final match in matches) {
      final formula = match.group(1)!.trim();
      current = _filterByNthChild(current, formula);
    }

    return current;
  }

  /// 根据 nth-child 公式过滤元素
  /// 支持: n+1, 2n+1, odd, even, 3, -n+3 等
  List<dom.Element> _filterByNthChild(List<dom.Element> elements, String formula) {
    final lower = formula.toLowerCase().trim();

    // 特殊关键字
    if (lower == 'odd') {
      return elements.asMap().entries
          .where((e) => e.key % 2 == 0) // 1-based: 1st, 3rd, 5th...
          .map((e) => e.value)
          .toList();
    }
    if (lower == 'even') {
      return elements.asMap().entries
          .where((e) => e.key % 2 == 1) // 1-based: 2nd, 4th, 6th...
          .map((e) => e.value)
          .toList();
    }

    // 纯数字: nth-child(3) → 第3个
    final pureNum = int.tryParse(lower);
    if (pureNum != null) {
      final idx = pureNum - 1; // CSS nth-child 是 1-based
      if (idx >= 0 && idx < elements.length) return [elements[idx]];
      return [];
    }

    // 公式: An+B 或 n+B 或 -n+B 等
    final formulaPattern = RegExp(r'^(-?\d*)n\s*([+-]\s*\d+)?$');
    final m = formulaPattern.firstMatch(lower);
    if (m != null) {
      var aStr = m.group(1);
      var bStr = m.group(2);

      // 解析 A
      int a;
      if (aStr == null || aStr.isEmpty || aStr == '+') {
        a = 1;
      } else if (aStr == '-') {
        a = -1;
      } else {
        a = int.parse(aStr);
      }

      // 解析 B
      int b = 0;
      if (bStr != null) {
        b = int.parse(bStr.replaceAll(' ', ''));
      }

      // 对于 n+1 (a=1, b=1): 匹配 1, 2, 3, ... → 所有元素从第 b 个开始
      // 对于 -n+3 (a=-1, b=3): 匹配 3, 2, 1 → 前3个
      // 对于 2n+1 (a=2, b=1): 匹配 1, 3, 5, ...
      final result = <dom.Element>[];
      for (var i = 0; i < elements.length; i++) {
        final nth = i + 1; // CSS nth-child 是 1-based
        // 检查 nth = a*k + b 是否有非负整数解 k
        if (a == 0) {
          if (nth == b) result.add(elements[i]);
        } else {
          final diff = nth - b;
          if (diff % a == 0) {
            final k = diff ~/ a;
            if (k >= 0) result.add(elements[i]);
          }
        }
      }
      return result;
    }

    return elements;
  }

  /// 手动处理 CSS 属性选择器 [attr$=xxx] [attr~=xxx] [attr^=xxx] [attr*=xxx] [attr=xxx]
  /// html 包的 querySelectorAll 可能不支持这些高级属性选择器
  /// 借鉴 legado：直接用 JSoup 的 select()，咱手动实现
  List<dom.Element> _selectByAttribute(dom.Element root, String selector) {
    // 解析选择器：标签名 + 属性条件
    // 例如：[property$=author]、meta[property$=author]、[property~=category|status]
    final attrPattern = RegExp(r'\[([^\]]+)\]');
    final matches = attrPattern.allMatches(selector).toList();
    if (matches.isEmpty) return [];

    // 提取标签名（[] 之前的部分）
    var tagPart = selector.substring(0, selector.indexOf('[')).trim();
    if (tagPart.isEmpty) tagPart = '*';

    // 获取候选元素
    List<dom.Element> candidates;
    if (tagPart == '*') {
      candidates = root.querySelectorAll('*').whereType<dom.Element>().toList();
    } else {
      candidates = root.getElementsByTagName(tagPart).toList();
    }

    // 对每个属性条件进行过滤
    for (final match in matches) {
      final attrExpr = match.group(1)!;

      // 解析属性选择器操作符：$= ~= ^= *= =
      String attrName;
      String attrValue;
      bool Function(String?, String) matcher;

      if (attrExpr.contains('\$=')) {
        // [attr$=value] — 以 value 结尾
        final parts = attrExpr.split('\$=');
        attrName = parts[0].trim();
        attrValue = parts[1].trim().replaceAll('"', '').replaceAll("'", '');
        matcher = (actual, expected) => actual != null && actual.endsWith(expected);
      } else if (attrExpr.contains('~=')) {
        // [attr~=value] — 包含空格分隔的词
        final parts = attrExpr.split('~=');
        attrName = parts[0].trim();
        attrValue = parts[1].trim().replaceAll('"', '').replaceAll("'", '');
        // 借鉴 legado：~=` 中的值可能包含 | 分隔符，表示"匹配任意一个"
        // 例如 [property~=category|status] → 匹配 category 或 status
        final values = attrValue.split('|');
        matcher = (actual, expected) {
          if (actual == null) return false;
          for (final v in values) {
            if (actual.split(' ').any((word) => word == v)) return true;
          }
          return false;
        };
      } else if (attrExpr.contains('^=')) {
        // [attr^=value] — 以 value 开头
        final parts = attrExpr.split('^=');
        attrName = parts[0].trim();
        attrValue = parts[1].trim().replaceAll('"', '').replaceAll("'", '');
        matcher = (actual, expected) => actual != null && actual.startsWith(expected);
      } else if (attrExpr.contains('*=')) {
        // [attr*=value] — 包含 value
        final parts = attrExpr.split('*=');
        attrName = parts[0].trim();
        attrValue = parts[1].trim().replaceAll('"', '').replaceAll("'", '');
        matcher = (actual, expected) => actual != null && actual.contains(expected);
      } else if (attrExpr.contains('=')) {
        // [attr=value] — 精确匹配
        final parts = attrExpr.split('=');
        attrName = parts[0].trim();
        attrValue = parts[1].trim().replaceAll('"', '').replaceAll("'", '');
        matcher = (actual, expected) => actual == expected;
      } else {
        // [attr] — 属性存在
        attrName = attrExpr.trim();
        attrValue = '';
        matcher = (actual, _) => actual != null;
      }

      candidates = candidates.where((e) {
        final actual = e.attributes[attrName] ?? e.attributes[attrName.toLowerCase()];
        return matcher(actual, attrValue);
      }).toList();
    }

    return candidates;
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

      // Handle css: prefix (legado style: after @ split, css: becomes a step)
      if (singleRule.toLowerCase().startsWith('css:')) {
        final selector = singleRule.substring(4);
        try {
          final elements = root.querySelectorAll(selector)
              .whereType<dom.Element>()
              .toList();
          return elements
              .map((e) => e.text.trim())
              .where((e) => e.isNotEmpty)
              .toList();
        } catch (e) {
          debugPrint('CSS selector failed: $selector $e');
          return [];
        }
      }

      // 检查是否是提取规则（text, html, 属性等）
      // 借鉴 legado：只有 @ 后面跟着提取规则名称才是提取规则
      // @tag.h3 是选择器规则，@text 是提取规则
      final lowerRule = singleRule.toLowerCase();
      final isExtractionRule = lowerRule == 'text' ||
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
          lowerRule == 'onclick' ||
          lowerRule == 'title' ||
          lowerRule == 'alt' ||
          lowerRule == 'style' ||
          lowerRule == 'data-src' ||
          lowerRule == 'data-original' ||
          lowerRule == 'content' ||
          lowerRule == 'name' ||
          lowerRule == 'value' ||
          lowerRule == 'action' ||
          lowerRule == 'placeholder';

      if (isExtractionRule) {
        // 直接在根元素上提取
        return _extractLast([root], singleRule);
      }

      // 尝试作为属性提取（如果根元素有该属性）
      if (root.attributes[singleRule] != null ||
          root.attributes[singleRule.toLowerCase()] != null) {
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
      final stepRule = rules[i];
      // Handle css: prefix (legado style: @css:selector)
      if (stepRule.toLowerCase().startsWith('css:')) {
        final selector = stepRule.substring(4);
        final next = <dom.Element>[];
        for (final element in current) {
          try {
            next.addAll(element.querySelectorAll(selector).whereType<dom.Element>());
          } catch (e) {
            debugPrint('CSS selector failed: $selector $e');
          }
        }
        current = next;
        if (current.isEmpty) return [];
        continue;
      }
      final next = <dom.Element>[];
      for (final element in current) {
        next.addAll(
            _selectElementsSingle(element, stepRule).whereType<dom.Element>());
      }
      current = next;
      if (current.isEmpty) return [];
    }

    // Handle css: prefix on the last step as well
    final lastStepRule = rules.last;
    if (lastStepRule.toLowerCase().startsWith('css:')) {
      final selector = lastStepRule.substring(4);
      final next = <dom.Element>[];
      for (final element in current) {
        try {
          next.addAll(element.querySelectorAll(selector).whereType<dom.Element>());
        } catch (e) {
          debugPrint('CSS selector failed: $selector $e');
        }
      }
      return next
          .map((e) => e.text.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    return _extractLast(current, rules.last);
  }

  /// CSS选择器获取最后结果
  List<String> _cssLast(dom.Element root, String rule) {
    // Find the last @ that is NOT part of @css: prefix
    int lastAt = -1;
    for (int i = rule.length - 1; i >= 0; i--) {
      if (rule[i] == '@') {
        // Check if this @ is part of @css:
        if (i + 4 < rule.length &&
            rule.substring(i, i + 5).toLowerCase() == '@css:') {
          // This @ is part of @css: prefix, skip it
          continue;
        }
        lastAt = i;
        break;
      }
    }

    // 如果没有 @（或者只有 @css: 中的 @），直接选择元素并返回文本
    if (lastAt < 0) {
      // If the rule starts with @css:, strip the prefix
      var selector = rule;
      if (selector.toLowerCase().startsWith('@css:')) {
        selector = selector.substring(5).trim();
      }
      try {
        final elements = root.querySelectorAll(selector).toList();
        return elements
            .map((e) => e.text.trim())
            .where((e) => e.isNotEmpty)
            .toList();
      } catch (e) {
        debugPrint('CSS selector failed: $selector $e');
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
      case 'onclick':
        // 从 onclick 属性的 JS 代码中提取 URL
        return _extractUrlFromJs(element.attributes['onclick'] ?? '');
      default:
        final value = element.attributes[key] ??
            element.attributes[key.toLowerCase()] ??
            '';
        // 如果属性值包含 JS 跳转代码，尝试提取 URL
        if (value.contains('location.href') || value.contains('location=')) {
          final extracted = _extractUrlFromJs(value);
          if (extracted.isNotEmpty && extracted != value) return extracted;
        }
        return value;
    }
  }

  /// 从 JS 代码中提取 URL
  /// 支持格式: location.href='url', window.open('url'), ShowRead('url'), etc.
  static String _extractUrlFromJs(String jsCode) {
    if (jsCode.isEmpty) return '';
    final patterns = [
      // location.href='url' / location.href="url"
      RegExp(r"""location\.href\s*=\s*['"]([^'"]+)['"]"""),
      // location='url' / location="url"
      RegExp(r"""location\s*=\s*['"]([^'"]+)['"]"""),
      // window.location='url' / window.location="url"
      RegExp(r"""window\.location\s*=\s*['"]([^'"]+)['"]"""),
      // window.location.href='url'
      RegExp(r"""window\.location\.href\s*=\s*['"]([^'"]+)['"]"""),
      // window.open('url')
      RegExp(r"""window\.open\s*\(\s*['"]([^'"]+)['"]"""),
      // 通用函数调用: funcName('url') / funcName("url")
      RegExp(r"""['"]([^'"]*(?:\/|\.html?|\.htm|\.php|\.asp|\.jsp)[^'"]*)['"]"""),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(jsCode);
      if (match != null && match.groupCount > 0) {
        final url = match.group(1) ?? '';
        if (url.isNotEmpty && (url.startsWith('/') || url.startsWith('http'))) {
          return url;
        }
      }
    }
    return jsCode;
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

  /// JS 执行（借鉴 legado 的 evalJS 绑定上下文）
  /// 注入 java/source/book/chapter/cookie/result/baseUrl 等变量
  dynamic _applyJs(dynamic content, String jsCode, {String? ruleStep}) {
    try {
      // 收集规则上下文变量，注入到JS作用域
      final vars = <String, dynamic>{};
      vars.addAll(_variableMap);
      vars.addAll(_variables);
      // 注入书源/书籍/章节上下文（借鉴 legado 的 evalJS 绑定）
      if (_sourceInfo != null) vars['source'] = _sourceInfo;
      if (_bookInfo != null) vars['book'] = _bookInfo;
      if (_chapterInfo != null) vars['chapter'] = _chapterInfo;
      if (!vars.containsKey('cookie')) vars['cookie'] = <String, String>{};
      // Add src variable (legado: src = content, the original HTML/JSON)
      if (!vars.containsKey('src')) vars['src'] = _content;

      final contentPreview = content?.toString().length ?? 0;
      final codePreview = jsCode.length > 100 ? '${jsCode.substring(0, 100)}...' : jsCode;
      AppLogger.instance.debug(LogCategory.js, '[AnalyzeRule] 执行JS规则',
        detail: 'content=${contentPreview}chars, code=$codePreview');

      return JsEngine.instance.executeSync(
        jsCode,
        content,
        baseUrl: _baseUrl,
        sourceEngine: _sourceEngine,
        variables: vars,
        ruleStep: ruleStep,
      );
    } catch (e) {
      AppLogger.instance.logJsError('AnalyzeRule', e.toString());
      return null;
    }
  }

  /// JS 异步执行（带完整上下文绑定，借鉴 legado 的 evalJS）
  /// 在需要 java.ajax() 等异步操作时使用此方法
  Future<String?> applyJsAsync(dynamic content, String jsCode) async {
    try {
      // 收集上下文变量（包含 key/page 等自定义变量）
      final env = <String, dynamic>{
        'baseUrl': _baseUrl ?? '',
      };
      env.addAll(_variableMap);
      env.addAll(_variables);
      if (_sourceInfo != null) {
        env['source'] = _sourceInfo;
        // 注入书源变量（支持 source.getVariable()/setVariable()）
        final sourceVars = _sourceInfo!['variable'];
        if (sourceVars is Map) {
          env['sourceVars'] = sourceVars;
        }
        // 注入书源自定义请求头（支持 java.ajax() 预缓存时使用）
        final headerStr = _sourceInfo!['header'];
        if (headerStr is String && headerStr.isNotEmpty) {
          try {
            final parsed = jsonDecode(headerStr);
            if (parsed is Map) {
              env['headers'] = Map<String, String>.from(parsed);
            }
          } catch (_) {
            // header 不是 JSON 格式，忽略
          }
        }
      }
      if (_bookInfo != null) env['book'] = _bookInfo;
      if (_chapterInfo != null) env['chapter'] = _chapterInfo;
      env['cookie'] = <String, String>{};

      return await JsEngine.instance.processJsRule(
        content?.toString() ?? '',
        jsCode,
        baseUrl: _baseUrl,
        sourceEngine: _sourceEngine,
        env: env,
      );
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
          final vars = <String, dynamic>{};
          vars.addAll(_variableMap);
          vars.addAll(_variables);
          if (_sourceInfo != null) vars['source'] = _sourceInfo;
          if (_bookInfo != null) vars['book'] = _bookInfo;
          if (_chapterInfo != null) vars['chapter'] = _chapterInfo;
          if (!vars.containsKey('cookie')) vars['cookie'] = <String, String>{};
          if (!vars.containsKey('src')) vars['src'] = _content;

          return JsEngine.instance
                  .executeSync(expr, _content,
                      baseUrl: _baseUrl, sourceEngine: _sourceEngine, variables: vars)
                  ?.toString() ??
              '';
        } catch (_) {
          return '';
        }
      },
    );

    // 借鉴 legado：仅当原始规则只包含 {{}} 模板表达式时（expressionOnly），
    // 才将变量替换后的结果当作 literal 处理。
    // CSS 选择器（如 .xxx, #xxx, tag, class.xxx）不含 @ 也是合法选择器，
    // 绝对不能因为「不含 @」就误判为 literal！

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
    // 借鉴 legado：如果 content 是列表，取第一个元素
    if (content is List && content.isNotEmpty) {
      return _toElement(content.first);
    }
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
    if (value is List) {
      if (value.isEmpty) return null;
      // 对齐 legado：List 用换行符拼接，而非只取第一个元素
      return value.map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).join('\n');
    }
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
    // 借鉴 legado：## 分割需要跳过 {{}} 内的 ##，避免误切内嵌规则
    var replaceRegex = '';
    var replacement = '';
    var replaceFirst = false;

    final sharpIndex = _findSharpSplit(rule);
    if (sharpIndex >= 0) {
      final mainRule = rule.substring(0, sharpIndex);
      var afterSharp = rule.substring(sharpIndex + 2);

      // 借鉴 legado：### 是结束标记，### 后面的内容不属于替换模式
      // 例如：onclick##.*\'(.*)\'##$1###  → regex=.*\'(.*)\', replacement=$1
      final endMarker = afterSharp.indexOf('###');
      if (endMarker >= 0) {
        afterSharp = afterSharp.substring(0, endMarker);
      }

      final parts = afterSharp.split('##');
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

  /// 找到规则中第一个不在 {{}} 内的 ## 位置
  /// 借鉴 legado：## 分割需要跳过 {{}} 内的 ##，避免误切内嵌规则
  /// 例如：`《{{@@.bookname@text}}》\n标签：{{@@.tags@a@text##\s##,}}` 中
  /// 第一个 ## 在 {{}} 内，应该跳过，找到 {{}} 外的 ##
  static int _findSharpSplit(String rule) {
    var braceDepth = 0;
    var inSingleQuote = false;
    var inDoubleQuote = false;

    for (var i = 0; i < rule.length - 1; i++) {
      final ch = rule[i];

      // 转义字符跳过
      if (ch == '\\' && i + 1 < rule.length) {
        i++;
        continue;
      }

      // 引号状态管理
      if (ch == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
        continue;
      }
      if (ch == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
        continue;
      }

      // 引号内不处理
      if (inSingleQuote || inDoubleQuote) continue;

      // {{}} 深度管理
      if (ch == '{' && i + 1 < rule.length && rule[i + 1] == '{') {
        braceDepth++;
        i++; // 跳过第二个 {
        continue;
      }
      if (ch == '}' && i + 1 < rule.length && rule[i + 1] == '}') {
        braceDepth = braceDepth > 0 ? braceDepth - 1 : 0;
        i++; // 跳过第二个 }
        continue;
      }

      // 在 {{}} 外且匹配 ## 时返回位置
      if (braceDepth == 0 && ch == '#' && rule[i + 1] == '#') {
        return i;
      }
    }

    return -1; // 没有找到 {{}} 外的 ##
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
// 借鉴 legado 的 RuleAnalyzer，实现平衡组解析和引号内保护

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
      final parts = _splitOutsideBalanced(rule, type);
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

  /// 平衡组分割（借鉴 legado 的 chompRuleBalanced）
  /// 正确处理引号内的分隔符、括号嵌套、转义字符
  List<String> _splitOutsideBalanced(String value, String delimiter) {
    final result = <String>[];
    var depth = 0;
    var bracketDepth = 0;
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var start = 0;

    for (var i = 0; i <= value.length - delimiter.length; i++) {
      final ch = value[i];

      // 转义字符跳过
      if (ch == '\\' && i + 1 < value.length) {
        i++;
        continue;
      }

      // 引号状态管理
      if (ch == "'" && !inDoubleQuote) {
        inSingleQuote = !inSingleQuote;
        continue;
      }
      if (ch == '"' && !inSingleQuote) {
        inDoubleQuote = !inDoubleQuote;
        continue;
      }

      // 引号内不处理分隔符和括号
      if (inSingleQuote || inDoubleQuote) continue;

      // 括号深度管理
      if (ch == '[') {
        bracketDepth++;
      } else if (ch == ']') {
        bracketDepth = bracketDepth > 0 ? bracketDepth - 1 : 0;
      } else if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        depth = depth > 0 ? depth - 1 : 0;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth = depth > 0 ? depth - 1 : 0;
      }

      // 在括号外且匹配分隔符时分割
      if (depth == 0 && bracketDepth == 0 &&
          value.startsWith(delimiter, i)) {
        result.add(value.substring(start, i));
        start = i + delimiter.length;
        i = start - 1;
      }
    }

    if (start == 0) return [value];
    result.add(value.substring(start));
    return result;
  }

  /// 保留旧方法兼容
  // ignore: unused_element
  List<String> _splitOutside(String value, String delimiter) {
    return _splitOutsideBalanced(value, delimiter);
  }

  /// 内嵌规则替换（借鉴 legado 的 innerRule）
  /// 提取 startStr 和 endStr 之间的内容，用 fr 函数替换
  /// 例如 innerRule('{{', '}}', (expr) => evalJS(expr))
  // ignore: unused_element
  static String innerRule(
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

      // 使用平衡组找到匹配的 endStr
      final contentStart = startIdx + startStr.length;
      final endIdx = _findBalancedEnd(value, contentStart, startStr, endStr);

      if (endIdx < 0) {
        // 没有匹配的结束符，保留原文
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
  /// 处理嵌套的 startStr/endStr 对
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

      // 转义字符
      if (ch == '\\' && i + 1 < value.length) {
        i += 2;
        continue;
      }

      // 引号
      if (ch == "'" && !inDoubleQuote) inSingleQuote = !inSingleQuote;
      if (ch == '"' && !inSingleQuote) inDoubleQuote = !inDoubleQuote;

      if (!inSingleQuote && !inDoubleQuote) {
        if (value.startsWith(startStr, i)) {
          depth++;
          i += startStr.length;
          continue;
        }
        if (value.startsWith(endStr, i)) {
          depth--;
          if (depth == 0) return i;
          i += endStr.length;
          continue;
        }
      }

      i++;
    }

    return -1; // 没有找到匹配的结束符
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

  /// legado 内部规则关键字，这些关键字的 . 分隔是语义分隔
  static const _legadoKeywords = {'class', 'tag', 'id', 'text', 'children'};

  /// 常见 HTML 标签名，用于识别隐式 tag 前缀
  static const _htmlTags = {
    'a', 'abbr', 'address', 'area', 'article', 'aside', 'audio',
    'b', 'base', 'bdi', 'bdo', 'blockquote', 'body', 'br', 'button',
    'canvas', 'caption', 'cite', 'code', 'col', 'colgroup',
    'dd', 'del', 'details', 'dfn', 'dialog', 'div', 'dl', 'dt',
    'em', 'embed',
    'fieldset', 'figcaption', 'figure', 'footer', 'form',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'head', 'header', 'hgroup',
    'hr', 'html',
    'i', 'iframe', 'img', 'input', 'ins',
    'kbd',
    'label', 'legend', 'li', 'link',
    'main', 'map', 'mark', 'menu', 'meta', 'meter',
    'nav',
    'ol', 'optgroup', 'option', 'output',
    'p', 'picture', 'pre', 'progress',
    'q',
    'rp', 'rt', 'ruby',
    's', 'samp', 'script', 'section', 'select', 'slot', 'small',
    'source', 'span', 'strong', 'style', 'sub', 'summary', 'sup',
    'table', 'tbody', 'td', 'template', 'textarea', 'tfoot', 'th',
    'thead', 'time', 'title', 'tr', 'track',
    'u', 'ul',
    'var', 'video',
    'wbr',
  };

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

    // 借鉴 legado 的索引解析方式：按 . 分割，检查最后一段是否是纯数字
    // legado 格式：关键字.值.索引，如 class.book-item.0、tag.div.!0
    // class.coll-g-2 → 最后一段 coll-g-2 不是纯数字 → 无索引
    // class.book-item.0 → 最后一段 0 是纯数字 → 索引 0
    // tag.div.!0 → 最后一段 !0 以 ! 开头 → 排除索引 0
    final firstDotIdx = rule.indexOf('.');
    if (firstDotIdx >= 0) {
      final prefix = rule.substring(0, firstDotIdx);
      if (_legadoKeywords.contains(prefix)) {
        // legado 关键字格式，检查最后一段是否是索引
        final lastDotIdx = rule.lastIndexOf('.');
        if (lastDotIdx > firstDotIdx) {
          // 有多个 .，最后一段可能是索引
          final lastSegment = rule.substring(lastDotIdx + 1);
          final excludeIdx = lastSegment.startsWith('!');
          final numStr = excludeIdx ? lastSegment.substring(1) : lastSegment;
          final idx = int.tryParse(numStr);
          if (idx != null) {
            // 最后一段是纯数字，是索引
            rule = rule.substring(0, lastDotIdx);
            exclude = excludeIdx;
            indexes.add(idx);
            return _ElementSelector(rule, indexes, exclude);
          }
        }
        // 只有一个 . 或最后一段不是纯数字，无索引
        return _ElementSelector(rule, indexes, exclude);
      }

      // 借鉴 legado：隐式 tag 前缀识别
      // dd.0 → 等价于 tag.dd.0（第0个dd元素）
      // span.0:-1 → 等价于 tag.span[0:-1]
      // 但 .xxx.yyy（以.开头）是 CSS class 选择器，不处理
      if (_htmlTags.contains(prefix.toLowerCase())) {
        final lastDotIdx = rule.lastIndexOf('.');
        if (lastDotIdx > firstDotIdx) {
          final lastSegment = rule.substring(lastDotIdx + 1);
          // 检查最后一段是否是索引或范围（纯数字、!数字、数字:数字）
          final isIndex = RegExp(r'^!?\d+$').hasMatch(lastSegment);
          final isRange = RegExp(r'^-?\d+:-?\d+$').hasMatch(lastSegment);
          if (isIndex || isRange) {
            // dd.0 → tag.dd, 索引 0
            // dd.!0 → tag.dd, 排除索引 0
            // span.0:-1 → tag.span, 范围 0:-1
            final tagName = rule.substring(firstDotIdx + 1, lastDotIdx);
            if (isIndex) {
              final excludeIdx = lastSegment.startsWith('!');
              final numStr = excludeIdx ? lastSegment.substring(1) : lastSegment;
              final idx = int.tryParse(numStr);
              if (idx != null) {
                rule = 'tag.$tagName';
                exclude = excludeIdx;
                indexes.add(idx);
                return _ElementSelector(rule, indexes, exclude);
              }
            } else {
              // 范围格式
              rule = 'tag.$tagName';
              return _ElementSelector(rule, indexes, exclude, rangeExpression: lastSegment);
            }
          }
        }
        // dd.0 只有一个 . → 检查 . 后面是否是纯数字
        if (lastDotIdx == firstDotIdx) {
          final afterDot = rule.substring(firstDotIdx + 1);
          final isIndex = RegExp(r'^!?\d+$').hasMatch(afterDot);
          final isRange = RegExp(r'^-?\d+:-?\d+$').hasMatch(afterDot);
          if (isIndex) {
            final excludeIdx = afterDot.startsWith('!');
            final numStr = excludeIdx ? afterDot.substring(1) : afterDot;
            final idx = int.tryParse(numStr);
            if (idx != null) {
              rule = 'tag.$prefix';
              exclude = excludeIdx;
              indexes.add(idx);
              return _ElementSelector(rule, indexes, exclude);
            }
          } else if (isRange) {
            rule = 'tag.$prefix';
            return _ElementSelector(rule, indexes, exclude, rangeExpression: afterDot);
          }
        }
      }
    }

    // 非 legado 关键字格式（CSS 选择器等），不解析索引
    // 但借鉴 legado：CSS 类选择器（以.开头）末尾的负数索引需要解析
    // .page-item.-2 → CSS选择器 .page-item，索引 -2
    if (rule.startsWith('.') && rule.length > 1) {
      final lastDotIdx = rule.lastIndexOf('.');
      if (lastDotIdx > 0) {
        final lastSegment = rule.substring(lastDotIdx + 1);
        // 检查最后一段是否是索引（纯数字或负数）
        final isNegativeIndex = RegExp(r'^-\d+$').hasMatch(lastSegment);
        final isPositiveIndex = RegExp(r'^!?\d+$').hasMatch(lastSegment);
        final isRange = RegExp(r'^-?\d+:-?\d+$').hasMatch(lastSegment);
        if (isNegativeIndex) {
          // .page-item.-2 → beforeRule=.page-item, index=-2
          final idx = int.tryParse(lastSegment);
          if (idx != null) {
            rule = rule.substring(0, lastDotIdx);
            indexes.add(idx);
            return _ElementSelector(rule, indexes, exclude);
          }
        } else if (isPositiveIndex) {
          // .page-item.0 → beforeRule=.page-item, index=0
          final excludeIdx = lastSegment.startsWith('!');
          final numStr = excludeIdx ? lastSegment.substring(1) : lastSegment;
          final idx = int.tryParse(numStr);
          if (idx != null) {
            rule = rule.substring(0, lastDotIdx);
            exclude = excludeIdx;
            indexes.add(idx);
            return _ElementSelector(rule, indexes, exclude);
          }
        } else if (isRange) {
          rule = rule.substring(0, lastDotIdx);
          return _ElementSelector(rule, indexes, exclude, rangeExpression: lastSegment);
        }
      }
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
