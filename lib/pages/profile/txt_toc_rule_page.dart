import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/storage_service.dart';
import '../../utils/design_tokens.dart';

/// TXT目录规则模型
class TxtTocRule {
  final String id;
  final String name;
  final String rule;
  final bool isEnabled;

  TxtTocRule({
    required this.id,
    required this.name,
    required this.rule,
    this.isEnabled = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'rule': rule,
    'isEnabled': isEnabled,
  };

  factory TxtTocRule.fromJson(Map<String, dynamic> json) => TxtTocRule(
    id: json['id'] ?? '',
    name: json['name'] ?? '',
    rule: json['rule'] ?? '',
    isEnabled: json['isEnabled'] ?? true,
  );

  TxtTocRule copyWith({
    String? id,
    String? name,
    String? rule,
    bool? isEnabled,
  }) => TxtTocRule(
    id: id ?? this.id,
    name: name ?? this.name,
    rule: rule ?? this.rule,
    isEnabled: isEnabled ?? this.isEnabled,
  );
}

class TxtTocRulePage extends StatefulWidget {
  const TxtTocRulePage({super.key});

  @override
  State<TxtTocRulePage> createState() => _TxtTocRulePageState();
}

class _TxtTocRulePageState extends State<TxtTocRulePage> {
  List<TxtTocRule> _rules = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRules();
  }

  Future<void> _loadRules() async {
    final data = StorageService.instance.getCachedData('txt_toc_rules');
    if (data != null && data is String && data.isNotEmpty) {
      final decoded = jsonDecode(data) as List;
      setState(() {
        _rules = decoded
            .map((e) => TxtTocRule.fromJson(e as Map<String, dynamic>))
            .toList();
        _isLoading = false;
      });
    } else {
      // 添加默认规则
      _rules = [
        TxtTocRule(
          id: 'default_1',
          name: '章节标题',
          rule: r'^第[零一二三四五六七八九十百千万\d]+[章节回集卷部篇]\s*.+$',
        ),
        TxtTocRule(
          id: 'default_2',
          name: '数字章节',
          rule: r'^\d+[\.\s、].+$',
        ),
      ];
      await _saveRules();
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveRules() async {
    await StorageService.instance.cacheData(
      'txt_toc_rules',
      jsonEncode(_rules.map((r) => r.toJson()).toList()),
    );
  }

  void _addRule() {
    _showEditDialog(null);
  }

  void _editRule(TxtTocRule rule) {
    _showEditDialog(rule);
  }

  void _showEditDialog(TxtTocRule? rule) {
    final nameController = TextEditingController(text: rule?.name ?? '');
    final ruleController = TextEditingController(text: rule?.rule ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(rule == null ? '添加规则' : '编辑规则'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '规则名称',
                  hintText: '如：章节标题',
                ),
              ),
              const SizedBox(height: DesignTokens.spacingLg),
              TextField(
                controller: ruleController,
                decoration: const InputDecoration(
                  labelText: '正则表达式',
                  hintText: r'如：^第.+章.+$',
                ),
                maxLines: 3,
              ),
              const SizedBox(height: DesignTokens.spacingSm),
              Text(
                '提示：规则用于匹配TXT文件中的章节标题行',
                style: TextStyle(
                  fontSize: DesignTokens.fontCaption,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
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
              if (nameController.text.isEmpty || ruleController.text.isEmpty) {
                return;
              }

              final newRule = TxtTocRule(
                id: rule?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
                name: nameController.text,
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

  void _deleteRule(TxtTocRule rule) {
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

  Future<void> _toggleRule(TxtTocRule rule) async {
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
        title: const Text('TXT目录规则'),
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
                      Icon(Icons.text_snippet, size: DesignTokens.emptyIconSize, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(height: DesignTokens.spacingLg),
                      Text('暂无TXT目录规则', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      const SizedBox(height: DesignTokens.spacingSm),
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
                            : Theme.of(context).colorScheme.outline,
                      ),
                      title: Text(rule.name),
                      subtitle: Text(
                        rule.rule,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: DesignTokens.fontCaption,
                        ),
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
