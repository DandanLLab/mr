import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../providers/bookshelf_provider.dart';
import '../../providers/discovery_provider.dart';
import '../../widgets/android_switch.dart';
import 'book_source_manage_page.dart';
import '../settings/theme_settings_page.dart';
import '../settings/ai_settings_page.dart';
import '../../routes/app_routes.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
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
    super.build(context);
    final primaryColor = Theme.of(context).colorScheme.primary;
    // 参考 legado-main: 根据实际 primary 颜色明暗决定标题文字颜色
    final primaryForeground = ThemeData.estimateBrightnessForColor(primaryColor) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // 顶部标题栏（高度48dp，与其他主页面一致）
          Container(
            padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
            color: primaryColor,
            child: SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text(
                      '我的',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.normal,
                        color: primaryForeground,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(
                        Icons.help_outline,
                        color: primaryForeground,
                      ),
                      tooltip: '帮助',
                      onPressed: () {
                        _showHelpDialog();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 内容列表
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 8),
              children: [
                // 书源管理（无分类标题）
                _buildSection([
                  _buildListItem(
                    icon: Icons.menu_book_outlined,
                    title: '书源管理',
                    subtitle: '已导入 $_sourceCount 个书源',
                    onTap: () => _showBookSourceManagement(),
                  ),
                  _buildListItem(
                    icon: Icons.menu_book_outlined,
                    title: 'TXT目录规则',
                    subtitle: '管理TXT文件目录解析规则',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.txtTocRule),
                  ),
                  _buildListItem(
                    icon: Icons.swap_horiz,
                    title: '替换净化',
                    subtitle: '内容替换规则管理',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.replaceRule),
                  ),
                  _buildListItem(
                    icon: Icons.translate,
                    title: '字典规则',
                    subtitle: '字典翻译规则管理',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.dictRule),
                  ),
                  Consumer<AppProvider>(
                    builder: (context, provider, child) {
                      return _buildListItem(
                        leading: const _LegacyThemeIcon(),
                        title: '主题模式',
                        subtitle: '选择主题模式',
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0x1A0A84FF),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            _getThemeModeText(provider.themeMode),
                            style: TextStyle(
                              fontSize: 14,
                              color: primaryForeground,
                            ),
                          ),
                        ),
                        onTap: () => _showThemeDialog(provider),
                      );
                    },
                  ),
                  _buildSwitchItem(
                    icon: Icons.public,
                    title: 'Web服务',
                    subtitle: '开启后可通过浏览器访问',
                    value: false,
                    onChanged: (value) {},
                  ),
                ]),

                // 扩展与 AI
                _buildCategoryTitle('扩展与 AI'),
                _buildSection([
                  _buildListItem(
                    icon: Icons.extension_outlined,
                    title: '扩展设置',
                    subtitle: '管理插件和扩展功能',
                    onTap: () {},
                  ),
                  _buildListItem(
                    icon: Icons.psychology_outlined,
                    title: 'AI 设置',
                    subtitle: '配置 AI 相关功能',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AiSettingsPage()),
                    ),
                  ),
                ]),

                // 设置
                _buildCategoryTitle('设置'),
                _buildSection([
                  _buildListItem(
                    icon: Icons.folder_outlined,
                    title: '备份恢复',
                    subtitle: 'WebDAV备份与恢复',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.backupRestore),
                  ),
                  _buildListItem(
                    leading: const _LegacyThemeIcon(),
                    title: '主题设置',
                    subtitle: '自定义主题颜色和样式',
                    onTap: () => Navigator.push(
                      context,
                      AppPageRoute(
                        builder: (context) => const ThemeSettingsPage(),
                      ),
                    ),
                  ),
                  _buildListItem(
                    icon: Icons.settings_outlined,
                    title: '其他设置',
                    subtitle: '阅读、界面等更多设置',
                    onTap: () => _showReaderSettings(),
                  ),
                ]),

                // 其他
                _buildCategoryTitle('其他'),
                _buildSection([
                  _buildListItem(
                    icon: Icons.bookmark_border,
                    title: '书签',
                    subtitle: '查看所有书签',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.bookmark),
                  ),
                  _buildListItem(
                    icon: Icons.history_outlined,
                    title: '阅读记录',
                    subtitle: '查看阅读历史',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.readRecord),
                  ),
                  _buildListItem(
                    icon: Icons.storage_outlined,
                    title: '存储管理',
                    subtitle: '管理本地存储的书籍',
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.storageManage),
                  ),
                  _buildListItem(
                    icon: Icons.info_outline_rounded,
                    title: '关于',
                    onTap: _showAboutDialog,
                  ),
                  _buildListItem(
                    icon: Icons.logout,
                    title: '退出',
                    onTap: () => _showExitConfirm(),
                  ),
                ]),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(List<Widget> children) {
    final provider = context.watch<AppProvider>();
    final imagePath = provider.currentPanelBackgroundImage;
    final borderColor = provider.currentPanelBorderColor;
    final radius = 10 * provider.currentCornerScale;
    return Container(
      clipBehavior: imagePath == null ? Clip.none : Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: borderColor == null
            ? null
            : Border.all(
                color: borderColor.withValues(
                  alpha: provider.currentPanelBorderAlpha / 100,
                ),
              ),
        image: imagePath == null || imagePath.isEmpty
            ? null
            : DecorationImage(
                image: _panelImageProvider(imagePath),
                fit: provider.currentPanelBackgroundMode == 'fit'
                    ? BoxFit.contain
                    : BoxFit.cover,
                opacity: provider.currentLayoutAlpha / 100,
              ),
      ),
      child: Column(children: children),
    );
  }

  ImageProvider _panelImageProvider(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return NetworkImage(path);
    }
    return FileImage(File(path));
  }

  Widget _buildCategoryTitle(String title) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: colorScheme.secondary,
        ),
      ),
    );
  }

  Widget _buildListItem({
    IconData? icon,
    Widget? leading,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.transparent,
        highlightColor: theme.brightness == Brightness.dark
            ? const Color(0x634D4D4D)
            : const Color(0x63ACACAC),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: leading ??
                      Icon(
                        icon ?? Icons.circle_outlined,
                        color: colorScheme.secondary,
                        size: 24,
                      ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildItemText(
                    title: title,
                    subtitle: subtitle,
                    colorScheme: colorScheme,
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchItem({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(!value),
        splashColor: Colors.transparent,
        highlightColor: isDark
            ? const Color(0x634D4D4D)
            : const Color(0x63ACACAC),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(icon, color: colorScheme.secondary, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildItemText(
                    title: title,
                    subtitle: subtitle,
                    colorScheme: colorScheme,
                  ),
                ),
                const SizedBox(width: 8),
                AndroidSwitch(
                  value: value,
                  onChanged: onChanged,
                  accentColor: colorScheme.secondary,
                  isDark: isDark,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItemText({
    required String title,
    required String? subtitle,
    required ColorScheme colorScheme,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 16, color: colorScheme.onSurface),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
          ),
        ],
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

  void _showBookSourceManagement() {
    Navigator.push(
      context,
      AppPageRoute(builder: (context) => const BookSourceManagePage()),
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

class _LegacyThemeIcon extends StatelessWidget {
  final Color? color;

  const _LegacyThemeIcon({this.color});

  @override
  Widget build(BuildContext context) {
    final resolvedColor = color ?? Theme.of(context).colorScheme.secondary;
    return SizedBox(
      width: 24,
      height: 24,
      child: CustomPaint(
        painter: _LegacyThemeIconPainter(resolvedColor),
      ),
    );
  }
}

class _LegacyThemeIconPainter extends CustomPainter {
  final Color color;

  _LegacyThemeIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final scaleX = size.width / 24.0;
    final scaleY = size.height / 24.0;

    canvas.save();
    canvas.scale(scaleX, scaleY);

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    canvas.drawPath(_cfgThemePath, paint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LegacyThemeIconPainter oldDelegate) {
    return oldDelegate.color != color;
  }

  static final Path _cfgThemePath = _parseSvgPathData(
    'M20.37,4.75 L16,3H14.29A2.5,2.5 0,0 1,9.71 3H8L3.63,4.75A1,1 0,0 0,3 5.68V10a1.05,1.05 0,0 0,1 1.05,1 1,0 0,0 0.3,-0.05L6.5,10v9a2,2 0,0 0,2 2h7a2,2 0,0 0,2 -2V10l2.18,1A1,1 0,0 0,21 10V5.68A1,1 0,0 0,20.37 4.75ZM19.5,9.27 L16.72,8a0.51,0.51 0,0 0,-0.72 0.46V19a0.5,0.5 0,0 1,-0.5 0.5h-7A0.5,0.5 0,0 1,8 19V8.45A0.5,0.5 0,0 0,7.29 8L4.5,9.27V6L8.29,4.5H8.9a4,4 0,0 0,6.2 0h0.61L19.5,6Z',
  );

}

Path _parseSvgPathData(String data) {
  final parser = _SvgPathParser(data);
  return parser.parse();
}

class _SvgPathParser {
  final String data;
  int _index = 0;
  final Path _path = Path();
  Offset _current = Offset.zero;
  Offset _subpathStart = Offset.zero;

  _SvgPathParser(this.data);

  Path parse() {
    String? command;
    while (_skipSeparators()) {
      final ch = _peekChar();
      if (_isCommandLetter(ch)) {
        command = _nextChar();
      } else if (command == null) {
        throw FormatException('Invalid SVG path data');
      }
      _parseCommand(command!);
    }
    return _path;
  }

  void _parseCommand(String command) {
    switch (command) {
      case 'M':
      case 'm':
        _parseMoveTo(command == 'm');
        break;
      case 'L':
      case 'l':
        _parseLineTo(command == 'l');
        break;
      case 'H':
      case 'h':
        _parseHorizontal(command == 'h');
        break;
      case 'V':
      case 'v':
        _parseVertical(command == 'v');
        break;
      case 'C':
      case 'c':
        _parseCubic(command == 'c');
        break;
      case 'A':
      case 'a':
        _parseArc(command == 'a');
        break;
      case 'Z':
      case 'z':
        _path.close();
        _current = _subpathStart;
        break;
      default:
        throw FormatException('Unsupported SVG command: $command');
    }
  }

  void _parseMoveTo(bool relative) {
    final first = _readPoint(relative);
    _path.moveTo(first.dx, first.dy);
    _current = first;
    _subpathStart = first;
    while (_hasNumberAhead()) {
      final point = _readPoint(relative);
      _path.lineTo(point.dx, point.dy);
      _current = point;
    }
  }

  void _parseLineTo(bool relative) {
    while (_hasNumberAhead()) {
      final point = _readPoint(relative);
      _path.lineTo(point.dx, point.dy);
      _current = point;
    }
  }

  void _parseHorizontal(bool relative) {
    while (_hasNumberAhead()) {
      final x = _readNumber();
      final targetX = relative ? _current.dx + x : x;
      _path.lineTo(targetX, _current.dy);
      _current = Offset(targetX, _current.dy);
    }
  }

  void _parseVertical(bool relative) {
    while (_hasNumberAhead()) {
      final y = _readNumber();
      final targetY = relative ? _current.dy + y : y;
      _path.lineTo(_current.dx, targetY);
      _current = Offset(_current.dx, targetY);
    }
  }

  void _parseCubic(bool relative) {
    while (_hasNumberAhead()) {
      final c1 = _readPoint(relative);
      final c2 = _readPoint(relative);
      final end = _readPoint(relative);
      _path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
      _current = end;
    }
  }

  void _parseArc(bool relative) {
    while (_hasNumberAhead()) {
      final rx = _readNumber().abs();
      final ry = _readNumber().abs();
      final rotation = _readNumber();
      final largeArc = _readFlag();
      final sweep = _readFlag();
      final end = _readPoint(relative);
      _path.arcToPoint(
        end,
        radius: Radius.elliptical(rx, ry),
        rotation: rotation,
        largeArc: largeArc,
        clockwise: sweep,
      );
      _current = end;
    }
  }

  Offset _readPoint(bool relative) {
    final x = _readNumber();
    final y = _readNumber();
    return relative ? Offset(_current.dx + x, _current.dy + y) : Offset(x, y);
  }

  bool _readFlag() {
    _skipSeparators();
    final ch = _nextChar();
    if (ch == '0') return false;
    if (ch == '1') return true;
    throw FormatException('Invalid arc flag in SVG path data');
  }

  double _readNumber() {
    _skipSeparators();
    final start = _index;
    var seenDot = false;
    var seenExp = false;
    if (_peekChar() == '+' || _peekChar() == '-') {
      _index++;
    }
    while (_index < data.length) {
      final code = data.codeUnitAt(_index);
      if (code >= 0x30 && code <= 0x39) {
        _index++;
        continue;
      }
      if (code == 0x2E && !seenDot) {
        seenDot = true;
        _index++;
        continue;
      }
      if ((code == 0x65 || code == 0x45) && !seenExp) {
        seenExp = true;
        _index++;
        if (_index < data.length) {
          final nextCode = data.codeUnitAt(_index);
          if (nextCode == 0x2B || nextCode == 0x2D) {
            _index++;
          }
        }
        continue;
      }
      if ((code == 0x2B || code == 0x2D) && _index == start) {
        _index++;
        continue;
      }
      break;
    }
    final value = data.substring(start, _index);
    return double.parse(value);
  }

  bool _hasNumberAhead() {
    var i = _index;
    while (i < data.length) {
      final ch = data[i];
      if (ch == ',' || ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') {
        i++;
        continue;
      }
      return !_isCommandLetter(ch);
    }
    return false;
  }

  bool _skipSeparators() {
    var moved = false;
    while (_index < data.length) {
      final ch = data[_index];
      if (ch == ',' || ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') {
        _index++;
        moved = true;
        continue;
      }
      break;
    }
    return _index < data.length;
  }

  String _peekChar() => data[_index];

  String _nextChar() => data[_index++];

  bool _isCommandLetter(String ch) {
    return ch.length == 1 && RegExp(r'[A-Za-z]').hasMatch(ch);
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
          Text('阅读设置', style: Theme.of(context).textTheme.titleLarge),
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
