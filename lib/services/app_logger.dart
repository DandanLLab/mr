import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';
import 'crash_log_service.dart';

/// 日志级别
enum LogLevel {
  verbose,
  debug,
  info,
  warning,
  error,
}

/// 日志分类
enum LogCategory {
  network('网络'),
  js('JS引擎'),
  parse('规则解析'),
  proxy('代理服务'),
  engine('引擎调度'),
  ui('界面'),
  storage('存储'),
  system('系统');

  final String label;
  const LogCategory(this.label);
}

/// 单条日志记录
class LogEntry {
  final DateTime time;
  final LogLevel level;
  final LogCategory category;
  final String message;
  final String? detail;
  /// 会话ID
  final String sessionId;

  const LogEntry({
    required this.time,
    required this.level,
    required this.category,
    required this.message,
    this.detail,
    this.sessionId = '',
  });

  String get levelIcon {
    switch (level) {
      case LogLevel.verbose: return '⚪';
      case LogLevel.debug: return '🔵';
      case LogLevel.info: return '🟢';
      case LogLevel.warning: return '🟡';
      case LogLevel.error: return '🔴';
    }
  }

  String get levelName {
    switch (level) {
      case LogLevel.verbose: return 'V';
      case LogLevel.debug: return 'D';
      case LogLevel.info: return 'I';
      case LogLevel.warning: return 'W';
      case LogLevel.error: return 'E';
    }
  }

  /// UI 显示用简短格式
  String toShortString() {
    return '[$levelName][${category.label}] $message';
  }

  /// 导出文件用完整格式
  String toFullString() {
    final t = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
    final base = '[$t][$levelName][${category.label}][$sessionId] $message';
    if (detail != null && detail!.isNotEmpty) {
      return '$base\n  $detail';
    }
    return base;
  }
}

