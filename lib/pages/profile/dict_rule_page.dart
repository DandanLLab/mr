import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/storage_service.dart';

/// 字典规则模型
class DictRule {
  final String id;
  final String name;
  final String url;
  final String rule;
  final bool isEnabled;

  DictRule({
    required this.id,
    required this.name,
    required this.url,
    this.rule = '',
    this.isEnabled = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'rule': rule,
    'isEnabled': isEnabled,
  };

  factory DictRule.fromJson(Map<String, dynamic> json) => DictRule(
    id: json['id'] ?? '',
    name: json['name'] ?? '',
    url: json['url'] ?? '',
    rule: json['rule'] ?? '',
    isEnabled: json['isEnabled'] ?? true,
  );

  DictRule copyWith({
    String? id,
    String? name,
    String? url,
    String? rule,
    bool? isEnabled,
  }) => DictRule(
    id: id ?? this.id,
    name: name ?? this.name,
    url: url ?? this.url,
    rule: rule ?? this.rule,
    isEnabled: isEnabled ?? this.isEnabled,
  );
}

class DictRulePage extends StatefulWidget {
  const DictRulePage({super.key});

  @override
  State<DictRulePage> createState() => _DictRulePageState();
}

class _DictRulePageState extends State<DictRulePage> {
  List<DictRule> _rules = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRules();
  }

  Future<void> _loadRules() async {
    final data = StorageService.instance.getCachedData('dict_rules');
    if (data != null && data is String && data.isNotEmpty) {
      final decoded = jsonDecode(data) as List;
      setState(() {
        _rules = decoded
            .map((e) => DictRule.fromJson(e as Map<String, dynamic>))
            .toList();
        _isLoading = false;
      });
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveRules() async {
    await StorageService.instance.cacheData(
      'dict_rules',
      jsonEncode(_rules.map((r) => r.toJson()).toList()),
    );
  }

  void _addRule() {
    _showEditDialog(null);
  }

  void _editRule(DictRule rule) {
    _showEditDialog(rule);
  }

  void _showEditDialog(DictRule? rule) {
    final nameController = TextEditingController(text: rule?.name ?? '');
    final urlController = TextEditingController(text: rule?.url ?? '');
    final ruleController = TextEditingController(text: rule?.rule ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(rule == null ? '添加字典' : '编辑字典'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '字典名称',
                  hintText: '如：汉典',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: '字典URL',
                  hintText: '如：https://www.zdic.net/hans/',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ruleController,
                decoration: const InputDecoration(
                  labelText: '解析规则',
                  hintText: '可选，用于解析字典内容',
                ),
                maxLines: 3,
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
              if (nameController.text.isEmpty || urlController.text.isEmpty) {
                return;
              }

              final newRule = DictRule(
                id: rule?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
                name: nameController.text,
                url: urlController.text,
                rule: ruleController.text,
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
    );
  }

  void _deleteRule(DictRule rule) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除字典'),
        content: Text('确定要删除字典"${rule.name}"吗？'),
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

  Future<void> _toggleRule(DictRule rule) async {
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
        title: const Text('字典规则'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加字典',
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
                      Icon(Icons.translate, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      const Text('暂无字典规则', style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _addRule,
                        icon: const Icon(Icons.add),
                        label: const Text('添加字典'),
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
                        rule.url,
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
