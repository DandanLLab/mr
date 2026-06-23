import 'package:flutter/material.dart';
import '../../widgets/android_switch.dart';

/// AI 设置页面 - 参考原版 legado-main pref_config_ai.xml
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  bool _aiAssistantEnabled = false;
  bool _aiEnterToSend = true;
  bool _aiTavilyEnabled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 设置'),
      ),
      body: ListView(
        children: [
          // AI 助手
          _buildCategoryTitle('AI 助手'),
          _buildSection([
            _buildSwitchItem(
              title: '启用 AI',
              subtitle: '启用后长按搜索键进入 AI 页面',
              value: _aiAssistantEnabled,
              onChanged: (v) => setState(() => _aiAssistantEnabled = v),
            ),
            _buildListItem(
              title: '系统提示词',
              subtitle: '设置 AI 的身份、工具调用规则和回答风格',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            _buildListItem(
              title: '导入默认技能',
              subtitle: '导入内置的技能模板',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            _buildListItem(
              title: '技能提示词',
              subtitle: '暂无技能',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            _buildListItem(
              title: '管理原生工具',
              subtitle: '启用或停用内置工具能力',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            _buildSwitchItem(
              title: '回车发送',
              subtitle: '开启后按回车直接发送；关闭后只能点击发送按钮发送',
              value: _aiEnterToSend,
              onChanged: (v) => setState(() => _aiEnterToSend = v),
            ),
            _buildListItem(
              title: '上下文压缩',
              subtitle: '自动压缩对话上下文',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            _buildListItem(
              title: '人设管理',
              subtitle: '暂无人设',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            _buildListItem(
              title: '图片画廊',
              subtitle: '查看 AI 生成的图片',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            _buildListItem(
              title: '图片提供商管理',
              subtitle: '暂无图片提供商',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
          ]),

          // 提供商
          _buildCategoryTitle('提供商'),
          _buildSection([
            _buildListItem(
              title: '管理提供商',
              subtitle: '暂无提供商',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
          ]),

          // MCP 服务器
          _buildCategoryTitle('MCP 服务器'),
          _buildSection([
            _buildListItem(
              title: '添加 MCP 服务器',
              subtitle: '添加 Streamable HTTP MCP 接口',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            _buildListItem(
              title: '管理 MCP 服务器',
              subtitle: '暂无 MCP 服务器',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
          ]),

          // 联网工具
          _buildCategoryTitle('联网工具'),
          _buildSection([
            _buildSwitchItem(
              title: '启用 Tavily 搜索',
              subtitle: '将 Tavily 暴露给 AI 作为实时联网搜索工具',
              value: _aiTavilyEnabled,
              onChanged: (v) => setState(() => _aiTavilyEnabled = v),
            ),
            _buildListItem(
              title: 'Tavily API Key',
              subtitle: '点按填写 Tavily API Key',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            _buildListItem(
              title: 'Tavily 接口地址',
              subtitle: 'https://api.tavily.com/search',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            _buildListItem(
              title: '默认主题',
              subtitle: '通用',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            _buildListItem(
              title: '默认深度',
              subtitle: '基础',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            _buildListItem(
              title: '默认结果数',
              subtitle: '5',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('该功能开发中，敬请期待'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
          ]),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildCategoryTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.secondary,
        ),
      ),
    );
  }

  Widget _buildSection(List<Widget> children) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.onSurface.withValues(alpha: 0.04),
          width: 1,
        ),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildListItem({
    required String title,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      title: Text(
        title,
        style: TextStyle(
          color: isDark ? Colors.white : const Color(0xFF212121),
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white70 : const Color(0xFF757575),
              ),
            )
          : null,
      trailing: Icon(
        Icons.chevron_right,
        color: isDark ? Colors.white54 : const Color(0xFFBDBDBD),
      ),
      onTap: onTap,
    );
  }

  Widget _buildSwitchItem({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 使用强调色（secondary）而不是主色（primary），参考原版 SwitchPreference
    final accentColor = Theme.of(context).colorScheme.secondary;

    return InkWell(
      onTap: () => onChanged(!value),
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      color: isDark ? Colors.white : const Color(0xFF212121),
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark ? Colors.white70 : const Color(0xFF757575),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AndroidSwitch(
              value: value,
              onChanged: onChanged,
              accentColor: accentColor,
              isDark: isDark,
            ),
          ],
        ),
      ),
    );
  }
}