/// 应用日志工具
/// 支持分类、级别过滤、缓冲区、流式监听、文件持久化、日志轮转
///
/// 性能设计：
/// - RingBuffer 环形缓冲区（默认 10000 条上限），避免无限内存膨胀
/// - IOSink 批量文件写入（取代逐条异步 append），降低 100x I/O 开销
/// - debugPrint 热路径节流（每 100 条输出一次摘要）
/// - 日志出锁设计：日志生产者和消费者分离
class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  /// 环形缓冲区最大容量（达到上限后最旧的日志被覆盖）
  static const int _maxBufferSize = 10000;

  /// 日志缓冲区（环形，达到上限自动覆盖最旧条目）
  final List<LogEntry?> _buffer = List.filled(_maxBufferSize, null);

  /// 当前写入位置（环形索引）
  int _bufferIndex = 0;

  /// 累计写入总数（用于计算实际有效条数）
  int _totalWritten = 0;

  /// 日志流控制器
  final _controller = StreamController<LogEntry>.broadcast();

  /// 日志流
  Stream<LogEntry> get stream => _controller.stream;

  /// 当前最低显示级别
  LogLevel minLevel = kDebugMode ? LogLevel.verbose : LogLevel.info;

  // ===== JS 执行统计 =====
  int _quickjsExecutionCount = 0;

  int get quickjsExecutionCount => _quickjsExecutionCount;

  void incrementQuickjsCount() => _quickjsExecutionCount++;

  /// 是否已初始化文件写入
  bool _fileInitialized = false;

  /// 日志文件目录
  String? _logDirPath;

  /// IOSink 批量写入器（取代逐条异步 append）
  IOSink? _fileSink;

  /// 文件写入锁，防止并发 flush
  final _fileLock = Lock();

  /// 会话启动标记是否已写入
  bool _sessionMarkerWritten = false;

  // ===== debugPrint 节流 =====
  int _debugPrintCounter = 0;
  static const int _debugPrintThrottle = 100; // 每 100 条打印一次
  int _debugPrintAccumulated = 0; // 累积未打印的日志数

  /// 初始化文件日志系统
  Future<void> initFileLogging() async {
    if (_fileInitialized) return;
    _fileInitialized = true;

    try {
      final dir = await getApplicationDocumentsDirectory();
      _logDirPath = '${dir.path}/mr_logs';
      final logDir = Directory(_logDirPath!);
      if (!logDir.existsSync()) {
        logDir.createSync(recursive: true);
      }

      final now = DateTime.now();
      final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final logFile = File('$_logDirPath/app_$dateStr.log');

      // 打开 IOSink（批量写入，取代逐条 append）
      _fileSink = logFile.openWrite(mode: FileMode.append, encoding: utf8);

      // 写入会话启动标记
      if (!_sessionMarkerWritten) {
        _sessionMarkerWritten = true;
        final sessionId = CrashLogService.instance.sessionId;
        _fileSink!.writeln(
          '\n========== 会话启动 [${now.toIso8601String()}] session=$sessionId ==========\n',
        );
        // 立即 flush 确保会话标记写入
        await _fileSink!.flush();
      }

      if (kDebugMode) {
        debugPrint('✅ AppLogger 文件日志初始化完成: $logFile');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('AppLogger 文件日志初始化失败: $e');
    }
  }

  /// 写入一行到日志文件（批量 IOSink，非逐条 append）
  Future<void> _writeToFile(String line) async {
    final sink = _fileSink;
    if (sink == null) return;
    try {
      await _fileLock.synchronized(() {
        sink.writeln(line);
      });
    } catch (_) {}
  }

  /// 批量 flush 文件缓冲区，确保所有日志落盘
  Future<void> flushToFile() async {
    final sink = _fileSink;
    if (sink == null) return;
    try {
      await _fileLock.synchronized(() => sink.flush());
    } catch (_) {}
  }

  /// 获取所有有效日志（按时间顺序）
  List<LogEntry> get logs {
    if (_totalWritten == 0) return [];
    if (_totalWritten < _maxBufferSize) {
      // 环形未满：按写入顺序返回 [0.._bufferIndex)
      return _buffer.sublist(0, _bufferIndex).whereType<LogEntry>().toList();
    }
    // 环形已满：[_bufferIndex.._maxBufferSize) + [0.._bufferIndex)
    return [
      ..._buffer.sublist(_bufferIndex).whereType<LogEntry>(),
      ..._buffer.sublist(0, _bufferIndex).whereType<LogEntry>(),
    ];
  }

  /// 获取指定分类的日志
  List<LogEntry> getLogs({LogCategory? category, LogLevel? minLevel}) {
    return logs.where((e) {
      if (category != null && e.category != category) return false;
      if (minLevel != null && e.level.index < minLevel.index) return false;
      return true;
    }).toList();
  }

  /// 清空日志
  void clear() {
    for (var i = 0; i < _maxBufferSize; i++) {
      _buffer[i] = null;
    }
    _bufferIndex = 0;
    _totalWritten = 0;
  }

  void _log(LogLevel level, LogCategory category, String message, {String? detail}) {
    if (level.index < minLevel.index) return;

    final entry = LogEntry(
      time: DateTime.now(),
      level: level,
      category: category,
      message: message,
      detail: detail,
      sessionId: CrashLogService.instance.sessionId,
    );

    // RingBuffer 写入
    _buffer[_bufferIndex] = entry;
    _bufferIndex = (_bufferIndex + 1) % _maxBufferSize;
    _totalWritten++;

    _controller.add(entry);

    // 文件持久化：批量 IOSink 写入
    if (_fileInitialized && _fileSink != null) {
      unawaited(_writeToFile(entry.toFullString()));
    }

    // 控制台输出（热路径节流：每 _debugPrintThrottle 条输出一次摘要）
    if (kDebugMode) {
      _debugPrintCounter++;
      if (_debugPrintCounter >= _debugPrintThrottle) {
        // 输出累积摘要
        final accumulated = _debugPrintAccumulated + _debugPrintCounter;
        if (accumulated > 0) {
          debugPrint('[AppLogger] ⚡ ${entry.levelName}[${category.label}] $message (累计 ${accumulated - 1} 条相似日志, 最新 $_debugPrintCounter 条)');
        } else {
          debugPrint('[AppLogger] ⚡ ${entry.levelName}[${category.label}] $message');
        }
        _debugPrintCounter = 0;
        _debugPrintAccumulated = 0;
      } else {
        _debugPrintAccumulated++;
      }
    }
  }

  // ===== 便捷方法 =====

  void verbose(LogCategory category, String message, {String? detail}) =>
      _log(LogLevel.verbose, category, message, detail: detail);

  void debug(LogCategory category, String message, {String? detail}) =>
      _log(LogLevel.debug, category, message, detail: detail);

  void info(LogCategory category, String message, {String? detail}) =>
      _log(LogLevel.info, category, message, detail: detail);

  void warn(LogCategory category, String message, {String? detail}) =>
      _log(LogLevel.warning, category, message, detail: detail);

  void error(LogCategory category, String message, {String? detail}) =>
      _log(LogLevel.error, category, message, detail: detail);

  // ===== 网络请求专用 =====

  void logRequest(String method, String url, {Map<String, String>? headers}) {
    info(LogCategory.network, '$method $url', detail: headers?.isNotEmpty == true
        ? 'Headers: ${headers!.entries.take(5).map((e) => '${e.key}: ${e.value}').join(', ')}'
        : null);
  }

  void logResponse(String url, int statusCode, int bodyLength) {
    info(LogCategory.network, '← $statusCode $url (${_formatSize(bodyLength)})');
  }

  void logRequestError(String url, String errorMsg) {
    _log(LogLevel.error, LogCategory.network, '✗ $url', detail: errorMsg);
  }

  // ===== JS 引擎专用 =====

  void logJsExecute(String engine, String code, {int? codeLength}) {
    info(LogCategory.js, '[$engine] 执行JS #$_quickjsExecutionCount (${codeLength ?? code.length} chars)',
      detail: code);
  }

  void logJsResult(String engine, String? result) {
    info(LogCategory.js, '[$engine] 结果: ${result != null ? "${result.length} chars" : "null"}',
      detail: result);
  }

  void logJsError(String engine, String errorMsg) {
    _log(LogLevel.error, LogCategory.js, '[$engine] 执行失败', detail: errorMsg);
  }

  void logJsInput(String engine, String? input, {String? tag}) {
    final label = tag != null ? '[$engine] 输入[$tag]' : '[$engine] 输入';
    info(LogCategory.js, '$label (${input?.length ?? 0} chars)', detail: input);
  }

  void logJsOutput(String engine, String? output, {String? outputType, String? tag}) {
    final typeInfo = outputType != null ? '($outputType)' : '';
    final label = tag != null ? '[$engine] 输出[$tag]$typeInfo' : '[$engine] 输出$typeInfo';
    info(LogCategory.js, '$label (${output?.length ?? 0} chars)', detail: output);
  }

  void logJsTree(String engine, String treeString) {
    if (treeString.isEmpty || treeString == '(no trace)') return;
    info(LogCategory.js, '[$engine] JS执行树', detail: treeString);
  }

  void logJsStep(String engine, String step, {String? detail}) {
    info(LogCategory.js, '[$engine] $step', detail: detail);
  }

  // ===== 规则解析专用 =====

  void logParse(String ruleType, String rule, {String? content}) {
    debug(LogCategory.parse, '解析$ruleType: $rule',
      detail: content != null ? '内容长度: ${content.length}' : null);
  }

  void logParseResult(String ruleType, int count) {
    info(LogCategory.parse, '$ruleType 解析完成: $count 条结果');
  }

  String _formatSize(int chars) {
    if (chars < 1024) return '$chars B';
    if (chars < 1024 * 1024) return '${(chars / 1024).toStringAsFixed(1)} KB';
    return '${(chars / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// 导出日志为文本（支持分类/级别过滤）
  String exportLogs({LogCategory? category, LogLevel? minLevel}) {
    final filtered = getLogs(category: category, minLevel: minLevel);
    if (filtered.isEmpty) return '暂无日志';

    final sb = StringBuffer();
    sb.writeln('=== 日志导出 ===');
    sb.writeln('导出时间: ${DateTime.now().toString().substring(0, 19)}');
    sb.writeln('日志条数: ${filtered.length}');
    sb.writeln('会话ID: ${CrashLogService.instance.sessionId}');
    sb.writeln('');

    for (final entry in filtered) {
      sb.writeln(entry.toFullString());
    }

    return sb.toString();
  }

  /// 导出日志到文件
  Future<String?> exportLogsToFile({LogCategory? category, LogLevel? minLevel}) async {
    try {
      final text = exportLogs(category: category, minLevel: minLevel);
      if (text == '暂无日志') return null;

      final dir = await getTemporaryDirectory();
      final now = DateTime.now();
      final fileName = 'mr_export_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.txt';
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(text);
      return file.path;
    } catch (e) {
      debugPrint('导出日志到文件失败: $e');
      return null;
    }
  }

  /// 获取今日日志文件列表
  Future<List<File>> getTodayLogFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logDir = Directory('${dir.path}/mr_logs');
      if (!logDir.existsSync()) return [];
      final now = DateTime.now();
      final dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      return logDir.listSync().where((e) =>
        e is File && e.path.contains(dateStr)
      ).cast<File>().toList();
    } catch (_) {
      return [];
    }
  }
}