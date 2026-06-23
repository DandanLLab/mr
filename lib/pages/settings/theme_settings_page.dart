import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../../providers/app_provider.dart';
import '../../routes/app_routes.dart';
import '../../services/cover_config_service.dart';
import '../../widgets/android_switch.dart';
import '../../widgets/common_widgets.dart';

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
    final isDark = provider.themeMode == ThemeMode.dark ||
        (provider.themeMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);

    return Scaffold(
      appBar: AppBar(
        title: const Text('主题设置'),
        actions: [
          IconButton(
            icon: Icon(
              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
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
              onTap: () => Navigator.push(context, AppPageRoute(builder: (_) => const ThemeManagePage())),
            ),
            _buildListItem(
              title: '底栏管理',
              subtitle: '管理日间/夜间底栏样式和布局',
              onTap: () => Navigator.push(context, AppPageRoute(builder: (_) => const NavigationBarManagePage())),
            ),
            _buildListItem(
              title: '顶栏管理',
              subtitle: '管理日间/夜间顶栏样式和布局',
              onTap: () => Navigator.push(context, AppPageRoute(builder: (_) => const TopBarManagePage())),
            ),
            _buildListItem(
              title: '书籍信息管理',
              subtitle: '自定义书籍详情页样式',
              onTap: () => Navigator.push(context, AppPageRoute(builder: (_) => const BookInfoManagePage())),
            ),
            _buildListItem(
              title: '气泡管理',
              subtitle: '自定义气泡样式',
              onTap: () => Navigator.push(context, AppPageRoute(builder: (_) => const BubbleManagePage())),
            ),
          ]),

          // 其他设置
          _buildCategoryTitle('其他设置'),
          _buildSection([
            _buildListItem(
              title: '封面设置',
              subtitle: '通用封面规则及默认封面样式',
              onTap: () => Navigator.push(context, AppPageRoute(builder: (_) => const CoverConfigPage())),
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
      child: Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.secondary)),
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

  Widget _buildListItem({required String title, String? subtitle, VoidCallback? onTap}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 参考 legado-main: 日间 primaryText=#de000000(87%黑), 夜间 primaryText=#ffffffff(100%白)
    final primaryTextColor = isDark 
        ? const Color(0xDEFFFFFF)  // 夜间：87%白
        : const Color(0xDE000000); // 日间：87%黑
    final secondaryTextColor = isDark 
        ? const Color(0xB3FFFFFF)  // 夜间：70%白
        : const Color(0x8A000000); // 日间：54%黑
    return ListTile(
      title: Text(title, style: TextStyle(color: primaryTextColor)),
      subtitle: subtitle != null 
          ? Text(subtitle, style: TextStyle(fontSize: 12, color: secondaryTextColor)) 
          : null,
      trailing: Icon(Icons.chevron_right, color: secondaryTextColor),
      onTap: onTap,
    );
  }

  Widget _buildSwitchItem({required String title, String? subtitle, required bool value, required ValueChanged<bool> onChanged}) {
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

  Future<void> _switchThemeMode(bool isNightTheme) async {
    final prefs = await SharedPreferences.getInstance();
    final nextActiveThemeId = prefs.getString(
      isNightTheme ? 'activeNightThemeId' : 'activeDayThemeId',
    );
    final fallbackTheme = _themes
        .where((t) => t.isNight == isNightTheme)
        .toList()
        .firstOrNull;

    setState(() {
      _isNightTheme = isNightTheme;
      _activeThemeId = (nextActiveThemeId != null && nextActiveThemeId.isNotEmpty)
          ? nextActiveThemeId
          : fallbackTheme?.id;
    });

    await prefs.setBool('themeIsNight', _isNightTheme);
    await prefs.setString(
      _isNightTheme ? 'activeNightThemeId' : 'activeDayThemeId',
      _activeThemeId ?? '',
    );
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
        navBarColor: theme.navBarColor,
        backgroundImage: theme.mainBgImage ?? '',
        backgroundBlur: theme.bgImageBlur,
        bookInfoBackgroundImage: theme.bookInfoBgImage ?? '',
        panelBackgroundImage: theme.panelBgImage ?? '',
        panelBackgroundMode: theme.panelBgMode,
        cornerScale: theme.cornerScale,
        layoutAlpha: theme.layoutAlpha,
        panelBorderColor: theme.panelBorderColor ?? Colors.transparent,
        panelBorderAlpha: theme.panelBorderAlpha,
        searchFollow: theme.searchFollow,
        replyFollow: theme.replyFollow,
        fontScale: theme.fontScale,
        uiFontPath: theme.uiFont ?? '',
        titleFontPath: theme.titleFont ?? '',
      );
    } else {
      provider.setThemeMode(ThemeMode.light);
      await provider.setDayThemeColors(
        primaryColor: theme.primaryColor,
        accentColor: theme.accentColor,
        backgroundColor: theme.backgroundColor,
        surfaceColor: theme.backgroundColor,
        navBarColor: theme.navBarColor,
        backgroundImage: theme.mainBgImage ?? '',
        backgroundBlur: theme.bgImageBlur,
        bookInfoBackgroundImage: theme.bookInfoBgImage ?? '',
        panelBackgroundImage: theme.panelBgImage ?? '',
        panelBackgroundMode: theme.panelBgMode,
        cornerScale: theme.cornerScale,
        layoutAlpha: theme.layoutAlpha,
        panelBorderColor: theme.panelBorderColor ?? Colors.transparent,
        panelBorderAlpha: theme.panelBorderAlpha,
        searchFollow: theme.searchFollow,
        replyFollow: theme.replyFollow,
        fontScale: theme.fontScale,
        uiFontPath: theme.uiFont ?? '',
        titleFontPath: theme.titleFont ?? '',
      );
    }
    setState(() => _activeThemeId = theme.id);
    await _saveThemes();
    await _recordCloudSyncTask('主题已应用', theme);

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('主题管理'),
        actions: [
          PopupMenuButton<String>(
            offset: const Offset(0, 48),
            onSelected: (value) {
              switch (value) {
                case 'export_all':
                  _exportAllThemes();
                  break;
                case 'import':
                  _importThemes();
                  break;
                case 'cloud_sync_tasks':
                  Navigator.push(
                    context,
                    AppPageRoute(builder: (_) => const CloudSyncTaskPage()),
                  );
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
                value: 'cloud_sync_tasks',
                child: Text('云端同步任务'),
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
              color: isDark 
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      if (_isNightTheme) {
                        await _switchThemeMode(false);
                      }
                    },
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: !_isNightTheme 
                            ? (isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.06))
                            : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          '日间主题',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: !_isNightTheme 
                                ? colorScheme.secondary // 使用强调色
                                : (isDark ? const Color(0xDEFFFFFF) : const Color(0xDE000000)),
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
                        await _switchThemeMode(true);
                      }
                    },
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: _isNightTheme 
                            ? (isDark ? Colors.white.withValues(alpha: 0.12) : Colors.black.withValues(alpha: 0.06))
                            : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          '夜间主题',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _isNightTheme 
                                ? colorScheme.secondary // 使用强调色
                                : (isDark ? const Color(0xDEFFFFFF) : const Color(0xDE000000)),
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
                color: isDark 
                    ? const Color(0xB3FFFFFF)  // 夜间：70%白
                    : const Color(0x8A000000), // 日间：54%黑
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
              color: isDark 
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isDark 
                    ? Colors.white.withValues(alpha: 0.15)
                    : Colors.black.withValues(alpha: 0.08),
                width: 1,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _addTheme,
              child: const Center(
                child: Text(
                  '添加主题',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 主题卡片 - 完全参考 legado-main 的 item_theme_package.xml
  Widget _buildThemeCard(ThemeConfig theme, bool isActive) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dateFormat = '${theme.updatedAt.year}-${theme.updatedAt.month.toString().padLeft(2, '0')}-${theme.updatedAt.day.toString().padLeft(2, '0')}';
    
    // 参考 legado-main: 日间 primaryText=#de000000(87%黑), 夜间 primaryText=#ffffffff(100%白)
    final primaryTextColor = isDark 
        ? const Color(0xDEFFFFFF)  // 夜间：87%白
        : const Color(0xDE000000); // 日间：87%黑
    final secondaryTextColor = isDark 
        ? const Color(0xB3FFFFFF)  // 夜间：70%白
        : const Color(0x8A000000); // 日间：54%黑
    
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
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.hardEdge,
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
                          color: primaryTextColor,
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
                          color: isDark 
                              ? Colors.white.withValues(alpha: 0.12)
                              : Colors.black.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Text(
                          '内置',
                          style: TextStyle(
                            fontSize: 12,
                            color: primaryTextColor,
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
                      color: secondaryTextColor,
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
                      _buildActionButton(
                        isActive ? '已应用' : '应用',
                        () => _applyTheme(theme),
                        textColor: isActive ? Colors.red : null,
                        isDark: isDark,
                        primaryTextColor: primaryTextColor,
                      ),
                      
                      const SizedBox(width: 8),
                      
                      // btn_edit - 编辑按钮
                      _buildActionButton('编辑', () => _editTheme(theme), 
                        isDark: isDark, 
                        primaryTextColor: primaryTextColor,
                      ),
                      
                      const SizedBox(width: 8),
                      
                      // btn_more - 更多按钮
                      if (!theme.isBuiltin)
                        _buildActionButton('更多', () => _showMoreOptions(theme),
                          isDark: isDark,
                          primaryTextColor: primaryTextColor,
                        ),
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

  Widget _buildActionButton(
    String text,
    VoidCallback onTap, {
    Color? textColor,
    bool isDark = false,
    Color? primaryTextColor,
  }) {
    // 参考 legado-main: 日间 background_menu=#F1F2F6, 夜间 background_menu=#252528
    final bgColor = isDark 
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.04);
    final defaultTextColor = primaryTextColor ?? 
        (isDark ? const Color(0xDEFFFFFF) : const Color(0xDE000000));
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        constraints: const BoxConstraints(minWidth: 56),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: textColor ?? defaultTextColor,
              fontWeight: textColor == null ? FontWeight.normal : FontWeight.w600,
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
              color: theme.primaryColor.withValues(alpha: 0.3),
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
              color: theme.primaryColor.withValues(alpha: 0.2),
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
    final isBuiltinCopy = existing?.isBuiltin == true;
    final isEdit = existing != null && !isBuiltinCopy;
    final theme = existing?.copy() ?? ThemeConfig(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: '新主题',
      isNight: _isNightTheme,
      isBuiltin: false,
      primaryColor: _isNightTheme ? const Color(0xFF303030) : const Color(0xFF795548),
      accentColor: _isNightTheme ? const Color(0xFFE0E0E0) : const Color(0xFFE53935),
      backgroundColor: _isNightTheme ? const Color(0xFF424242) : const Color(0xFFF5F5F5),
      navBarColor: _isNightTheme ? const Color(0xFF424242) : const Color(0xFFEEEEEE),
    );
    if (isBuiltinCopy) {
      theme
        ..id = 'custom_${DateTime.now().millisecondsSinceEpoch}'
        ..name = '${theme.name} 副本'
        ..isBuiltin = false
        ..updatedAt = DateTime.now();
    }

    showDialog(
      context: context,
      builder: (ctx) => _ThemeEditDialog(
        theme: theme,
        isEdit: isEdit,
        onSave: (updatedTheme) async {
          if (isEdit) {
            final index = _themes.indexWhere((item) => item.id == updatedTheme.id);
            if (index >= 0) {
              setState(() => _themes[index] = updatedTheme);
            }
          } else {
            setState(() => _themes.add(updatedTheme));
          }
          await _saveThemes();
          await _recordCloudSyncTask('主题已保存', updatedTheme);
          if (isEdit && updatedTheme.id == _activeThemeId) {
            await _applyTheme(updatedTheme);
          }
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
      items.add(_buildDialogItem('复制主题', () {
        Navigator.pop(context);
        _copyTheme(theme);
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

  // 对话框列表项构建器
  Widget _buildDialogItem(String text, VoidCallback onTap, {bool isDestructive = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark
        ? const Color(0xDEFFFFFF)  // 夜间：87%白
        : const Color(0xDE000000); // 日间：87%黑
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 16,
            color: isDestructive ? Theme.of(context).colorScheme.error : primaryTextColor,
          ),
        ),
      ),
    );
  }

  void _exportTheme(ThemeConfig theme) {
    final json = theme.toJson();
    Share.share(json, subject: '主题分享');
  }

  Future<void> _copyTheme(ThemeConfig theme) async {
    final json = theme.toJson();
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板')),
    );
  }

  Future<void> _recordCloudSyncTask(String action, ThemeConfig theme) async {
    final prefs = await SharedPreferences.getInstance();
    final tasks = prefs.getStringList('cloudSyncTasks') ?? [];
    tasks.insert(
      0,
      jsonEncode({
        'action': action,
        'themeId': theme.id,
        'themeName': theme.name,
        'time': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    if (tasks.length > 20) {
      tasks.removeRange(20, tasks.length);
    }
    await prefs.setStringList('cloudSyncTasks', tasks);
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
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入主题包'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            minLines: 5,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: '粘贴一个或多个主题配置，每行一个',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final lines = controller.text
                  .split(RegExp(r'[\r\n]+'))
                  .map((line) => line.trim())
                  .where((line) => line.isNotEmpty);
              final imported = <ThemeConfig>[];
              var failed = 0;
              for (final line in lines) {
                try {
                  final theme = ThemeConfig.fromJson(line)
                    ..id = 'custom_${DateTime.now().microsecondsSinceEpoch}_${imported.length}'
                    ..isBuiltin = false
                    ..updatedAt = DateTime.now();
                  imported.add(theme);
                } catch (_) {
                  failed++;
                }
              }
              if (imported.isNotEmpty) {
                setState(() => _themes.addAll(imported));
                await _saveThemes();
              }
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    imported.isEmpty
                        ? '没有可导入的有效主题'
                        : '已导入 ${imported.length} 个主题${failed > 0 ? '，$failed 个失败' : ''}',
                  ),
                ),
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

class CloudSyncTaskPage extends StatefulWidget {
  const CloudSyncTaskPage({super.key});

  @override
  State<CloudSyncTaskPage> createState() => _CloudSyncTaskPageState();
}

class _CloudSyncTaskPageState extends State<CloudSyncTaskPage> {
  final List<_CloudSyncTaskEntry> _tasks = [];

  @override
  void initState() {
    super.initState();
    _loadTasks();
  }

  Future<void> _loadTasks() async {
    final prefs = await SharedPreferences.getInstance();
    final rawTasks = prefs.getStringList('cloudSyncTasks') ?? [];
    final tasks = <_CloudSyncTaskEntry>[];
    for (final raw in rawTasks) {
      try {
        tasks.add(_CloudSyncTaskEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } catch (_) {
        continue;
      }
    }
    if (!mounted) return;
    setState(() {
      _tasks
        ..clear()
        ..addAll(tasks);
    });
  }

  Future<void> _clearTasks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('cloudSyncTasks');
    if (!mounted) return;
    setState(_tasks.clear);
  }

  String _formatTime(int millisecondsSinceEpoch) {
    final time = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('云端同步任务'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loadTasks,
          ),
          if (_tasks.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空',
              onPressed: _clearTasks,
            ),
        ],
      ),
      body: _tasks.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '暂无云端同步任务\n\n主题被应用、保存或复制后，会在这里记录待同步项。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _tasks.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final task = _tasks[index];
                return Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.action,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        task.themeName,
                        style: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatTime(task.time),
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _CloudSyncTaskEntry {
  final String action;
  final String themeName;
  final int time;

  _CloudSyncTaskEntry({
    required this.action,
    required this.themeName,
    required this.time,
  });

  factory _CloudSyncTaskEntry.fromJson(Map<String, dynamic> json) {
    return _CloudSyncTaskEntry(
      action: json['action'] as String? ?? '同步任务',
      themeName: json['themeName'] as String? ?? '未知主题',
      time: json['time'] as int? ?? DateTime.now().millisecondsSinceEpoch,
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
    _theme = widget.theme.copy();
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
                  color: colorScheme.onSurface.withValues(alpha: 0.16),
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
    bool isEditingColorCode = false;
    
    // 颜色编码输入控制器
    final colorController = TextEditingController(
      text: '#${currentColor.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
    );
    final colorFocusNode = FocusNode();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final selectedColor = HSVColor.fromAHSV(1.0, hue, saturation, value).toColor();
          
          // 滑动调色时同步编码；手动输入期间不覆盖用户正在编辑的内容。
          final colorHex = '#${selectedColor.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
          if (!isEditingColorCode && colorController.text != colorHex) {
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
                    onChanged: (v) {
                      colorFocusNode.unfocus();
                      setDialogState(() {
                        isEditingColorCode = false;
                        hue = v;
                      });
                    },
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
                    onChanged: (v) {
                      colorFocusNode.unfocus();
                      setDialogState(() {
                        isEditingColorCode = false;
                        saturation = v;
                      });
                    },
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
                    onChanged: (v) {
                      colorFocusNode.unfocus();
                      setDialogState(() {
                        isEditingColorCode = false;
                        value = v;
                      });
                    },
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
                          focusNode: colorFocusNode,
                          decoration: InputDecoration(
                            hintText: '#RRGGBB',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                           ),
                           style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
                           keyboardType: TextInputType.text,
                           textCapitalization: TextCapitalization.characters,
                           autocorrect: false,
                           enableSuggestions: false,
                           onTap: () {
                             isEditingColorCode = true;
                           },
                           onChanged: (text) {
                             final color = _parseColor(text);
                             if (color == null) return;
                             final hsv = HSVColor.fromColor(color);
                             setDialogState(() {
                               hue = hsv.hue;
                               saturation = hsv.saturation;
                               value = hsv.value;
                             });
                           },
                           onSubmitted: (text) {
                             final color = _parseColor(text);
                             if (color != null) {
                               final hsv = HSVColor.fromColor(color);
                               setDialogState(() {
                                 hue = hsv.hue;
                                 saturation = hsv.saturation;
                                 value = hsv.value;
                                 isEditingColorCode = false;
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
                           onChanged(
                             _parseColor(colorController.text) ?? selectedColor,
                           );
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
    ).whenComplete(() {
      colorController.dispose();
      colorFocusNode.dispose();
    });
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
            clipBehavior: Clip.none,
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
                   trackShape: const _FullWidthSliderTrackShape(),
                   thumbColor: Colors.white,
                   thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                   overlayShape: SliderComponentShape.noOverlay,
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
                  onChanged: (v) => setState(() => value = v),
                ),
                Text(
                  isPercentage ? '${value.round()}%' : value.round().toString(),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
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

class _FullWidthSliderTrackShape extends RoundedRectSliderTrackShape {
  const _FullWidthSliderTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 2;
    return Rect.fromLTWH(
      offset.dx,
      offset.dy + (parentBox.size.height - trackHeight) / 2,
      parentBox.size.width,
      trackHeight,
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

  ThemeConfig copy() {
    return ThemeConfig(
      id: id,
      name: name,
      isNight: isNight,
      isBuiltin: isBuiltin,
      primaryColor: primaryColor,
      accentColor: accentColor,
      backgroundColor: backgroundColor,
      navBarColor: navBarColor,
      mainBgImage: mainBgImage,
      bgImageBlur: bgImageBlur,
      bookInfoBgImage: bookInfoBgImage,
      panelBgImage: panelBgImage,
      panelBgMode: panelBgMode,
      cornerScale: cornerScale,
      layoutAlpha: layoutAlpha,
      panelBorderColor: panelBorderColor,
      panelBorderAlpha: panelBorderAlpha,
      searchFollow: searchFollow,
      replyFollow: replyFollow,
      fontScale: fontScale,
      uiFont: uiFont,
      titleFont: titleFont,
      updatedAt: updatedAt,
    );
  }

  String toJson() {
    return '$id|$name|$isNight|$isBuiltin|${primaryColor.value}|${accentColor.value}|${backgroundColor.value}|${navBarColor.value}|${mainBgImage ?? ''}|$bgImageBlur|${bookInfoBgImage ?? ''}|${panelBgImage ?? ''}|$panelBgMode|$cornerScale|$layoutAlpha|${panelBorderColor?.value ?? 0}|$panelBorderAlpha|$searchFollow|$replyFollow|$fontScale|${uiFont ?? ''}|${titleFont ?? ''}|${updatedAt.millisecondsSinceEpoch}';
  }

  factory ThemeConfig.fromJson(String json) {
    final parts = json.split('|');
    if (parts.length < 8) {
      throw const FormatException('主题配置字段不足');
    }
    String valueAt(int index, [String fallback = '']) {
      return index < parts.length ? parts[index] : fallback;
    }

    int intAt(int index, int fallback) {
      return int.tryParse(valueAt(index)) ?? fallback;
    }

    double doubleAt(int index, double fallback) {
      return double.tryParse(valueAt(index)) ?? fallback;
    }

    return ThemeConfig(
      id: parts[0],
      name: parts[1],
      isNight: parts[2] == 'true',
      isBuiltin: parts[3] == 'true',
      primaryColor: Color(int.parse(parts[4])),
      accentColor: Color(int.parse(parts[5])),
      backgroundColor: Color(int.parse(parts[6])),
      navBarColor: Color(int.parse(parts[7])),
      mainBgImage: valueAt(8).isEmpty ? null : valueAt(8),
      bgImageBlur: intAt(9, 0).clamp(0, 25),
      bookInfoBgImage: valueAt(10).isEmpty ? null : valueAt(10),
      panelBgImage: valueAt(11).isEmpty ? null : valueAt(11),
      panelBgMode: valueAt(12, 'crop') == 'fit' ? 'fit' : 'crop',
      cornerScale: doubleAt(13, 1).clamp(0, 3),
      layoutAlpha: intAt(14, 100).clamp(0, 100),
      panelBorderColor: intAt(15, 0) == 0
          ? null
          : Color(intAt(15, 0)),
      panelBorderAlpha: intAt(16, 100).clamp(0, 100),
      searchFollow: valueAt(17) == 'true',
      replyFollow: valueAt(18) == 'true',
      fontScale: intAt(19, 10).clamp(8, 16),
      uiFont: valueAt(20).isEmpty ? null : valueAt(20),
      titleFont: valueAt(21).isEmpty ? null : valueAt(21),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        intAt(22, DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }
}

/// 底栏配置类 - 参考 legado-main 的 NavigationBarIconConfig.Config
class NavigationBarConfig {
  String id;
  String name;
  bool isNight;
  bool isBuiltin;
  String layoutMode; // floating, standard, sidebar
  String effectMode; // solid, glass, frosted
  int opacity;
  int? borderColor;
  int borderAlpha;
  String? wallpaperPath;
  String? sidebarBackgroundPath;
  String sidebarGravity; // start, end
  Map<String, String> icons; // 自定义图标
  DateTime updatedAt;

  NavigationBarConfig({
    required this.id,
    required this.name,
    required this.isNight,
    this.isBuiltin = false,
    this.layoutMode = 'floating',
    this.effectMode = 'glass',
    this.opacity = 72,
    this.borderColor,
    this.borderAlpha = 100,
    this.wallpaperPath,
    this.sidebarBackgroundPath,
    this.sidebarGravity = 'start',
    Map<String, String>? icons,
    DateTime? updatedAt,
  }) : icons = icons ?? {}, updatedAt = updatedAt ?? DateTime.now();

  String toJson() {
    final iconsJson = icons.entries.map((e) => '${e.key}=${e.value}').join(',');
    return '$id|$name|$isNight|$isBuiltin|$layoutMode|$effectMode|$opacity|${borderColor ?? 0}|$borderAlpha|${wallpaperPath ?? ''}|${sidebarBackgroundPath ?? ''}|$sidebarGravity|$iconsJson|${updatedAt.millisecondsSinceEpoch}';
  }

  factory NavigationBarConfig.fromJson(String json) {
    final parts = json.split('|');
    final icons = <String, String>{};
    if (parts.length > 12 && parts[12].isNotEmpty) {
      for (final entry in parts[12].split(',')) {
        if (entry.contains('=')) {
          final kv = entry.split('=');
          icons[kv[0]] = kv[1];
        }
      }
    }
    return NavigationBarConfig(
      id: parts[0],
      name: parts[1],
      isNight: parts[2] == 'true',
      isBuiltin: parts[3] == 'true',
      layoutMode: parts[4],
      effectMode: parts[5],
      opacity: int.parse(parts[6]),
      borderColor: int.parse(parts[7]) == 0 ? null : int.parse(parts[7]),
      borderAlpha: int.parse(parts[8]),
      wallpaperPath: parts[9].isEmpty ? null : parts[9],
      sidebarBackgroundPath: parts[10].isEmpty ? null : parts[10],
      sidebarGravity: parts[11],
      icons: icons,
      updatedAt: parts.length > 13 ? DateTime.fromMillisecondsSinceEpoch(int.parse(parts[13])) : DateTime.now(),
    );
  }

  NavigationBarConfig copy() {
    return NavigationBarConfig(
      id: id,
      name: name,
      isNight: isNight,
      isBuiltin: isBuiltin,
      layoutMode: layoutMode,
      effectMode: effectMode,
      opacity: opacity,
      borderColor: borderColor,
      borderAlpha: borderAlpha,
      wallpaperPath: wallpaperPath,
      sidebarBackgroundPath: sidebarBackgroundPath,
      sidebarGravity: sidebarGravity,
      icons: Map.from(icons),
      updatedAt: updatedAt,
    );
  }
}

// 底栏管理页面 - 参考 legado-main 的 NavigationBarManageActivity
class NavigationBarManagePage extends StatefulWidget {
  const NavigationBarManagePage({super.key});
  @override
  State<NavigationBarManagePage> createState() => _NavigationBarManagePageState();
}

class _NavigationBarManagePageState extends State<NavigationBarManagePage> {
  bool _isNightMode = false;
  final List<NavigationBarConfig> _configs = [];
  String? _activeConfigId;

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isNightMode = prefs.getBool('navBarIsNight') ?? false;
      _activeConfigId = prefs.getString(_isNightMode ? 'activeNightNavBarId' : 'activeDayNavBarId');
      
      // 加载内置底栏包
      _configs.clear();
      // 日间默认底栏包
      _configs.add(NavigationBarConfig(
        id: 'builtin_default_day',
        name: '默认',
        isNight: false,
        isBuiltin: true,
        layoutMode: 'floating',
        effectMode: 'glass',
        opacity: 72,
      ));
      // 夜间默认底栏包
      _configs.add(NavigationBarConfig(
        id: 'builtin_default_night',
        name: '默认',
        isNight: true,
        isBuiltin: true,
        layoutMode: 'floating',
        effectMode: 'glass',
        opacity: 72,
      ));
      
      // 加载自定义底栏包
      final customConfigs = prefs.getStringList('customNavBarConfigs') ?? [];
      for (final json in customConfigs) {
        try {
          _configs.add(NavigationBarConfig.fromJson(json));
        } catch (e) {
          debugPrint('加载底栏包失败: $e');
        }
      }
      
      // 如果没有激活的底栏包，默认激活第一个对应模式的底栏包
      if (_activeConfigId == null || _activeConfigId!.isEmpty) {
        final defaultConfig = _filteredConfigs.firstOrNull;
        if (defaultConfig != null) {
          _activeConfigId = defaultConfig.id;
        }
      }
    });
  }

  List<NavigationBarConfig> get _filteredConfigs => _configs.where((c) => c.isNight == _isNightMode).toList();

  Future<void> _saveConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('navBarIsNight', _isNightMode);
    await prefs.setString(_isNightMode ? 'activeNightNavBarId' : 'activeDayNavBarId', _activeConfigId ?? '');
    
    final customConfigs = _configs.where((c) => !c.isBuiltin).map((c) => c.toJson()).toList();
    await prefs.setStringList('customNavBarConfigs', customConfigs);
  }

  Future<void> _applyConfig(NavigationBarConfig config) async {
    setState(() => _activeConfigId = config.id);
    await _saveConfigs();

    // 应用底栏配置到 AppProvider
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    await appProvider.setNavBarConfig(
      layoutMode: config.layoutMode,
      effectMode: config.effectMode,
      opacity: config.opacity,
      borderColor: config.borderColor ?? 0,
      borderAlpha: config.borderAlpha,
      wallpaperPath: config.wallpaperPath ?? '',
      sidebarBackgroundPath: config.sidebarBackgroundPath ?? '',
      sidebarGravity: config.sidebarGravity,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已应用底栏包: ${config.name}'),
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
        title: const Text('底栏管理'),
      ),
      body: Column(
        children: [
          // TabBar - 日间/夜间切换
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
                      if (_isNightMode) {
                        setState(() => _isNightMode = false);
                        _activeConfigId = _filteredConfigs.firstOrNull?.id;
                        await _saveConfigs();
                      }
                    },
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
                            color: !_isNightMode ? colorScheme.secondary : colorScheme.onSurface, // 使用强调色
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      if (!_isNightMode) {
                        setState(() => _isNightMode = true);
                        _activeConfigId = _filteredConfigs.firstOrNull?.id;
                        await _saveConfigs();
                      }
                    },
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
                            color: _isNightMode ? colorScheme.secondary : colorScheme.onSurface, // 使用强调色
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // 摘要文本
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            constraints: const BoxConstraints(minHeight: 18),
            child: Text(
              _filteredConfigs.isEmpty 
                ? '暂无${_isNightMode ? "夜间" : "日间"}底栏包，点击下方添加'
                : '点击应用按钮应用底栏包，点击编辑按钮编辑底栏包',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          
          const SizedBox(height: 8),
          
          // 底栏包列表
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: _filteredConfigs.length,
              itemBuilder: (context, index) {
                final config = _filteredConfigs[index];
                final isActive = config.id == _activeConfigId;
                return _buildNavBarCard(config, isActive);
              },
            ),
          ),
          
          // 添加按钮
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            width: double.infinity,
            height: 48,
            decoration: BoxDecoration(
              color: colorScheme.surface.withValues(alpha: 0.87),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: colorScheme.onSurface.withValues(alpha: 0.4),
                width: 1,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _showAddOptions,
              child: Center(
                child: Text(
                  '添加底栏包',
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
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加底栏包'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDialogItem('手动配置', () {
              Navigator.pop(ctx);
              _addConfig();
            }),
            _buildDialogItem('导入底栏包', () async {
              Navigator.pop(ctx);
              final result = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: ['zip'],
                allowCompression: false,
              );
              if (result != null && result.files.isNotEmpty) {
                final path = result.files.first.path;
                if (path != null) {
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark 
        ? const Color(0xDEFFFFFF)  // 夜间：87%白
        : const Color(0xDE000000); // 日间：87%黑
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 16,
            color: isDestructive ? Theme.of(context).colorScheme.error : primaryTextColor,
          ),
        ),
      ),
    );
  }

  // 底栏包卡片
  Widget _buildNavBarCard(NavigationBarConfig config, bool isActive) {
    final colorScheme = Theme.of(context).colorScheme;
    final dateFormat = '${config.updatedAt.year}-${config.updatedAt.month.toString().padLeft(2, '0')}-${config.updatedAt.day.toString().padLeft(2, '0')}';
    
    // 构建信息文本
    String infoText = _getLayoutModeText(config.layoutMode);
    if (config.layoutMode == 'floating') {
      infoText += ' · ${_getEffectModeText(config.effectMode)}';
    }
    if (config.layoutMode != 'sidebar') {
      infoText += ' · 不透明度 ${config.opacity}%';
      if (config.layoutMode == 'standard' && config.wallpaperPath != null && config.wallpaperPath!.isNotEmpty) {
        infoText += ' · 底栏壁纸';
      }
    }
    infoText += ' · $dateFormat';
    
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 名称 + 内置标签
          Row(
            children: [
              Expanded(
                child: Text(
                  config.name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (config.isBuiltin)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                  ),
                ),
            ],
          ),
          
          // 信息文本
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${isActive ? "当前应用 · " : ""}$infoText',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          
          const SizedBox(height: 8),
          
          // 底部按钮
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildActionButton(
                  isActive ? '已应用' : '应用',
                  () => _applyConfig(config),
                  isPrimary: !isActive,
                ),
                const SizedBox(width: 8),
                if (!config.isBuiltin)
                  _buildActionButton('编辑', () => _editConfig(config)),
                if (!config.isBuiltin) const SizedBox(width: 8),
                _buildActionButton('更多', () => _showMoreOptions(config)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(String text, VoidCallback onTap, {bool isPrimary = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        constraints: const BoxConstraints(minWidth: 56),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isPrimary ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: isPrimary ? colorScheme.onPrimaryContainer : colorScheme.onSurface,
              fontWeight: isPrimary ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  String _getLayoutModeText(String mode) {
    switch (mode) {
      case 'floating': return '悬浮';
      case 'standard': return '标准';
      case 'sidebar': return '侧边栏';
      default: return '悬浮';
    }
  }

  String _getEffectModeText(String mode) {
    switch (mode) {
      case 'solid': return '实心';
      case 'glass': return '玻璃';
      case 'frosted': return '磨砂';
      default: return '玻璃';
    }
  }

  void _addConfig() {
    _editConfig(null);
  }

  void _editConfig(NavigationBarConfig? existing) {
    final isEdit = existing != null;
    final wasActive = isEdit && existing.id == _activeConfigId;
    final config = existing ?? NavigationBarConfig(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: _getNextConfigName(),
      isNight: _isNightMode,
      isBuiltin: false,
      layoutMode: 'floating',
      effectMode: 'glass',
      opacity: 100,
    );

    showDialog(
      context: context,
      builder: (ctx) => _NavBarEditDialog(
        config: config,
        isEdit: isEdit,
        onSave: (updatedConfig) async {
          if (isEdit) {
            setState(() {});
          } else {
            setState(() => _configs.add(updatedConfig));
          }
          await _saveConfigs();
          // 如果编辑的是当前已应用的底栏包，保存后自动重新应用
          if (wasActive) {
            _applyConfig(updatedConfig);
          }
        },
      ),
    );
  }

  String _getNextConfigName() {
    const base = '自定义底栏';
    final usedNames = _configs.map((c) => c.name).toSet();
    if (!usedNames.contains(base)) return base;
    for (int index = 2; index <= 999; index++) {
      final name = '$base $index';
      if (!usedNames.contains(name)) return name;
    }
    return '$base ${DateTime.now().millisecondsSinceEpoch}';
  }

  void _showMoreOptions(NavigationBarConfig config) {
    final items = <Widget>[];
    
    // 应用
    items.add(_buildDialogItem('应用', () {
      Navigator.pop(context);
      _applyConfig(config);
    }));
    
    // 非内置主题可以编辑和导出
    if (!config.isBuiltin) {
      items.add(_buildDialogItem('编辑', () {
        Navigator.pop(context);
        _editConfig(config);
      }));
      items.add(_buildDialogItem('导出底栏包', () {
        Navigator.pop(context);
        _exportConfig(config);
      }));
    }
    
    // 非内置主题且非当前应用的主题可以删除
    if (!config.isBuiltin && config.id != _activeConfigId) {
      items.add(_buildDialogItem('删除底栏包', () {
        Navigator.pop(context);
        _deleteConfig(config);
      }, isDestructive: true));
    }
    
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(config.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: items,
        ),
      ),
    );
  }

  void _exportConfig(NavigationBarConfig config) {
    final json = config.toJson();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('底栏包配置已生成\n$json'),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  void _deleteConfig(NavigationBarConfig config) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除底栏包 "${config.name}" 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              setState(() => _configs.remove(config));
              await _saveConfigs();
              Navigator.pop(ctx);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

// 底栏包编辑对话框 - 参考 legado-main 的编辑对话框
class _NavBarEditDialog extends StatefulWidget {
  final NavigationBarConfig config;
  final bool isEdit;
  final Future<void> Function(NavigationBarConfig) onSave;

  const _NavBarEditDialog({
    required this.config,
    required this.isEdit,
    required this.onSave,
  });

  @override
  State<_NavBarEditDialog> createState() => _NavBarEditDialogState();
}

class _NavBarEditDialogState extends State<_NavBarEditDialog> {
  late NavigationBarConfig _config;
  final TextEditingController _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    _nameController.text = _config.name;
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
    final dialogWidth = screenWidth * 0.94;
    final dialogHeight = screenHeight < 1600 ? screenHeight * 0.74 : screenHeight * 0.68;

    return Dialog(
      insetPadding: EdgeInsets.zero,
      alignment: Alignment.center,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
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
                widget.isEdit ? '编辑底栏包' : '添加底栏包',
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
                    // 名称输入框
                    _buildOptionRow(
                      child: TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          hintText: '底栏包名称',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 14),
                        ),
                        style: const TextStyle(fontSize: 15),
                        onChanged: (v) => _config.name = v,
                      ),
                    ),

                    const SizedBox(height: 10),

                    // 布局模式
                    _buildSelectOption(
                      '布局模式',
                      _getLayoutModeText(_config.layoutMode),
                      () => _showLayoutModePicker(),
                    ),

                    // 材质模式 - 仅悬浮模式
                    if (_config.layoutMode == 'floating')
                      _buildSelectOption(
                        '材质模式',
                        _getEffectModeText(_config.effectMode),
                        () => _showEffectModePicker(),
                      ),

                    // 底栏壁纸 - 仅标准模式
                    if (_config.layoutMode == 'standard')
                      _buildSelectOption(
                        '底栏壁纸',
                        _config.wallpaperPath != null && _config.wallpaperPath!.isNotEmpty ? '已设置' : '选择图片',
                        () => _showWallpaperPicker(),
                      ),

                    // 不透明度 - 非侧边栏模式
                    _buildSliderOption(
                      '不透明度',
                      _config.opacity.toDouble(),
                      0,
                      100,
                      (v) => setState(() => _config.opacity = v.round()),
                      isPercentage: true,
                    ),

                    // 边框颜色 - 非侧边栏模式
                    _buildColorOption(
                      '边框颜色',
                      _config.borderColor != null ? Color(_config.borderColor!) : Colors.transparent,
                      (c) => setState(() => _config.borderColor = c.value),
                      canDisable: true,
                    ),

                    // 边框透明度 - 非侧边栏模式
                    _buildSliderOption(
                      '边框透明度',
                      _config.borderAlpha.toDouble(),
                      0,
                      100,
                      (v) => setState(() => _config.borderAlpha = v.round()),
                      isPercentage: true,
                    ),

                    // 侧边栏背景 - 仅侧边栏模式
                    if (_config.layoutMode == 'sidebar')
                      _buildSelectOption(
                        '侧边栏背景',
                        _config.sidebarBackgroundPath != null && _config.sidebarBackgroundPath!.isNotEmpty ? '已设置' : '选择图片',
                        () => _showSidebarBackgroundPicker(),
                      ),

                    // 侧边栏位置 - 仅侧边栏模式
                    if (_config.layoutMode == 'sidebar')
                      _buildSelectOption(
                        '侧边栏位置',
                        _config.sidebarGravity == 'start' ? '左侧' : '右侧',
                        () => _showSidebarGravityPicker(),
                      ),

                    // 图标配置
                    ..._buildIconRows(),
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
                        await widget.onSave(_config);
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

  Widget _buildSliderOption(String title, double value, double min, double max, ValueChanged<double> onChanged, {bool isPercentage = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    String valueText = isPercentage ? '${value.round()}%' : value.toStringAsFixed(1);

    return _buildOptionRow(
      child: GestureDetector(
        onTap: () => _showNumberPickerDialog(title, value, min, max, onChanged, isPercentage: isPercentage),
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

  Widget _buildColorOption(String title, Color color, ValueChanged<Color> onChanged, {bool canDisable = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    final colorHex = color != Colors.transparent 
        ? '#${color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}'
        : '禁用';

    return _buildOptionRow(
      child: GestureDetector(
        onTap: () => _showColorPicker(title, color, onChanged, canDisable: canDisable),
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
            if (color != Colors.transparent)
              Container(
                width: 22,
                height: 22,
                margin: const EdgeInsets.only(left: 10),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: colorScheme.onSurface.withValues(alpha: 0.16),
                    width: 1,
                  ),
                ),
              ),
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

  // 导航项列表 - 参考原版 NavigationBarIconConfig.items
  static const _navItems = [
    _NavItem('bookshelf', '书架', Icons.menu_book),
    _NavItem('discovery', '发现', Icons.explore),
    _NavItem('rss', '订阅', Icons.rss_feed),
    _NavItem('my', '我的', Icons.person),
    _NavItem('ai', '助手', Icons.smart_toy),
  ];

  List<Widget> _buildIconRows() {
    final colorScheme = Theme.of(context).colorScheme;
    final items = _navItems.where((item) {
      // 非侧边栏模式不显示AI助手
      if (_config.layoutMode != 'sidebar' && item.key == 'ai') {
        return false;
      }
      return true;
    }).toList();

    return items.map((item) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                item.title,
                style: TextStyle(
                  fontSize: 15,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            // 正常状态图标按钮
            _buildIconButton(item, false),
            const SizedBox(width: 8),
            // 选中状态图标按钮
            _buildIconButton(item, true),
          ],
        ),
      );
    }).toList();
  }

  Widget _buildIconButton(_NavItem item, bool selected) {
    final colorScheme = Theme.of(context).colorScheme;
    final iconKey = '${item.key}_${selected ? 'selected' : 'normal'}';
    final hasCustomIcon = _config.icons.containsKey(iconKey);

    return GestureDetector(
      onTap: () => _showIconOptions(item, selected),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          hasCustomIcon ? Icons.image : item.icon,
          size: 24,
          color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  void _showIconOptions(_NavItem item, bool selected) {
    final iconKey = '${item.key}_${selected ? 'selected' : 'normal'}';
    final hasCustomIcon = _config.icons.containsKey(iconKey);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${item.title} - ${selected ? '选中' : '正常'}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDialogItem('选择图片', () {
              Navigator.pop(ctx);
              _pickIconImage(item, selected);
            }),
            if (hasCustomIcon)
              _buildDialogItem('删除', () {
                Navigator.pop(ctx);
                setState(() {
                  _config.icons.remove(iconKey);
                });
              }, isDestructive: true),
          ],
        ),
      ),
    );
  }

  Widget _buildDialogItem(String text, VoidCallback onTap, {bool isDestructive = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark 
        ? const Color(0xDEFFFFFF)  // 夜间：87%白
        : const Color(0xDE000000); // 日间：87%黑
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 16,
            color: isDestructive ? Theme.of(context).colorScheme.error : primaryTextColor,
          ),
        ),
      ),
    );
  }

  Future<void> _pickIconImage(_NavItem item, bool selected) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'svg', 'ico'],
    );
    if (result != null && result.files.isNotEmpty) {
      final path = result.files.first.path;
      if (path != null) {
        final iconKey = '${item.key}_${selected ? 'selected' : 'normal'}';
        setState(() {
          _config.icons[iconKey] = path;
        });
      }
    }
  }

  String _getLayoutModeText(String mode) {
    switch (mode) {
      case 'floating': return '悬浮';
      case 'standard': return '标准';
      case 'sidebar': return '侧边栏';
      default: return '悬浮';
    }
  }

  String _getEffectModeText(String mode) {
    switch (mode) {
      case 'solid': return '实心';
      case 'glass': return '玻璃';
      case 'frosted': return '磨砂';
      default: return '玻璃';
    }
  }

  void _showLayoutModePicker() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('布局模式'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('悬浮'),
              subtitle: const Text('悬浮在底部，支持玻璃效果'),
              trailing: _config.layoutMode == 'floating' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _config.layoutMode = 'floating');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('标准'),
              subtitle: const Text('传统底部导航栏样式'),
              trailing: _config.layoutMode == 'standard' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() {
                  _config.layoutMode = 'standard';
                  _config.effectMode = 'solid';
                });
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('侧边栏'),
              subtitle: const Text('侧边抽屉式导航'),
              trailing: _config.layoutMode == 'sidebar' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _config.layoutMode = 'sidebar');
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEffectModePicker() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('材质模式'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('实心'),
              trailing: _config.effectMode == 'solid' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _config.effectMode = 'solid');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('玻璃'),
              trailing: _config.effectMode == 'glass' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _config.effectMode = 'glass');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('磨砂'),
              trailing: _config.effectMode == 'frosted' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _config.effectMode = 'frosted');
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showSidebarGravityPicker() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('侧边栏位置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('左侧'),
              trailing: _config.sidebarGravity == 'start' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _config.sidebarGravity = 'start');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('右侧'),
              trailing: _config.sidebarGravity == 'end' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _config.sidebarGravity = 'end');
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showWallpaperPicker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowCompression: false,
    );
    if (result != null && result.files.isNotEmpty) {
      final path = result.files.first.path;
      if (path != null) {
        setState(() => _config.wallpaperPath = path);
      }
    }
  }

  void _showSidebarBackgroundPicker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowCompression: false,
    );
    if (result != null && result.files.isNotEmpty) {
      final path = result.files.first.path;
      if (path != null) {
        setState(() => _config.sidebarBackgroundPath = path);
      }
    }
  }

  void _showNumberPickerDialog(String title, double currentValue, double min, double max, ValueChanged<double> onChanged, {bool isPercentage = false}) {
    double value = currentValue;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: value,
                  min: min,
                  max: max,
                  onChanged: (v) => setState(() => value = v),
                ),
                Text(
                  isPercentage ? '${value.round()}%' : value.round().toString(),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            actions: [
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

  void _showColorPicker(String title, Color currentColor, ValueChanged<Color> onChanged, {bool canDisable = false}) {
    if (canDisable) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
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
    
    double hue = HSVColor.fromColor(currentColor).hue;
    double saturation = HSVColor.fromColor(currentColor).saturation;
    double value = HSVColor.fromColor(currentColor).value;
    bool isEditingColorCode = false;
    
    final colorController = TextEditingController(
      text: '#${currentColor.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
    );
    final colorFocusNode = FocusNode();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final selectedColor = HSVColor.fromAHSV(1.0, hue, saturation, value).toColor();
          
          final colorHex = '#${selectedColor.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
          if (!isEditingColorCode && colorController.text != colorHex) {
            colorController.text = colorHex;
            colorController.selection = TextSelection.collapsed(offset: colorHex.length);
          }
          
          return Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            child: Container(
              width: 320,
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
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
                    onChanged: (v) {
                      colorFocusNode.unfocus();
                      setDialogState(() {
                        isEditingColorCode = false;
                        hue = v;
                      });
                    },
                    displayValue: hue.round().toString(),
                    gradientColors: [
                      const Color(0xFFFF0000),
                      const Color(0xFFFFFF00),
                      const Color(0xFF00FF00),
                      const Color(0xFF00FFFF),
                      const Color(0xFF0000FF),
                      const Color(0xFFFF00FF),
                      const Color(0xFFFF0000),
                    ],
                  ),
                  
                  const SizedBox(height: 12),
                  
                  // 饱和度滑块
                  _buildColorSlider(
                    label: '饱和度',
                    value: saturation,
                    min: 0,
                    max: 1,
                    onChanged: (v) {
                      colorFocusNode.unfocus();
                      setDialogState(() {
                        isEditingColorCode = false;
                        saturation = v;
                      });
                    },
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
                    onChanged: (v) {
                      colorFocusNode.unfocus();
                      setDialogState(() {
                        isEditingColorCode = false;
                        value = v;
                      });
                    },
                    displayValue: '${(value * 100).round()}%',
                    gradientColors: [
                      HSVColor.fromAHSV(1.0, hue, saturation, 0).toColor(),
                      HSVColor.fromAHSV(1.0, hue, saturation, 1).toColor(),
                    ],
                  ),
                  
                  const SizedBox(height: 20),
                  
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: colorController,
                          focusNode: colorFocusNode,
                          decoration: InputDecoration(
                            hintText: '#RRGGBB',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
                          keyboardType: TextInputType.text,
                          textCapitalization: TextCapitalization.characters,
                          autocorrect: false,
                          enableSuggestions: false,
                          onTap: () {
                            isEditingColorCode = true;
                          },
                          onChanged: (text) {
                            final color = _parseColor(text);
                            if (color == null) return;
                            final hsv = HSVColor.fromColor(color);
                            setDialogState(() {
                              hue = hsv.hue;
                              saturation = hsv.saturation;
                              value = hsv.value;
                            });
                          },
                          onSubmitted: (text) {
                            final color = _parseColor(text);
                            if (color == null) return;
                            final hsv = HSVColor.fromColor(color);
                            setDialogState(() {
                              hue = hsv.hue;
                              saturation = hsv.saturation;
                              value = hsv.value;
                              isEditingColorCode = false;
                            });
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
                          onChanged(
                            _parseColor(colorController.text) ?? selectedColor,
                          );
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
    ).whenComplete(() {
      colorController.dispose();
      colorFocusNode.dispose();
    });
  }

  Color? _parseColor(String text) {
    var value = text.trim();
    if (value.startsWith('#')) {
      value = value.substring(1);
    }
    if (value.toLowerCase().startsWith('0x')) {
      value = value.substring(2);
    }

    if (value.length != 6 && value.length != 8) return null;
    final parsed = int.tryParse(value, radix: 16);
    if (parsed == null) return null;
    return Color(value.length == 6 ? parsed + 0xFF000000 : parsed);
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
            clipBehavior: Clip.none,
            children: [
              Container(
                height: 24,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: gradientColors),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: 24,
                  trackShape: const _FullWidthSliderTrackShape(),
                  thumbColor: Colors.white,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  overlayShape: SliderComponentShape.noOverlay,
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
}

// 顶栏配置类 - 参考 legado-main 的 TopBarConfig.Config
class TopBarConfig {
  String id;
  String name;
  bool isNight;
  bool isBuiltin;
  String style; // default, regular
  double cornerScale; // 0.0 ~ 3.0
  int? backgroundColor;
  String? wallpaperPath;
  int wallpaperAlpha; // 0 ~ 100
  int? tagBarColor;
  int tagBarAlpha; // 0 ~ 100
  int? tagSelectedColor;
  int tagSelectedAlpha; // 0 ~ 100
  bool expandFiltersByDefault;
  DateTime updatedAt;

  TopBarConfig({
    required this.id,
    required this.name,
    required this.isNight,
    this.isBuiltin = false,
    this.style = 'default',
    this.cornerScale = 1.0,
    this.backgroundColor,
    this.wallpaperPath,
    this.wallpaperAlpha = 100,
    this.tagBarColor,
    this.tagBarAlpha = 100,
    this.tagSelectedColor,
    this.tagSelectedAlpha = 100,
    this.expandFiltersByDefault = false,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  String toJson() {
    return '$id|$name|$isNight|$isBuiltin|$style|$cornerScale|${backgroundColor ?? 0}|${wallpaperPath ?? ''}|$wallpaperAlpha|${tagBarColor ?? 0}|$tagBarAlpha|${tagSelectedColor ?? 0}|$tagSelectedAlpha|$expandFiltersByDefault|${updatedAt.millisecondsSinceEpoch}';
  }

  factory TopBarConfig.fromJson(String json) {
    final parts = json.split('|');
    return TopBarConfig(
      id: parts[0],
      name: parts[1],
      isNight: parts[2] == 'true',
      isBuiltin: parts[3] == 'true',
      style: parts[4],
      cornerScale: double.parse(parts[5]),
      backgroundColor: int.parse(parts[6]) == 0 ? null : int.parse(parts[6]),
      wallpaperPath: parts[7].isEmpty ? null : parts[7],
      wallpaperAlpha: int.parse(parts[8]),
      tagBarColor: int.parse(parts[9]) == 0 ? null : int.parse(parts[9]),
      tagBarAlpha: int.parse(parts[10]),
      tagSelectedColor: int.parse(parts[11]) == 0 ? null : int.parse(parts[11]),
      tagSelectedAlpha: int.parse(parts[12]),
      expandFiltersByDefault: parts[13] == 'true',
      updatedAt: parts.length > 14 ? DateTime.fromMillisecondsSinceEpoch(int.parse(parts[14])) : DateTime.now(),
    );
  }

  TopBarConfig copy() {
    return TopBarConfig(
      id: id,
      name: name,
      isNight: isNight,
      isBuiltin: isBuiltin,
      style: style,
      cornerScale: cornerScale,
      backgroundColor: backgroundColor,
      wallpaperPath: wallpaperPath,
      wallpaperAlpha: wallpaperAlpha,
      tagBarColor: tagBarColor,
      tagBarAlpha: tagBarAlpha,
      tagSelectedColor: tagSelectedColor,
      tagSelectedAlpha: tagSelectedAlpha,
      expandFiltersByDefault: expandFiltersByDefault,
      updatedAt: updatedAt,
    );
  }
}

// 顶栏管理页面 - 参考 legado-main 的 TopBarManageActivity
class TopBarManagePage extends StatefulWidget {
  const TopBarManagePage({super.key});
  @override
  State<TopBarManagePage> createState() => _TopBarManagePageState();
}

class _TopBarManagePageState extends State<TopBarManagePage> {
  bool _isNightMode = false;
  final List<TopBarConfig> _configs = [];
  String? _activeConfigId;

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isNightMode = prefs.getBool('topBarIsNight') ?? false;
      _activeConfigId = prefs.getString(_isNightMode ? 'activeNightTopBarId' : 'activeDayTopBarId');

      _configs.clear();
      // 日间默认顶栏包
      _configs.add(TopBarConfig(
        id: 'builtin_default_day',
        name: '默认',
        isNight: false,
        isBuiltin: true,
        style: 'default',
        cornerScale: 1.0,
        tagBarAlpha: 100,
        tagSelectedAlpha: 100,
        wallpaperAlpha: 100,
      ));
      // 夜间默认顶栏包
      _configs.add(TopBarConfig(
        id: 'builtin_default_night',
        name: '默认',
        isNight: true,
        isBuiltin: true,
        style: 'default',
        cornerScale: 1.0,
        tagBarAlpha: 100,
        tagSelectedAlpha: 100,
        wallpaperAlpha: 100,
      ));

      // 加载自定义顶栏包
      final customConfigs = prefs.getStringList('customTopBarConfigs') ?? [];
      for (final json in customConfigs) {
        try {
          _configs.add(TopBarConfig.fromJson(json));
        } catch (e) {
          debugPrint('加载顶栏包失败: $e');
        }
      }

      if (_activeConfigId == null || _activeConfigId!.isEmpty) {
        final defaultConfig = _filteredConfigs.firstOrNull;
        if (defaultConfig != null) {
          _activeConfigId = defaultConfig.id;
        }
      }
    });
  }

  List<TopBarConfig> get _filteredConfigs => _configs.where((c) => c.isNight == _isNightMode).toList();

  Future<void> _saveConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('topBarIsNight', _isNightMode);
    await prefs.setString(_isNightMode ? 'activeNightTopBarId' : 'activeDayTopBarId', _activeConfigId ?? '');

    final customConfigs = _configs.where((c) => !c.isBuiltin).map((c) => c.toJson()).toList();
    await prefs.setStringList('customTopBarConfigs', customConfigs);
  }

  Future<void> _applyConfig(TopBarConfig config) async {
    setState(() => _activeConfigId = config.id);
    await _saveConfigs();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已应用顶栏包: ${config.name}'),
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
        title: const Text('顶栏管理'),
      ),
      body: Column(
        children: [
          // TabBar - 日间/夜间切换
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
                      if (_isNightMode) {
                        setState(() => _isNightMode = false);
                        _activeConfigId = _filteredConfigs.firstOrNull?.id;
                        await _saveConfigs();
                      }
                    },
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
                            color: !_isNightMode ? colorScheme.secondary : colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      if (!_isNightMode) {
                        setState(() => _isNightMode = true);
                        _activeConfigId = _filteredConfigs.firstOrNull?.id;
                        await _saveConfigs();
                      }
                    },
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
                            color: _isNightMode ? colorScheme.secondary : colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 摘要文本
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            constraints: const BoxConstraints(minHeight: 18),
            child: Text(
              _filteredConfigs.isEmpty
                ? '暂无${_isNightMode ? "夜间" : "日间"}顶栏包，点击下方添加'
                : '管理主页面顶栏的${_isNightMode ? "夜间" : "日间"}样式',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          const SizedBox(height: 8),

          // 顶栏包列表
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: _filteredConfigs.length,
              itemBuilder: (context, index) {
                final config = _filteredConfigs[index];
                final isActive = config.id == _activeConfigId;
                return _buildTopBarCard(config, isActive);
              },
            ),
          ),

          // 添加按钮
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            width: double.infinity,
            height: 48,
            decoration: BoxDecoration(
              color: colorScheme.surface.withValues(alpha: 0.87),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: colorScheme.onSurface.withValues(alpha: 0.4),
                width: 1,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _showAddOptions,
              child: Center(
                child: Text(
                  '添加顶栏包',
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
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加顶栏包'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDialogItem('手动配置', () {
              Navigator.pop(ctx);
              _addConfig();
            }),
            _buildDialogItem('导入顶栏包', () async {
              Navigator.pop(ctx);
              final result = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: ['zip'],
                allowCompression: false,
              );
              if (result != null && result.files.isNotEmpty) {
                final path = result.files.first.path;
                if (path != null) {
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark
        ? const Color(0xDEFFFFFF)
        : const Color(0xDE000000);
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 16,
            color: isDestructive ? Theme.of(context).colorScheme.error : primaryTextColor,
          ),
        ),
      ),
    );
  }

  // 顶栏包卡片
  Widget _buildTopBarCard(TopBarConfig config, bool isActive) {
    final colorScheme = Theme.of(context).colorScheme;
    final dateFormat = '${config.updatedAt.year}-${config.updatedAt.month.toString().padLeft(2, '0')}-${config.updatedAt.day.toString().padLeft(2, '0')}';

    // 构建信息文本
    String infoText = _getStyleText(config.style);
    if (config.style == 'regular') {
      infoText += ' · 圆角 ${config.cornerScale.toStringAsFixed(1)}';
      if (config.wallpaperPath != null && config.wallpaperPath!.isNotEmpty) {
        infoText += ' · 壁纸';
      }
    }
    infoText += ' · 标签透明度 ${config.tagBarAlpha}%';
    infoText += ' · $dateFormat';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 名称 + 内置标签
          Row(
            children: [
              Expanded(
                child: Text(
                  config.name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (config.isBuiltin)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
                  ),
                ),
            ],
          ),

          // 信息文本
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${isActive ? "当前应用 · " : ""}$infoText',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),

          const SizedBox(height: 8),

          // 底部按钮
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildActionButton(
                  isActive ? '已应用' : '应用',
                  () => _applyConfig(config),
                  isPrimary: !isActive,
                ),
                const SizedBox(width: 8),
                if (!config.isBuiltin)
                  _buildActionButton('编辑', () => _editConfig(config)),
                if (!config.isBuiltin) const SizedBox(width: 8),
                _buildActionButton('更多', () => _showMoreOptions(config)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(String text, VoidCallback onTap, {bool isPrimary = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        constraints: const BoxConstraints(minWidth: 56),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isPrimary ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: isPrimary ? colorScheme.onPrimaryContainer : colorScheme.onSurface,
              fontWeight: isPrimary ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  String _getStyleText(String style) {
    switch (style) {
      case 'regular': return '常规顶栏';
      default: return '默认顶栏';
    }
  }

  void _addConfig() {
    _editConfig(null);
  }

  void _editConfig(TopBarConfig? existing) {
    final isEdit = existing != null;
    final config = existing ?? TopBarConfig(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: _getNextConfigName(),
      isNight: _isNightMode,
      isBuiltin: false,
      style: 'default',
      cornerScale: 1.0,
      tagBarAlpha: 100,
      tagSelectedAlpha: 100,
      wallpaperAlpha: 100,
    );

    showDialog(
      context: context,
      builder: (ctx) => _TopBarEditDialog(
        config: config,
        isEdit: isEdit,
        onSave: (updatedConfig) async {
          if (isEdit) {
            setState(() {});
          } else {
            setState(() => _configs.add(updatedConfig));
          }
          await _saveConfigs();
        },
      ),
    );
  }

  String _getNextConfigName() {
    const base = '自定义顶栏';
    final usedNames = _configs.map((c) => c.name).toSet();
    if (!usedNames.contains(base)) return base;
    for (int index = 2; index <= 999; index++) {
      final name = '$base $index';
      if (!usedNames.contains(name)) return name;
    }
    return '$base ${DateTime.now().millisecondsSinceEpoch}';
  }

  void _showMoreOptions(TopBarConfig config) {
    final items = <Widget>[];

    items.add(_buildDialogItem('应用', () {
      Navigator.pop(context);
      _applyConfig(config);
    }));

    if (!config.isBuiltin) {
      items.add(_buildDialogItem('编辑', () {
        Navigator.pop(context);
        _editConfig(config);
      }));
      items.add(_buildDialogItem('导出顶栏包', () {
        Navigator.pop(context);
        _exportConfig(config);
      }));
    }

    if (!config.isBuiltin && config.id != _activeConfigId) {
      items.add(_buildDialogItem('删除顶栏包', () {
        Navigator.pop(context);
        _deleteConfig(config);
      }, isDestructive: true));
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(config.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: items,
        ),
      ),
    );
  }

  void _exportConfig(TopBarConfig config) {
    final json = config.toJson();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('顶栏包配置已生成\n$json'),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  void _deleteConfig(TopBarConfig config) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除顶栏包 "${config.name}" 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              setState(() => _configs.remove(config));
              await _saveConfigs();
              Navigator.pop(ctx);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

// 顶栏包编辑对话框 - 参考 legado-main 的 TopBarManageActivity.buildEditView
class _TopBarEditDialog extends StatefulWidget {
  final TopBarConfig config;
  final bool isEdit;
  final Future<void> Function(TopBarConfig) onSave;

  const _TopBarEditDialog({
    required this.config,
    required this.isEdit,
    required this.onSave,
  });

  @override
  State<_TopBarEditDialog> createState() => _TopBarEditDialogState();
}

class _TopBarEditDialogState extends State<_TopBarEditDialog> {
  late TopBarConfig _config;
  final TextEditingController _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    _nameController.text = _config.name;
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
    final dialogWidth = screenWidth * 0.94;
    final dialogHeight = screenHeight < 1600 ? screenHeight * 0.74 : screenHeight * 0.68;

    return Dialog(
      insetPadding: EdgeInsets.zero,
      alignment: Alignment.center,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
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
                widget.isEdit ? '编辑顶栏包' : '添加顶栏包',
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
                    // 名称输入框
                    _buildOptionRow(
                      child: TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          hintText: '顶栏包名称',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 14),
                        ),
                        style: const TextStyle(fontSize: 15),
                        onChanged: (v) => _config.name = v,
                      ),
                    ),

                    const SizedBox(height: 10),

                    // 顶栏样式
                    _buildSelectOption(
                      '顶栏样式',
                      _getStyleText(_config.style),
                      () => _showStylePicker(),
                    ),

                    // 常规样式专属选项
                    if (_config.style == 'regular') ...[
                      _buildSliderOption(
                        '圆角倍率',
                        _config.cornerScale * 10,
                        0,
                        30,
                        (v) => setState(() => _config.cornerScale = v / 10),
                        displayValue: _config.cornerScale.toStringAsFixed(1),
                      ),
                      _buildColorOption(
                        '背景色',
                        _config.backgroundColor != null ? Color(_config.backgroundColor!) : (_config.isNight ? Colors.black : Colors.white),
                        (c) => setState(() => _config.backgroundColor = c.value),
                      ),
                      _buildSelectOption(
                        '顶栏壁纸',
                        _config.wallpaperPath != null && _config.wallpaperPath!.isNotEmpty ? '已设置' : '选择图片',
                        () => _showWallpaperPicker(),
                      ),
                      _buildSliderOption(
                        '壁纸透明度',
                        _config.wallpaperAlpha.toDouble(),
                        0,
                        100,
                        (v) => setState(() => _config.wallpaperAlpha = v.round()),
                        isPercentage: true,
                      ),
                      _buildSelectOption(
                        '筛选栏默认状态',
                        _config.expandFiltersByDefault ? '展开' : '折叠',
                        () => _showFilterDefaultPicker(),
                      ),
                    ],

                    // 标签栏背景色
                    _buildColorOption(
                      '标签栏背景',
                      _config.tagBarColor != null ? Color(_config.tagBarColor!) : (_config.style == 'regular' ? Colors.white : colorScheme.surfaceContainerHighest),
                      (c) => setState(() => _config.tagBarColor = c.value),
                    ),

                    // 标签栏透明度
                    _buildSliderOption(
                      '标签栏透明度',
                      _config.tagBarAlpha.toDouble(),
                      0,
                      100,
                      (v) => setState(() => _config.tagBarAlpha = v.round()),
                      isPercentage: true,
                    ),

                    // 选中标签背景色
                    _buildColorOption(
                      '选中标签背景',
                      _config.tagSelectedColor != null ? Color(_config.tagSelectedColor!) : colorScheme.surface,
                      (c) => setState(() => _config.tagSelectedColor = c.value),
                    ),

                    // 选中标签透明度
                    _buildSliderOption(
                      '选中标签透明度',
                      _config.tagSelectedAlpha.toDouble(),
                      0,
                      100,
                      (v) => setState(() => _config.tagSelectedAlpha = v.round()),
                      isPercentage: true,
                    ),
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
                        await widget.onSave(_config);
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

  Widget _buildSliderOption(String title, double value, double min, double max, ValueChanged<double> onChanged, {bool isPercentage = false, String? displayValue}) {
    final colorScheme = Theme.of(context).colorScheme;
    String valueText = displayValue ?? (isPercentage ? '${value.round()}%' : value.toStringAsFixed(1));

    return _buildOptionRow(
      child: GestureDetector(
        onTap: () => _showNumberPickerDialog(title, value, min, max, onChanged, isPercentage: isPercentage),
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

  Widget _buildColorOption(String title, Color color, ValueChanged<Color> onChanged) {
    final colorScheme = Theme.of(context).colorScheme;
    final colorHex = '#${color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

    return _buildOptionRow(
      child: GestureDetector(
        onTap: () => _showColorPicker(title, color, onChanged),
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
            Container(
              width: 22,
              height: 22,
              margin: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: colorScheme.onSurface.withValues(alpha: 0.16),
                  width: 1,
                ),
              ),
            ),
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

  String _getStyleText(String style) {
    switch (style) {
      case 'regular': return '常规顶栏';
      default: return '默认顶栏';
    }
  }

  void _showStylePicker() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('顶栏样式'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('默认顶栏'),
              subtitle: const Text('系统默认顶栏样式'),
              trailing: _config.style == 'default' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _config.style = 'default');
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('常规顶栏'),
              subtitle: const Text('支持圆角、壁纸、背景色等自定义'),
              trailing: _config.style == 'regular' ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() {
                  _config.style = 'regular';
                  if (_config.backgroundColor == null) {
                    _config.backgroundColor = (_config.isNight ? Colors.black : Colors.white).value;
                  }
                  if (_config.tagBarColor == null) {
                    _config.tagBarColor = Colors.white.value;
                  }
                });
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showFilterDefaultPicker() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('筛选栏默认状态'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('折叠'),
              trailing: !_config.expandFiltersByDefault ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _config.expandFiltersByDefault = false);
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              title: const Text('展开'),
              trailing: _config.expandFiltersByDefault ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
              onTap: () {
                setState(() => _config.expandFiltersByDefault = true);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showWallpaperPicker() async {
    final hasWallpaper = _config.wallpaperPath != null && _config.wallpaperPath!.isNotEmpty;
    if (hasWallpaper) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('选择图片'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickWallpaperImage();
                },
              ),
              ListTile(
                title: const Text('删除壁纸'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _config.wallpaperPath = null);
                },
              ),
            ],
          ),
        ),
      );
    } else {
      _pickWallpaperImage();
    }
  }

  Future<void> _pickWallpaperImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowCompression: false,
    );
    if (result != null && result.files.isNotEmpty) {
      final path = result.files.first.path;
      if (path != null) {
        setState(() => _config.wallpaperPath = path);
      }
    }
  }

  void _showNumberPickerDialog(String title, double currentValue, double min, double max, ValueChanged<double> onChanged, {bool isPercentage = false}) {
    double value = currentValue;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Slider(
                  value: value,
                  min: min,
                  max: max,
                  onChanged: (v) => setState(() => value = v),
                ),
                Text(
                  isPercentage ? '${value.round()}%' : value.toStringAsFixed(1),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            actions: [
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

  void _showColorPicker(String title, Color currentColor, ValueChanged<Color> onChanged) {
    final colorScheme = Theme.of(context).colorScheme;

    double hue = HSVColor.fromColor(currentColor).hue;
    double saturation = HSVColor.fromColor(currentColor).saturation;
    double value = HSVColor.fromColor(currentColor).value;
    bool isEditingColorCode = false;

    final colorController = TextEditingController(
      text: '#${currentColor.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
    );
    final colorFocusNode = FocusNode();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final selectedColor = HSVColor.fromAHSV(1.0, hue, saturation, value).toColor();

          final colorHex = '#${selectedColor.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
          if (!isEditingColorCode && colorController.text != colorHex) {
            colorController.text = colorHex;
            colorController.selection = TextSelection.collapsed(offset: colorHex.length);
          }

          return Dialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            child: Container(
              width: 320,
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),

                  const SizedBox(height: 16),

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
                    sliderValue: hue,
                    min: 0,
                    max: 360,
                    onChanged: (v) {
                      colorFocusNode.unfocus();
                      setDialogState(() {
                        isEditingColorCode = false;
                        hue = v;
                      });
                    },
                    displayValue: hue.round().toString(),
                    gradientColors: [
                      const Color(0xFFFF0000),
                      const Color(0xFFFFFF00),
                      const Color(0xFF00FF00),
                      const Color(0xFF00FFFF),
                      const Color(0xFF0000FF),
                      const Color(0xFFFF00FF),
                      const Color(0xFFFF0000),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // 饱和度滑块
                  _buildColorSlider(
                    label: '饱和度',
                    sliderValue: saturation,
                    min: 0,
                    max: 1,
                    onChanged: (v) {
                      colorFocusNode.unfocus();
                      setDialogState(() {
                        isEditingColorCode = false;
                        saturation = v;
                      });
                    },
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
                    sliderValue: value,
                    min: 0,
                    max: 1,
                    onChanged: (v) {
                      colorFocusNode.unfocus();
                      setDialogState(() {
                        isEditingColorCode = false;
                        value = v;
                      });
                    },
                    displayValue: '${(value * 100).round()}%',
                    gradientColors: [
                      HSVColor.fromAHSV(1.0, hue, saturation, 0).toColor(),
                      HSVColor.fromAHSV(1.0, hue, saturation, 1).toColor(),
                    ],
                  ),

                  const SizedBox(height: 20),

                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: colorController,
                          focusNode: colorFocusNode,
                          decoration: InputDecoration(
                            hintText: '#RRGGBB',
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
                          keyboardType: TextInputType.text,
                          textCapitalization: TextCapitalization.characters,
                          autocorrect: false,
                          enableSuggestions: false,
                          onTap: () {
                            isEditingColorCode = true;
                          },
                          onChanged: (text) {
                            final color = _parseColor(text);
                            if (color == null) return;
                            final hsv = HSVColor.fromColor(color);
                            setDialogState(() {
                              hue = hsv.hue;
                              saturation = hsv.saturation;
                              value = hsv.value;
                            });
                          },
                          onSubmitted: (text) {
                            final color = _parseColor(text);
                            if (color == null) return;
                            final hsv = HSVColor.fromColor(color);
                            setDialogState(() {
                              hue = hsv.hue;
                              saturation = hsv.saturation;
                              value = hsv.value;
                              isEditingColorCode = false;
                            });
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
                          onChanged(
                            _parseColor(colorController.text) ?? selectedColor,
                          );
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
    ).whenComplete(() {
      colorController.dispose();
      colorFocusNode.dispose();
    });
  }

  Color? _parseColor(String text) {
    var value = text.trim();
    if (value.startsWith('#')) {
      value = value.substring(1);
    }
    if (value.toLowerCase().startsWith('0x')) {
      value = value.substring(2);
    }

    if (value.length != 6 && value.length != 8) return null;
    final parsed = int.tryParse(value, radix: 16);
    if (parsed == null) return null;
    return Color(value.length == 6 ? parsed + 0xFF000000 : parsed);
  }

  Widget _buildColorSlider({
    required String label,
    required double sliderValue,
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
            clipBehavior: Clip.none,
            children: [
              Container(
                height: 24,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: gradientColors),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              SliderTheme(
                data: SliderThemeData(
                  trackHeight: 24,
                  trackShape: const _FullWidthSliderTrackShape(),
                  thumbColor: Colors.white,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                  overlayShape: SliderComponentShape.noOverlay,
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                ),
                child: Slider(
                  value: sliderValue,
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
              AndroidSwitch(
                value: item.visible,
                onChanged: (v) => setState(() => item.visible = v),
                accentColor: Theme.of(context).colorScheme.secondary,
                isDark: Theme.of(context).brightness == Brightness.dark,
              ),
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

// 封面设置页面 - 参考原版 legado CoverConfigFragment
class CoverConfigPage extends StatefulWidget {
  const CoverConfigPage({super.key});
  @override
  State<CoverConfigPage> createState() => _CoverConfigPageState();
}

class _CoverConfigPageState extends State<CoverConfigPage> {
  // 通用设置
  bool _loadCoverOnlyWifi = false;
  bool _loadCoverHighQuality = false;
  bool _useDefaultCover = false;
  // 日间
  String _coverCollectionDay = '';
  String _coverCollectionModeDay = 'random';
  bool _coverShowName = true;
  bool _coverShowAuthor = true;
  String _defaultCover = '';
  // 夜间
  String _coverCollectionNight = '';
  String _coverCollectionModeNight = 'random';
  bool _coverShowNameN = true;
  bool _coverShowAuthorN = true;
  String _defaultCoverDark = '';
  // 显示作者的真实状态（用户手动设置的，不受显示书名影响）
  bool _coverShowAuthorReal = true;
  bool _coverShowAuthorNReal = true;
  // 图集名称缓存
  String _coverCollectionDayName = '';
  String _coverCollectionNightName = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _loadCoverOnlyWifi = prefs.getBool('loadCoverOnlyWifi') ?? false;
      _loadCoverHighQuality = prefs.getBool('loadCoverHighQuality') ?? false;
      _useDefaultCover = prefs.getBool('useDefaultCover') ?? false;
      _coverCollectionDay = prefs.getString('coverCollectionDay') ?? '';
      _coverCollectionModeDay = prefs.getString('coverCollectionModeDay') ?? 'random';
      _coverShowName = prefs.getBool('coverShowName') ?? true;
      // 读取真实状态
      _coverShowAuthorReal = prefs.getBool('coverShowAuthorReal') ?? true;
      // 如果显示书名关闭，显示作者强制关闭；否则恢复真实状态
      _coverShowAuthor = _coverShowName ? _coverShowAuthorReal : false;
      _defaultCover = prefs.getString('defaultCover') ?? '';
      _coverCollectionNight = prefs.getString('coverCollectionNight') ?? '';
      _coverCollectionModeNight = prefs.getString('coverCollectionModeNight') ?? 'random';
      _coverShowNameN = prefs.getBool('coverShowNameN') ?? true;
      // 读取真实状态
      _coverShowAuthorNReal = prefs.getBool('coverShowAuthorNReal') ?? true;
      // 如果显示书名关闭，显示作者强制关闭；否则恢复真实状态
      _coverShowAuthorN = _coverShowNameN ? _coverShowAuthorNReal : false;
      _defaultCoverDark = prefs.getString('defaultCoverDark') ?? '';
    });
    // 加载图集名称
    await _loadCollectionNames();
  }

  Future<void> _loadCollectionNames() async {
    if (_coverCollectionDay.isNotEmpty) {
      final dayCollections = await CoverCollectionManager.instance.getCollections(false);
      final dayColl = dayCollections.where((c) => c.id == _coverCollectionDay).firstOrNull;
      if (mounted && dayColl != null) {
        setState(() => _coverCollectionDayName = dayColl.name);
      }
    }
    if (_coverCollectionNight.isNotEmpty) {
      final nightCollections = await CoverCollectionManager.instance.getCollections(true);
      final nightColl = nightCollections.where((c) => c.id == _coverCollectionNight).firstOrNull;
      if (mounted && nightColl != null) {
        setState(() => _coverCollectionNightName = nightColl.name);
      }
    }
  }

  Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    CoverConfigService.instance.reload();
  }

  Future<void> _saveString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
    CoverConfigService.instance.reload();
  }

  Future<void> _removePref(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
    CoverConfigService.instance.reload();
  }

  String _getModeLabel(String mode) {
    switch (mode) {
      case 'random': return '随机';
      case 'sequence': return '顺序';
      case 'mixed': return '混合';
      default: return '随机';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('封面设置'),
      ),
      body: ListView(
        children: [
          // 仅WiFi加载封面
          _buildSwitchItem(
            title: '仅WiFi加载',
            subtitle: '仅WiFi网络下加载封面图片',
            value: _loadCoverOnlyWifi,
            onChanged: (v) {
              setState(() => _loadCoverOnlyWifi = v);
              _saveBool('loadCoverOnlyWifi', v);
            },
          ),

          // 加载高清封面
          _buildSwitchItem(
            title: '加载高清封面',
            subtitle: '开启后使用封面原图，关闭时优先加载缩略图',
            value: _loadCoverHighQuality,
            onChanged: (v) {
              setState(() => _loadCoverHighQuality = v);
              _saveBool('loadCoverHighQuality', v);
            },
          ),

          // 封面规则
          _buildListItem(
            title: '封面规则',
            subtitle: '进入详情页时使用封面规则重新获取封面',
            onTap: () => _showCoverRuleDialog(),
          ),

          // 总是使用默认封面
          _buildSwitchItem(
            title: '总是使用默认封面',
            subtitle: '总是显示默认封面（不显示网络封面）',
            value: _useDefaultCover,
            onChanged: (v) {
              setState(() => _useDefaultCover = v);
              _saveBool('useDefaultCover', v);
            },
          ),

          // 封面图集
          _buildListItem(
            title: '封面图集',
            onTap: () => _navigateToCoverCollectionManage(),
          ),

          const SizedBox(height: 8),

          // 日间主题
          _buildCategoryHeader('日间主题'),

          _buildListItem(
            title: '选用图集',
            subtitle: _coverCollectionDayName.isEmpty ? '无' : _coverCollectionDayName,
            onTap: () => _selectCoverCollection(false),
          ),

          _buildListItem(
            title: '封面模式',
            subtitle: _getModeLabel(_coverCollectionModeDay),
            onTap: () => _selectCoverMode(false),
          ),

          _buildSwitchItem(
            title: '显示书名',
            subtitle: '封面上显示书名',
            value: _coverShowName,
            onChanged: (v) {
              setState(() {
                _coverShowName = v;
                // 显示书名关闭时，显示作者强制关闭
                // 显示书名开启时，显示作者恢复真实状态
                if (!v) {
                  _coverShowAuthor = false;
                } else {
                  _coverShowAuthor = _coverShowAuthorReal;
                }
              });
              _saveBool('coverShowName', v);
              // 同步保存显示作者状态
              _saveBool('coverShowAuthor', _coverShowAuthor);
            },
          ),

          _buildSwitchItem(
            title: '显示作者',
            subtitle: '封面上显示作者',
            value: _coverShowAuthor,
            enabled: _coverShowName,
            onChanged: (v) {
              setState(() {
                _coverShowAuthor = v;
                _coverShowAuthorReal = v; // 保存真实状态
              });
              _saveBool('coverShowAuthor', v);
              _saveBool('coverShowAuthorReal', v); // 保存真实状态
            },
          ),

          _buildListItem(
            title: '默认封面',
            subtitle: _defaultCover.isEmpty ? '选择图片' : _defaultCover.split('/').last,
            onTap: () => _selectDefaultCover(false),
          ),

          const SizedBox(height: 8),

          // 夜间主题
          _buildCategoryHeader('夜间主题'),

          _buildListItem(
            title: '选用图集',
            subtitle: _coverCollectionNightName.isEmpty ? '无' : _coverCollectionNightName,
            onTap: () => _selectCoverCollection(true),
          ),

          _buildListItem(
            title: '封面模式',
            subtitle: _getModeLabel(_coverCollectionModeNight),
            onTap: () => _selectCoverMode(true),
          ),

          _buildSwitchItem(
            title: '显示书名',
            subtitle: '封面上显示书名',
            value: _coverShowNameN,
            onChanged: (v) {
              setState(() {
                _coverShowNameN = v;
                // 显示书名关闭时，显示作者强制关闭
                // 显示书名开启时，显示作者恢复真实状态
                if (!v) {
                  _coverShowAuthorN = false;
                } else {
                  _coverShowAuthorN = _coverShowAuthorNReal;
                }
              });
              _saveBool('coverShowNameN', v);
              // 同步保存显示作者状态
              _saveBool('coverShowAuthorN', _coverShowAuthorN);
            },
          ),

          _buildSwitchItem(
            title: '显示作者',
            subtitle: '封面上显示作者',
            value: _coverShowAuthorN,
            enabled: _coverShowNameN,
            onChanged: (v) {
              setState(() {
                _coverShowAuthorN = v;
                _coverShowAuthorNReal = v; // 保存真实状态
              });
              _saveBool('coverShowAuthorN', v);
              _saveBool('coverShowAuthorNReal', v); // 保存真实状态
            },
          ),

          _buildListItem(
            title: '默认封面',
            subtitle: _defaultCoverDark.isEmpty ? '选择图片' : _defaultCoverDark.split('/').last,
            onTap: () => _selectDefaultCover(true),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// 构建分类标题 - 参考原版 view_preference_category.xml
  /// 使用强调色（accentColor）
  Widget _buildCategoryHeader(String title) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: colorScheme.secondary, // 使用强调色
        ),
      ),
    );
  }

  /// 构建列表项 - 参考原版 view_preference.xml
  /// 标题 16sp，副标题 14sp，高度 60dp，padding 10dp
  Widget _buildListItem({
    required String title,
    String? subtitle,
    VoidCallback? onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
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
            Icon(Icons.chevron_right,
                color: isDark ? Colors.white54 : const Color(0xFFBDBDBD)),
          ],
        ),
      ),
    );
  }

  /// 构建开关项 - 参考原版 view_preference.xml + SwitchPreference
  /// 标题 16sp，副标题 14sp，高度 60dp，padding 10dp
  Widget _buildSwitchItem({
    required String title,
    String? subtitle,
    required bool value,
    bool enabled = true,
    required ValueChanged<bool> onChanged,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 使用强调色（secondary）而不是主色（primary），参考原版 SwitchPreference
    final accentColor = Theme.of(context).colorScheme.secondary;

    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
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
                      color: enabled
                          ? (isDark ? Colors.white : const Color(0xFF212121))
                          : (isDark ? Colors.white38 : const Color(0xFFBDBDBD)),
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: enabled
                              ? (isDark ? Colors.white70 : const Color(0xFF757575))
                              : (isDark ? Colors.white24 : const Color(0xFFBDBDBD)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 原版Android SwitchCompat风格 - 自定义绘制thumb和track
            AndroidSwitch(
              value: value,
              onChanged: onChanged,
              accentColor: accentColor,
              isDark: isDark,
              enabled: enabled,
            ),
          ],
        ),
      ),
    );
  }

  /// 封面规则配置对话框 - 参考原版 CoverRuleConfigDialog
  void _showCoverRuleDialog() async {
    final rule = CoverConfigService.instance.coverRule;
    bool enable = rule.enable;
    String searchUrl = rule.searchUrl;
    String coverRule = rule.coverRule;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          backgroundColor: Theme.of(ctx).brightness == Brightness.dark
              ? const Color(0xFF424242)
              : Colors.white,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 标题栏 - 与AlertDialog一致，无背景色
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: Text(
                    '封面规则',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(ctx).brightness == Brightness.dark
                          ? Colors.white
                          : const Color(0xFF212121),
                    ),
                  ),
                ),

                // 内容区域
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 启用开关
                        Row(
                          children: [
                            Checkbox(
                              value: enable,
                              activeColor: Theme.of(ctx).colorScheme.primary,
                              onChanged: (v) => setDialogState(() => enable = v ?? true),
                            ),
                            Text('启用',
                                style: TextStyle(
                                  color: Theme.of(ctx).brightness == Brightness.dark
                                      ? Colors.white
                                      : const Color(0xFF212121),
                                )),
                          ],
                        ),

                        const SizedBox(height: 12),

                        // 搜索URL输入框
                        TextField(
                          controller: TextEditingController(text: searchUrl),
                          style: TextStyle(
                            color: Theme.of(ctx).brightness == Brightness.dark
                                ? Colors.white
                                : const Color(0xFF212121),
                          ),
                          decoration: InputDecoration(
                            labelText: '搜索URL',
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            labelStyle: TextStyle(
                              color: Theme.of(ctx).brightness == Brightness.dark
                                  ? Colors.white70
                                  : const Color(0xFF757575),
                            ),
                          ),
                          maxLines: 2,
                          onChanged: (v) => searchUrl = v,
                        ),

                        const SizedBox(height: 12),

                        // 封面规则输入框
                        TextField(
                          controller: TextEditingController(text: coverRule),
                          style: TextStyle(
                            color: Theme.of(ctx).brightness == Brightness.dark
                                ? Colors.white
                                : const Color(0xFF212121),
                          ),
                          decoration: InputDecoration(
                            labelText: '封面规则',
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            labelStyle: TextStyle(
                              color: Theme.of(ctx).brightness == Brightness.dark
                                  ? Colors.white70
                                  : const Color(0xFF757575),
                            ),
                          ),
                          maxLines: 8,
                          onChanged: (v) => coverRule = v,
                        ),
                      ],
                    ),
                  ),
                ),

                // 底部按钮区域
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () async {
                          // 恢复默认
                          await CoverConfigService.instance.deleteCoverRule();
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已恢复默认封面规则')),
                          );
                        },
                        child: Text(
                          '默认',
                          style: TextStyle(color: Theme.of(ctx).colorScheme.primary),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text('取消',
                                style: TextStyle(
                                  color: Theme.of(ctx).brightness == Brightness.dark
                                      ? Colors.white70
                                      : const Color(0xFF757575),
                                )),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () async {
                              if (searchUrl.isEmpty || coverRule.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('搜索URL和封面规则不能为空')),
                                );
                                return;
                              }
                              final newRule = CoverRule(
                                enable: enable,
                                searchUrl: searchUrl,
                                coverRule: coverRule,
                              );
                              await CoverConfigService.instance.saveCoverRule(newRule);
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('封面规则已保存')),
                              );
                            },
                            child: Text(
                              '确定',
                              style: TextStyle(color: Theme.of(ctx).colorScheme.primary),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _selectCoverCollection(bool isNight) async {
    final collections = await CoverCollectionManager.instance.getCollections(isNight);
    final selectedId = isNight ? _coverCollectionNight : _coverCollectionDay;

    if (!mounted) return;

    final items = ['无'];
    items.addAll(collections.map((c) => '${c.name} (${c.images.length}张)'));
    int selectedIndex = selectedId.isEmpty ? 0 : collections.indexWhere((c) => c.id == selectedId) + 1;

    final result = await CommonWidgets.showSelectorDialog(
      context,
      title: '选用图集',
      items: items,
      selectedIndex: selectedIndex,
    );

    if (result != null) {
      final selected = result == 0 ? null : (result - 1 < collections.length ? collections[result - 1] : null);
      await CoverCollectionManager.instance.setSelectedCollection(selected?.id, isNight);
      setState(() {
        if (isNight) {
          _coverCollectionNight = selected?.id ?? '';
          _coverCollectionNightName = selected?.name ?? '';
        } else {
          _coverCollectionDay = selected?.id ?? '';
          _coverCollectionDayName = selected?.name ?? '';
        }
      });
    }
  }

  /// 导航到封面图集管理页 - 使用流畅的页面过渡
  void _navigateToCoverCollectionManage() {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const CoverCollectionManagePage(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // 使用淡入淡出过渡，更流畅
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 200),
      ),
    ).then((_) {
      // 返回后刷新图集名称
      _loadCollectionNames();
    });
  }

  void _selectCoverMode(bool isNight) {
    final modes = ['随机', '顺序', '混合'];
    final modeValues = ['random', 'sequence', 'mixed'];
    final currentMode = isNight ? _coverCollectionModeNight : _coverCollectionModeDay;
    int selectedIndex = modeValues.indexOf(currentMode);

    CommonWidgets.showSelectorDialog(
      context,
      title: '封面模式',
      items: modes,
      selectedIndex: selectedIndex,
    ).then((result) {
      if (result != null) {
        final mode = modeValues[result];
        if (isNight) {
          setState(() => _coverCollectionModeNight = mode);
          _saveString('coverCollectionModeNight', mode);
        } else {
          setState(() => _coverCollectionModeDay = mode);
          _saveString('coverCollectionModeDay', mode);
        }
      }
    });
  }

  void _selectDefaultCover(bool isNight) {
    final currentPath = isNight ? _defaultCoverDark : _defaultCover;

    if (currentPath.isEmpty) {
      _pickCoverImage(isNight);
    } else {
      showModalBottomSheet(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('删除'),
                onTap: () {
                  Navigator.pop(ctx);
                  final key = isNight ? 'defaultCoverDark' : 'defaultCover';
                  _removePref(key);
                  setState(() {
                    if (isNight) {
                      _defaultCoverDark = '';
                    } else {
                      _defaultCover = '';
                    }
                  });
                },
              ),
              ListTile(
                title: const Text('选择图片'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickCoverImage(isNight);
                },
              ),
            ],
          ),
        ),
      );
    }
  }

  Future<void> _pickCoverImage(bool isNight) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        final key = isNight ? 'defaultCoverDark' : 'defaultCover';
        await _saveString(key, path);
        setState(() {
          if (isNight) {
            _defaultCoverDark = path;
          } else {
            _defaultCover = path;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择图片失败: $e')),
        );
      }
    }
  }
}

