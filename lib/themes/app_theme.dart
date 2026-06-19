import 'package:flutter/material.dart';
import '../utils/design_tokens.dart';
import 'theme_config.dart';
import 'ui_corner.dart';

/// 应用主题系统
///
/// 完整移植自 Legado-Rimchars 的主题系统：
/// - ThemeStore.kt: 颜色存储与应用
/// - ThemeConfig.kt: 主题配置管理
/// - UiCorner.kt: 圆角缩放
/// - UiTypography.kt: 字体排版
/// - colors.xml: 颜色定义
/// - styles.xml: 样式定义
///
/// 使用方式：
/// ```dart
/// MaterialApp(
///   theme: AppTheme.light(),
///   darkTheme: AppTheme.dark(),
///   themeMode: ThemeMode.system,
/// )
/// ```
class AppTheme {
  AppTheme._();

  /// 亮色主题
  static ThemeData light({ThemeConfig? config}) {
    final c = config ?? ThemeConfig.defaultLight();
    final colorScheme = ColorScheme.light(
      primary: c.primaryColor,
      onPrimary: _onColorFor(c.primaryColor),
      secondary: c.accentColor,
      onSecondary: _onColorFor(c.accentColor),
      surface: DesignTokens.lightBackgroundCard,
      onSurface: DesignTokens.lightPrimaryText,
      surfaceContainerHighest: DesignTokens.lightBackgroundMenu,
      error: const Color(0xFFEB4333),
      onError: Colors.white,
    );

    return _buildTheme(
      brightness: Brightness.light,
      colorScheme: colorScheme,
      config: c,
      scaffoldBg: c.backgroundColor,
      cardBg: DesignTokens.lightBackgroundCard,
      menuBg: DesignTokens.lightBackgroundMenu,
      primaryText: DesignTokens.lightPrimaryText,
      secondaryText: DesignTokens.lightSecondaryText,
      divider: const Color(0x1F000000),
    );
  }

  /// 暗色主题
  static ThemeData dark({ThemeConfig? config}) {
    final c = config ?? ThemeConfig.defaultDark();
    final colorScheme = ColorScheme.dark(
      primary: c.primaryColor,
      onPrimary: _onColorFor(c.primaryColor),
      secondary: c.accentColor,
      onSecondary: _onColorFor(c.accentColor),
      surface: DesignTokens.darkBackgroundCard,
      onSurface: DesignTokens.darkPrimaryText,
      surfaceContainerHighest: DesignTokens.darkBackgroundMenu,
      error: const Color(0xFFEB4333),
      onError: Colors.white,
    );

    return _buildTheme(
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      config: c,
      scaffoldBg: c.backgroundColor,
      cardBg: DesignTokens.darkBackgroundCard,
      menuBg: DesignTokens.darkBackgroundMenu,
      primaryText: DesignTokens.darkPrimaryText,
      secondaryText: DesignTokens.darkSecondaryText,
      divider: const Color(0x1FFFFFFF),
    );
  }

  /// E-Ink 主题
  static ThemeData eInk() {
    final c = ThemeConfig.defaultEInk();
    final colorScheme = ColorScheme.light(
      primary: Colors.black,
      onPrimary: Colors.white,
      secondary: Colors.black,
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: Colors.black,
      surfaceContainerHighest: const Color(0xFFEEEEEE),
      error: Colors.black,
      onError: Colors.white,
    );

    return _buildTheme(
      brightness: Brightness.light,
      colorScheme: colorScheme,
      config: c,
      scaffoldBg: Colors.white,
      cardBg: Colors.white,
      menuBg: const Color(0xFFEEEEEE),
      primaryText: Colors.black,
      secondaryText: const Color(0x8A000000),
      divider: const Color(0x1F000000),
    );
  }

