import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../providers/app_provider.dart';

class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  bool _mainTransparentStatusBar = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _mainTransparentStatusBar = prefs.getBool('mainTransparentStatusBar') ?? false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final isDark = provider.themeMode == ThemeMode.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('主题设置'),
        actions: [
          IconButton(
            icon: Icon(
              isDark ? Icons.light_mode : Icons.dark_mode,
              color: isDark ? Colors.amber : Colors.indigo,
            ),
            tooltip: isDark ? '切换到日间模式' : '切换到夜间模式',
            onPressed: () {
              if (isDark) {
                provider.setThemeMode(ThemeMode.light);
              } else {
                provider.setThemeMode(ThemeMode.dark);
              }
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          // 通用设置
          _buildCategoryTitle('通用设置'),
          _buildSection([
            _buildSwitchItem(
              icon: Icons.fullscreen,
              title: '主界面沉浸状态栏',
              subtitle: '主界面状态栏透明，内容延伸到状态栏下方',
              value: _mainTransparentStatusBar,
              onChanged: (value) async {
                setState(() => _mainTransparentStatusBar = value);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('mainTransparentStatusBar', value);
              },
            ),
          ]),

          // 界面管理
          _buildCategoryTitle('界面管理'),
          _buildSection([
            _buildListItem(
              icon: Icons.palette,
              title: '主题管理',
              subtitle: '管理日间/夜间主题颜色和背景',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ThemeManagePage())),
            ),
            _buildListItem(
              icon: Icons.navigation,
              title: '导航栏管理',
              subtitle: '自定义底部导航栏样式',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NavigationBarManagePage())),
            ),
            _buildListItem(
              icon: Icons.view_headline,
              title: '顶栏管理',
              subtitle: '自定义顶部工具栏样式',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TopBarManagePage())),
            ),
            _buildListItem(
              icon: Icons.info_outline,
              title: '书籍信息管理',
              subtitle: '自定义书籍详情页样式',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BookInfoManagePage())),
            ),
            _buildListItem(
              icon: Icons.chat_bubble_outline,
              title: '气泡管理',
              subtitle: '自定义气泡样式',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BubbleManagePage())),
            ),
          ]),

          // 其他设置
          _buildCategoryTitle('其他设置'),
          _buildSection([
            _buildListItem(
              icon: Icons.image,
              title: '封面配置',
              subtitle: '自定义封面显示样式',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CoverConfigPage())),
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
      child: Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary)),
    );
  }

  Widget _buildSection(List<Widget> children) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(12)),
      child: Column(children: children),
    );
  }

  Widget _buildListItem({required IconData icon, required String title, String? subtitle, VoidCallback? onTap}) {
    return ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)) : null,
      trailing: Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
      onTap: onTap,
    );
  }

  Widget _buildSwitchItem({required IconData icon, required String title, String? subtitle, required bool value, required ValueChanged<bool> onChanged}) {
    return ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)) : null,
      trailing: Switch(value: value, onChanged: onChanged),
      onTap: () => onChanged(!value),
    );
  }
}

// 主题管理页面 - 参考 legado-main 的 ThemeManageActivity
class ThemeManagePage extends StatefulWidget {
  const ThemeManagePage({super.key});
  @override
  State<ThemeManagePage> createState() => _ThemeManagePageState();
}

class _ThemeManagePageState extends State<ThemeManagePage> {
  bool _isNightTheme = false;
  final List<ThemeConfig> _themes = [];
  String? _activeThemeId;

  @override
  void initState() {
    super.initState();
    _loadThemes();
  }

  Future<void> _loadThemes() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isNightTheme = prefs.getBool('themeIsNight') ?? false;
      _activeThemeId = prefs.getString(_isNightTheme ? 'activeNightThemeId' : 'activeDayThemeId');
      
      // 加载内置主题（与 legado-main 一致）
      _themes.clear();
      // 日间主题
      _themes.add(ThemeConfig(
        id: 'builtin_default',
        name: '默认',
        isNight: false,
        isBuiltin: true,
        primaryColor: const Color(0xFF795548), // Brown 500
        accentColor: const Color(0xFFE53935), // Red 600
        backgroundColor: const Color(0xFFF5F5F5), // Grey 100
        navBarColor: const Color(0xFFEEEEEE), // Grey 200
      ));
      _themes.add(ThemeConfig(
        id: 'builtin_elegant_blue',
        name: '典雅蓝',
        isNight: false,
        isBuiltin: true,
        primaryColor: const Color(0xFF03A9F4), // Light Blue 500
        accentColor: const Color(0xFFAD1457), // Pink 800
        backgroundColor: const Color(0xFFF5F5F5),
        navBarColor: const Color(0xFFEEEEEE),
      ));
      // 夜间主题
      _themes.add(ThemeConfig(
        id: 'builtin_black_white',
        name: '黑白',
        isNight: true,
        isBuiltin: true,
        primaryColor: const Color(0xFF303030), // Grey 700
        accentColor: const Color(0xFFE0E0E0), // Grey 300
        backgroundColor: const Color(0xFF424242), // Grey 800
        navBarColor: const Color(0xFF424242),
      ));
      _themes.add(ThemeConfig(
        id: 'builtin_a_screen',
        name: 'A屏黑',
        isNight: true,
        isBuiltin: true,
        primaryColor: const Color(0xFF000000), // 纯黑
        accentColor: const Color(0xFFFFFFFF), // 纯白
        backgroundColor: const Color(0xFF000000),
        navBarColor: const Color(0xFF000000),
      ));
      
      // 加载自定义主题
      final customThemes = prefs.getStringList('customThemes') ?? [];
      for (final json in customThemes) {
        try {
          _themes.add(ThemeConfig.fromJson(json));
        } catch (e) {
          debugPrint('加载主题失败: $e');
        }
      }
      
