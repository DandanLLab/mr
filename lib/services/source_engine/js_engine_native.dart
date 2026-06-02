import 'dart:convert';
import 'package:flutter/foundation.dart';

class JsEngine {
  static final JsEngine instance = JsEngine._internal();
  JsEngine._internal();

  bool _initialized = false;
  final Map<String, dynamic> _globalVariables = {};

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    debugPrint('Native JS Engine initialized (flutter_js not available)');
  }

  void setGlobalVariable(String name, dynamic value) {
    _globalVariables[name] = value;
  }

  dynamic getGlobalVariable(String name) {
    return _globalVariables[name];
  }

  Future<dynamic> execute(String jsCode, {Map<String, dynamic>? variables}) async {
    if (!_initialized) {
      await init();
    }

    debugPrint('JS execution requires flutter_js package. Code: ${jsCode.substring(0, jsCode.length > 100 ? 100 : jsCode.length)}...');
    
    return null;
  }

  Future<String?> executeString(String jsCode, {Map<String, dynamic>? variables}) async {
    final result = await execute(jsCode, variables: variables);
    return result?.toString();
  }

  Future<int?> executeInt(String jsCode, {Map<String, dynamic>? variables}) async {
    final result = await execute(jsCode, variables: variables);
    if (result is int) return result;
    if (result is double) return result.toInt();
    if (result is String) return int.tryParse(result);
    return null;
  }

  Future<double?> executeDouble(String jsCode, {Map<String, dynamic>? variables}) async {
    final result = await execute(jsCode, variables: variables);
    if (result is double) return result;
    if (result is int) return result.toDouble();
    if (result is String) return double.tryParse(result);
    return null;
  }

  Future<bool?> executeBool(String jsCode, {Map<String, dynamic>? variables}) async {
    final result = await execute(jsCode, variables: variables);
    if (result is bool) return result;
    if (result is String) {
      final lower = result.toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
    return null;
  }

  Future<List<dynamic>?> executeList(String jsCode, {Map<String, dynamic>? variables}) async {
    final result = await execute(jsCode, variables: variables);
    if (result is List) return result;
    return null;
  }

  Future<Map<String, dynamic>?> executeMap(String jsCode, {Map<String, dynamic>? variables}) async {
    final result = await execute(jsCode, variables: variables);
    if (result is Map) return Map<String, dynamic>.from(result);
    return null;
  }

  String _encodeValue(dynamic value) {
    if (value == null) return 'null';
    if (value is String) return json.encode(value);
    if (value is num || value is bool) return value.toString();
    if (value is List || value is Map) return json.encode(value);
    return json.encode(value.toString());
  }

  void dispose() {
    _initialized = false;
    _globalVariables.clear();
  }

  Future<String?> processJsRule(String content, String jsCode, {String? baseUrl}) async {
    if (!_initialized) {
      await init();
    }

    debugPrint('JS rule processing requires flutter_js package');
    return null;
  }

  /// 同步执行 JS 代码（用于规则解析）
  dynamic executeSync(String jsCode, dynamic content, {String? baseUrl}) {
    debugPrint('⚠️ JS 同步执行需要 flutter_js 包支持');
    debugPrint('   JS代码: ${jsCode.length > 50 ? '${jsCode.substring(0, 50)}...' : jsCode}');
    return null;
  }

  Future<String?> processJsWithBook(
    String jsCode, {
    Map<String, dynamic>? book,
    Map<String, dynamic>? chapter,
    String? content,
    int? index,
  }) async {
    if (!_initialized) {
      await init();
    }

    debugPrint('JS book processing requires flutter_js package');
    return null;
  }
}
