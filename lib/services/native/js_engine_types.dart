// ===== JsEngineType =====

/// JS 引擎类型枚举（保留用于 book_source.dart / analyze_rule.dart 兼容）
enum JsEngineType { quickjs }

// ===== JS 执行追踪（保留用于 analyze_rule.dart 兼容）=====

/// JS 执行追踪节点
class JsTraceNode {
  final String id;
  final String engine;
  final String caller;
  final String? ruleStep;
  final String codePreview;
  final String? inputPreview;
  String? outputPreview;
  String? outputType;
  String? error;
  final DateTime startTime;
  DateTime? endTime;
  final List<JsTraceNode> children = [];
  final JsTraceNode? parent;

  JsTraceNode({
    required this.id,
    required this.engine,
    required this.caller,
    this.ruleStep,
    required this.codePreview,
    this.inputPreview,
    this.parent,
  }) : startTime = DateTime.now();

  Duration? get duration => endTime?.difference(startTime);

  String toTreeString({int indent = 0}) {
    final prefix = '  ' * indent;
    final buf = StringBuffer();
    final dur = duration != null ? '${duration!.inMilliseconds}ms' : '?';
    final errMark = error != null ? ' [ERROR]' : '';
    buf.writeln('$prefix├─ [$engine] $caller${ruleStep != null ? " | $ruleStep" : ""} ($dur)$errMark');
    final codeLines = codePreview.split('\n');
    for (final line in codeLines.take(3)) {
      buf.writeln('$prefix│  code: ${line.length > 80 ? '${line.substring(0, 80)}...' : line}');
    }
    if (codeLines.length > 3) {
      buf.writeln('$prefix│  code: ... (${codeLines.length - 3} more lines)');
    }
    if (inputPreview != null && inputPreview!.isNotEmpty) {
      buf.writeln('$prefix│  input: ${inputPreview!.replaceAll('\n', '\\n')}');
    }
    if (outputPreview != null && outputPreview!.isNotEmpty) {
      buf.writeln('$prefix│  output($outputType): ${outputPreview!.replaceAll('\n', '\\n')}');
    }
    if (error != null) {
      buf.writeln('$prefix│  error: $error');
    }
    for (final child in children) {
      buf.write(child.toTreeString(indent: indent + 1));
    }
    return buf.toString();
  }
}

/// JS 执行追踪器（全局单例）
class JsTracer {
  JsTracer._();
  static final JsTracer instance = JsTracer._();

  bool enabled = false;
  final List<JsTraceNode> _stack = [];
  final List<JsTraceNode> _roots = [];

  /// 追踪栈是否为空
  bool get isStackEmpty => _stack.isEmpty;

  JsTraceNode beginRoot(String caller, String engine, String codePreview, {String? inputPreview, String? ruleStep}) {
    final node = JsTraceNode(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      engine: engine,
      caller: caller,
      codePreview: codePreview,
      inputPreview: inputPreview,
      ruleStep: ruleStep,
    );
    _roots.add(node);
    return node;
  }

  JsTraceNode addChild(String caller, String engine, String codePreview, {String? inputPreview, String? ruleStep}) {
    final parent = _stack.isEmpty ? (_roots.isEmpty ? null : _roots.last) : _stack.last;
    final node = JsTraceNode(
      id: '${DateTime.now().microsecondsSinceEpoch}_${_stack.length}',
      engine: engine,
      caller: caller,
      codePreview: codePreview,
      inputPreview: inputPreview,
      ruleStep: ruleStep,
      parent: parent,
    );
    parent?.children.add(node);
    return node;
  }

  void push(JsTraceNode node) {
    _stack.add(node);
  }

  void pop({String? outputPreview, String? outputType, String? error}) {
    if (_stack.isEmpty) return;
    final node = _stack.removeLast();
    node.endTime = DateTime.now();
    node.outputPreview = outputPreview;
    node.outputType = outputType;
    node.error = error;
  }

  String getTreeString() {
    final buf = StringBuffer();
    for (final root in _roots) {
      buf.write(root.toTreeString());
    }
    return buf.toString();
  }

  void clear() {
    _stack.clear();
    _roots.clear();
  }
}