      // 如果没有激活的主题，默认激活第一个对应模式的主题
      if (_activeThemeId == null || _activeThemeId!.isEmpty) {
        final defaultTheme = _filteredThemes.firstOrNull;
        if (defaultTheme != null) {
          _activeThemeId = defaultTheme.id;
        }
      }
    });
  }

  List<ThemeConfig> get _filteredThemes => _themes.where((t) => t.isNight == _isNightTheme).toList();

  Future<void> _saveThemes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('themeIsNight', _isNightTheme);
    await prefs.setString(_isNightTheme ? 'activeNightThemeId' : 'activeDayThemeId', _activeThemeId ?? '');
    
    final customThemes = _themes.where((t) => !t.isBuiltin).map((t) => t.toJson()).toList();
    await prefs.setStringList('customThemes', customThemes);
  }

  Future<void> _applyTheme(ThemeConfig theme) async {
    final provider = context.read<AppProvider>();
    if (theme.isNight) {
      await provider.setNightThemeColors(
        primaryColor: theme.primaryColor,
        accentColor: theme.accentColor,
        backgroundColor: theme.backgroundColor,
        surfaceColor: theme.backgroundColor,
      );
    } else {
      await provider.setDayThemeColors(
        primaryColor: theme.primaryColor,
        accentColor: theme.accentColor,
        backgroundColor: theme.backgroundColor,
        surfaceColor: theme.backgroundColor,
      );
    }
    setState(() => _activeThemeId = theme.id);
    await _saveThemes();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('主题管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加主题',
            onPressed: _addTheme,
          ),
        ],
      ),
      body: Column(
        children: [
          // 日间/夜间切换
          Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      setState(() => _isNightTheme = false);
                      await _saveThemes();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: !_isNightTheme ? Theme.of(context).colorScheme.primary : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('日间主题', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w600, color: !_isNightTheme ? Colors.white : null)),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      setState(() => _isNightTheme = true);
                      await _saveThemes();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: _isNightTheme ? Theme.of(context).colorScheme.primary : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('夜间主题', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w600, color: _isNightTheme ? Colors.white : null)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 主题列表
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _filteredThemes.length,
              itemBuilder: (context, index) {
                final theme = _filteredThemes[index];
                final isActive = theme.id == _activeThemeId;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: isActive ? Border.all(color: Theme.of(context).colorScheme.primary, width: 2) : null,
                  ),
                  child: ListTile(
                    leading: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: theme.primaryColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: theme.backgroundColor,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: theme.accentColor, width: 2),
                          ),
                        ),
                      ),
                    ),
                    title: Row(
                      children: [
                        Text(theme.name),
                        if (theme.isBuiltin) 
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('内置', style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.primary)),
                          ),
                      ],
                    ),
                    subtitle: Text('点击应用'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!theme.isBuiltin) ...[
                          IconButton(icon: const Icon(Icons.edit, size: 20), onPressed: () => _editTheme(theme)),
                          IconButton(icon: const Icon(Icons.delete, size: 20), onPressed: () => _deleteTheme(theme)),
                        ],
                      ],
                    ),
                    onTap: () => _applyTheme(theme),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _addTheme() {
    _editTheme(null);
  }

  void _editTheme(ThemeConfig? existing) {
    final isEdit = existing != null;
    final theme = existing ?? ThemeConfig(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: '新主题',
      isNight: _isNightTheme,
      isBuiltin: false,
      primaryColor: _isNightTheme ? const Color(0xFF303030) : const Color(0xFF795548),
      accentColor: _isNightTheme ? const Color(0xFFE0E0E0) : const Color(0xFFE53935),
      backgroundColor: _isNightTheme ? const Color(0xFF424242) : const Color(0xFFF5F5F5),
      navBarColor: _isNightTheme ? const Color(0xFF424242) : const Color(0xFFEEEEEE),
    );

    int selectedTab = 0; // 0: 颜色, 1: 图片, 2: 界面, 3: 字体

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isEdit ? '编辑主题' : '添加主题'),
          content: SizedBox(
            width: double.maxFinite,
            height: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 主题名称
                TextField(
                  decoration: const InputDecoration(labelText: '主题名称'),
                  controller: TextEditingController(text: theme.name),
                  onChanged: (v) => theme.name = v,
                ),
                const SizedBox(height: 12),
                // 分组标签
                Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      _buildTabButton(ctx, '颜色', 0, selectedTab, (i) => setDialogState(() => selectedTab = i)),
                      _buildTabButton(ctx, '图片', 1, selectedTab, (i) => setDialogState(() => selectedTab = i)),
                      _buildTabButton(ctx, '界面', 2, selectedTab, (i) => setDialogState(() => selectedTab = i)),
                      _buildTabButton(ctx, '字体', 3, selectedTab, (i) => setDialogState(() => selectedTab = i)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 内容区域
                Expanded(
                  child: SingleChildScrollView(
                    child: _buildTabContent(ctx, selectedTab, theme, setDialogState),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(onPressed: () async {
              if (isEdit) {
                setState(() {});
              } else {
                setState(() => _themes.add(theme));
              }
              await _saveThemes();
              Navigator.pop(ctx);
            }, child: const Text('保存')),
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton(BuildContext ctx, String label, int index, int selectedIndex, ValueChanged<int> onTap) {
    final isSelected = index == selectedIndex;
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? Theme.of(context).colorScheme.primaryContainer : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: isSelected ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent(BuildContext ctx, int tabIndex, ThemeConfig theme, StateSetter setDialogState) {
    switch (tabIndex) {
      case 0: // 颜色
        return Column(
          children: [
            _buildColorPickerRow(ctx, '主色', theme.primaryColor, (c) => setDialogState(() => theme.primaryColor = c)),
            _buildColorPickerRow(ctx, '强调色', theme.accentColor, (c) => setDialogState(() => theme.accentColor = c)),
            _buildColorPickerRow(ctx, '背景色', theme.backgroundColor, (c) => setDialogState(() => theme.backgroundColor = c)),
            _buildColorPickerRow(ctx, '底部背景色', theme.navBarColor, (c) => setDialogState(() => theme.navBarColor = c)),
          ],
        );
      case 1: // 图片
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('主背景图片'),
              subtitle: Text(theme.mainBgImage ?? '未设置'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _selectImage(ctx, '主背景图片', (path) => setDialogState(() => theme.mainBgImage = path)),
            ),
            ListTile(
              leading: const Icon(Icons.blur_on),
              title: const Text('背景图片模糊度'),
              subtitle: Slider(
                value: theme.bgImageBlur.toDouble(),
                min: 0,
                max: 25,
                divisions: 25,
                onChanged: (v) => setDialogState(() => theme.bgImageBlur = v.round()),
              ),
              trailing: Text('${theme.bgImageBlur}'),
            ),
            ListTile(
              leading: const Icon(Icons.book),
              title: const Text('书籍信息背景'),
              subtitle: Text(theme.bookInfoBgImage ?? '未设置'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _selectImage(ctx, '书籍信息背景', (path) => setDialogState(() => theme.bookInfoBgImage = path)),
            ),
            ListTile(
              leading: const Icon(Icons.dashboard),
              title: const Text('面板背景'),
              subtitle: Text(theme.panelBgImage ?? '未设置'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _selectImage(ctx, '面板背景', (path) => setDialogState(() => theme.panelBgImage = path)),
            ),
            ListTile(
              leading: const Icon(Icons.crop),
              title: const Text('面板背景模式'),
              subtitle: Text(theme.panelBgMode == 'crop' ? '裁剪' : '适应'),
              trailing: Switch(
                value: theme.panelBgMode == 'fit',
                onChanged: (v) => setDialogState(() => theme.panelBgMode = v ? 'fit' : 'crop'),
              ),
            ),
          ],
        );
      case 2: // 界面
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.rounded_corner),
              title: const Text('圆角比例'),
              subtitle: Slider(
                value: theme.cornerScale,
                min: 0.0,
                max: 3.0,
                divisions: 30,
                onChanged: (v) => setDialogState(() => theme.cornerScale = v),
              ),
              trailing: Text(theme.cornerScale.toStringAsFixed(1)),
            ),
            ListTile(
              leading: const Icon(Icons.opacity),
              title: const Text('布局透明度'),
              subtitle: Slider(
                value: theme.layoutAlpha.toDouble(),
                min: 0,
                max: 100,
                divisions: 20,
                onChanged: (v) => setDialogState(() => theme.layoutAlpha = v.round()),
              ),
              trailing: Text('${theme.layoutAlpha}%'),
            ),
            _buildColorPickerRow(ctx, '面板边框色', theme.panelBorderColor ?? Colors.transparent, (c) => setDialogState(() => theme.panelBorderColor = c)),
            ListTile(
              leading: const Icon(Icons.border_style),
              title: const Text('边框透明度'),
              subtitle: Slider(
                value: theme.panelBorderAlpha.toDouble(),
                min: 0,
                max: 100,
                divisions: 20,
                onChanged: (v) => setDialogState(() => theme.panelBorderAlpha = v.round()),
              ),
              trailing: Text('${theme.panelBorderAlpha}%'),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.search),
              title: const Text('搜索跟随主题'),
              value: theme.searchFollow,
              onChanged: (v) => setDialogState(() => theme.searchFollow = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.reply),
              title: const Text('回复跟随主题'),
              value: theme.replyFollow,
              onChanged: (v) => setDialogState(() => theme.replyFollow = v),
            ),
          ],
        );
      case 3: // 字体
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: const Text('字体缩放'),
              subtitle: Slider(
                value: theme.fontScale.toDouble(),
                min: 8,
                max: 16,
                divisions: 8,
                onChanged: (v) => setDialogState(() => theme.fontScale = v.round()),
              ),
              trailing: Text(theme.fontScale == 10 ? '默认' : '${(theme.fontScale / 10).toStringAsFixed(1)}'),
            ),
            ListTile(
              leading: const Icon(Icons.font_download),
              title: const Text('UI字体'),
              subtitle: Text(theme.uiFont ?? '默认'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _selectFont(ctx, 'UI字体', (font) => setDialogState(() => theme.uiFont = font)),
            ),
            ListTile(
              leading: const Icon(Icons.title),
              title: const Text('标题字体'),
              subtitle: Text(theme.titleFont ?? '默认'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _selectFont(ctx, '标题字体', (font) => setDialogState(() => theme.titleFont = font)),
            ),
          ],
        );
      default:
        return const SizedBox();
    }
  }

  void _selectImage(BuildContext ctx, String title, ValueChanged<String?> onSelected) {
    showModalBottomSheet(
      context: ctx,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('选择图片'),
              onTap: () {
                Navigator.pop(c);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('图片选择功能开发中...')));
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('输入URL'),
              onTap: () {
                Navigator.pop(c);
                _inputUrl(ctx, title, onSelected);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('清除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(c);
                onSelected(null);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _inputUrl(BuildContext ctx, String title, ValueChanged<String?> onSelected) {
    final controller = TextEditingController();
    showDialog(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '输入图片URL'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          TextButton(onPressed: () {
            Navigator.pop(c);
            onSelected(controller.text.isEmpty ? null : controller.text);
          }, child: const Text('确定')),
        ],
      ),
    );
  }

  void _selectFont(BuildContext ctx, String title, ValueChanged<String?> onSelected) {
    showModalBottomSheet(
      context: ctx,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('默认字体'),
              onTap: () {
                Navigator.pop(c);
                onSelected(null);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('选择字体文件'),
              onTap: () {
                Navigator.pop(c);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('字体选择功能开发中...')));
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildColorPickerRow(BuildContext ctx, String title, Color color, ValueChanged<Color> onChanged) {
    return ListTile(
      leading: Container(width: 32, height: 32, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey))),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showColorPicker(ctx, title, color, onChanged),
    );
  }

  void _showColorPicker(BuildContext ctx, String title, Color currentColor, ValueChanged<Color> onChanged) {
    // 使用 HSV 颜色选择器，可以调节颜色
    final hsvColor = HSVColor.fromColor(currentColor);
    double hue = hsvColor.hue;
    double saturation = hsvColor.saturation;
    double value = hsvColor.value;
    double alpha = currentColor.alpha / 255.0;

    showDialog(
      context: ctx,
      builder: (c) => StatefulBuilder(
        builder: (c, setState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 280,
            height: 350,
            child: Column(
              children: [
                // 预览
                Container(
                  width: double.infinity,
                  height: 60,
                  decoration: BoxDecoration(
                    color: HSVColor.fromAHSV(alpha, hue, saturation, value).toColor(),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey),
                  ),
                ),
                const SizedBox(height: 16),
                // 色相
                Row(
                  children: [
                    const SizedBox(width: 40, child: Text('色相')),
                    Expanded(
                      child: Slider(
                        value: hue,
                        min: 0,
                        max: 360,
                        onChanged: (v) => setState(() => hue = v),
                      ),
                    ),
                    SizedBox(width: 50, child: Text(hue.round().toString())),
                  ],
                ),
                // 饱和度
                Row(
                  children: [
                    const SizedBox(width: 40, child: Text('饱和度')),
                    Expanded(
                      child: Slider(
                        value: saturation,
                        min: 0,
                        max: 1,
                        onChanged: (v) => setState(() => saturation = v),
                      ),
                    ),
                    SizedBox(width: 50, child: Text('${(saturation * 100).round()}%')),
                  ],
                ),
                // 明度
                Row(
                  children: [
                    const SizedBox(width: 40, child: Text('明度')),
                    Expanded(
                      child: Slider(
                        value: value,
                        min: 0,
                        max: 1,
                        onChanged: (v) => setState(() => value = v),
                      ),
                    ),
                    SizedBox(width: 50, child: Text('${(value * 100).round()}%')),
                  ],
                ),
                // 透明度
                Row(
                  children: [
                    const SizedBox(width: 40, child: Text('透明度')),
                    Expanded(
                      child: Slider(
                        value: alpha,
                        min: 0,
                        max: 1,
                        onChanged: (v) => setState(() => alpha = v),
                      ),
                    ),
                    SizedBox(width: 50, child: Text('${(alpha * 100).round()}%')),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
            TextButton(
              onPressed: () {
                onChanged(HSVColor.fromAHSV(alpha, hue, saturation, value).toColor());
                Navigator.pop(c);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  void _deleteTheme(ThemeConfig theme) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除主题 "${theme.name}" 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              setState(() => _themes.remove(theme));
              await _saveThemes();
              Navigator.pop(ctx);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

/// 主题配置类 - 参考 legado-main 的 ThemeConfig.Config
class ThemeConfig {
  String id;
  String name;
  bool isNight;
  bool isBuiltin;
  Color primaryColor;
  Color accentColor;
  Color backgroundColor;
  Color navBarColor;
  // 图片设置
  String? mainBgImage;
  int bgImageBlur;
  String? bookInfoBgImage;
  String? panelBgImage;
  String panelBgMode; // crop, fit
  // 界面设置
  double cornerScale;
  int layoutAlpha;
  Color? panelBorderColor;
  int panelBorderAlpha;
  bool searchFollow;
  bool replyFollow;
  // 字体设置
  int fontScale;
  String? uiFont;
  String? titleFont;

  ThemeConfig({
    required this.id,
    required this.name,
    required this.isNight,
    required this.isBuiltin,
    required this.primaryColor,
    required this.accentColor,
    required this.backgroundColor,
    this.navBarColor = const Color(0xFFF5F5F5),
    this.mainBgImage,
    this.bgImageBlur = 0,
    this.bookInfoBgImage,
    this.panelBgImage,
    this.panelBgMode = 'crop',
    this.cornerScale = 1.0,
    this.layoutAlpha = 100,
    this.panelBorderColor,
    this.panelBorderAlpha = 100,
    this.searchFollow = true,
    this.replyFollow = true,
    this.fontScale = 10,
    this.uiFont,
    this.titleFont,
  });

  String toJson() {
    return '$id|$name|$isNight|$isBuiltin|${primaryColor.value}|${accentColor.value}|${backgroundColor.value}|${navBarColor.value}|${mainBgImage ?? ''}|$bgImageBlur|${bookInfoBgImage ?? ''}|${panelBgImage ?? ''}|$panelBgMode|$cornerScale|$layoutAlpha|${panelBorderColor?.value ?? 0}|$panelBorderAlpha|$searchFollow|$replyFollow|$fontScale|${uiFont ?? ''}|${titleFont ?? ''}';
  }

  factory ThemeConfig.fromJson(String json) {
    final parts = json.split('|');
    return ThemeConfig(
      id: parts[0],
      name: parts[1],
      isNight: parts[2] == 'true',
      isBuiltin: parts[3] == 'true',
      primaryColor: Color(int.parse(parts[4])),
      accentColor: Color(int.parse(parts[5])),
      backgroundColor: Color(int.parse(parts[6])),
      navBarColor: Color(int.parse(parts[7])),
      mainBgImage: parts[8].isEmpty ? null : parts[8],
      bgImageBlur: int.parse(parts[9]),
      bookInfoBgImage: parts[10].isEmpty ? null : parts[10],
      panelBgImage: parts[11].isEmpty ? null : parts[11],
      panelBgMode: parts[12],
      cornerScale: double.parse(parts[13]),
      layoutAlpha: int.parse(parts[14]),
      panelBorderColor: int.parse(parts[15]) == 0 ? null : Color(int.parse(parts[15])),
      panelBorderAlpha: int.parse(parts[16]),
      searchFollow: parts[17] == 'true',
      replyFollow: parts[18] == 'true',
      fontScale: int.parse(parts[19]),
      uiFont: parts[20].isEmpty ? null : parts[20],
      titleFont: parts[21].isEmpty ? null : parts[21],
    );
  }
}

// 导航栏管理页面
class NavigationBarManagePage extends StatefulWidget {
  const NavigationBarManagePage({super.key});
  @override
  State<NavigationBarManagePage> createState() => _NavigationBarManagePageState();
}

class _NavigationBarManagePageState extends State<NavigationBarManagePage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isNightMode = false;
  
  // 导航栏配置
  String _layoutMode = 'floating';
  String _effectMode = 'glass';
  int _opacity = 72;
  String _sidebarGravity = 'start';
  bool _showSearchButton = false;  // 默认不显示
  bool _showIndicator = true;
  double _cornerScale = 1.0;
  Color _borderColor = Colors.transparent;
  int _borderAlpha = 100;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadSettings();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isNightMode = prefs.getBool('navIsNightMode') ?? false;
      _layoutMode = prefs.getString('navLayoutMode') ?? 'floating';
      _effectMode = prefs.getString('navEffectMode') ?? 'glass';
      _opacity = prefs.getInt('navOpacity') ?? 72;
      _sidebarGravity = prefs.getString('navSidebarGravity') ?? 'start';
      _showSearchButton = prefs.getBool('navShowSearchButton') ?? false;  // 默认不显示
      _showIndicator = prefs.getBool('navShowIndicator') ?? true;
      _cornerScale = prefs.getDouble('navCornerScale') ?? 1.0;
      _borderColor = Color(prefs.getInt('navBorderColor') ?? Colors.transparent.value);
      _borderAlpha = prefs.getInt('navBorderAlpha') ?? 100;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('navIsNightMode', _isNightMode);
    await prefs.setString('navLayoutMode', _layoutMode);
    await prefs.setString('navEffectMode', _effectMode);
    await prefs.setInt('navOpacity', _opacity);
    await prefs.setString('navSidebarGravity', _sidebarGravity);
    await prefs.setBool('navShowSearchButton', _showSearchButton);
    await prefs.setBool('navShowIndicator', _showIndicator);
    await prefs.setDouble('navCornerScale', _cornerScale);
    await prefs.setInt('navBorderColor', _borderColor.value);
    await prefs.setInt('navBorderAlpha', _borderAlpha);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('导航栏管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: '保存',
            onPressed: () async {
              await _saveSettings();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('设置已保存，重启应用生效')),
                );
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 日间/夜间切换
          _buildSection([
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _isNightMode = false),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: !_isNightMode ? Theme.of(context).colorScheme.primaryContainer : null,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text('日间', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w600, color: !_isNightMode ? Theme.of(context).colorScheme.primary : null)),
                      ),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _isNightMode = true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: _isNightMode ? Theme.of(context).colorScheme.primaryContainer : null,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text('夜间', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w600, color: _isNightMode ? Theme.of(context).colorScheme.primary : null)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ]),
          
          const SizedBox(height: 16),
          
          // 布局设置
          _buildCategoryTitle('布局设置'),
          _buildSection([
            ListTile(
              leading: const Icon(Icons.view_quilt),
              title: const Text('布局模式'),
              subtitle: Text(_getLayoutModeText()),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showLayoutModePicker,
            ),
            if (_layoutMode == 'sidebar')
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('侧边栏位置'),
                subtitle: Text(_sidebarGravity == 'start' ? '左侧' : '右侧'),
                trailing: Switch(
                  value: _sidebarGravity == 'end',
                  onChanged: (v) => setState(() => _sidebarGravity = v ? 'end' : 'start'),
                ),
              ),
          ]),
          
          const SizedBox(height: 16),
          
          // 效果设置
          _buildCategoryTitle('效果设置'),
          _buildSection([
            ListTile(
              leading: const Icon(Icons.blur_on),
              title: const Text('效果模式'),
              subtitle: Text(_getEffectModeText()),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showEffectModePicker,
            ),
            ListTile(
              leading: const Icon(Icons.opacity),
              title: const Text('透明度'),
              subtitle: Slider(
                value: _opacity.toDouble(),
                min: 0,
                max: 100,
                onChanged: (v) => setState(() => _opacity = v.round()),
              ),
              trailing: Text('$_opacity%'),
            ),
            ListTile(
              leading: const Icon(Icons.rounded_corner),
              title: const Text('圆角比例'),
              subtitle: Slider(
                value: _cornerScale,
                min: 0.5,
                max: 2.0,
                divisions: 15,
                onChanged: (v) => setState(() => _cornerScale = v),
              ),
              trailing: Text(_cornerScale.toStringAsFixed(1)),
            ),
          ]),
          
          const SizedBox(height: 16),
          
          // 边框设置
          _buildCategoryTitle('边框设置'),
          _buildSection([
            ListTile(
              leading: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _borderColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey),
                ),
              ),
              title: const Text('边框颜色'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showBorderColorPicker(),
            ),
            ListTile(
              leading: const Icon(Icons.border_style),
              title: const Text('边框透明度'),
              subtitle: Slider(
                value: _borderAlpha.toDouble(),
                min: 0,
                max: 100,
                onChanged: (v) => setState(() => _borderAlpha = v.round()),
              ),
              trailing: Text('$_borderAlpha%'),
            ),
          ]),
          
          const SizedBox(height: 16),
          
          // 其他设置
          _buildCategoryTitle('其他设置'),
          _buildSection([
            SwitchListTile(
              secondary: const Icon(Icons.search),
              title: const Text('显示搜索按钮'),
              subtitle: const Text('在导航栏右侧显示独立的搜索按钮'),
              value: _showSearchButton,
              onChanged: (v) => setState(() => _showSearchButton = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.linear_scale),
              title: const Text('显示导航指示器'),
              subtitle: const Text('在选中项下方显示动态指示器'),
              value: _showIndicator,
              onChanged: (v) => setState(() => _showIndicator = v),
            ),
          ]),
          
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildCategoryTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary)),
    );
  }

  Widget _buildSection(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(12)),
      child: Column(children: children),
    );
  }

  String _getLayoutModeText() {
    switch (_layoutMode) {
      case 'floating': return '悬浮导航栏';
      case 'standard': return '标准导航栏';
      case 'sidebar': return '侧边栏';
      default: return '悬浮导航栏';
    }
  }

  String _getEffectModeText() {
    switch (_effectMode) {
      case 'liquid': return '液态玻璃';
      case 'frosted': return '毛玻璃';
      case 'glass': return '普通玻璃';
      case 'solid': return '固体';
      default: return '液态玻璃';
    }
  }

  void _showLayoutModePicker() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.view_quilt),
              title: const Text('悬浮导航栏'),
              subtitle: const Text('玻璃效果 + 悬浮在底部'),
              trailing: _layoutMode == 'floating' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _layoutMode = 'floating');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.view_stream),
              title: const Text('标准导航栏'),
              subtitle: const Text('传统底部导航栏样式'),
              trailing: _layoutMode == 'standard' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _layoutMode = 'standard');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.view_sidebar),
              title: const Text('侧边栏'),
              subtitle: const Text('侧边抽屉式导航'),
              trailing: _layoutMode == 'sidebar' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _layoutMode = 'sidebar');
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEffectModePicker() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.water_drop),
              title: const Text('液态玻璃'),
              subtitle: const Text('高级模糊 + 折射 + 色散效果'),
              trailing: _effectMode == 'liquid' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _effectMode = 'liquid');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.grain),
              title: const Text('毛玻璃'),
              subtitle: const Text('中等模糊效果'),
              trailing: _effectMode == 'frosted' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _effectMode = 'frosted');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.blur_on),
              title: const Text('普通玻璃'),
              subtitle: const Text('简单模糊效果'),
              trailing: _effectMode == 'glass' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _effectMode = 'glass');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.crop_square),
              title: const Text('固体'),
              subtitle: const Text('无模糊效果'),
              trailing: _effectMode == 'solid' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _effectMode = 'solid');
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showBorderColorPicker() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('边框颜色'),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Colors.transparent,
            Colors.white,
            Colors.black,
            Colors.grey,
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.secondary,
            Colors.red,
            Colors.blue,
            Colors.green,
          ].map((c) => GestureDetector(
            onTap: () {
              setState(() => _borderColor = c);
              Navigator.pop(ctx);
            },
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c == Colors.transparent ? Theme.of(context).colorScheme.surface : c,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: c == _borderColor ? Theme.of(context).colorScheme.primary : Colors.grey,
                  width: c == _borderColor ? 3 : 1,
                ),
              ),
              child: c == Colors.transparent ? const Center(child: Text('无', style: TextStyle(fontSize: 10))) : null,
            ),
          )).toList(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        ],
      ),
    );
  }
}

