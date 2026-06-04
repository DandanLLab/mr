import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../providers/bookshelf_provider.dart';
import '../../providers/discovery_provider.dart';
import '../../routes/app_routes.dart';
import 'book_source_manage_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String _nickname = '小蛋子';
  int _readingTime = 0;
  int _bookCount = 0;
  int _sourceCount = 0;
  int _miniprogramCount = 0;
  int _pluginCount = 0;

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
      appBar: AppBar(
        title: const Text('我的'),
      ),
      body: ListView(
        children: [
          _buildProfileCard(),
          const Divider(),
          _buildManagementSection(),
          const Divider(),
          _buildSettingsSection(),
          const Divider(),
          _buildAboutSection(),
        ],
      ),
    );
  }

  Widget _buildProfileCard() {
    return Container(
      margin: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Icon(
                  Icons.person,
                  size: 32,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _nickname,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _buildStatItem('阅读', '${_readingTime}分钟'),
                        const SizedBox(width: 16),
                        _buildStatItem('书籍', '$_bookCount本'),
                        const SizedBox(width: 16),
                        _buildStatItem('应用', '${_miniprogramCount + _pluginCount}个'),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: _editNickname,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildManagementSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '管理',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.book),
          title: const Text('书源管理'),
          subtitle: Text('已导入 $_sourceCount 个书源'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showBookSourceManagement(),
        ),
        ListTile(
          leading: const Icon(Icons.apps),
          title: const Text('小程序管理'),
          subtitle: Text('已安装 $_miniprogramCount 个小程序'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showMiniprogramManagement(),
        ),
        ListTile(
          leading: const Icon(Icons.extension),
          title: const Text('插件管理'),
          subtitle: Text('已安装 $_pluginCount 个插件'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showPluginManagement(),
        ),
      ],
    );
  }

  Widget _buildSettingsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '设置',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Consumer<AppProvider>(
          builder: (context, provider, child) {
            return ListTile(
              leading: const Icon(Icons.palette),
              title: const Text('主题设置'),
              subtitle: Text(_getThemeModeText(provider.themeMode)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showThemeDialog(provider),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.menu_book),
          title: const Text('阅读设置'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showReaderSettings(),
        ),
        ListTile(
          leading: const Icon(Icons.network_check),
          title: const Text('网络与缓存'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showNetworkSettings(),
        ),
        Consumer<AppProvider>(
          builder: (context, provider, child) {
            return SwitchListTile(
              secondary: const Icon(Icons.image_not_supported),
              title: const Text('无图模式'),
              subtitle: const Text('开启后封面仅显示文字'),
              value: provider.isNoImageMode,
              onChanged: (value) => provider.toggleNoImageMode(),
            );
          },
        ),
      ],
    );
  }

  Widget _buildAboutSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '关于',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.info),
          title: const Text('关于蛋的神器'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _showAboutDialog,
        ),
        ListTile(
          leading: const Icon(Icons.help),
          title: const Text('使用帮助'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {},
        ),
        ListTile(
          leading: const Icon(Icons.feedback),
          title: const Text('反馈建议'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {},
        ),
      ],
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

  void _editNickname() {
    final controller = TextEditingController(text: _nickname);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('修改昵称'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: '请输入昵称',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _nickname = controller.text;
                });
                context.read<AppProvider>().setNickname(controller.text);
                Navigator.pop(context);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _showBookSourceManagement() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const BookSourceManagePage(),
      ),
    );
  }

  void _showMiniprogramManagement() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const MiniprogramManagementPage(),
      ),
    );
  }

  void _showPluginManagement() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const PluginManagementPage(),
      ),
    );
  }

  void _showThemeDialog(AppProvider provider) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('主题设置'),
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

  void _showNetworkSettings() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return const NetworkSettingsSheet();
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
}

class MiniprogramManagementPage extends StatelessWidget {
  const MiniprogramManagementPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('小程序管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {},
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: 3,
        itemBuilder: (context, index) {
          return ListTile(
            leading: const CircleAvatar(child: Icon(Icons.apps)),
            title: Text('小程序 ${index + 1}'),
            subtitle: const Text('v1.0.0'),
            trailing: Switch(
              value: true,
              onChanged: (value) {},
            ),
          );
        },
      ),
    );
  }
}

class PluginManagementPage extends StatelessWidget {
  const PluginManagementPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('插件管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {},
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: 2,
        itemBuilder: (context, index) {
          return ListTile(
            leading: const CircleAvatar(child: Icon(Icons.extension)),
            title: Text('插件 ${index + 1}'),
            subtitle: const Text('功能增强'),
            trailing: Switch(
              value: true,
              onChanged: (value) {},
            ),
          );
        },
      ),
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

class NetworkSettingsSheet extends StatelessWidget {
  const NetworkSettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '网络与缓存',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          ListTile(
            title: const Text('同时搜索书源上限'),
            subtitle: const Text('5个'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          ),
          ListTile(
            title: const Text('图片缓存过期时间'),
            subtitle: const Text('7天'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          ),
          ListTile(
            title: const Text('视频/音频缓存目录'),
            subtitle: const Text('/storage/emulated/0/Download'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          ),
          SwitchListTile(
            title: const Text('自动清除缓存'),
            subtitle: const Text('每周自动清理过期缓存'),
            value: true,
            onChanged: (value) {},
          ),
          ListTile(
            title: const Text('清除所有缓存'),
            trailing: const Icon(Icons.delete),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) {
                  return AlertDialog(
                    title: const Text('确认清除'),
                    content: const Text('确定要清除所有缓存吗？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('缓存已清除')),
                          );
                        },
                        child: const Text('确定'),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}
