import 'package:flutter/material.dart';
import '../utils/design_tokens.dart';

/// 主题模式枚举
///
/// 移植自 Legado-Rimchars: constant/Theme.kt
enum AppThemeMode {
  dark,
  light,
  auto,
  eInk,
}

/// 主题配置数据类
///
/// 完整移植自 Legado-Rimchars: help/config/ThemeConfig.kt -> Config
/// 包含主题颜色、背景图、面板边框、圆角缩放等全部可配置项。
class ThemeConfig {
  final String themeName;
  final bool isNightTheme;
  final Color primaryColor;
  final Color accentColor;
  final Color backgroundColor;
  final Color bottomBackground;
  final bool transparentNavBar;

  /// 背景图路径
  final String? backgroundImgPath;
  final int backgroundImgBlur;

  /// 书籍详情页背景图
  final String? bookInfoBackgroundImgPath;

  /// 面板背景图
  final String? panelBackgroundImgPath;

  /// 面板背景图缩放模式: crop / fit
  final String panelBackgroundScaleType;

  /// 面板边框颜色
  final Color? panelBorderColor;
  final int panelBorderAlpha;

  /// UI 圆角缩放系数 (0.0 ~ 3.0)
  final double uiCornerScale;

  /// UI 布局透明度 (0 ~ 100)
  final int uiLayoutAlpha;

  /// 搜索框圆角是否跟随缩放
  final bool uiCornerSearchFollow;

  /// 回复框圆角是否跟随缩放
  final bool uiCornerReplyFollow;

  /// 字号缩放 (0 ~ 16)
  final int fontScale;

  /// UI 字体路径
  final String? uiFontPath;

  /// 标题字体路径
  final String? titleFontPath;

  const ThemeConfig({
    required this.themeName,
    required this.isNightTheme,
    required this.primaryColor,
    required this.accentColor,
    required this.backgroundColor,
    required this.bottomBackground,
    this.transparentNavBar = true,
    this.backgroundImgPath,
    this.backgroundImgBlur = 0,
    this.bookInfoBackgroundImgPath,
    this.panelBackgroundImgPath,
    this.panelBackgroundScaleType = 'crop',
    this.panelBorderColor,
    this.panelBorderAlpha = 100,
    this.uiCornerScale = 1.0,
    this.uiLayoutAlpha = 100,
    this.uiCornerSearchFollow = true,
    this.uiCornerReplyFollow = true,
    this.fontScale = 0,
    this.uiFontPath,
    this.titleFontPath,
  });

  /// 亮色默认主题
  factory ThemeConfig.defaultLight() {
    return const ThemeConfig(
      themeName: '默认亮色',
      isNightTheme: false,
      primaryColor: DesignTokens.lightPrimary,
      accentColor: DesignTokens.lightAccent,
      backgroundColor: DesignTokens.lightBackground,
      bottomBackground: Color(0xFFEEEEEE),
    );
  }

  /// 暗色默认主题
  factory ThemeConfig.defaultDark() {
    return const ThemeConfig(
      themeName: '默认暗色',
      isNightTheme: true,
      primaryColor: DesignTokens.darkPrimary,
      accentColor: DesignTokens.darkAccent,
      backgroundColor: DesignTokens.darkBackground,
      bottomBackground: Color(0xFF1A1A1A),
    );
  }

  /// EInk 默认主题
  factory ThemeConfig.defaultEInk() {
    return const ThemeConfig(
      themeName: 'E-Ink',
      isNightTheme: false,
      primaryColor: Colors.white,
      accentColor: Colors.black,
      backgroundColor: Colors.white,
      bottomBackground: Colors.white,
    );
  }

  /// 品牌蓝主题
  factory ThemeConfig.brandBlue() {
    return const ThemeConfig(
      themeName: '品牌蓝',
      isNightTheme: false,
      primaryColor: DesignTokens.brandPrimary,
      accentColor: DesignTokens.brandAccent,
      backgroundColor: DesignTokens.lightBackground,
      bottomBackground: Color(0xFFEEEEEE),
    );
  }

  /// 从 JSON 创建
  factory ThemeConfig.fromJson(Map<String, dynamic> json) {
    return ThemeConfig(
      themeName: json['themeName'] as String? ?? '未命名',
      isNightTheme: json['isNightTheme'] as bool? ?? false,
      primaryColor: _parseColor(json['primaryColor'] as String?),
      accentColor: _parseColor(json['accentColor'] as String?),
      backgroundColor: _parseColor(json['backgroundColor'] as String?),
      bottomBackground: _parseColor(json['bottomBackground'] as String?),
      transparentNavBar: json['transparentNavBar'] as bool? ?? true,
      backgroundImgPath: json['backgroundImgPath'] as String?,
      backgroundImgBlur: json['backgroundImgBlur'] as int? ?? 0,
      bookInfoBackgroundImgPath: json['bookInfoBackgroundImgPath'] as String?,
      panelBackgroundImgPath: json['panelBackgroundImgPath'] as String?,
      panelBackgroundScaleType:
          json['panelBackgroundScaleType'] as String? ?? 'crop',
      panelBorderColor: _parseColor(json['panelBorderColor'] as String?),
      panelBorderAlpha: json['panelBorderAlpha'] as int? ?? 100,
      uiCornerScale: (json['uiCornerScale'] as num?)?.toDouble() ?? 1.0,
      uiLayoutAlpha: json['uiLayoutAlpha'] as int? ?? 100,
      uiCornerSearchFollow: json['uiCornerSearchFollow'] as bool? ?? true,
      uiCornerReplyFollow: json['uiCornerReplyFollow'] as bool? ?? true,
      fontScale: json['fontScale'] as int? ?? 0,
      uiFontPath: json['uiFontPath'] as String?,
      titleFontPath: json['titleFontPath'] as String?,
    );
  }