// 顶栏管理页面
class TopBarManagePage extends StatefulWidget {
  const TopBarManagePage({super.key});
  @override
  State<TopBarManagePage> createState() => _TopBarManagePageState();
}

class _TopBarManagePageState extends State<TopBarManagePage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _style = 'default';
  double _cornerScale = 1.0;
  Color _backgroundColor = const Color(0xFF6200EE);
  int _wallpaperAlpha = 0;
  bool _expandFiltersByDefault = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadSettings();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _style = prefs.getString('topBarStyle') ?? 'default';
      _cornerScale = prefs.getDouble('topBarCornerScale') ?? 1.0;
      _backgroundColor = Color(prefs.getInt('topBarBackgroundColor') ?? 0xFF6200EE);
      _wallpaperAlpha = prefs.getInt('topBarWallpaperAlpha') ?? 0;
      _expandFiltersByDefault = prefs.getBool('topBarExpandFiltersByDefault') ?? false;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('topBarStyle', _style);
    await prefs.setDouble('topBarCornerScale', _cornerScale);
    await prefs.setInt('topBarBackgroundColor', _backgroundColor.value);
    await prefs.setInt('topBarWallpaperAlpha', _wallpaperAlpha);
    await prefs.setBool('topBarExpandFiltersByDefault', _expandFiltersByDefault);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('顶栏管理'),
        actions: [IconButton(icon: const Icon(Icons.save), tooltip: '保存', onPressed: () { _saveSettings(); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('设置已保存'))); })],
        bottom: TabBar(controller: _tabController, tabs: const [Tab(text: '日间'), Tab(text: '夜间')]),
      ),
      body: TabBarView(controller: _tabController, children: [_buildTopBarPanel(), _buildTopBarPanel()]),
    );
  }

  Widget _buildTopBarPanel() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          leading: const Icon(Icons.style),
          title: const Text('样式'),
          subtitle: Text(_style == 'default' ? '默认样式' : '常规样式'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showModalBottomSheet(context: context, builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [ListTile(title: const Text('默认样式'), onTap: () { setState(() => _style = 'default'); Navigator.pop(ctx); }), ListTile(title: const Text('常规样式'), onTap: () { setState(() => _style = 'regular'); Navigator.pop(ctx); })]))),
        ),
        ListTile(
          leading: const Icon(Icons.rounded_corner),
          title: const Text('圆角比例'),
          subtitle: Slider(value: _cornerScale, min: 0.5, max: 2.0, onChanged: (v) => setState(() => _cornerScale = v)),
          trailing: Text(_cornerScale.toStringAsFixed(1)),
        ),
        ListTile(
          leading: Container(width: 32, height: 32, decoration: BoxDecoration(color: _backgroundColor, borderRadius: BorderRadius.circular(8))),
          title: const Text('背景颜色'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showColorPicker('背景颜色', _backgroundColor, (c) => setState(() => _backgroundColor = c)),
        ),
        ListTile(
          leading: const Icon(Icons.opacity),
          title: const Text('壁纸透明度'),
          subtitle: Slider(value: _wallpaperAlpha.toDouble(), min: 0, max: 100, onChanged: (v) => setState(() => _wallpaperAlpha = v.round())),
          trailing: Text('$_wallpaperAlpha%'),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.expand),
          title: const Text('过滤器默认展开'),
          value: _expandFiltersByDefault,
          onChanged: (v) => setState(() => _expandFiltersByDefault = v),
        ),
      ],
    );
  }

  void _showColorPicker(String title, Color currentColor, ValueChanged<Color> onChanged) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Wrap(spacing: 8, runSpacing: 8, children: [Colors.red, Colors.pink, Colors.purple, Colors.deepPurple, Colors.indigo, Colors.blue, Colors.lightBlue, Colors.cyan, Colors.teal, Colors.green, Colors.lightGreen, Colors.lime, Colors.yellow, Colors.amber, Colors.orange, Colors.deepOrange, Colors.brown, Colors.grey, Colors.blueGrey, Colors.black, Colors.white].map((c) => GestureDetector(onTap: () { onChanged(c); Navigator.pop(ctx); }, child: Container(width: 40, height: 40, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(8), border: Border.all(color: c == currentColor ? Theme.of(context).colorScheme.primary : Colors.grey, width: c == currentColor ? 3 : 1))))).toList()),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消'))],
      ),
    );
  }
}

