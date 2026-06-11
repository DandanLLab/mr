import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
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
              title: '主题管理',
              subtitle: '管理日间/夜间主题颜色和背景',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ThemeManagePage())),
            ),
            _buildListItem(
              title: '导航栏管理',
              subtitle: '自定义底部导航栏样式',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NavigationBarManagePage())),
            ),
            _buildListItem(
              title: '顶栏管理',
              subtitle: '自定义顶部工具栏样式',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TopBarManagePage())),
            ),
            _buildListItem(
              title: '书籍信息管理',
              subtitle: '自定义书籍详情页样式',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BookInfoManagePage())),
            ),
            _buildListItem(
              title: '气泡管理',
              subtitle: '自定义气泡样式',
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BubbleManagePage())),
            ),
          ]),

          // 其他设置
          _buildCategoryTitle('其他设置'),
          _buildSection([
            _buildListItem(
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

  Widget _buildListItem({required String title, String? subtitle, VoidCallback? onTap}) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)) : null,
      trailing: Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
      onTap: onTap,
    );
  }

  Widget _buildSwitchItem({required String title, String? subtitle, required bool value, required ValueChanged<bool> onChanged}) {
    return ListTile(
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)) : null,
      trailing: Switch(value: value, onChanged: onChanged),
      onTap: () => onChanged(!value),
    );
  }
}