  static ThemeData _buildTheme({
    required Brightness brightness,
    required ColorScheme colorScheme,
    required ThemeConfig config,
    required Color scaffoldBg,
    required Color cardBg,
    required Color menuBg,
    required Color primaryText,
    required Color secondaryText,
    required Color divider,
  }) {
    final panelRadius = UiCorner.panelRadius(config);
    final actionRadius = UiCorner.actionRadius(config);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldBg,
      canvasColor: scaffoldBg,
      cardColor: cardBg,

      // 文字主题 (UiTypography.kt)
      textTheme: TextTheme(
        displayLarge: TextStyle(
            fontSize: DesignTokens.fontLargeTitle,
            color: primaryText,
            fontWeight: FontWeight.bold),
        displayMedium: TextStyle(
            fontSize: DesignTokens.fontTitle,
            color: primaryText,
            fontWeight: FontWeight.bold),
        displaySmall: TextStyle(
            fontSize: DesignTokens.fontSubtitle,
            color: primaryText,
            fontWeight: FontWeight.w600),
        headlineLarge: TextStyle(
            fontSize: DesignTokens.fontTitle, color: primaryText),
        headlineMedium: TextStyle(
            fontSize: DesignTokens.fontSubtitle, color: primaryText),
        headlineSmall: TextStyle(
            fontSize: DesignTokens.fontBody, color: primaryText),
        bodyLarge: TextStyle(
            fontSize: DesignTokens.fontBody, color: primaryText),
        bodyMedium: TextStyle(
            fontSize: DesignTokens.fontBody, color: primaryText),
        bodySmall: TextStyle(
            fontSize: DesignTokens.fontSummary, color: secondaryText),
        labelLarge: TextStyle(
            fontSize: DesignTokens.fontBody,
            color: primaryText,
            fontWeight: FontWeight.w500),
        labelMedium: TextStyle(
            fontSize: DesignTokens.fontCaption, color: secondaryText),
        labelSmall: TextStyle(
            fontSize: 10.0, color: secondaryText),
      ),

      // AppBar 主题 (TitleBar.kt)
      appBarTheme: AppBarTheme(
        backgroundColor: config.transparentNavBar
            ? Colors.transparent
            : colorScheme.primary,
        foregroundColor: config.transparentNavBar
            ? primaryText
            : _onColorFor(colorScheme.primary),
        elevation: config.transparentNavBar ? 0 : DesignTokens.toolbarElevation,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 0,
        toolbarHeight: DesignTokens.topBarHeight,
      ),

      // 卡片主题
      cardTheme: CardThemeData(
        color: cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
        ),
        margin: EdgeInsets.zero,
      ),

