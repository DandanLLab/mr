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
/// - debugPrint 拦截：全局 debugPrint 重定向到日志系统，调试/日志页面可见
/// - 循环日志去重：相同消息连续出现时合并为一条摘要，避免刷屏
/// - 执行数据日志：成功时自动跳过，仅在错误/异常时记录
/// - 日志出锁设计：日志生产者和消费者分离
class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  // ===== debugPrint 拦截 =====
  /// 原始 debugPrint 函数（在替换前保存）
  /// 注意：不能用 static final 懒加载，否则首次访问时 debugPrint 已被替换为
  /// _capturedDebugPrint，导致 _originalDebugPrint 捕获到自身 → 无限递归 → Stack Overflow
  static DebugPrintCallback? _originalDebugPrint;
  /// 是否正在拦截（防止递归）
  static bool _isCapturing = false;
  /// 是否已启用 debugPrint 拦截
  static bool _captureEnabled = false;

  /// 启用 debugPrint 全局拦截
  /// 所有 debugPrint 调用将被重定向到 AppLogger，同时仍输出到控制台
  static void enableDebugPrintCapture() {
    if (_captureEnabled) return;
    _captureEnabled = true;
    // 必须在替换之前保存原始函数，否则懒加载会捕获到已被替换的 _capturedDebugPrint
    _originalDebugPrint = debugPrint;
    debugPrint = _capturedDebugPrint;
  }

  /// 拦截后的 debugPrint 实现
  static void _capturedDebugPrint(String? message, {int? wrapWidth}) {
    // 先输出到控制台（保持原有行为）
    _originalDebugPrint?.call(message, wrapWidth: wrapWidth);

    // 防止递归：AppLogger 内部的 debugPrint 不再次捕获
    if (_isCapturing) return;
    if (message == null || message.isEmpty) return;

    _isCapturing = true;
    try {
      instance._capturePrint(message);
    } finally {
      _isCapturing = false;
    }
  }

  /// 将 debugPrint 消息转为 LogEntry 并写入日志系统
  void _capturePrint(String message) {
    // 智能分类：根据消息内容判断日志级别和分类
    final result = _classifyPrintMessage(message);

    // 跳过低价值日志（AppLogger 自身的节流输出等）
    if (result == null) return;

    _log(result.$1, result.$2, result.$3, detail: result.$4);
  }

  /// 根据 debugPrint 消息内容智能分类
  /// 返回 (level, category, message, detail?) 或 null（跳过）
  (LogLevel, LogCategory, String, String?)? _classifyPrintMessage(
      String message) {
    final msg = message.trim();
    if (msg.isEmpty) return null;

    // 跳过 AppLogger 自身的节流输出（避免递归噪音）
    if (msg.startsWith('[AppLogger]')) return null;

    // 根据前缀符号判断级别
    LogLevel level;
    LogCategory category;

    if (msg.contains('❌') ||
        msg.contains('失败') && !msg.contains('重试')) {
      level = LogLevel.error;
    } else if (msg.contains('⚠️') ||
        msg.contains('警告') ||
        msg.contains('跳过')) {
      level = LogLevel.warning;
    } else if (msg.contains('✅') ||
        msg.contains('成功') ||
        msg.contains('完成')) {
      level = LogLevel.info;
    } else {
      level = LogLevel.debug;
    }

    // 根据内容关键词判断分类
    // 注意：不能用 contains('JS')，因为 'JSON' 包含 'JS' 子串会误分类
    // 用 \bJS\b 单词边界匹配，'JSON' 中的 'JS' 不是单词边界不会匹配
    if (RegExp(r'\bJS\b').hasMatch(msg) ||
        msg.contains('QuickJS') ||
        msg.contains('引擎') ||
        msg.contains('FFI')) {
      category = LogCategory.js;
    } else if (msg.contains('HTTP') ||
        msg.contains('网络') ||
        msg.contains('URL') ||
        msg.contains('搜索') && msg.contains('响应')) {
      category = LogCategory.network;
    } else if (msg.contains('解析') ||
        msg.contains('规则') ||
        msg.contains('搜索结果')) {
      category = LogCategory.parse;
    } else if (msg.contains('Storage') ||
        msg.contains('Hive') ||
        msg.contains('Box') ||
        msg.contains('书源')) {
      category = LogCategory.storage;
    } else if (msg.contains('代理') ||
        msg.contains('CORS') ||
        msg.contains('Proxy')) {
      category = LogCategory.proxy;
    } else {
      category = LogCategory.system;
    }

    return (level, category, msg, null);
  }

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

  // ===== 循环日志去重 =====
  /// 上一条日志的消息（用于去重检测）
  String? _lastLogMessage;
  /// 上一条日志的级别
  LogLevel? _lastLogLevel;
  /// 相同日志连续出现次数
  int _duplicateCount = 0;
  /// 去重阈值：相同消息连续出现超过此次数后合并
  static const int _dedupThreshold = 2;

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
    // 重置去重状态
    _lastLogMessage = null;
    _lastLogLevel = null;
    _duplicateCount = 0;
  }

  void _log(LogLevel level, LogCategory category, String message, {String? detail}) {
    if (level.index < minLevel.index) return;

    // ===== 循环日志去重 =====
    // 相同消息连续出现时，合并为一条摘要，避免循环日志刷屏
    if (_lastLogMessage != null &&
        _lastLogLevel == level &&
        _isSimilarMessage(_lastLogMessage!, message)) {
      _duplicateCount++;
      if (_duplicateCount >= _dedupThreshold) {
        // 更新最后一条日志的消息为合并摘要
        _updateLastLogSummary(message, _duplicateCount + 1);
        return;
      }
    } else {
      _lastLogMessage = message;
      _lastLogLevel = level;
      _duplicateCount = 0;
    }

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
  }

  /// 判断两条消息是否相似（用于循环日志去重）
  /// 提取消息前缀部分比较，忽略数字/URL 等动态部分
  bool _isSimilarMessage(String a, String b) {
    // 完全相同
    if (a == b) return true;
    // 提取前缀（前20个字符或到第一个数字之前的部分）
    final prefixA = _extractPrefix(a);
    final prefixB = _extractPrefix(b);
    return prefixA == prefixB && prefixA.length >= 5;
  }

  /// 提取消息前缀（将数字替换为 # 用于模式匹配）
  String _extractPrefix(String msg) {
    // 取前30个字符，将数字替换为 #
    final truncated = msg.length > 30 ? msg.substring(0, 30) : msg;
    return truncated.replaceAll(RegExp(r'\d+'), '#');
  }

  /// 更新最后一条日志为合并摘要
  void _updateLastLogSummary(String currentMsg, int totalCount) {
    if (_totalWritten == 0) return;
    final lastIdx = (_bufferIndex - 1 + _maxBufferSize) % _maxBufferSize;
    final lastEntry = _buffer[lastIdx];
    if (lastEntry == null) return;

    final summary = LogEntry(
      time: lastEntry.time,
      level: lastEntry.level,
      category: lastEntry.category,
      message: '${lastEntry.message.split(' (重复')[0]} (重复 $totalCount 次)',
      detail: lastEntry.detail,
      sessionId: lastEntry.sessionId,
    );

    _buffer[lastIdx] = summary;
    _controller.add(summary);
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
  // 执行数据日志策略：成功时跳过，仅错误时记录

  void logJsExecute(String engine, String code, {int? codeLength}) {
    // 执行数据日志：成功执行时不记录，避免刷屏
    // 仅在出错时由 logJsError 记录
  }

  void logJsResult(String engine, String? result) {
    // 执行数据日志：成功结果不记录
    // 仅 null/空结果可能是异常，但由调用方决定是否记为 error
  }

  void logJsError(String engine, String errorMsg) {
    _log(LogLevel.error, LogCategory.js, '[$engine] 执行失败', detail: errorMsg);
  }

  void logJsInput(String engine, String? input, {String? tag}) {
    // 执行数据日志：输入不单独记录，避免刷屏
  }

  void logJsOutput(String engine, String? output, {String? outputType, String? tag}) {
    // 执行数据日志：输出不单独记录，避免刷屏
  }

  void logJsTree(String engine, String treeString) {
    // 执行数据日志：执行树不记录，避免大量循环日志
  }

  void logJsStep(String engine, String step, {String? detail}) {
    // 执行数据日志：步骤不记录，避免大量循环日志
  }

  // ===== 规则解析专用 =====
  // 执行数据日志策略：成功时跳过，仅 0 结果/错误时记录

  void logParse(String ruleType, String rule, {String? content}) {
    // 执行数据日志：解析规则不单独记录，避免刷屏
  }

  void logParseResult(String ruleType, int count) {
    // 执行数据日志：仅 0 结果时记录（可能有问题），有结果时跳过
    if (count == 0) {
      warn(LogCategory.parse, '$ruleType 解析完成: 0 条结果（可能规则有误）');
    }
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