  /// 转为 JSON
  Map<String, dynamic> toJson() => {
        'themeName': themeName,
        'isNightTheme': isNightTheme,
        'primaryColor': _colorToHex(primaryColor),
        'accentColor': _colorToHex(accentColor),
        'backgroundColor': _colorToHex(backgroundColor),
        'bottomBackground': _colorToHex(bottomBackground),
        'transparentNavBar': transparentNavBar,
        'backgroundImgPath': backgroundImgPath,
        'backgroundImgBlur': backgroundImgBlur,
        'bookInfoBackgroundImgPath': bookInfoBackgroundImgPath,
        'panelBackgroundImgPath': panelBackgroundImgPath,
        'panelBackgroundScaleType': panelBackgroundScaleType,
        'panelBorderColor': panelBorderColor != null
            ? _colorToHex(panelBorderColor!)
            : null,
        'panelBorderAlpha': panelBorderAlpha,
        'uiCornerScale': uiCornerScale,
        'uiLayoutAlpha': uiLayoutAlpha,
        'uiCornerSearchFollow': uiCornerSearchFollow,
        'uiCornerReplyFollow': uiCornerReplyFollow,
        'fontScale': fontScale,
        'uiFontPath': uiFontPath,
        'titleFontPath': titleFontPath,
      };

  ThemeConfig copyWith({
    String? themeName,
    bool? isNightTheme,
    Color? primaryColor,
    Color? accentColor,
    Color? backgroundColor,
    Color? bottomBackground,
    bool? transparentNavBar,
    String? backgroundImgPath,
    int? backgroundImgBlur,
    String? bookInfoBackgroundImgPath,
    String? panelBackgroundImgPath,
    String? panelBackgroundScaleType,
    Color? panelBorderColor,
    int? panelBorderAlpha,
    double? uiCornerScale,
    int? uiLayoutAlpha,
    bool? uiCornerSearchFollow,
    bool? uiCornerReplyFollow,
    int? fontScale,
    String? uiFontPath,
    String? titleFontPath,
  }) {
    return ThemeConfig(
      themeName: themeName ?? this.themeName,
      isNightTheme: isNightTheme ?? this.isNightTheme,
      primaryColor: primaryColor ?? this.primaryColor,
      accentColor: accentColor ?? this.accentColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      bottomBackground: bottomBackground ?? this.bottomBackground,
      transparentNavBar: transparentNavBar ?? this.transparentNavBar,
      backgroundImgPath: backgroundImgPath ?? this.backgroundImgPath,
      backgroundImgBlur: backgroundImgBlur ?? this.backgroundImgBlur,
      bookInfoBackgroundImgPath:
          bookInfoBackgroundImgPath ?? this.bookInfoBackgroundImgPath,
      panelBackgroundImgPath:
          panelBackgroundImgPath ?? this.panelBackgroundImgPath,
      panelBackgroundScaleType:
          panelBackgroundScaleType ?? this.panelBackgroundScaleType,
      panelBorderColor: panelBorderColor ?? this.panelBorderColor,
      panelBorderAlpha: panelBorderAlpha ?? this.panelBorderAlpha,
      uiCornerScale: uiCornerScale ?? this.uiCornerScale,
      uiLayoutAlpha: uiLayoutAlpha ?? this.uiLayoutAlpha,
      uiCornerSearchFollow:
          uiCornerSearchFollow ?? this.uiCornerSearchFollow,
      uiCornerReplyFollow: uiCornerReplyFollow ?? this.uiCornerReplyFollow,
      fontScale: fontScale ?? this.fontScale,
      uiFontPath: uiFontPath ?? this.uiFontPath,
      titleFontPath: titleFontPath ?? this.titleFontPath,
    );
  }

  static Color _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return Colors.grey;
    final clean = hex.replaceAll('#', '');
    if (clean.length == 6) {
      return Color(int.parse('FF$clean', radix: 16));
    } else if (clean.length == 8) {
      return Color(int.parse(clean, radix: 16));
    }
    return Colors.grey;
  }

  static String _colorToHex(Color color) {
    return '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }
}