// 书籍信息管理页面
class BookInfoManagePage extends StatefulWidget {
  const BookInfoManagePage({super.key});
  @override
  State<BookInfoManagePage> createState() => _BookInfoManagePageState();
}

class _BookInfoManagePageState extends State<BookInfoManagePage> {
  final List<BookInfoItem> _items = [
    BookInfoItem('封面', Icons.image, true),
    BookInfoItem('书名', Icons.book, true),
    BookInfoItem('作者', Icons.person, true),
    BookInfoItem('简介', Icons.description, true),
    BookInfoItem('最新章节', Icons.bookmark, true),
    BookInfoItem('更新时间', Icons.update, true),
    BookInfoItem('阅读进度', Icons.bar_chart, true),
  ];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      for (var item in _items) {
        item.visible = prefs.getBool('bookInfo_${item.title}') ?? true;
      }
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    for (var item in _items) {
      await prefs.setBool('bookInfo_${item.title}', item.visible);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书籍信息管理'),
        actions: [
          IconButton(icon: const Icon(Icons.save), tooltip: '保存', onPressed: () { _saveSettings(); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('设置已保存'))); }),
          IconButton(icon: const Icon(Icons.refresh), tooltip: '重置', onPressed: () => setState(() { for (var item in _items) item.visible = true; })),
        ],
      ),
      body: ReorderableListView(
        padding: const EdgeInsets.all(16),
        onReorder: (oldIndex, newIndex) {
          setState(() {
            if (newIndex > oldIndex) newIndex--;
            final item = _items.removeAt(oldIndex);
            _items.insert(newIndex, item);
          });
        },
        children: _items.map((item) => ListTile(
          key: ValueKey(item.title),
          leading: Icon(item.icon, color: Theme.of(context).colorScheme.primary),
          title: Text(item.title),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Switch(value: item.visible, onChanged: (v) => setState(() => item.visible = v)),
            const Icon(Icons.drag_handle),
          ]),
        )).toList(),
      ),
    );
  }
}

