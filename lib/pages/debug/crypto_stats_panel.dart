import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/native/js_engine.dart';
import '../../services/native/quickjs_runtime_stub.dart'
    if (dart.library.io) '../../services/native/quickjs_runtime.dart';

/// 加密解密性能统计面板（Phase 6）
///
/// 实时显示 C 原生加密路径的累计统计：
/// - 调用次数、输入/输出字节
/// - 平均/最大/最小单次耗时
/// - 吞吐率、压缩比
/// - CPU 核心数（并行能力指示）
///
/// 支持手动刷新、自动刷新、重置计数器
class CryptoStatsPanel extends StatefulWidget {
  const CryptoStatsPanel({super.key});

  @override
  State<CryptoStatsPanel> createState() => _CryptoStatsPanelState();
}

class _CryptoStatsPanelState extends State<CryptoStatsPanel> {
  CryptoStats? _stats;
  int _cpuCount = 1;
  bool _autoRefresh = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _refresh() {
    final js = JsEngine.instance;
    setState(() {
      _stats = js.getCryptoStats();
      _cpuCount = js.nativeCpuCount;
    });
  }

  void _toggleAutoRefresh(bool value) {
    setState(() => _autoRefresh = value);
    if (value) {
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _reset() {
    JsEngine.instance.resetCryptoStats();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _stats;
    return Scaffold(
      appBar: AppBar(
        title: const Text('加密性能统计'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '重置计数器',
            onPressed: _reset,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // CPU 核心数 + 自动刷新开关
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.memory, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('CPU 逻辑核心数', style: theme.textTheme.bodySmall),
                        Text('$_cpuCount',
                            style: theme.textTheme.headlineSmall),
                      ],
                    ),
                  ),
                  Switch(
                    value: _autoRefresh,
                    onChanged: _toggleAutoRefresh,
                  ),
                  const SizedBox(width: 8),
                  Text('自动刷新', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (s == null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.warning, color: Colors.orange),
                title: const Text('JS 引擎未初始化'),
                subtitle: const Text('请先初始化书源后再查看统计'),
              ),
            )
          else ...[
            _buildStatGrid(theme, s),
            const SizedBox(height: 12),
            _buildTimingCard(theme, s),
            const SizedBox(height: 12),
            _buildThroughputCard(theme, s),
          ],
        ],
      ),
    );
  }

  Widget _buildStatGrid(ThemeData theme, CryptoStats s) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.2,
      children: [
        _buildMetricCard(theme, '总调用次数', '${s.totalCalls}', Icons.functions),
        _buildMetricCard(theme, '总输入', _formatBytes(s.totalBytesIn),
            Icons.arrow_downward, Colors.blue),
        _buildMetricCard(theme, '总输出', _formatBytes(s.totalBytesOut),
            Icons.arrow_upward, Colors.green),
        _buildMetricCard(theme, '总耗时', _formatDuration(s.totalUs),
            Icons.schedule, Colors.purple),
      ],
    );
  }

  Widget _buildMetricCard(
    ThemeData theme,
    String label,
    String value,
    IconData icon, [
    Color? color,
  ]) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(children: [
              Icon(icon, size: 16, color: color ?? theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(label, style: theme.textTheme.bodySmall),
            ]),
            const SizedBox(height: 4),
            Text(value,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildTimingCard(ThemeData theme, CryptoStats s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('单次耗时分布（微秒）',
                style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _buildTimingRow(theme, '平均', s.totalCalls == 0 ? 0 : s.totalUs / s.totalCalls),
            _buildTimingRow(theme, '最大', s.maxUs.toDouble()),
            _buildTimingRow(theme, '最小', s.minUs.toDouble()),
            const SizedBox(height: 8),
            // 简单柱状图：max vs avg
            if (s.totalCalls > 0) ...[
              const Divider(),
              Text('最大/平均比: ${s.maxUs == 0 ? 0 : (s.totalUs / s.totalCalls / s.maxUs).toStringAsFixed(2)}',
                  style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTimingRow(ThemeData theme, String label, double us) {
    final ms = us / 1000;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(
            us < 1000
                ? '${us.toStringAsFixed(1)} µs'
                : '${ms.toStringAsFixed(2)} ms',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThroughputCard(ThemeData theme, CryptoStats s) {
    final throughput = s.totalUs == 0
        ? 0.0
        : (s.totalBytesIn / 1024 / 1024) / (s.totalUs / 1000000);
    final ratio = s.totalBytesIn == 0
        ? 0.0
        : s.totalBytesOut / s.totalBytesIn;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('吞吐率与压缩比',
                style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _buildTimingRow(theme, '吞吐率', throughput <= 0 ? 0 : throughput * 1000),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('输入→输出比', style: theme.textTheme.bodyMedium),
                  Text('${ratio.toStringAsFixed(2)}×',
                      style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (s.totalCalls > 0)
              Text(
                throughput > 10
                    ? '⚡ 吞吐率优异（>10 MB/s）'
                    : throughput > 1
                        ? '✓ 吞吐率正常'
                        : '○ 数据量较小，吞吐率仅供参考',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: throughput > 10 ? Colors.green : Colors.grey,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  String _formatDuration(int us) {
    if (us < 1000) return '$us µs';
    if (us < 1000000) return '${(us / 1000).toStringAsFixed(1)} ms';
    return '${(us / 1000000).toStringAsFixed(2)} s';
  }
}
