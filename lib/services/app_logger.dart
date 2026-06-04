import 'dart:async';
import 'package:flutter/foundation.dart';

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

  const LogEntry({
    required this.time,
    required this.level,
    required this.category,
    required this.message,
    this.detail,
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

  String toShortString() {
    final t = '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}.${time.millisecond.toString().padLeft(3, '0')}';
    return '$levelIcon [$t] [${category.label}] $message';
  }

  String toFullString() {
    final base = toShortString();
    if (detail != null && detail!.isNotEmpty) {
      return '$base\n$detail';
    }
    return base;
  }
}

/// 应用日志工具
/// 支持分类、级别过滤、缓冲区、流式监听
class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  /// 日志缓冲区最大条数
  static const int maxBufferSize = 2000;

  /// 日志缓冲区
  final List<LogEntry> _buffer = [];

  /// 日志流控制器
  final _controller = StreamController<LogEntry>.broadcast();

  /// 日志流（供 UI 监听）
  Stream<LogEntry> get stream => _controller.stream;

  /// 当前最低显示级别
  LogLevel minLevel = kDebugMode ? LogLevel.verbose : LogLevel.info;

  /// 获取所有日志
  List<LogEntry> get logs => List.unmodifiable(_buffer);

  /// 获取指定分类的日志
  List<LogEntry> getLogs({LogCategory? category, LogLevel? minLevel}) {
    return _buffer.where((e) {
      if (category != null && e.category != category) return false;
      if (minLevel != null && e.level.index < minLevel.index) return false;
      return true;
    }).toList();
  }

  /// 清空日志
  void clear() {
    _buffer.clear();
  }

  void _log(LogLevel level, LogCategory category, String message, {String? detail}) {
    if (level.index < minLevel.index) return;

    final entry = LogEntry(
      time: DateTime.now(),
      level: level,
      category: category,
      message: message,
      detail: detail,
    );

    _buffer.add(entry);
    if (_buffer.length > maxBufferSize) {
      _buffer.removeRange(0, _buffer.length - maxBufferSize);
    }

    _controller.add(entry);

    // 同时输出到控制台
    if (kDebugMode) {
      debugPrint(entry.toShortString());
      if (detail != null) {
        debugPrint('  $detail');
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

  /// 记录网络请求开始
  void logRequest(String method, String url, {Map<String, String>? headers}) {
    info(LogCategory.network, '$method $url', detail: headers?.isNotEmpty == true
        ? 'Headers: ${headers!.entries.take(5).map((e) => '${e.key}: ${e.value}').join(', ')}'
        : null);
  }

  /// 记录网络请求成功
  void logResponse(String url, int statusCode, int bodyLength) {
    info(LogCategory.network, '← $statusCode $url (${_formatSize(bodyLength)})');
  }

  /// 记录网络请求失败
  void logRequestError(String url, String error) {
    error;
  }

  // ===== JS 引擎专用 =====

  /// 记录 JS 执行
  void logJsExecute(String engine, String code, {int? codeLength}) {
    debug(LogCategory.js, '[$engine] 执行JS (${codeLength ?? code.length} chars)',
      detail: code.length > 200 ? '${code.substring(0, 200)}...' : code);
  }

  /// 记录 JS 执行结果
  void logJsResult(String engine, String? result) {
    debug(LogCategory.js, '[$engine] 结果: ${result != null ? "${result.length} chars" : "null"}',
      detail: result != null && result.length > 200 ? '${result.substring(0, 200)}...' : result);
  }

  /// 记录 JS 执行失败
  void logJsError(String engine, String error) {
    error;
  }

  // ===== 规则解析专用 =====

  /// 记录规则解析
  void logParse(String ruleType, String rule, {String? content}) {
    debug(LogCategory.parse, '解析$ruleType: $rule',
      detail: content != null ? '内容长度: ${content.length}' : null);
  }

  /// 记录解析结果
  void logParseResult(String ruleType, int count) {
    info(LogCategory.parse, '$ruleType 解析完成: $count 条结果');
  }

  String _formatSize(int chars) {
    if (chars < 1024) return '$chars B';
    if (chars < 1024 * 1024) return '${(chars / 1024).toStringAsFixed(1)} KB';
    return '${(chars / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