/// 封面图集管理页 - 完全参考原版 CoverCollectionManageActivity
class CoverCollectionManagePage extends StatefulWidget {
  const CoverCollectionManagePage({super.key});

  @override
  State<CoverCollectionManagePage> createState() => _CoverCollectionManagePageState();
}

class _CoverCollectionManagePageState extends State<CoverCollectionManagePage> {
  bool _isNight = false;
  List<CoverCollection> _dayCollections = [];
  List<CoverCollection> _nightCollections = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // 使用addPostFrameCallback延迟加载，让页面先完成渲染
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCollections();
    });
  }

  Future<void> _loadCollections() async {
    final day = await CoverCollectionManager.instance.getCollections(false);
    final night = await CoverCollectionManager.instance.getCollections(true);
    if (mounted) {
      setState(() {
        _dayCollections = day;
        _nightCollections = night;
        _loading = false;
      });
    }
  }

  List<CoverCollection> get _currentCollections =>
      _isNight ? _nightCollections : _dayCollections;

  Future<void> _switchTab(bool isNight) async {
    if (_isNight == isNight) return;
    setState(() => _isNight = isNight);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('封面图集'),
      ),
      body: Column(
        children: [
          // TabBar - 完全参考原版 activity_cover_collection_manage.xml 的 tabBar
          Container(
            margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            height: 42,
            decoration: BoxDecoration(
              color: colorScheme.surface.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => _switchTab(false),
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: !_isNight ? colorScheme.surface.withValues(alpha: 0.2) : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          '日间',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: !_isNight ? colorScheme.secondary : colorScheme.onSurface, // 使用强调色
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _switchTab(true),
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: _isNight ? colorScheme.surface.withValues(alpha: 0.2) : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          '夜间',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _isNight ? colorScheme.secondary : colorScheme.onSurface, // 使用强调色
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 8),
          
          // RecyclerView - 图集列表
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _buildList(),
          ),
          
          // btn_add - 添加按钮 (参考原版 bg_book_info_action_secondary)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            width: double.infinity,
            height: 48,
            decoration: BoxDecoration(
              color: colorScheme.surface.withValues(alpha: 0.87),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: colorScheme.onSurface.withValues(alpha: 0.4),
                width: 1,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _showAddActions,
              child: Center(
                child: Text(
                  '添加图集',
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

  void _showAddActions() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加图集'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDialogItem('创建图集', () {
              Navigator.pop(ctx);
              _createCollection();
            }),
            _buildDialogItem('导入ZIP', () {
              Navigator.pop(ctx);
              _importZip();
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildDialogItem(String text, VoidCallback onTap, {bool isDestructive = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark 
        ? const Color(0xDEFFFFFF)  // 夜间：87%白
        : const Color(0xDE000000); // 日间：87%黑
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 16,
            color: isDestructive ? Theme.of(context).colorScheme.error : primaryTextColor,
          ),
        ),
      ),
    );
  }

  Widget _buildList() {
    final collections = _currentCollections;
    final colorScheme = Theme.of(context).colorScheme;
    
    if (collections.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '暂无${_isNight ? "夜间" : "日间"}图集，点击下方添加',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: collections.length,
      itemBuilder: (ctx, index) => _buildCollectionItem(collections[index]),
    );
  }

  // 图集卡片 - 完全参考原版 item_cover_collection.xml
  Widget _buildCollectionItem(CoverCollection collection) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.onSurface.withValues(alpha: 0.04),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: () => _navigateToDetail(collection),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // iv_preview - 预览图 (54dp x 72dp)
            Container(
              width: 54,
              height: 72,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: collection.images.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      clipBehavior: Clip.hardEdge,
                      child: Image.file(
                        File(collection.images.first),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(
                          Icons.broken_image,
                          size: 24,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Icon(
                      Icons.image,
                      size: 24,
                      color: colorScheme.onSurfaceVariant,
                    ),
            ),
            
            const SizedBox(width: 12),
            
            // lay_info - 信息区域
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // tv_name - 名称 (16sp, bold)
                  Text(
                    collection.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  
                  const SizedBox(height: 5),
                  
                  // tv_info - 信息 (13sp)
                  Text(
                    '${collection.images.length}张图片',
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            
            // btn_more - 更多按钮 (34dp高度, minWidth 56dp)
            GestureDetector(
              onTap: () => _showCollectionOptions(collection),
              child: Container(
                height: 34,
                constraints: const BoxConstraints(minWidth: 56),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: colorScheme.surface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    '更多',
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _createCollection() async {
    final colorScheme = Theme.of(context).colorScheme;
    final nameController = TextEditingController();
    
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('图集名称'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            hintText: '请输入图集名称',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入图集名称')),
                );
                return;
              }
              Navigator.pop(ctx);
              try {
                await CoverCollectionManager.instance.createCollection(
                  name: name,
                  isNight: _isNight,
                );
                _loadCollections();
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('创建失败: $e')),
                );
              }
            },
            child: Text('确定', style: TextStyle(color: colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  void _importZip() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        allowCompression: false,
      );
      if (result != null && result.files.isNotEmpty) {
        final path = result.files.first.path;
        if (path != null) {
          // TODO: 实现ZIP导入功能
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('选择文件: $path')),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
  }

  void _showCollectionOptions(CoverCollection collection) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(collection.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDialogItem('重命名', () {
              Navigator.pop(ctx);
              _renameCollection(collection);
            }),
            _buildDialogItem('导出ZIP', () {
              Navigator.pop(ctx);
              _exportCollection(collection);
            }),
            _buildDialogItem('删除', () {
              Navigator.pop(ctx);
              _deleteCollection(collection);
            }, isDestructive: true),
          ],
        ),
      ),
    );
  }

  void _renameCollection(CoverCollection collection) async {
    final colorScheme = Theme.of(context).colorScheme;
    final nameController = TextEditingController(text: collection.name);
    
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('图集名称'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            hintText: '请输入图集名称',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入图集名称')),
                );
                return;
              }
              Navigator.pop(ctx);
              try {
                await CoverCollectionManager.instance.renameCollection(
                  collection.id, name, collection.isNight,
                );
                _loadCollections();
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('重命名失败: $e')),
                );
              }
            },
            child: Text('确定', style: TextStyle(color: colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  void _exportCollection(CoverCollection collection) {
    // TODO: 实现导出ZIP功能
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('导出功能待实现')),
    );
  }

  void _deleteCollection(CoverCollection collection) async {
    final colorScheme = Theme.of(context).colorScheme;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除图集 "${collection.name}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: colorScheme.error)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await CoverCollectionManager.instance.deleteCollection(
          collection.id, collection.isNight,
        );
        _loadCollections();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  void _navigateToDetail(CoverCollection collection) async {
    await Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            CoverCollectionDetailPage(collection: collection),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // 使用淡入淡出过渡，更流畅
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
    _loadCollections();
  }
}

