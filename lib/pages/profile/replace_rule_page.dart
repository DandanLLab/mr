import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/storage_service.dart';

/// 替换规则模型
class ReplaceRule {
  final String id;
  final String name;
  final String pattern;
  final String replacement;
  final bool isRegex;
  final bool isEnabled;

  ReplaceRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.isRegex = false,
    this.isEnabled = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'pattern': pattern,
    'replacement': replacement,
    'isRegex': isRegex,
    'isEnabled': isEnabled,
  };

  factory ReplaceRule.fromJson(Map<String, dynamic> json) => ReplaceRule(
    id: json['id'] ?? '',
    name: json['name'] ?? '',
    pattern: json['pattern'] ?? '',
    replacement: json['replacement'] ?? '',
    isRegex: json['isRegex'] ?? false,
    isEnabled: json['isEnabled'] ?? true,
  );

  ReplaceRule copyWith({
    String? id,
    String? name,
    String? pattern,
    String? replacement,
    bool? isRegex,
    bool? isEnabled,
  }) => ReplaceRule(
    id: id ?? this.id,
    name: name ?? this.name,
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    isRegex: isRegex ?? this.isRegex,
    isEnabled: isEnabled ?? this.isEnabled,
  );
}

class ReplaceRulePage extends StatefulWidget {
  const ReplaceRulePage({super.key});

  @override
  State<ReplaceRulePage> createState() => _ReplaceRulePageState();
}

class _ReplaceRulePageState extends State<ReplaceRulePage> {
  List<ReplaceRule> _rules = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRules();
  }

  Future<void> _loadRules() async {
    final data = StorageService.instance.getCachedData('replace_rules');
    if (data != null && data is String && data.isNotEmpty) {
      final decoded = jsonDecode(data) as List;
      setState(() {
        _rules = decoded
            .map((e) => ReplaceRule.fromJson(e as Map<String, dynamic>))
            .toList();
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveRules() async {
    await StorageService.instance.cacheData(
      'replace_rules',
      jsonEncode(_rules.map((r) => r.toJson()).toList()),
    );
  }

  void _addRule() {
    _showEditDialog(null);
  }

  void _editRule(ReplaceRule rule) {
    _showEditDialog(rule);
  }

  void _showEditDialog(ReplaceRule? rule) {
    final nameController = TextEditingController(text: rule?.name ?? '');
    final patternController = TextEditingController(text: rule?.pattern ?? '');
    final replacementController = TextEditingController(text: rule?.replacement ?? '');
    bool isRegex = rule?.isRegex ?? false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(rule == null ? '添加规则' : '编辑规则'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '规则名称',
                    hintText: '如：去除广告',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: patternController,
                  decoration: const InputDecoration(
                    labelText: '匹配模式',
                    hintText: '要替换的文本或正则表达式',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: replacementController,
                  decoration: const InputDecoration(
                    labelText: '替换为',
                    hintText: '留空则删除匹配内容',
                  ),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: const Text('使用正则表达式'),
                  value: isRegex,
                  onChanged: (value) => setDialogState(() => isRegex = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (nameController.text.isEmpty || patternController.text.isEmpty) {
                  return;
                }

                final newRule = ReplaceRule(
                  id: rule?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
                  name: nameController.text,
                  pattern: patternController.text,
                  replacement: replacementController.text,
                  isRegex: isRegex,
                  isEnabled: rule?.isEnabled ?? true,
                );

                setState(() {
                  if (rule == null) {
                    _rules.add(newRule);
                  } else {
                    final index = _rules.indexWhere((r) => r.id == rule.id);
                    if (index >= 0) {
                      _rules[index] = newRule;
                    }
                  }
                });

                await _saveRules();
                Navigator.pop(context);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  void _deleteRule(ReplaceRule rule) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除规则'),
        content: Text('确定要删除规则"${rule.name}"吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              setState(() => _rules.removeWhere((r) => r.id == rule.id));
              await _saveRules();
              Navigator.pop(context);
            },
            child: Text('确定', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleRule(ReplaceRule rule) async {
    setState(() {
      final index = _rules.indexWhere((r) => r.id == rule.id);
      if (index >= 0) {
        _rules[index] = rule.copyWith(isEnabled: !rule.isEnabled);
      }
    });
    await _saveRules();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('替换净化'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加规则',
            onPressed: _addRule,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _rules.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.find_replace, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      const Text('暂无替换规则', style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _addRule,
                        icon: const Icon(Icons.add),
                        label: const Text('添加规则'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _rules.length,
                  itemBuilder: (context, index) {
                    final rule = _rules[index];
                    return ListTile(
                      leading: Icon(
                        rule.isEnabled ? Icons.check_circle : Icons.check_circle_outline,
                        color: rule.isEnabled
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey,
                      ),
                      title: Text(rule.name),
                      subtitle: Text(
                        '${rule.isRegex ? '正则: ' : ''}${rule.pattern}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit),
                            tooltip: '编辑',
                            onPressed: () => _editRule(rule),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: '删除',
                            onPressed: () => _deleteRule(rule),
                          ),
                        ],
                      ),
                      onTap: () => _toggleRule(rule),
                    );
                  },
                ),
    );
  }
}