class BookInfoItem {
  String title;
  IconData icon;
  bool visible;
  BookInfoItem(this.title, this.icon, this.visible);
}

// 气泡管理页面
class BubbleManagePage extends StatefulWidget {
  const BubbleManagePage({super.key});
  @override
  State<BubbleManagePage> createState() => _BubbleManagePageState();
}

class _BubbleManagePageState extends State<BubbleManagePage> {
  double _sizeScale = 1.0;
  Color _dayNormalColor = const Color(0xFFE0E0E0);
  Color _dayEmphasisColor = const Color(0xFF4CAF50);
  Color _nightNormalColor = const Color(0xFF424242);
  Color _nightEmphasisColor = const Color(0xFF4CAF50);

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _sizeScale = prefs.getDouble('bubbleSizeScale') ?? 1.0;
      _dayNormalColor = Color(prefs.getInt('bubbleDayNormalColor') ?? 0xFFE0E0E0);
      _dayEmphasisColor = Color(prefs.getInt('bubbleDayEmphasisColor') ?? 0xFF4CAF50);
      _nightNormalColor = Color(prefs.getInt('bubbleNightNormalColor') ?? 0xFF424242);
      _nightEmphasisColor = Color(prefs.getInt('bubbleNightEmphasisColor') ?? 0xFF4CAF50);
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('bubbleSizeScale', _sizeScale);
    await prefs.setInt('bubbleDayNormalColor', _dayNormalColor.value);
    await prefs.setInt('bubbleDayEmphasisColor', _dayEmphasisColor.value);
    await prefs.setInt('bubbleNightNormalColor', _nightNormalColor.value);
    await prefs.setInt('bubbleNightEmphasisColor', _nightEmphasisColor.value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('气泡管理'),
        actions: [IconButton(icon: const Icon(Icons.save), tooltip: '保存', onPressed: () { _saveSettings(); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('设置已保存'))); })],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.aspect_ratio),
            title: const Text('大小倍率'),
            subtitle: Slider(value: _sizeScale, min: 0.1, max: 3.0, divisions: 29, onChanged: (v) => setState(() => _sizeScale = v)),
            trailing: Text(_sizeScale.toStringAsFixed(1)),
          ),
          const Divider(),
          const Text('日间颜色', style: TextStyle(fontWeight: FontWeight.bold)),
          ListTile(
            leading: Container(width: 32, height: 32, decoration: BoxDecoration(color: _dayNormalColor, borderRadius: BorderRadius.circular(8))),
            title: const Text('常规色'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showColorPicker('常规色', _dayNormalColor, (c) => setState(() => _dayNormalColor = c)),
          ),
          ListTile(
            leading: Container(width: 32, height: 32, decoration: BoxDecoration(color: _dayEmphasisColor, borderRadius: BorderRadius.circular(8))),
            title: const Text('强调色'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showColorPicker('强调色', _dayEmphasisColor, (c) => setState(() => _dayEmphasisColor = c)),
          ),
          const Divider(),
          const Text('夜间颜色', style: TextStyle(fontWeight: FontWeight.bold)),
          ListTile(
            leading: Container(width: 32, height: 32, decoration: BoxDecoration(color: _nightNormalColor, borderRadius: BorderRadius.circular(8))),
            title: const Text('常规色'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showColorPicker('常规色', _nightNormalColor, (c) => setState(() => _nightNormalColor = c)),
          ),
          ListTile(
            leading: Container(width: 32, height: 32, decoration: BoxDecoration(color: _nightEmphasisColor, borderRadius: BorderRadius.circular(8))),
            title: const Text('强调色'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showColorPicker('强调色', _nightEmphasisColor, (c) => setState(() => _nightEmphasisColor = c)),
          ),
        ],
      ),
    );
  }

  void _showColorPicker(String title, Color currentColor, ValueChanged<Color> onChanged) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Wrap(spacing: 8, runSpacing: 8, children: [Colors.red, Colors.pink, Colors.purple, Colors.deepPurple, Colors.indigo, Colors.blue, Colors.lightBlue, Colors.cyan, Colors.teal, Colors.green, Colors.lightGreen, Colors.lime, Colors.yellow, Colors.amber, Colors.orange, Colors.deepOrange, Colors.brown, Colors.grey, Colors.blueGrey, Colors.black, Colors.white].map((c) => GestureDetector(onTap: () { onChanged(c); Navigator.pop(ctx); }, child: Container(width: 40, height: 40, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(8), border: Border.all(color: c == currentColor ? Theme.of(context).colorScheme.primary : Colors.grey, width: c == currentColor ? 3 : 1))))).toList()),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消'))],
      ),
    );
  }
}