/// 图集详情页 - 完全参考原版 CoverCollectionDetailActivity
class CoverCollectionDetailPage extends StatefulWidget {
  final CoverCollection collection;

  const CoverCollectionDetailPage({super.key, required this.collection});

  @override
  State<CoverCollectionDetailPage> createState() => _CoverCollectionDetailPageState();
}

class _CoverCollectionDetailPageState extends State<CoverCollectionDetailPage> {
  late CoverCollection _collection;

  @override
  void initState() {
    super.initState();
    _collection = widget.collection;
    // 使用addPostFrameCallback延迟加载，让页面先完成渲染
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reloadCollection();
    });
  }

  Future<void> _reloadCollection() async {
    final collections = await CoverCollectionManager.instance.getCollections(_collection.isNight);
    final updated = collections.where((c) => c.id == _collection.id).firstOrNull;
    if (updated != null && mounted) {
      setState(() => _collection = updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(_collection.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_photo_alternate),
            tooltip: '导入图片',
            onPressed: _importImages,
          ),
        ],
      ),
      body: _collection.images.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '暂无图片，点击右上角按钮导入',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.0, // 150dp高度，保持正方形
              ),
              itemCount: _collection.images.length,
              itemBuilder: (ctx, index) => _buildImageItem(index),
            ),
    );
  }

  // 图片项 - 完全参考原版 item_cover_collection_image.xml
  // FrameLayout: 150dp高度，5dp margin，4dp padding
  Widget _buildImageItem(int index) {
    final colorScheme = Theme.of(context).colorScheme;
    final imagePath = _collection.images[index];
    
    return GestureDetector(
      onLongPress: () => _removeImage(index),
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surface.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.onSurface.withValues(alpha: 0.04),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.all(4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.hardEdge,
          child: Image.file(
            File(imagePath),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Center(
              child: Icon(
                Icons.broken_image,
                size: 32,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _importImages() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (result != null && result.paths.isNotEmpty) {
        final paths = result.paths.whereType<String>().toList();
        await CoverCollectionManager.instance.importImages(
          _collection.id, paths, _collection.isNight,
        );
        _reloadCollection();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入${paths.length}张图片')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入图片失败: $e')),
        );
      }
    }
  }

  void _removeImage(int index) async {
    final colorScheme = Theme.of(context).colorScheme;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除图片'),
        content: const Text('确定要删除这张图片吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: colorScheme.error)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await CoverCollectionManager.instance.removeImage(
          _collection.id, _collection.images[index], _collection.isNight,
        );
        _reloadCollection();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }
}

/// 导航项数据类 - 参考原版 NavigationBarIconConfig.NavItem
class _NavItem {
  final String key;
  final String title;
  final IconData icon;

  const _NavItem(this.key, this.title, this.icon);
}