      // 对话框主题
      dialogTheme: DialogThemeData(
        backgroundColor: cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
        ),
        titleTextStyle: TextStyle(
          fontSize: DesignTokens.fontTitle,
          fontWeight: FontWeight.bold,
          color: primaryText,
        ),
        contentTextStyle: TextStyle(
          fontSize: DesignTokens.fontBody,
          color: primaryText,
        ),
      ),

      // 底部弹窗主题
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(panelRadius),
          ),
        ),
      ),

      // 按钮主题
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: _onColorFor(colorScheme.primary),
          elevation: 0,
          padding: const EdgeInsets.symmetric(
            horizontal: DesignTokens.spacingLg,
            vertical: DesignTokens.spacingSm,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(actionRadius),
          ),
          textStyle: TextStyle(fontSize: DesignTokens.fontBody),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(actionRadius),
          ),
          textStyle: TextStyle(fontSize: DesignTokens.fontBody),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: divider, width: DesignTokens.borderWidth),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(actionRadius),
          ),
          textStyle: TextStyle(fontSize: DesignTokens.fontBody),
        ),
      ),

      // 输入框主题 (UiTypography.kt: applyUiInputStyle)
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: menuBg,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: DesignTokens.spacingMd,
          vertical: DesignTokens.spacingSm,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(panelRadius),
          borderSide: BorderSide(color: divider, width: DesignTokens.borderWidth),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(panelRadius),
          borderSide: BorderSide(color: divider, width: DesignTokens.borderWidth),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(panelRadius),
          borderSide: BorderSide(
              color: colorScheme.primary, width: DesignTokens.borderWidth),
        ),
        labelStyle: TextStyle(
            fontSize: DesignTokens.fontBody, color: secondaryText),
        hintStyle: TextStyle(
            fontSize: DesignTokens.fontBody, color: secondaryText),
      ),

      // 分隔线主题
      dividerTheme: DividerThemeData(
        color: divider,
        thickness: DesignTokens.dividerHeight,
        space: 0,
      ),

      // 列表项主题
      listTileTheme: ListTileThemeData(
        textColor: primaryText,
        iconColor: primaryText,
        minLeadingWidth: DesignTokens.listItemIconSize,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: DesignTokens.spacingLg,
          vertical: 0,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(actionRadius),
        ),
      ),

      // 芯片主题
      chipTheme: ChipThemeData(
        backgroundColor: menuBg,
        selectedColor: colorScheme.primary.withValues(alpha: 0.15),
        labelStyle: TextStyle(
            fontSize: DesignTokens.fontCaption, color: primaryText),
        secondaryLabelStyle: TextStyle(
            fontSize: DesignTokens.fontCaption, color: primaryText),
        side: BorderSide(color: divider, width: DesignTokens.borderWidth),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(actionRadius),
        ),
      ),

      // 导航栏主题 (dimens.xml: main_bottom_*)
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cardBg,
        elevation: 0,
        height: DesignTokens.bottomStandardHeight,
        indicatorColor: colorScheme.primary.withValues(alpha: 0.15),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
              DesignTokens.bottomIndicatorCornerRadius),
        ),
        labelTextStyle: WidgetStateProperty.all(
          TextStyle(fontSize: DesignTokens.fontCaption),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(
                size: DesignTokens.bottomStandardIconSize,
                color: colorScheme.primary);
          }
          return IconThemeData(
              size: DesignTokens.bottomNavIconSize, color: secondaryText);
        }),
      ),

      // 浮动按钮主题
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: _onColorFor(colorScheme.primary),
        elevation: DesignTokens.toolbarElevation,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
              DesignTokens.capsuleRadius(DesignTokens.searchButtonSize)),
        ),
      ),

      // 滑块主题
      sliderTheme: SliderThemeData(
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: divider,
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: 0.12),
        trackHeight: 2.0,
      ),

      // 进度指示器主题
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: divider,
      ),

      // 菜单主题
      popupMenuTheme: PopupMenuThemeData(
        color: cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
        ),
        textStyle: TextStyle(
            fontSize: DesignTokens.fontBody, color: primaryText),
      ),

      // SnackBar 主题
      snackBarTheme: SnackBarThemeData(
        backgroundColor: menuBg,
        contentTextStyle: TextStyle(
            fontSize: DesignTokens.fontBody, color: primaryText),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(actionRadius),
        ),
        behavior: SnackBarBehavior.floating,
      ),

      // TabBar 主题
      tabBarTheme: TabBarThemeData(
        labelColor: colorScheme.primary,
        unselectedLabelColor: secondaryText,
        labelStyle: TextStyle(
            fontSize: DesignTokens.fontBody, fontWeight: FontWeight.w600),
        unselectedLabelStyle: TextStyle(fontSize: DesignTokens.fontBody),
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
      ),

      // 开关主题
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return _onColorFor(colorScheme.primary);
          }
          return brightness == Brightness.dark
              ? const Color(0xFFBDBDBD)
              : const Color(0xFFFAFAFA);
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return brightness == Brightness.dark
              ? const Color(0x4DFFFFFF)
              : const Color(0x43000000);
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),

      // 复选框主题
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(
            _onColorFor(colorScheme.primary)),
        side: BorderSide(color: secondaryText, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(actionRadius * 0.4),
        ),
      ),

      // 单选按钮主题
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return secondaryText;
        }),
      ),

      // 水波纹颜色
      splashColor: colorScheme.primary.withValues(alpha: 0.08),
      highlightColor: colorScheme.primary.withValues(alpha: 0.04),
    );
  }

  /// 根据背景色亮度计算前景色（黑或白）
  static Color _onColorFor(Color backgroundColor) {
    return backgroundColor.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
  }
}
