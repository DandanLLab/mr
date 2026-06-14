import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'js_engine.dart';
import 'platform_channel.dart';

// ===== 双引擎统一调度器 =====
//
// 引擎架构：
//   1. QuickJS  (flutter_js)  → ES6+ 原生支持，主引擎
//   2. Rhino    (Android)     → Java 互操作，Legado 规则
//
// 调度策略：
//   JS 代码 → QuickJS → 失败 → null
//   @java: 代码 → Rhino

/// 引擎状态
enum EngineStatus {
  unavailable, // 不可用
  idle,        // 空闲
  busy,        // 执行中
  error,       // 错误
}

/// 单个引擎的状态信息
class EngineInfo {
  final String name;
  final EngineStatus status;
  final String? version;
  final String? error;
  final int executionCount;

  const EngineInfo({
    required this.name,
    required this.status,
    this.version,
    this.error,
    this.executionCount = 0,
  });
}

/// 双引擎统一调度器
class EngineDispatcher {
  static final EngineDispatcher _instance = EngineDispatcher._();
  static EngineDispatcher get instance => _instance;
  EngineDispatcher._();

  // ===== 引擎执行计数 =====
  int _quickjsCount = 0;
  int _rhinoCount = 0;

  /// 获取所有引擎状态
  List<EngineInfo> get engineStatuses => [
    EngineInfo(
      name: 'QuickJS',
      status: JsEngine.instance.isAvailable ? EngineStatus.idle : EngineStatus.unavailable,
      version: 'flutter_js',
      executionCount: _quickjsCount,
    ),
    EngineInfo(
      name: 'Rhino',
      status: !kIsWeb ? EngineStatus.idle : EngineStatus.unavailable,
      version: '1.9.1',
      executionCount: _rhinoCount,
    ),
  ];

  // ===== 统一调度 API =====

  /// 执行 JS 代码（双引擎自动降级）
  ///
  /// 路由策略：
  ///   1. 含 @java:/@css:/@text:/@attr:/java: 前缀 → Rhino
  ///   2. 其他 → QuickJS → 失败 → null
  Future<String?> execute(String code, {
    dynamic result,
    String? baseUrl,
    Map<String, dynamic>? env,
    JsEngineType? sourceEngine,
  }) async {
    final resolved = JsEngine.instance.resolveEngine(code, sourceEngine: sourceEngine);

    // Rhino 路径
    if (resolved.engine == JsEngineType.rhino) {
      _rhinoCount++;
      return JsEngine.instance.evaluateBookRule(
        code, result: result, env: env, sourceEngine: sourceEngine,
      );
    }

    // QuickJS 路径
    _quickjsCount++;
    // 序列化 result 用于 processJsRule 的 content 参数
    String contentStr;
    if (result is List || result is Map) {
      contentStr = jsonEncode(result);
    } else if (result is String) {
      contentStr = result;
    } else {
      contentStr = result?.toString() ?? '';
    }
    final quickjsResult = await JsEngine.instance.processJsRule(
      contentStr, resolved.code, baseUrl: baseUrl, sourceEngine: sourceEngine,
      dynamicContent: result,
    );

    return quickjsResult;
  }

  /// 健康检查：检测所有引擎是否可用
  Future<Map<String, bool>> healthCheck() async {
    final results = <String, bool>{};

    // QuickJS
    results['quickjs'] = JsEngine.instance.isAvailable;

    // Rhino
    if (!kIsWeb) {
      try {
        final test = await NativeChannel.instance.evaluateJavaRule('@css:body@text', result: '<body>ok</body>');
        results['rhino'] = test != null;
      } catch (_) {
        results['rhino'] = false;
      }
    } else {
      results['rhino'] = false;
    }

    return results;
  }

  /// 获取引擎状态摘要
  String get statusSummary {
    final statuses = engineStatuses;
    final lines = statuses.map((e) =>
      '${e.name}: ${e.status.name}${e.executionCount > 0 ? " (${e.executionCount}次)" : ""}'
    );
    return lines.join('\n');
  }
}
