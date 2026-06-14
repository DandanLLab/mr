import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'js_engine.dart';
import 'platform_channel.dart';

// ===== 四引擎统一调度器 =====
//
// 引擎架构：
//   1. QuickJS  (flutter_js)  → ES6+ 原生支持，主引擎
//   2. Rhino    (Android)     → Java 互操作，Legado 规则
//   3. Rust boa (native-proxy)→ JS 降级引擎，QuickJS 失败时启用
//   4. Node.js  (cors-proxy)  → 原生能力（HTTP/加密/HTML解析/URL）
//
// 调度策略：
//   JS 代码 → QuickJS → 失败 → Rust boa → 失败 → null
//   @java: 代码 → Rhino
//   原生能力 → Node.js API（HTTP/加密/HTML/URL）

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

/// 四引擎统一调度器
class EngineDispatcher {
  static final EngineDispatcher _instance = EngineDispatcher._();
  static EngineDispatcher get instance => _instance;
  EngineDispatcher._();

  // ===== Node.js 进程管理 =====
  Process? _nodeProcess;
  int _nodeProxyPort = 0;
  int _nodeApiPort = 0;
  bool _nodeRunning = false;

  // ===== 引擎执行计数 =====
  int _quickjsCount = 0;
  int _rhinoCount = 0;
  int _rustCount = 0;
  int _nodeCount = 0;

  // ===== 公开属性 =====

