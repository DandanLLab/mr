import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 崩溃日志条目
class CrashLogEntry {
  final DateTime time;
  final String type; // 'flutter' | 'zone' | 'isolate' | 'manual'
  final String error;
  final String? stackTrace;
  /// 会话ID，标记本次启动会话
  final String sessionId;

  const CrashLogEntry({
    required this.time,
    required this.type,
    required this.error,
    this.stackTrace,
    this.sessionId = '',
  });

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'type': type,
        'error': error,
        'stackTrace': stackTrace,
        'sessionId': sessionId,
      };

  factory CrashLogEntry.fromJson(Map<String, dynamic> json) => CrashLogEntry(
        time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
        type: json['type'] as String? ?? 'unknown',
        error: json['error'] as String? ?? '',
        stackTrace: json['stackTrace'] as String?,
        sessionId: json['sessionId'] as String? ?? '',
      );

  /// 完整格式化文本
  String toFullString() {
    final sb = StringBuffer();
    sb.writeln('========== 崩溃日志 ==========');
    sb.writeln('时间: ${time.toString().substring(0, 19)}');
    sb.writeln('类型: $type');
    sb.writeln('会话: $sessionId');
    sb.writeln('错误: $error');
    if (stackTrace != null && stackTrace!.isNotEmpty) {
      sb.writeln('堆栈:');
      sb.writeln(stackTrace);
    }
    sb.writeln('==============================');
    return sb.toString();
  }
}

/// 崩溃日志服务（单例）
///
/// 功能：
/// 1. 捕获 Flutter 框架错误、Zone 错误、Isolate 错误
/// 2. 持久化到本地文件（文档目录/缓存目录双路径降级）
/// 3. 自动复制到粘贴板
/// 4. 启动时检测上次崩溃并提示用户
/// 5. 会话追踪 + 错误计数
class CrashLogService {
  CrashLogService._();
  static final CrashLogService instance = CrashLogService._();

  /// 崩溃日志文件名
  static const String _crashFileName = 'crash_logs.json';

  /// 错误计数文件
  static const String _counterFileName = 'error_counters.json';

  /// 内存中的崩溃日志列表
  final List<CrashLogEntry> _entries = [];

  /// 是否已初始化
  bool _initialized = false;

  /// 是否有新的崩溃日志待显示
  bool _hasNewCrash = false;

  /// 并发保护
  bool _isLogging = false;

  /// 会话ID（启动时生成，用于追踪本次会话的多次崩溃）
  late final String _sessionId;

  /// 启动时间
  late final DateTime _startTime;

  /// 软件启动时的总错误计数
  Map<String, int> _errorCounters = {};

  /// 获取所有崩溃日志（只读副本）
  List<CrashLogEntry> get entries => List.unmodifiable(_entries);

  /// 是否有新的崩溃日志
  bool get hasNewCrash => _hasNewCrash;

  /// 会话ID
  String get sessionId => _sessionId;

  /// 运行时长（秒）
  int get uptimeSeconds => DateTime.now().difference(_startTime).inSeconds;

  /// 标记崩溃日志已查看
  void markCrashViewed() => _hasNewCrash = false;

  /// 初始化：生成会话ID + 加载历史崩溃日志 + 注册错误捕获
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _startTime = DateTime.now();
    _sessionId = '${_startTime.millisecondsSinceEpoch.toRadixString(36)}-${_startTime.microsecond}';

    // 加载错误计数
    await _loadErrorCounters();

    // 加载历史崩溃日志
    await _loadCrashLogs();

    // 注册 Flutter 框架错误捕获
    FlutterError.onError = _onFlutterError;

    // 注册 Isolate 错误捕获（异步错误）
    Isolate.current.addErrorListener(RawReceivePort((dynamic pair) {
      final list = pair as List<dynamic>;
      final error = list.first.toString();
      final stack = list.last.toString();
      logCrash(error: error, stackTrace: stack, type: 'isolate');
    }).sendPort);

    // 注册 Zone 错误捕获（未捕获的异步错误）
    PlatformDispatcher.instance.onError = (error, stack) {
      logCrash(
        error: error.toString(),
        stackTrace: stack.toString(),
        type: 'zone',
      );
      return true;
    };

