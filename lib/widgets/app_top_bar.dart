import 'package:flutter/material.dart';
import '../../utils/design_tokens.dart';

/// 统一顶栏组件
///
/// 解决项目中自定义 Container 顶栏与标准 AppBar 混用的问题。
/// 支持两种模式：
/// - [AppTopBarMode.primary]：主色背景，用于主 Tab 页面（书架/发现/订阅/我的）
/// - [AppTopBarMode.surface]：Surface 色背景，用于子页面
///
/// 自动处理状态栏安全区域、标题颜色对比度。
class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;
  final Widget? leading;
  final AppTopBarMode mode;
  final bool centerTitle;
  final VoidCallback? onTitleTap;

  const AppTopBar({
    super.key,
    required this.title,
    this.actions,
    this.leading,
    this.mode = AppTopBarMode.surface,
    this.centerTitle = false,
    this.onTitleTap,
  });

  @override
  Size get preferredSize => const Size.fromHeight(DesignTokens.topBarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final Color backgroundColor;
    final Color foregroundColor;

    switch (mode) {
      case AppTopBarMode.primary:
        backgroundColor = colorScheme.primary;
        foregroundColor =
            ThemeData.estimateBrightnessForColor(backgroundColor) ==
                    Brightness.dark
                ? Colors.white
                : Colors.black;
        break;
      case AppTopBarMode.surface:
        backgroundColor = Colors.transparent;
        foregroundColor =
            isDark ? Colors.white : colorScheme.onSurface;
        break;
    }

    return Material(
      color: backgroundColor,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: DesignTokens.topBarHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: DesignTokens.spacingLg),
            child: NavigationToolbar(
              leading: leading,
              middle: GestureDetector(
                onTap: onTitleTap,
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: DesignTokens.fontTitle,
                    fontWeight: FontWeight.normal,
                    color: foregroundColor,
                  ),
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: actions ?? [],
              ),
              centerMiddle: centerTitle,
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶栏模式
enum AppTopBarMode {
  /// 主色背景，用于主 Tab 页面
  primary,

  /// Surface 色背景（透明），用于子页面
  surface,
}
