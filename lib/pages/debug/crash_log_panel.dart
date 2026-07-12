import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/crash_log_service.dart';
import '../../services/app_logger.dart';

/// 崩溃日志显示面板
///
/// 替换原有的加密性能统计面板，专注展示：
/// - 本次会话的崩溃日志列表
/// - 一键复制/导出
/// - 自动导出到文件
/// - 错误计数 + 会话追踪
class CrashLogPanel extends StatefulWidget {
  const CrashLogPanel({super.key});

  @override
  State<CrashLogPanel> createState() => _CrashLogPanelState();
}

class _CrashLogPanelState extends State<CrashLogPanel> {
  final _crashService = CrashLogService.instance;
  List<CrashLogEntry> _entries = [];
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // 每 2 秒自动刷新（轻量）
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) => _load());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _load() {
    setState(() {
      _entries = _crashService.entries;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('崩溃日志'),
            if (_crashService.totalErrorCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red.shade700,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${_crashService.totalErrorCount}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '复制全部',
            onPressed: _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.file_download),
            tooltip: '导出到文件',
            onPressed: _exportToFile,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空',
            onPressed: _clear,
          ),
        ],
      ),
      body: _entries.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 64, color: Colors.green.shade300),
                  const SizedBox(height: 16),
                  Text('暂无崩溃日志',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: Colors.grey)),
                  const SizedBox(height: 8),
                  Text(
                    '会话 ${_crashService.sessionId}',
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                  ),
                  const SizedBox(height: 4),
                  Text('运行 ${_crashService.uptimeSeconds} 秒',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.grey)),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _entries.length,
              itemBuilder: (context, index) {
                final entry = _entries[index];
                return _CrashLogCard(entry: entry, index: index);
              },
            ),
    );
  }

  void _copyAll() {
    final text = _crashService.exportLogs();
    Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('崩溃日志已复制到剪贴板'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _exportToFile() async {
    final path = await AppLogger.instance.exportLogsToFile();
    if (!mounted) return;
    if (path != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('日志已导出: $path'),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(label: '复制路径', onPressed: () {
            Clipboard.setData(ClipboardData(text: path));
          }),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('导出失败：暂无日志')),
      );
    }
  }

  Future<void> _clear() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清空'),
        content: const Text('清空后无法恢复，确定要继续吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _crashService.clear();
      _load();
    }
  }
}

/// 单个崩溃日志卡片
class _CrashLogCard extends StatelessWidget {
  final CrashLogEntry entry;
  final int index;

  const _CrashLogCard({required this.entry, required this.index});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = '${entry.time.hour.toString().padLeft(2, '0')}:'
        '${entry.time.minute.toString().padLeft(2, '0')}:'
        '${entry.time.second.toString().padLeft(2, '0')}';

    final icon = switch (entry.type) {
      'flutter' => Icons.flutter_dash,
      'zone' => Icons.warning_amber,
      'isolate' => Icons.memory,
      _ => Icons.bug_report,
    };

    final color = switch (entry.type) {
      'flutter' => Colors.red,
      'zone' => Colors.orange,
      'isolate' => Colors.purple,
      _ => Colors.blueGrey,
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Text(
          '[$timeStr] ${entry.type}',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          entry.error.length > 120
              ? '${entry.error.substring(0, 120)}...'
              : entry.error,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.copy, size: 16),
              tooltip: '复制本条',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: entry.toFullString()));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已复制'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            const Icon(Icons.expand_more),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('会话', entry.sessionId),
                _row('类型', entry.type),
                const Divider(height: 12),
                SelectableText(
                  entry.error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: Colors.red.shade800,
                  ),
                ),
                if (entry.stackTrace != null && entry.stackTrace!.isNotEmpty) ...[
                  const Divider(height: 12),
                  Text('堆栈:', style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  )),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: SelectableText(
                      entry.stackTrace!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(
            fontWeight: FontWeight.w600, fontSize: 12, color: Colors.grey)),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}