// 主题管理页面 - 完全参考 legado-main 的 ThemeManageActivity
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

    // 根据主题类型切换主题模式（参考原版 legado-main 的 applyConfig 方法）
    if (theme.isNight) {
      provider.setThemeMode(ThemeMode.dark);
      await provider.setNightThemeColors(
        primaryColor: theme.primaryColor,
        accentColor: theme.accentColor,
        backgroundColor: theme.backgroundColor,
        surfaceColor: theme.backgroundColor,
        backgroundImage: theme.mainBgImage ?? '',
        backgroundBlur: theme.bgImageBlur,
      );
    } else {
      provider.setThemeMode(ThemeMode.light);
      await provider.setDayThemeColors(
        primaryColor: theme.primaryColor,
        accentColor: theme.accentColor,
        backgroundColor: theme.backgroundColor,
        surfaceColor: theme.backgroundColor,
        backgroundImage: theme.mainBgImage ?? '',
        backgroundBlur: theme.bgImageBlur,
      );
    }
    setState(() => _activeThemeId = theme.id);
    await _saveThemes();

    // 显示提示信息
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已应用主题: ${theme.name}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('主题管理'),
        actions: [
          PopupMenuButton<String>(
            // 添加偏移量，避免遮挡其他按钮
            offset: const Offset(0, 48),
            onSelected: (value) {
              switch (value) {
                case 'export_all':
                  _exportAllThemes();
                  break;
                case 'import':
                  _importThemes();
                  break;
                case 'reset':
                  _resetToDefault();
                  break;
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'export_all',
                child: Text('导出全部主题'),
              ),
              const PopupMenuItem(
                value: 'import',
                child: Text('导入主题包'),
              ),
              const PopupMenuItem(
                value: 'reset',
                child: Text('恢复默认主题'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // TabBar - 完全参考 legado-main 的 tabBar 样式
          Container(
            margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            height: 42,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      if (_isNightTheme) {
                        setState(() => _isNightTheme = false);
                        await _saveThemes();
                      }
                    },
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: !_isNightTheme ? colorScheme.surface : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          '日间主题',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: !_isNightTheme ? colorScheme.primary : colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      if (!_isNightTheme) {
                        setState(() => _isNightTheme = true);
                        await _saveThemes();
                      }
                    },
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: _isNightTheme ? colorScheme.surface : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          '夜间主题',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _isNightTheme ? colorScheme.primary : colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // tv_summary - 摘要文本
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            constraints: const BoxConstraints(minHeight: 18),
            child: Text(
              _filteredThemes.isEmpty 
                ? '暂无${_isNightTheme ? "夜间" : "日间"}主题，点击下方添加'
                : '点击应用按钮应用主题，点击编辑按钮编辑主题',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          
          const SizedBox(height: 8),
          
          // RecyclerView - 主题列表
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: _filteredThemes.length,
              itemBuilder: (context, index) {
                final theme = _filteredThemes[index];
                final isActive = theme.id == _activeThemeId;
                return _buildThemeCard(theme, isActive);
              },
            ),
          ),
          
          // btn_add - 添加按钮 (半透明背景 + 边框)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            width: double.infinity,
            height: 48,
            decoration: BoxDecoration(
              color: colorScheme.surface.withOpacity(0.87), // 半透明背景，类似原版 book_info_frost
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: colorScheme.onSurface.withOpacity(0.4), // 类似原版 glass_stroke
                width: 1,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _showAddOptions,
              child: Center(
                child: Text(
                  '添加主题',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddOptions() {
    // 使用中间显示的选择对话框，匹配原版 legado-main 的 selector 样式
    // 原版使用 AlertDialog.setItems() 显示简单列表
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加主题'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDialogItem('手动配置', () {
              Navigator.pop(ctx);
              _addTheme();
            }),
            _buildDialogItem('导入主题包', () async {
              Navigator.pop(ctx);
              final result = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: ['zip'],
                allowCompression: false,
              );
              if (result != null && result.files.isNotEmpty) {
                final path = result.files.first.path;
                if (path != null) {
                  // TODO: 实现导入主题包功能
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('选择文件: $path')),
                  );
                }
              }
            }),
          ],
        ),
      ),
    );
  }
  
  Widget _buildDialogItem(String text, VoidCallback onTap, {bool isDestructive = false}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 16,
            color: isDestructive ? Theme.of(context).colorScheme.error : null,
          ),
        ),
      ),
    );
  }

  // 主题卡片 - 完全参考 legado-main 的 item_theme_package.xml
  Widget _buildThemeCard(ThemeConfig theme, bool isActive) {
    final colorScheme = Theme.of(context).colorScheme;
    final dateFormat = '${theme.updatedAt.year}-${theme.updatedAt.month.toString().padLeft(2, '0')}-${theme.updatedAt.day.toString().padLeft(2, '0')}';
    
    // 原版使用 bg_book_info_intro_panel 背景
    // 卡片背景是透明的，没有边框
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      constraints: const BoxConstraints(minHeight: 122),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // card_preview - 预览卡片 (74dp x 102dp)
          // 显示背景图片预览，参考原版 bindPreview 方法
          Container(
            width: 74,
            height: 102,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10), // ui_panel_radius
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                color: theme.backgroundColor,
                child: _buildThemePreview(theme),
              ),
            ),
          ),
          
          const SizedBox(width: 12),
          
          // lay_info - 信息区域
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 名称 + 来源标签
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        theme.name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (theme.isBuiltin)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        constraints: const BoxConstraints(maxWidth: 118),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Text(
                          '内置',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
                
                // tv_info - 信息文本
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${isActive ? "当前应用 · " : ""}${_isNightTheme ? "夜间" : "日间"} · $dateFormat',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                
                const SizedBox(height: 8),
                
                // 底部按钮
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      // btn_apply - 应用按钮
                      _buildActionButton('应用', () => _applyTheme(theme)),
                      
                      const SizedBox(width: 8),
                      
                      // btn_edit - 编辑按钮
                      _buildActionButton('编辑', () => _editTheme(theme)),
                      
                      const SizedBox(width: 8),
                      
                      // btn_more - 更多按钮
                      if (!theme.isBuiltin)
                        _buildActionButton('更多', () => _showMoreOptions(theme)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(String text, VoidCallback onTap) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        constraints: const BoxConstraints(minWidth: 56),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  /// 构建主题预览 - 参考原版 bindPreview 方法
  /// 如果有背景图片则显示背景图片，否则显示默认预览效果
  Widget _buildThemePreview(ThemeConfig theme) {
    final backgroundPath = theme.mainBgImage;
    
    // 如果有背景图片，显示背景图片
    if (backgroundPath != null && backgroundPath.isNotEmpty) {
      Widget imageWidget;
      
      if (backgroundPath.startsWith('http://') || backgroundPath.startsWith('https://')) {
        // 网络图片
        imageWidget = Image.network(
          backgroundPath,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            // 加载失败时显示默认预览
            return _buildDefaultPreview(theme);
          },
        );
      } else {
        // 本地文件
        imageWidget = Image.file(
          File(backgroundPath),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            // 加载失败时显示默认预览
            return _buildDefaultPreview(theme);
          },
        );
      }
      
      return imageWidget;
    }
    
    // 没有背景图片时，显示默认预览效果
    return _buildDefaultPreview(theme);
  }
  
  /// 构建默认预览效果 - 模拟主题样式
  Widget _buildDefaultPreview(ThemeConfig theme) {
    return Stack(
      children: [
        // 模拟主题预览
        Positioned(
          left: 8,
          top: 8,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: theme.primaryColor,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        Positioned(
          left: 8,
          top: 44,
          child: Container(
            width: 56,
            height: 8,
            decoration: BoxDecoration(
              color: theme.primaryColor.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Positioned(
          left: 8,
          top: 56,
          child: Container(
            width: 40,
            height: 8,
            decoration: BoxDecoration(
              color: theme.primaryColor.withOpacity(0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ],
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

    showDialog(
      context: context,
      builder: (ctx) => _ThemeEditDialog(
        theme: theme,
        isEdit: isEdit,
        onSave: (updatedTheme) async {
          if (isEdit) {
            setState(() {});
          } else {
            setState(() => _themes.add(updatedTheme));
          }
          await _saveThemes();
        },
      ),
    );
  }

  void _showMoreOptions(ThemeConfig theme) {
    // 使用中间显示的选择对话框，匹配原版 legado-main 的 selector 样式
    // 原版使用 AlertDialog.setItems() 显示简单列表
    // 根据原版 ThemeManageActivity.showActions() 的逻辑
    final items = <Widget>[];
    
    // 应用 - 始终显示
    items.add(_buildDialogItem('应用', () {
      Navigator.pop(context);
      _applyTheme(theme);
    }));
    
    // 非内置主题可以编辑和导出
    if (!theme.isBuiltin) {
      items.add(_buildDialogItem('编辑', () {
        Navigator.pop(context);
        _editTheme(theme);
      }));
      items.add(_buildDialogItem('导出主题包', () {
        Navigator.pop(context);
        _exportTheme(theme);
      }));
    }
    
    // 非内置主题且非当前应用的主题可以删除
    if (!theme.isBuiltin && theme.id != _activeThemeId) {
      items.add(_buildDialogItem('删除主题', () {
        Navigator.pop(context);
        _deleteTheme(theme);
      }, isDestructive: true));
    }
    
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(theme.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: items,
        ),
      ),
    );
  }

  void _exportTheme(ThemeConfig theme) {
    // 导出主题为 JSON
    final json = theme.toJson();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('主题配置已生成\n$json'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: '复制',
          onPressed: () {
            // 复制到剪贴板
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已复制到剪贴板')),
            );
          },
        ),
      ),
    );
  }

  void _exportAllThemes() {
    final customThemes = _themes.where((t) => !t.isBuiltin).toList();
    if (customThemes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可导出的自定义主题')),
      );
      return;
    }
    
    final jsonList = customThemes.map((t) => t.toJson()).join('\n');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已导出 ${customThemes.length} 个主题'),
        action: SnackBarAction(
          label: '查看',
          onPressed: () {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('导出数据'),
                content: SingleChildScrollView(
                  child: SelectableText(jsonList),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _importThemes() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入主题包'),
        content: const Text('请粘贴主题配置数据：'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('导入功能开发中...')),
              );
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  void _resetToDefault() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认主题'),
        content: const Text('确定要恢复默认主题吗？这将删除所有自定义主题。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              setState(() {
                _themes.removeWhere((t) => !t.isBuiltin);
              });
              await _saveThemes();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已恢复默认主题')),
              );
            },
            child: const Text('确定', style: TextStyle(color: Colors.red)),
          ),
        ],
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

// 主题编辑对话框 - 完全参考 legado-main 的 dialog_theme_package_edit.xml
class _ThemeEditDialog extends StatefulWidget {
  final ThemeConfig theme;
  final bool isEdit;
  final Future<void> Function(ThemeConfig) onSave;

  const _ThemeEditDialog({
    required this.theme,
    required this.isEdit,
    required this.onSave,
  });

  @override
  State<_ThemeEditDialog> createState() => _ThemeEditDialogState();
}

class _ThemeEditDialogState extends State<_ThemeEditDialog> {
  late ThemeConfig _theme;
  int _selectedTab = 0;
  final TextEditingController _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _theme = widget.theme;
    _nameController.text = _theme.name;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    // 完全匹配原版 legado-main 的对话框大小
    // EDIT_DIALOG_WIDTH_RATIO = 0.94f
    // EDIT_DIALOG_HEIGHT_RATIO = 0.68f (屏幕高度 >= 1600)
    // EDIT_DIALOG_HEIGHT_RATIO_COMPACT = 0.74f (屏幕高度 < 1600)
    final dialogWidth = screenWidth * 0.94;
    final dialogHeight = screenHeight < 1600 ? screenHeight * 0.74 : screenHeight * 0.68;

    return Dialog(
      insetPadding: EdgeInsets.zero,
      alignment: Alignment.center,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10), // ui_panel_radius = 10dp
      ),
      child: Container(
        width: dialogWidth,
        height: dialogHeight,
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            // 标题
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                widget.isEdit ? '编辑主题' : '添加主题',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ),

            const SizedBox(height: 12),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(2, 0, 2, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 名称输入框 - 高度 44dp
                    Container(
                      height: 44,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TextField(
                        controller: _nameController,
                        decoration: InputDecoration(
                          hintText: '主题名称',
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        style: const TextStyle(fontSize: 15),
                        onChanged: (v) => _theme.name = v,
                      ),
                    ),

                    const SizedBox(height: 10),

                    // 分组标签 - 高度 42dp
                    Container(
                      height: 42,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          _buildTabButton('颜色', 0),
                          _buildTabButton('图片', 1),
                          _buildTabButton('界面', 2),
                          _buildTabButton('字体', 3),
                        ],
                      ),
                    ),

                    const SizedBox(height: 10),

                    // 内容区域
                    _buildTabContent(),
                  ],
                ),
              ),
            ),

            // 底部按钮栏
            Container(
              padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // 取消按钮 - 宽度 96dp, 高度 40dp
                  SizedBox(
                    width: 96,
                    height: 40,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: colorScheme.surfaceContainerHighest,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () => Navigator.pop(context),
                      child: Text(
                        '取消',
                        style: TextStyle(
                          fontSize: 14,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 8),

                  // 确认按钮 - 宽度 96dp, 高度 40dp
                  SizedBox(
                    width: 96,
                    height: 40,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: colorScheme.surfaceContainerHighest,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () async {
                        await widget.onSave(_theme);
                        Navigator.pop(context);
                      },
                      child: Text(
                        '确定',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton(String label, int index) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSelected = _selectedTab == index;

    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedTab = index),
        child: Container(
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isSelected ? colorScheme.surface : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected ? colorScheme.primary : colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent() {
    switch (_selectedTab) {
      case 0:
        return _buildColorGroup();
      case 1:
        return _buildImageGroup();
      case 2:
        return _buildInterfaceGroup();
      case 3:
        return _buildFontGroup();
      default:
        return const SizedBox();
    }
  }

  // 颜色分组
  Widget _buildColorGroup() {
    return Column(
      children: [
        _buildColorOption('主色', _theme.primaryColor, (c) => setState(() => _theme.primaryColor = c)),
        _buildColorOption('强调色', _theme.accentColor, (c) => setState(() => _theme.accentColor = c)),
        _buildColorOption('背景色', _theme.backgroundColor, (c) => setState(() => _theme.backgroundColor = c)),
        _buildColorOption('底部背景色', _theme.navBarColor, (c) => setState(() => _theme.navBarColor = c)),
      ],
    );
  }

  // 图片分组
  Widget _buildImageGroup() {
    return Column(
      children: [
        _buildImageOption('主背景图片', _theme.mainBgImage, _theme.bgImageBlur, true, (path) => setState(() => _theme.mainBgImage = path), (blur) => setState(() => _theme.bgImageBlur = blur)),
        _buildImageOption('书籍信息背景', _theme.bookInfoBgImage, null, false, (path) => setState(() => _theme.bookInfoBgImage = path), null),
        _buildImageOption('面板背景', _theme.panelBgImage, null, false, (path) => setState(() => _theme.panelBgImage = path), null),
        _buildSelectOption('面板背景模式', _theme.panelBgMode == 'crop' ? '裁剪' : '适应', () {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: const Text('裁剪'),
                    onTap: () {
                      setState(() => _theme.panelBgMode = 'crop');
                      Navigator.pop(ctx);
                    },
                  ),
                  ListTile(
                    title: const Text('适应'),
                    onTap: () {
                      setState(() => _theme.panelBgMode = 'fit');
                      Navigator.pop(ctx);
                    },
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  // 界面分组
  Widget _buildInterfaceGroup() {
    return Column(
      children: [
        _buildSliderOption('圆角比例', _theme.cornerScale, 0.0, 3.0, (v) => setState(() => _theme.cornerScale = v)),
        _buildSliderOption('布局透明度', _theme.layoutAlpha.toDouble(), 0, 100, (v) => setState(() => _theme.layoutAlpha = v.round()), isPercentage: true),
        _buildColorOption('面板边框色', _theme.panelBorderColor ?? Colors.transparent, (c) => setState(() => _theme.panelBorderColor = c), canDisable: true),
        _buildSliderOption('边框透明度', _theme.panelBorderAlpha.toDouble(), 0, 100, (v) => setState(() => _theme.panelBorderAlpha = v.round()), isPercentage: true),
        _buildSwitchOption('搜索跟随主题', _theme.searchFollow, (v) => setState(() => _theme.searchFollow = v)),
        _buildSwitchOption('回复跟随主题', _theme.replyFollow, (v) => setState(() => _theme.replyFollow = v)),
      ],
    );
  }

  // 字体分组
  Widget _buildFontGroup() {
    return Column(
      children: [
        _buildSliderOption('字体缩放', _theme.fontScale.toDouble(), 8, 16, (v) => setState(() => _theme.fontScale = v.round()), showDefault: true, defaultValue: 10),
        _buildSelectOption('UI字体', _theme.uiFont ?? '默认', () => _showFontSelector(true)),
        _buildSelectOption('标题字体', _theme.titleFont ?? '默认', () => _showFontSelector(false)),
      ],
    );
  }

  // 选项行 - 高度 44dp
  Widget _buildOptionRow({required Widget child}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 44,
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }

  // 颜色选项
  Widget _buildColorOption(String title, Color color, ValueChanged<Color> onChanged, {bool canDisable = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    final colorHex = '#${color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

    return _buildOptionRow(
      child: GestureDetector(
        onTap: () => _showColorPicker(title, color, onChanged, canDisable: canDisable),
        child: Row(
          children: [
            // 标题
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface,
                ),
              ),
            ),

            // 颜色预览 - 22dp x 22dp
            Container(
              width: 22,
              height: 22,
              margin: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: colorScheme.onSurface.withOpacity(0.16),
                  width: 1,
                ),
              ),
            ),

            // 颜色值 - 宽度 132dp
            SizedBox(
              width: 132,
              child: Text(
                colorHex,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showColorPicker(String title, Color currentColor, ValueChanged<Color> onChanged, {bool canDisable = false}) {
    if (canDisable) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('禁用'),
                onTap: () {
                  Navigator.pop(ctx);
                  onChanged(Colors.transparent);
                },
              ),
              ListTile(
                title: const Text('选择颜色'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showColorPickerDialog(title, currentColor, onChanged);
                },
              ),
            ],
          ),
        ),
      );
    } else {
      _showColorPickerDialog(title, currentColor, onChanged);
    }
  }

  void _showColorPickerDialog(String title, Color currentColor, ValueChanged<Color> onChanged) {
    final colorScheme = Theme.of(context).colorScheme;
    
    // 初始 HSV 值
    double hue = HSVColor.fromColor(currentColor).hue;
    double saturation = HSVColor.fromColor(currentColor).saturation;
    double value = HSVColor.fromColor(currentColor).value;
    
    // 颜色编码输入控制器
    final colorController = TextEditingController(
      text: '#${currentColor.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
    );

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final selectedColor = HSVColor.fromAHSV(1.0, hue, saturation, value).toColor();
          
          // 更新颜色编码显示
          final colorHex = '#${selectedColor.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
          if (colorController.text != colorHex) {
            colorController.text = colorHex;
            colorController.selection = TextSelection.collapsed(offset: colorHex.length);
          }
          
          return Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10), // ui_panel_radius = 10dp
            ),
            child: Container(
              width: 320,
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // 颜色预览 - 大方块
                  Container(
                    width: double.infinity,
                    height: 80,
                    decoration: BoxDecoration(
                      color: selectedColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: colorScheme.outline,
                        width: 1,
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // 色相滑块
                  _buildColorSlider(
                    label: '色相',
                    value: hue,
                    min: 0,
                    max: 360,
                    onChanged: (v) => setDialogState(() => hue = v),
                    displayValue: hue.round().toString(),
                    gradientColors: [
                      const Color(0xFFFF0000), // 红
                      const Color(0xFFFFFF00), // 黄
                      const Color(0xFF00FF00), // 绿
                      const Color(0xFF00FFFF), // 青
                      const Color(0xFF0000FF), // 蓝
                      const Color(0xFFFF00FF), // 品红
                      const Color(0xFFFF0000), // 红
                    ],
                  ),
                  
                  const SizedBox(height: 12),
                  
                  // 饱和度滑块
                  _buildColorSlider(
                    label: '饱和度',
                    value: saturation,
                    min: 0,
                    max: 1,
                    onChanged: (v) => setDialogState(() => saturation = v),
                    displayValue: '${(saturation * 100).round()}%',
                    gradientColors: [
                      HSVColor.fromAHSV(1.0, hue, 0, value).toColor(),
                      HSVColor.fromAHSV(1.0, hue, 1, value).toColor(),
                    ],
                  ),
                  
                  const SizedBox(height: 12),
                  
                  // 明度滑块
                  _buildColorSlider(
                    label: '明度',
                    value: value,
                    min: 0,
                    max: 1,
                    onChanged: (v) => setDialogState(() => value = v),
                    displayValue: '${(value * 100).round()}%',
                    gradientColors: [
                      HSVColor.fromAHSV(1.0, hue, saturation, 0).toColor(),
                      HSVColor.fromAHSV(1.0, hue, saturation, 1).toColor(),
                    ],
                  ),
                  
                  const SizedBox(height: 20),
                  
                  // 按钮
                  Row(
                    children: [
                      // 颜色编码输入框
                      Expanded(
                        child: TextField(
                          controller: colorController,
                          decoration: InputDecoration(
                            hintText: '#RRGGBB',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
                          onSubmitted: (text) {
                            final color = _parseColor(text);
                            if (color != null) {
                              setDialogState(() {
                                hue = HSVColor.fromColor(color).hue;
                                saturation = HSVColor.fromColor(color).saturation;
                                value = HSVColor.fromColor(color).value;
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(
                          '取消',
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          onChanged(selectedColor);
                          Navigator.pop(ctx);
                        },
                        child: Text(
                          '确定',
                          style: TextStyle(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
  
  /// 解析颜色字符串，支持 #RRGGBB、#AARRGGBB、RRGGBB 等格式
  Color? _parseColor(String text) {
    text = text.trim();
    if (text.isEmpty) return null;
    
    // 移除 # 前缀
    if (text.startsWith('#')) {
      text = text.substring(1);
    }
    
    // 移除 0x 前缀
    if (text.toLowerCase().startsWith('0x')) {
      text = text.substring(2);
    }
    
    try {
      int colorValue;
      if (text.length == 6) {
        // RRGGBB 格式，添加完全不透明的 Alpha
        colorValue = int.parse(text, radix: 16) + 0xFF000000;
      } else if (text.length == 8) {
        // AARRGGBB 格式
        colorValue = int.parse(text, radix: 16);
      } else {
        return null;
      }
      return Color(colorValue);
    } catch (e) {
      return null;
    }
  }

  Widget _buildColorSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
    required String displayValue,
    required List<Color> gradientColors,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 50,
          child: Text(
            label,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              // 渐变背景
              Container(
                height: 24,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: gradientColors,
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              // 滑块
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: 24,
                  thumbColor: Colors.white,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  overlayColor: Colors.white.withOpacity(0.2),
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                ),
                child: Slider(
                  value: value,
                  min: min,
                  max: max,
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 50,
          child: Text(
            displayValue,
            style: const TextStyle(fontSize: 12),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  // 图片选项
  Widget _buildImageOption(String title, String? path, int? blur, bool showBlur, ValueChanged<String?> onPathChanged, ValueChanged<int>? onBlurChanged) {
    final colorScheme = Theme.of(context).colorScheme;
    String valueText;
    if (path == null || path.isEmpty) {
      if (showBlur && blur != null) {
        valueText = '未设置 (模糊: $blur)';
      } else {
        valueText = '未设置';
      }
    } else {
      final fileName = path.split('/').last;
      if (showBlur && blur != null) {
        valueText = '$fileName (模糊: $blur)';
      } else {
        valueText = fileName;
      }
    }

    return _buildOptionRow(
      child: GestureDetector(
        onTap: () => _showImageActions(title, path, blur, showBlur, onPathChanged, onBlurChanged),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            SizedBox(
              width: 132,
              child: Text(
                valueText,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showImageActions(String title, String? currentPath, int? currentBlur, bool showBlur, ValueChanged<String?> onPathChanged, ValueChanged<int>? onBlurChanged) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showBlur)
              ListTile(
                title: const Text('设置模糊度'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showBlurDialog(currentBlur ?? 0, onBlurChanged!);
                },
              ),
            ListTile(
              title: const Text('选择图片'),
              onTap: () async {
                Navigator.pop(ctx);
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.image,
                  allowCompression: false,
                );
                if (result != null && result.files.isNotEmpty) {
                  final path = result.files.first.path;
                  if (path != null) {
                    onPathChanged(path);
                  }
                }
              },
            ),
            ListTile(
              title: const Text('输入URL'),
              onTap: () {
                Navigator.pop(ctx);
                _showUrlInputDialog(title, onPathChanged);
              },
            ),
            if (currentPath != null && currentPath.isNotEmpty)
              ListTile(
                title: const Text('清除', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(ctx);
                  onPathChanged(null);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showBlurDialog(int currentBlur, ValueChanged<int> onBlurChanged) {
    int blur = currentBlur;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: const Text('背景图片模糊度'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: blur.toDouble(),
                  min: 0,
                  max: 25,
                  divisions: 25,
                  onChanged: (v) => setState(() => blur = v.round()),
                ),
                Text('模糊度: $blur'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  onBlurChanged(blur);
                  Navigator.pop(ctx);
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showUrlInputDialog(String title, ValueChanged<String?> onPathChanged) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '输入图片URL'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              onPathChanged(controller.text.isEmpty ? null : controller.text);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // 滑块选项
  Widget _buildSliderOption(String title, double value, double min, double max, ValueChanged<double> onChanged, {bool isPercentage = false, bool showDefault = false, double? defaultValue}) {
    final colorScheme = Theme.of(context).colorScheme;
    String valueText;
    if (showDefault && defaultValue != null && value == defaultValue) {
      valueText = '默认';
    } else if (isPercentage) {
      valueText = '${value.round()}%';
    } else if (value == value.roundToDouble()) {
      valueText = value.round().toString();
    } else {
      valueText = value.toStringAsFixed(1);
    }

    return _buildOptionRow(
      child: GestureDetector(
        onTap: () => _showNumberPickerDialog(title, value, min, max, onChanged, isPercentage: isPercentage, showDefault: showDefault, defaultValue: defaultValue),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            SizedBox(
              width: 132,
              child: Text(
                valueText,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showNumberPickerDialog(String title, double currentValue, double min, double max, ValueChanged<double> onChanged, {bool isPercentage = false, bool showDefault = false, double? defaultValue}) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          double value = currentValue;
          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: value,
                  min: min,
                  max: max,
                  divisions: ((max - min) * 10).round(),
                  onChanged: (v) => setState(() => value = v),
                ),
                Text(isPercentage ? '${value.round()}%' : value.toStringAsFixed(1)),
              ],
            ),
            actions: [
              if (showDefault && defaultValue != null)
                TextButton(
                  onPressed: () {
                    onChanged(defaultValue);
                    Navigator.pop(ctx);
                  },
                  child: const Text('默认'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  onChanged(value);
                  Navigator.pop(ctx);
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
  }

  // 选择选项
  Widget _buildSelectOption(String title, String value, VoidCallback onTap) {
    final colorScheme = Theme.of(context).colorScheme;

    return _buildOptionRow(
      child: GestureDetector(
        onTap: onTap,
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            SizedBox(
              width: 132,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 开关选项
  Widget _buildSwitchOption(String title, bool value, ValueChanged<bool> onChanged) {
    final colorScheme = Theme.of(context).colorScheme;

    return _buildOptionRow(
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            SizedBox(
              width: 132,
              child: Text(
                value ? '启用' : '禁用',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFontSelector(bool isUiFont) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('默认字体'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  if (isUiFont) {
                    _theme.uiFont = null;
                  } else {
                    _theme.titleFont = null;
                  }
                });
              },
            ),
            ListTile(
              title: const Text('选择字体文件'),
              onTap: () async {
                Navigator.pop(ctx);
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['ttf', 'otf'],
                  allowCompression: false,
                );
                if (result != null && result.files.isNotEmpty) {
                  final path = result.files.first.path;
                  if (path != null) {
                    setState(() {
                      if (isUiFont) {
                        _theme.uiFont = path;
                      } else {
                        _theme.titleFont = path;
                      }
                    });
                  }
                }
              },
            ),
          ],
        ),
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
  // 时间戳
  DateTime updatedAt;

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
    this.searchFollow = false,
    this.replyFollow = false,
    this.fontScale = 10,
    this.uiFont,
    this.titleFont,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  String toJson() {
    return '$id|$name|$isNight|$isBuiltin|${primaryColor.value}|${accentColor.value}|${backgroundColor.value}|${navBarColor.value}|${mainBgImage ?? ''}|$bgImageBlur|${bookInfoBgImage ?? ''}|${panelBgImage ?? ''}|$panelBgMode|$cornerScale|$layoutAlpha|${panelBorderColor?.value ?? 0}|$panelBorderAlpha|$searchFollow|$replyFollow|$fontScale|${uiFont ?? ''}|${titleFont ?? ''}|${updatedAt.millisecondsSinceEpoch}';
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
      updatedAt: parts.length > 22 ? DateTime.fromMillisecondsSinceEpoch(int.parse(parts[22])) : DateTime.now(),
    );
  }
}

// 导航栏管理页面
class NavigationBarManagePage extends StatefulWidget {
  const NavigationBarManagePage({super.key});
  @override
  State<NavigationBarManagePage> createState() => _NavigationBarManagePageState();
}

class _NavigationBarManagePageState extends State<NavigationBarManagePage> {
  bool _isNightMode = false;
  
  // 导航栏配置
  String _layoutMode = 'floating';
  String _sidebarGravity = 'start';
  bool _showSearchButton = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isNightMode = prefs.getBool('navIsNightMode') ?? false;
      _layoutMode = prefs.getString('navLayoutMode') ?? 'floating';
      _sidebarGravity = prefs.getString('navSidebarGravity') ?? 'start';
      _showSearchButton = prefs.getBool('navShowSearchButton') ?? false;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('navIsNightMode', _isNightMode);
    await prefs.setString('navLayoutMode', _layoutMode);
    await prefs.setString('navSidebarGravity', _sidebarGravity);
    await prefs.setBool('navShowSearchButton', _showSearchButton);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
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
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _isNightMode = false),
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: !_isNightMode ? colorScheme.surface : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          '日间',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: !_isNightMode ? colorScheme.primary : colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _isNightMode = true),
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: _isNightMode ? colorScheme.surface : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          '夜间',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _isNightMode ? colorScheme.primary : colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 16),
          
          // 布局设置
          _buildCategoryTitle('布局设置'),
          _buildSection([
            ListTile(
              title: const Text('布局模式'),
              subtitle: Text(_getLayoutModeText()),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showLayoutModePicker,
            ),
            if (_layoutMode == 'sidebar')
              ListTile(
                title: const Text('侧边栏位置'),
                subtitle: Text(_sidebarGravity == 'start' ? '左侧' : '右侧'),
                trailing: Switch(
                  value: _sidebarGravity == 'end',
                  onChanged: (v) => setState(() => _sidebarGravity = v ? 'end' : 'start'),
                ),
              ),
          ]),
          
          const SizedBox(height: 16),
          
          // 其他设置
          _buildCategoryTitle('其他设置'),
          _buildSection([
            SwitchListTile(
              title: const Text('显示搜索按钮'),
              subtitle: const Text('在导航栏右侧显示独立的搜索按钮'),
              value: _showSearchButton,
              onChanged: (v) => setState(() => _showSearchButton = v),
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

  void _showLayoutModePicker() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('悬浮导航栏'),
              subtitle: const Text('玻璃效果 + 悬浮在底部'),
              trailing: _layoutMode == 'floating' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _layoutMode = 'floating');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('标准导航栏'),
              subtitle: const Text('传统底部导航栏样式'),
              trailing: _layoutMode == 'standard' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _layoutMode = 'standard');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
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
}

// 顶栏管理页面
class TopBarManagePage extends StatefulWidget {
  const TopBarManagePage({super.key});
  @override
  State<TopBarManagePage> createState() => _TopBarManagePageState();
}

class _TopBarManagePageState extends State<TopBarManagePage> {
  String _style = 'default';
  double _cornerScale = 1.0;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _style = prefs.getString('topBarStyle') ?? 'default';
      _cornerScale = prefs.getDouble('topBarCornerScale') ?? 1.0;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('topBarStyle', _style);
    await prefs.setDouble('topBarCornerScale', _cornerScale);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('顶栏管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: '保存',
            onPressed: () {
              _saveSettings();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('设置已保存')));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: const Text('样式'),
            subtitle: Text(_style == 'default' ? '默认样式' : '常规样式'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showModalBottomSheet(
              context: context,
              builder: (ctx) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      title: const Text('默认样式'),
                      onTap: () {
                        setState(() => _style = 'default');
                        Navigator.pop(ctx);
                      },
                    ),
                    ListTile(
                      title: const Text('常规样式'),
                      onTap: () {
                        setState(() => _style = 'regular');
                        Navigator.pop(ctx);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          ListTile(
            title: const Text('圆角比例'),
            subtitle: Slider(
              value: _cornerScale,
              min: 0.5,
              max: 2.0,
              onChanged: (v) => setState(() => _cornerScale = v),
            ),
            trailing: Text(_cornerScale.toStringAsFixed(1)),
          ),
        ],
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
    BookInfoItem('封面', true),
    BookInfoItem('书名', true),
    BookInfoItem('作者', true),
    BookInfoItem('简介', true),
    BookInfoItem('最新章节', true),
    BookInfoItem('更新时间', true),
    BookInfoItem('阅读进度', true),
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
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: '保存',
            onPressed: () {
              _saveSettings();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('设置已保存')));
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重置',
            onPressed: () => setState(() {
              for (var item in _items) item.visible = true;
            }),
          ),
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
          title: Text(item.title),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(value: item.visible, onChanged: (v) => setState(() => item.visible = v)),
              const Icon(Icons.drag_handle),
            ],
          ),
        )).toList(),
      ),
    );
  }
}

class BookInfoItem {
  String title;
  bool visible;
  BookInfoItem(this.title, this.visible);
}

// 气泡管理页面
class BubbleManagePage extends StatefulWidget {
  const BubbleManagePage({super.key});
  @override
  State<BubbleManagePage> createState() => _BubbleManagePageState();
}

class _BubbleManagePageState extends State<BubbleManagePage> {
  double _sizeScale = 1.0;
  Color _dayColor = const Color(0xFFF5F5F5);
  Color _nightColor = const Color(0xFF424242);

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _sizeScale = prefs.getDouble('bubbleSizeScale') ?? 1.0;
      _dayColor = Color(prefs.getInt('bubbleDayColor') ?? 0xFFF5F5F5);
      _nightColor = Color(prefs.getInt('bubbleNightColor') ?? 0xFF424242);
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('bubbleSizeScale', _sizeScale);
    await prefs.setInt('bubbleDayColor', _dayColor.value);
    await prefs.setInt('bubbleNightColor', _nightColor.value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('气泡管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: '保存',
            onPressed: () {
              _saveSettings();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('设置已保存')));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: const Text('大小倍率'),
            subtitle: Slider(
              value: _sizeScale,
              min: 0.5,
              max: 2.0,
              divisions: 15,
              onChanged: (v) => setState(() => _sizeScale = v),
            ),
            trailing: Text(_sizeScale.toStringAsFixed(1)),
          ),
          ListTile(
            leading: Container(width: 32, height: 32, decoration: BoxDecoration(color: _dayColor, borderRadius: BorderRadius.circular(8))),
            title: const Text('日间颜色'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showColorPicker('日间颜色', _dayColor, (c) => setState(() => _dayColor = c)),
          ),
          ListTile(
            leading: Container(width: 32, height: 32, decoration: BoxDecoration(color: _nightColor, borderRadius: BorderRadius.circular(8))),
            title: const Text('夜间颜色'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showColorPicker('夜间颜色', _nightColor, (c) => setState(() => _nightColor = c)),
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
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Colors.red, Colors.pink, Colors.purple, Colors.deepPurple,
            Colors.indigo, Colors.blue, Colors.lightBlue, Colors.cyan,
            Colors.teal, Colors.green, Colors.lightGreen, Colors.lime,
            Colors.yellow, Colors.amber, Colors.orange, Colors.deepOrange,
            Colors.brown, Colors.grey, Colors.blueGrey, Colors.black, Colors.white,
          ].map((c) => GestureDetector(
            onTap: () {
              onChanged(c);
              Navigator.pop(ctx);
            },
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: c == currentColor ? Theme.of(context).colorScheme.primary : Colors.grey,
                  width: c == currentColor ? 3 : 1,
                ),
              ),
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

// 封面配置页面
class CoverConfigPage extends StatefulWidget {
  const CoverConfigPage({super.key});
  @override
  State<CoverConfigPage> createState() => _CoverConfigPageState();
}

class _CoverConfigPageState extends State<CoverConfigPage> {
  String _dayDefaultCover = '';
  String _nightDefaultCover = '';
  bool _showBookName = true;
  bool _showAuthor = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _dayDefaultCover = prefs.getString('coverDayDefault') ?? '';
      _nightDefaultCover = prefs.getString('coverNightDefault') ?? '';
      _showBookName = prefs.getBool('coverShowBookName') ?? true;
      _showAuthor = prefs.getBool('coverShowAuthor') ?? true;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('coverDayDefault', _dayDefaultCover);
    await prefs.setString('coverNightDefault', _nightDefaultCover);
    await prefs.setBool('coverShowBookName', _showBookName);
    await prefs.setBool('coverShowAuthor', _showAuthor);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('封面配置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: '保存',
            onPressed: () {
              _saveSettings();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('设置已保存')));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: const Text('日间默认封面'),
            subtitle: Text(_dayDefaultCover.isEmpty ? '未设置' : _dayDefaultCover.split('/').last),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _selectCover('日间默认封面', (path) => setState(() => _dayDefaultCover = path ?? '')),
          ),
          ListTile(
            title: const Text('夜间默认封面'),
            subtitle: Text(_nightDefaultCover.isEmpty ? '未设置' : _nightDefaultCover.split('/').last),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _selectCover('夜间默认封面', (path) => setState(() => _nightDefaultCover = path ?? '')),
          ),
          SwitchListTile(
            title: const Text('显示书名'),
            value: _showBookName,
            onChanged: (v) => setState(() => _showBookName = v),
          ),
          SwitchListTile(
            title: const Text('显示作者'),
            value: _showAuthor,
            onChanged: (v) => setState(() => _showAuthor = v),
          ),
        ],
      ),
    );
  }

  void _selectCover(String title, ValueChanged<String?> onSelected) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('选择图片'),
              onTap: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('图片选择功能开发中...')));
              },
            ),
            ListTile(
              title: const Text('清除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                onSelected(null);
              },
            ),
          ],
        ),
      ),
    );
  }
}
