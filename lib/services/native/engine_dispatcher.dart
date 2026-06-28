import 'dart:convert';
import '../app_logger.dart';
import 'js_engine.dart';

// ===== QuickJS 统一调度器 =====
//
// 引擎架构：
//   QuickJS (flutter_js) → 唯一 JS 引擎，ES6+ 原生支持
//   原生桥接（NativeChannel）→ HTTP/Jsoup/加密等，供预缓存调用
//
// 调度策略：
//   所有 JS 代码 → QuickJS → 失败 → null

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

/// JS 引擎统一调度器
class EngineDispatcher {
  static final EngineDispatcher _instance = EngineDispatcher._();
  static EngineDispatcher get instance => _instance;
  EngineDispatcher._();

  // ===== 引擎执行计数 =====
  int _quickjsCount = 0;

  /// 获取引擎状态
  List<EngineInfo> get engineStatuses => [
    EngineInfo(
      name: 'QuickJS',
      status: JsEngine.instance.isAvailable ? EngineStatus.idle : EngineStatus.unavailable,
      version: 'flutter_js',
      executionCount: _quickjsCount,
    ),
  ];

  // ===== 统一调度 API =====

  /// 执行 JS 代码
  ///
  /// 路由策略：所有代码 → QuickJS
  Future<String?> execute(String code, {
    dynamic result,
    String? baseUrl,
    Map<String, dynamic>? env,
    JsEngineType? sourceEngine,
  }) async {
    final resolved = JsEngine.instance.resolveEngine(code, sourceEngine: sourceEngine);

    // QuickJS 路径（唯一引擎）
    _quickjsCount++;
    // 注意：processJsRule 内部会调用 incrementQuickjsCount()，这里不重复调用
    AppLogger.instance.logJsStep('EngineDispatcher', '调度JS执行 #$_quickjsCount',
      detail: 'codeLen=${resolved.code.length}, hasResult=${result != null}, baseUrl=$baseUrl');
    String contentStr;
    if (result is List || result is Map) {
      contentStr = jsonEncode(result);
    } else if (result is String) {
      contentStr = result;
    } else {
      contentStr = result?.toString() ?? '';
    }
    final out = await JsEngine.instance.processJsRule(
      contentStr, resolved.code, baseUrl: baseUrl, sourceEngine: sourceEngine,
      dynamicContent: result,
    );
    AppLogger.instance.logJsResult('EngineDispatcher', out);
    return out;
  }

  /// 健康检查：检测引擎是否可用
  Future<Map<String, bool>> healthCheck() async {
    return {'quickjs': JsEngine.instance.isAvailable};
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