    if (kDebugMode) {
      debugPrint('✅ CrashLogService 初始化完成 (session=$_sessionId)');
    }
  }

  /// Flutter 框架错误回调
  void _onFlutterError(FlutterErrorDetails details) {
    logCrash(
      error: details.exceptionAsString(),
      stackTrace: details.stack?.toString(),
      type: 'flutter',
    );
    // 同时输出到控制台
    FlutterError.dumpErrorToConsole(details);
  }

  /// 记录一条崩溃日志
  Future<void> logCrash({
    required String error,
    String? stackTrace,
    String type = 'manual',
  }) async {
    // 并发保护
    if (_isLogging) {
      if (kDebugMode) debugPrint('🔴 崩溃日志正在写入中，跳过并发记录: $error');
      return;
    }
    _isLogging = true;

    try {
      final entry = CrashLogEntry(
        time: DateTime.now(),
        type: type,
        error: error.length > 10000 ? '${error.substring(0, 10000)}...(已截断)' : error,
        stackTrace: stackTrace != null && stackTrace.length > 20000
            ? '${stackTrace.substring(0, 20000)}...(已截断)'
            : stackTrace,
        sessionId: _sessionId,
      );

      _entries.add(entry);
      _hasNewCrash = true;

      // 更新错误计数（按类型分类）
      _errorCounters[type] = (_errorCounters[type] ?? 0) + 1;
      _errorCounters['total'] = (_errorCounters['total'] ?? 0) + 1;

      // 持久化
      await _saveCrashLogs();
      await _saveErrorCounters();

      // 自动复制到粘贴板
      try {
        await Clipboard.setData(ClipboardData(text: entry.toFullString()));
      } catch (e) {
        if (kDebugMode) debugPrint('复制崩溃日志到粘贴板失败: $e');
      }

      if (kDebugMode) {
        debugPrint('🔴 崩溃已记录 (session=$_sessionId):\n${entry.toFullString()}');
      }
    } finally {
      _isLogging = false;
    }
  }

  /// 手动记录错误
  Future<void> recordError(Object error, StackTrace? stackTrace,
      {String type = 'manual'}) async {
    await logCrash(
      error: error.toString(),
      stackTrace: stackTrace?.toString(),
      type: type,
    );
  }

  /// 记录 JS 引擎错误（非崩溃但需要追踪）
  Future<void> logJsEngineError(String context, String error) async {
    // JS 引擎错误不触发崩溃弹窗，只持久化
    try {
      final file = await _getCrashFile();
      final dir = file.parent;
      final jsLogFile = File('${dir.path}/js_engine_errors.log');
      await jsLogFile.writeAsString(
        '[${DateTime.now().toIso8601String()}][session=$_sessionId] $context: $error\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  /// 清空所有崩溃日志
  Future<void> clear() async {
    _entries.clear();
    _hasNewCrash = false;
    await _saveCrashLogs();
  }

  /// 获取指定会话的崩溃日志
  List<CrashLogEntry> getEntriesBySession(String sessionId) {
    return _entries.where((e) => e.sessionId == sessionId).toList();
  }

  /// 获取错误总数
  int get totalErrorCount => _errorCounters['total'] ?? 0;

  /// 导出所有崩溃日志为文本
  String exportLogs() {
    if (_entries.isEmpty) return '暂无崩溃日志';
    final sb = StringBuffer();
    sb.writeln('========== 崩溃日志导出 ==========');
    sb.writeln('导出时间: ${DateTime.now().toString().substring(0, 19)}');
    sb.writeln('日志条数: ${_entries.length}');
    sb.writeln('会话ID: $_sessionId');
    sb.writeln('错误总数: ${totalErrorCount}');
    sb.writeln('');
    for (final entry in _entries) {
      sb.writeln(entry.toFullString());
      sb.writeln('');
    }
    return sb.toString();
  }

  /// 加载历史崩溃日志
  Future<void> _loadCrashLogs() async {
    try {
      final files = await _getCrashFiles();
      for (final file in files) {
        if (!file.existsSync()) continue;
        final content = await file.readAsString();
        if (content.isEmpty) continue;
        final json = jsonDecode(content);
        if (json is List) {
          for (final item in json) {
            if (item is Map<String, dynamic>) {
              _entries.add(CrashLogEntry.fromJson(item));
            }
          }
        }
      }
      if (_entries.isNotEmpty) {
        _hasNewCrash = true;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('加载崩溃日志失败: $e');
    }
  }

  /// 保存崩溃日志到文件
  Future<void> _saveCrashLogs() async {
    try {
      final file = await _getCrashFile();
      final json = jsonEncode(_entries.map((e) => e.toJson()).toList());
      await file.writeAsString(json);
    } catch (e) {
      if (kDebugMode) debugPrint('保存崩溃日志失败: $e');
    }
  }

  /// 获取崩溃日志文件（多路径降级）
  Future<File> _getCrashFile() async {
    try {
      // 优先使用文档目录（更稳定，不随临时清理丢失）
      final dir = await getApplicationDocumentsDirectory();
      return File('${dir.path}/mr_crash/$_crashFileName');
    } catch (_) {
      // 降级到临时目录
      final dir = await getTemporaryDirectory();
      return File('${dir.path}/$_crashFileName');
    }
  }

  /// 获取所有可能的崩溃日志文件
  Future<List<File>> _getCrashFiles() async {
    final files = <File>[];
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final docFile = File('${docDir.path}/mr_crash/$_crashFileName');
      if (docFile.existsSync()) files.add(docFile);
    } catch (_) {}
    try {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$_crashFileName');
      if (tempFile.existsSync()) files.add(tempFile);
    } catch (_) {}
    return files;
  }

  // ===== 错误计数 =====

  Future<void> _loadErrorCounters() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/mr_crash/$_counterFileName');
      if (file.existsSync()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final json = jsonDecode(content) as Map<String, dynamic>;
          _errorCounters = json.map((k, v) => MapEntry(k, v as int));
        }
      }
    } catch (_) {}
  }

  Future<void> _saveErrorCounters() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final crashDir = Directory('${dir.path}/mr_crash');
      if (!crashDir.existsSync()) crashDir.createSync(recursive: true);
      final file = File('${dir.path}/mr_crash/$_counterFileName');
      await file.writeAsString(jsonEncode(_errorCounters));
    } catch (_) {}
  }
}