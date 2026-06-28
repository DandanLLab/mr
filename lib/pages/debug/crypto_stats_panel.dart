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
  MemoryStats? _memStats;
  JsMemoryStats? _jsMemStats;
  int _cpuCount = 1;
  String _qsVersion = '';
  bool _hasException = false;
  bool _autoRefresh = false;
  Timer? _timer;
  String _promiseVarName = '';
  int _lastPromiseState = -1;
  String _jsValueExpr = '';
  String? _jsValueResult;
  final TextEditingController _promiseCtrl = TextEditingController();
  final TextEditingController _valueExprCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _promiseCtrl.dispose();
    _valueExprCtrl.dispose();
    super.dispose();
  }

  void _refresh() {
    final js = JsEngine.instance;
    setState(() {
      _stats = js.getCryptoStats();
      _cpuCount = js.nativeCpuCount;
      _memStats = MemoryStats.current;
      _jsMemStats = js.getJsMemoryStats();
      _qsVersion = js.quickJsVersion;
      _hasException = js.hasException;
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
    MemoryStats.reset();
    _refresh();
  }

  void _runGc() {
    JsEngine.instance.runGc();
    _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已触发 JS_RunGC'), duration: Duration(seconds: 1)),
    );
  }

  void _checkPromise() {
    final name = _promiseCtrl.text.trim();
    if (name.isEmpty) return;
    final state = JsEngine.instance.promiseState(name);
    setState(() {
      _promiseVarName = name;
      _lastPromiseState = state;
    });
  }

  void _printJsValue() {
    final expr = _valueExprCtrl.text.trim();
    if (expr.isEmpty) return;
    final result = JsEngine.instance.printValue(expr, maxDepth: 2, maxStringLength: 256);
    setState(() {
      _jsValueExpr = expr;
      _jsValueResult = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _stats;
    return Scaffold(
      appBar: AppBar(
        title: const Text('引擎性能统计'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cleaning_services),
            tooltip: '触发 GC',
            onPressed: _runGc,
          ),
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
            const Card(
              child: ListTile(
                leading: Icon(Icons.warning, color: Colors.orange),
                title: Text('JS 引擎未初始化'),
                subtitle: Text('请先初始化书源后再查看统计'),
              ),
            )
          else ...[
            _buildStatGrid(theme, s),
            const SizedBox(height: 12),
            _buildTimingCard(theme, s),
            const SizedBox(height: 12),
            _buildThroughputCard(theme, s),
            const SizedBox(height: 12),
            _buildMemoryCard(theme),
            const SizedBox(height: 12),
            _buildJsEngineCard(theme),
            const SizedBox(height: 12),
            _buildJsMemoryCard(theme),
            const SizedBox(height: 12),
            _buildPromiseMonitorCard(theme),
            const SizedBox(height: 12),
            _buildJsValuePrinterCard(theme),
          ],
        ],
      ),
    );
  }

  /// QuickJS 引擎版本 + 异常状态
  Widget _buildJsEngineCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bolt, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('QuickJS 引擎',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            _buildMemoryRow('版本', _qsVersion, Colors.indigo),
            _buildMemoryRow(
                'context 异常',
                _hasException ? '⚠ 有未捕获异常' : '✓ 无异常',
                _hasException ? Colors.red : Colors.green),
          ],
        ),
      ),
    );
  }

  /// QuickJS 引擎内部内存统计（JS_ComputeMemoryUsage 25 字段）
  Widget _buildJsMemoryCard(ThemeData theme) {
    final j = _jsMemStats;
    if (j == null) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.memory, color: Colors.grey),
          title: Text('QuickJS 引擎内存统计'),
          subtitle: Text('不可用'),
        ),
      );
    }
    final usagePct = j.limitMB > 0
        ? (j.usedKB / (j.limitMB * 1024) * 100).clamp(0, 999)
        : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.storage, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('QuickJS 引擎内存监控',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            _buildMemoryRow('已使用', '${j.usedKB.toStringAsFixed(1)} KB',
                j.usedKB > 1024 ? Colors.orange : Colors.green),
            _buildMemoryRow('内存限额', '${j.limitMB.toStringAsFixed(1)} MB',
                Colors.blue),
            _buildMemoryRow(
                '使用率', '${usagePct.toStringAsFixed(1)}%', Colors.deepPurple),
            _buildMemoryRow('malloc 次数', '${j.mallocCount}', Colors.teal),
            _buildMemoryRow(
                '活跃对象', '${j.totalObjects}', Colors.purple),
            const Divider(),
            _buildMemoryRow('字符串', '${j.strCount} 个 / ${_fmtBytes(j.strSize)}',
                Colors.brown),
            _buildMemoryRow(
                '对象', '${j.objCount} 个 / ${_fmtBytes(j.objSize)}', Colors.brown),
            _buildMemoryRow(
                '属性', '${j.propCount} 个 / ${_fmtBytes(j.propSize)}', Colors.brown),
            _buildMemoryRow(
                'shape', '${j.shapeCount} 个 / ${_fmtBytes(j.shapeSize)}', Colors.brown),
            _buildMemoryRow(
                'JS 函数', '${j.jsFuncCount} 个 / ${_fmtBytes(j.jsFuncSize)}',
                Colors.brown),
            _buildMemoryRow(
                '字节码', _fmtBytes(j.jsFuncCodeSize), Colors.brown),
            _buildMemoryRow(
                'C 函数', '${j.cFuncCount} 个', Colors.brown),
            _buildMemoryRow(
                '数组', '${j.arrayCount} 个', Colors.brown),
            _buildMemoryRow('快数组',
                '${j.fastArrayCount} 个 / ${j.fastArrayElements} 元素', Colors.brown),
            _buildMemoryRow(
                '二进制对象', '${j.binaryObjectCount} 个 / ${_fmtBytes(j.binaryObjectSize)}',
                Colors.brown),
            _buildMemoryRow(
                'atom', '${j.atomCount} 个 / ${_fmtBytes(j.atomSize)}', Colors.brown),
          ],
        ),
      ),
    );
  }

  /// Promise 状态监控（参考 quickjs-ng JS_PromiseState）
  Widget _buildPromiseMonitorCard(ThemeData theme) {
    final label = switch (_lastPromiseState) {
      -1 => '尚未检测',
      0 => '非 Promise 对象',
      1 => '⏳ pending（等待中）',
      2 => '✅ fulfilled（已完成）',
      3 => '❌ rejected（已拒绝）',
      _ => '未知状态 ($_lastPromiseState)',
    };
    final color = switch (_lastPromiseState) {
      2 => Colors.green,
      3 => Colors.red,
      1 => Colors.orange,
      0 => Colors.grey,
      _ => Colors.grey,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sync_problem, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Promise 状态监控',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 4),
            Text('输入 JS 全局变量名，查询其 Promise 状态',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _promiseCtrl,
                    decoration: const InputDecoration(
                      hintText: '例如: bookLoadPromise',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _checkPromise(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _checkPromise,
                  child: const Text('查询'),
                ),
              ],
            ),
            if (_promiseVarName.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildMemoryRow('变量: $_promiseVarName', label, color),
            ],
          ],
        ),
      ),
    );
  }

  /// JS 值流式打印（参考 quickjs-zh JS_PrintValue）
  Widget _buildJsValuePrinterCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.print, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('JS 值打印（JS_PrintValue）',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 4),
            Text('输入 JS 表达式，输出其字符串表示（maxDepth=2, maxLen=256）',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _valueExprCtrl,
                    decoration: const InputDecoration(
                      hintText: '例如: typeof book',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _printJsValue(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _printJsValue,
                  child: const Text('打印'),
                ),
              ],
            ),
            if (_jsValueExpr.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('表达式: $_jsValueExpr',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  _jsValueResult ?? '(null 或不可用)',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
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

  /// P5: C 层内存监控面板
  Widget _buildMemoryCard(ThemeData theme) {
    final m = _memStats;
    if (m == null) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.memory, color: Colors.grey),
          title: Text('C 层内存统计'),
          subtitle: Text('不可用'),
        ),
      );
    }
    final handles = MemoryStats.activeHandleCount;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.memory, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('C 层内存监控',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            _buildMemoryRow('当前持有', '${m.currentKB.toStringAsFixed(1)} KB',
                m.currentKB > 1024 ? Colors.orange : Colors.green),
            _buildMemoryRow('峰值', '${m.peakKB.toStringAsFixed(1)} KB',
                Colors.blue),
            _buildMemoryRow(
                '分配次数', '${m.totalAllocs}', Colors.teal),
            _buildMemoryRow(
                '释放次数', '${m.totalFrees}', Colors.teal),
            _buildMemoryRow(
                '活跃句柄', '$handles', Colors.purple),
            if (m.allocFailures > 0)
              _buildMemoryRow(
                  '分配失败', '${m.allocFailures}', Colors.red),
          ],
        ),
      ),
    );
  }

  Widget _buildMemoryRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: color, fontSize: 13)),
          Text(value, style: TextStyle(
              color: color, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