  bool get isNodeRunning => _nodeRunning;
  int get nodeProxyPort => _nodeProxyPort;
  int get nodeApiPort => _nodeApiPort;

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
    EngineInfo(
      name: 'Rust boa',
      status: _nodeApiPort > 0 ? EngineStatus.idle : EngineStatus.unavailable,
      version: 'boa_engine',
      executionCount: _rustCount,
    ),
    EngineInfo(
      name: 'Node.js',
      status: _nodeRunning ? EngineStatus.idle : EngineStatus.unavailable,
      version: _nodeRunning ? 'running' : 'stopped',
      executionCount: _nodeCount,
    ),
  ];

  // ===== Node.js 进程启动 =====

  /// 启动 Node.js 代理服务进程（优先使用内置 Node.js）
  Future<bool> startNodeProxy() async {
    if (kIsWeb || _nodeRunning) return _nodeRunning;

    try {
      // 优先使用内置 Node.js（通过 NativeChannel，无需解压二进制）
      if (!kIsWeb) {
        debugPrint('[EngineDispatcher] 启动内置 Node.js...');
        final result = await NativeChannel.instance.nodeStartProxy();
        if (result != null) {
          _nodeProxyPort = (result['proxyPort'] as num?)?.toInt() ?? 0;
          _nodeApiPort = (result['apiPort'] as num?)?.toInt() ?? 0;
          _nodeRunning = result['running'] == true;

          if (_nodeRunning && _nodeProxyPort > 0 && _nodeApiPort > 0) {
            JsEngine.instance.setRustApiPort(_nodeApiPort);
            debugPrint('[EngineDispatcher] 内置 Node.js 就绪: proxy=$_nodeProxyPort, api=$_nodeApiPort');
            return true;
          }
        }
        debugPrint('[EngineDispatcher] 内置 Node.js 启动失败，尝试系统 Node.js...');
      }

      // 降级：尝试系统安装的 Node.js
      final nodePath = await _findNodeExecutable();
      if (nodePath == null) {
        debugPrint('[EngineDispatcher] Node.js 不可用（内置和系统均未找到）');
        return false;
      }

      final scriptPath = await _findCorsProxyScript();
      if (scriptPath == null) {
        debugPrint('[EngineDispatcher] cors-proxy.js 未找到');
        return false;
      }

      debugPrint('[EngineDispatcher] 使用系统 Node.js: $nodePath $scriptPath');

      _nodeProcess = await Process.start(nodePath, [scriptPath]);
      _nodeRunning = true;

      _nodeProcess!.stderr.transform(utf8.decoder).listen(_parseNodeOutput);
      _nodeProcess!.stdout.transform(utf8.decoder).listen((data) {
        debugPrint('[Node.js] $data');
      });
      _nodeProcess!.exitCode.then((code) {
        debugPrint('[EngineDispatcher] Node.js 退出: code=$code');
        _nodeRunning = false;
        _nodeProxyPort = 0;
        _nodeApiPort = 0;
      });

      for (int i = 0; i < 50; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (_nodeProxyPort > 0 && _nodeApiPort > 0) {
          JsEngine.instance.setRustApiPort(_nodeApiPort);
          debugPrint('[EngineDispatcher] 系统 Node.js 就绪: proxy=$_nodeProxyPort, api=$_nodeApiPort');
          return true;
        }
      }

      debugPrint('[EngineDispatcher] Node.js 启动超时');
      return _nodeRunning;
    } catch (e) {
      debugPrint('[EngineDispatcher] Node.js 启动失败: $e');
      _nodeRunning = false;
      return false;
    }
  }

  /// 停止 Node.js 进程
  void stopNodeProxy() {
    _nodeProcess?.kill();
    _nodeProcess = null;
    _nodeRunning = false;
    _nodeProxyPort = 0;
    _nodeApiPort = 0;
  }

  /// 解析 Node.js 输出的端口信息
  void _parseNodeOutput(String data) {
    // 格式: PROXY_PORT:12345 或 API_PORT:12346
    for (final line in data.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('PROXY_PORT:')) {
        _nodeProxyPort = int.tryParse(trimmed.substring(11)) ?? 0;
        debugPrint('[EngineDispatcher] 发现代理端口: $_nodeProxyPort');
      } else if (trimmed.startsWith('API_PORT:')) {
        _nodeApiPort = int.tryParse(trimmed.substring(9)) ?? 0;
        debugPrint('[EngineDispatcher] 发现 API 端口: $_nodeApiPort');
      }
    }
  }

  /// 查找 Node.js 可执行文件
  Future<String?> _findNodeExecutable() async {
    // Android 上 Node.js 不太可能存在，但可以检查
    const candidates = ['node', '/usr/local/bin/node', '/usr/bin/node'];
    for (final candidate in candidates) {
      try {
        final result = await Process.run(candidate, ['--version']);
        if (result.exitCode == 0) return candidate;
      } catch (_) {}
    }
    return null;
  }

  /// 查找 cors-proxy.js 脚本
  Future<String?> _findCorsProxyScript() async {
    // 尝试多个可能的路径
    const candidates = [
      'tools/cors-proxy.js',
      '../tools/cors-proxy.js',
      '/data/data/com.mr.app/tools/cors-proxy.js',
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  // ===== 统一调度 API =====

  /// 执行 JS 代码（四引擎自动降级）
  ///
  /// 路由策略：
  ///   1. 含 @java:/@css:/@text:/@attr:/java: 前缀 → Rhino
  ///   2. 其他 → QuickJS → 失败 → Rust boa → 失败 → null
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

    // QuickJS 路径（含自动降级到 Rust）
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

    if (quickjsResult != null) return quickjsResult;

    // QuickJS 失败，Rust 降级
    if (_nodeApiPort > 0) {
      _rustCount++;
      return JsEngine.instance.fallbackToRustEngine(
        resolved.code, result: result, env: env,
      );
    }

    return null;
  }

  /// 调用 Node.js 原生能力（HTTP/加密/HTML/URL）
  Future<T?> callNativeApi<T>(String path, Map<String, String> params) async {
    if (_nodeApiPort == 0) return null;

    _nodeCount++;
    try {
      final client = HttpClient();
      final queryString = params.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
          .join('&');
      final url = 'http://localhost:$_nodeApiPort$path?$queryString';

      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      client.close();

      if (body.isEmpty) return null;

      final json = jsonDecode(body) as Map<String, dynamic>;
      final result = json['result'];

      if (T == String) return result?.toString() as T?;
      if (T == int) return int.tryParse(result?.toString() ?? '') as T?;
      if (T == bool) return (result?.toString() == 'true') as T?;
      return result as T?;
    } catch (e) {
      debugPrint('[EngineDispatcher] Native API 调用失败: $e');
      return null;
    }
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

    // Rust boa
    if (_nodeApiPort > 0) {
      try {
        final result = await callNativeApi<String>('/api/js/evaluate', {'code': '1+1'});
        results['rust_boa'] = result == '2';
      } catch (_) {
        results['rust_boa'] = false;
      }
    } else {
      results['rust_boa'] = false;
    }

    // Node.js
    results['nodejs'] = _nodeRunning;

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
