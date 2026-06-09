import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../providers/bookshelf_provider.dart';
import '../../providers/discovery_provider.dart';
import 'book_source_manage_page.dart';
import '../../routes/app_routes.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String _nickname = '小蛋子';
  int _bookCount = 0;
  int _sourceCount = 0;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  void _loadStats() {
    final bookshelfProvider = context.read<BookshelfProvider>();
    final discoveryProvider = context.read<DiscoveryProvider>();

    setState(() {
      _bookCount = bookshelfProvider.books.length;
      _sourceCount = discoveryProvider.bookSources.length;
      _nickname = context.read<AppProvider>().nickname ?? '小蛋子';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top,
        ),
        children: [
          // 顶部标题栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Text(
                  '我的',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.help_outline),
                  tooltip: '帮助',
                  onPressed: () {
                    _showHelpDialog();
                  },
                ),
              ],
            ),
          ),
          // 书源管理（无分类标题）
          _buildSection([
            _buildListItem(
              icon: Icons.book,
              title: '书源管理',
              subtitle: '已导入 $_sourceCount 个书源',
              onTap: () => _showBookSourceManagement(),
            ),
            _buildListItem(
              icon: Icons.text_snippet,
              title: 'TXT目录规则',
              subtitle: '管理TXT文件目录解析规则',
              onTap: () => Navigator.pushNamed(context, AppRoutes.txtTocRule),
            ),
            _buildListItem(
              icon: Icons.find_replace,
              title: '替换净化',
              subtitle: '内容替换规则管理',
              onTap: () => Navigator.pushNamed(context, AppRoutes.replaceRule),
            ),
            _buildListItem(
              icon: Icons.translate,
              title: '字典规则',
              subtitle: '字典翻译规则管理',
              onTap: () => Navigator.pushNamed(context, AppRoutes.dictRule),
            ),
            Consumer<AppProvider>(
              builder: (context, provider, child) {
                return _buildListItem(
                  icon: Icons.palette,
                  title: '主题模式',
                  subtitle: _getThemeModeText(provider.themeMode),
                  onTap: () => _showThemeDialog(provider),
                );
              },
            ),
            _buildSwitchItem(
              icon: Icons.web,
              title: 'Web服务',
              subtitle: '开启后可通过浏览器访问',
              value: false,
              onChanged: (value) {},
            ),
          ]),

          // 设置
          _buildCategoryTitle('设置'),
          _buildSection([
            _buildListItem(
              icon: Icons.backup,
              title: '备份恢复',
              subtitle: 'WebDAV备份与恢复',
              onTap: () => Navigator.pushNamed(context, AppRoutes.backupRestore),
            ),
            _buildListItem(
              icon: Icons.color_lens,
              title: '主题设置',
              subtitle: '自定义主题颜色和样式',
              onTap: () {},
            ),
            _buildListItem(
              icon: Icons.settings,
              title: '其他设置',
              subtitle: '阅读、界面等更多设置',
              onTap: () => _showReaderSettings(),
            ),
          ]),

          // 其他
          _buildCategoryTitle('其他'),
          _buildSection([
            _buildListItem(
              icon: Icons.bookmark,
              title: '书签',
              subtitle: '查看所有书签',
              onTap: () => Navigator.pushNamed(context, AppRoutes.bookmark),
            ),
            _buildListItem(
              icon: Icons.history,
              title: '阅读记录',
              subtitle: '查看阅读历史',
              onTap: () => Navigator.pushNamed(context, AppRoutes.readRecord),
            ),
            _buildListItem(
              icon: Icons.storage,
              title: '存储管理',
              subtitle: '管理本地存储的书籍',
              onTap: () => Navigator.pushNamed(context, AppRoutes.storageManage),
            ),
            _buildListItem(
              icon: Icons.info_outline,
              title: '关于',
              onTap: _showAboutDialog,
            ),
            _buildListItem(
              icon: Icons.exit_to_app,
              title: '退出',
              onTap: () => _showExitConfirm(),
            ),
          ]),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSection(List<Widget> children) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: _insertDividers(children),
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
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  List<Widget> _insertDividers(List<Widget> children) {
    final result = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      result.add(children[i]);
      if (i < children.length - 1) {
        result.add(Divider(
          height: 1,
          indent: 56,
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
        ));
      }
    }
    return result;
  }

  Widget _buildListItem({
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title),
      subtitle: subtitle != null ? Text(
        subtitle,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ) : null,
      trailing: Icon(
        Icons.chevron_right,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }

  Widget _buildSwitchItem({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title),
      subtitle: subtitle != null ? Text(
        subtitle,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ) : null,
      trailing: Switch(
        value: value,
        onChanged: onChanged,
      ),
      onTap: () => onChanged(!value),
    );
  }

  String _getThemeModeText(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return '跟随系统';
      case ThemeMode.light:
        return '浅色模式';
      case ThemeMode.dark:
        return '深色模式';
    }
  }

  void _showBookSourceManagement() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const BookSourceManagePage(),
      ),
    );
  }

  void _showThemeDialog(AppProvider provider) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('主题模式'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<ThemeMode>(
                title: const Text('跟随系统'),
                value: ThemeMode.system,
                groupValue: provider.themeMode,
                onChanged: (mode) {
                  provider.setThemeMode(mode!);
                  Navigator.pop(context);
                },
              ),
              RadioListTile<ThemeMode>(
                title: const Text('浅色模式'),
                value: ThemeMode.light,
                groupValue: provider.themeMode,
                onChanged: (mode) {
                  provider.setThemeMode(mode!);
                  Navigator.pop(context);
                },
              ),
              RadioListTile<ThemeMode>(
                title: const Text('深色模式'),
                value: ThemeMode.dark,
                groupValue: provider.themeMode,
                onChanged: (mode) {
                  provider.setThemeMode(mode!);
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showReaderSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return const ReaderSettingsSheet();
      },
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AboutDialog(
          applicationName: '蛋的神器',
          applicationVersion: '1.0.0',
          applicationIcon: const Icon(Icons.book, size: 48),
          children: [
            const Text('一款支持小说、漫画、视频、音频的多媒体阅读器'),
            const SizedBox(height: 8),
            const Text('nojs.py 引擎版本: 1.0.0'),
          ],
        );
      },
    );
  }

  void _showExitConfirm() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('退出'),
          content: const Text('确定要退出应用吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                // 退出应用
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('使用帮助'),
          content: const SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('📖 书源管理', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text('导入和管理书源，支持JSON格式导入'),
                SizedBox(height: 12),
                Text('🔍 发现', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text('浏览书源提供的发现内容'),
                SizedBox(height: 12),
                Text('📱 小程序', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text('安装和管理小程序扩展'),
                SizedBox(height: 12),
                Text('⚙️ 设置', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text('自定义主题、阅读设置等'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }
}

class ReaderSettingsSheet extends StatelessWidget {
  const ReaderSettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '阅读设置',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          ListTile(
            title: const Text('默认翻页方式'),
            subtitle: const Text('仿真翻页'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          ),
          ListTile(
            title: const Text('字体大小'),
            subtitle: const Text('18'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          ),
          ListTile(
            title: const Text('背景色'),
            trailing: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            onTap: () {},
          ),
          SwitchListTile(
            title: const Text('屏幕常亮'),
            value: true,
            onChanged: (value) {},
          ),
          SwitchListTile(
            title: const Text('音量键翻页'),
            value: false,
            onChanged: (value) {},
          ),
        ],
      ),
    );
  }
}