// 封面配置页面
class CoverConfigPage extends StatefulWidget {
  const CoverConfigPage({super.key});
  @override
  State<CoverConfigPage> createState() => _CoverConfigPageState();
}

class _CoverConfigPageState extends State<CoverConfigPage> {
  String? _defaultCover;
  String? _defaultCoverDark;
  bool _coverShowName = true;
  bool _coverShowAuthor = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _defaultCover = prefs.getString('defaultCover');
      _defaultCoverDark = prefs.getString('defaultCoverDark');
      _coverShowName = prefs.getBool('coverShowName') ?? true;
      _coverShowAuthor = prefs.getBool('coverShowAuthor') ?? false;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (_defaultCover != null) await prefs.setString('defaultCover', _defaultCover!);
    else await prefs.remove('defaultCover');
    if (_defaultCoverDark != null) await prefs.setString('defaultCoverDark', _defaultCoverDark!);
    else await prefs.remove('defaultCoverDark');
    await prefs.setBool('coverShowName', _coverShowName);
    await prefs.setBool('coverShowAuthor', _coverShowAuthor);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('封面配置'),
        actions: [IconButton(icon: const Icon(Icons.save), tooltip: '保存', onPressed: () { _saveSettings(); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('设置已保存'))); })],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.image),
            title: const Text('日间默认封面'),
            subtitle: Text(_defaultCover ?? '未设置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _selectCover(false),
          ),
          ListTile(
            leading: const Icon(Icons.image),
            title: const Text('夜间默认封面'),
            subtitle: Text(_defaultCoverDark ?? '未设置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _selectCover(true),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.text_fields),
            title: const Text('显示书名'),
            value: _coverShowName,
            onChanged: (v) => setState(() => _coverShowName = v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.person),
            title: const Text('显示作者'),
            value: _coverShowAuthor,
            onChanged: (v) => setState(() => _coverShowAuthor = v),
          ),
        ],
      ),
    );
  }

  void _selectCover(bool isNight) {
    showModalBottomSheet(context: context, builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [ListTile(leading: const Icon(Icons.image), title: const Text('选择图片'), onTap: () { Navigator.pop(ctx); }), if ((isNight ? _defaultCoverDark : _defaultCover) != null) ListTile(leading: const Icon(Icons.delete, color: Colors.red), title: const Text('删除', style: TextStyle(color: Colors.red)), onTap: () { Navigator.pop(ctx); setState(() { if (isNight) _defaultCoverDark = null; else _defaultCover = null; }); })])));
  }
}
