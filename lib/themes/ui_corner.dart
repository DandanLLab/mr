import 'package:flutter/material.dart';
import '../utils/design_tokens.dart';
import 'theme_config.dart';

/// 圆角缩放系统
///
/// 完整移植自 Legado-Rimchars: lib/theme/UiCorner.kt
/// 支持全局圆角缩放、布局透明度、面板表面色计算。
class UiCorner {
  UiCorner._();

  /// 获取当前主题配置的圆角缩放系数 (0.0 ~ 3.0)
  static double scale(ThemeConfig config) {
    return config.uiCornerScale.clamp(0.0, 3.0);
  }

  /// 面板圆角 (ui_panel_radius * scale)
  static double panelRadius(ThemeConfig config) {
    return DesignTokens.panelRadius * scale(config);
  }

  /// 按钮圆角 (ui_action_radius * scale)
  static double actionRadius(ThemeConfig config) {
    return DesignTokens.actionRadius * scale(config);
  }

  /// 缩放后的 dp 值
  static double scaledDp(ThemeConfig config, double value) {
    return value * scale(config);
  }

  /// 搜索框圆角（可选跟随缩放）
  static double searchRadius(ThemeConfig config, double value) {
    if (config.uiCornerSearchFollow) {
      return scaledDp(config, value);
    }
    return value;
  }

  /// 回复框圆角（可选跟随缩放）
  static double replyRadius(ThemeConfig config, double value) {
    if (config.uiCornerReplyFollow) {
      return scaledDp(config, value);
    }
    return value;
  }

  /// 布局透明度 (0.0 ~ 1.0)
  static double layoutAlpha(ThemeConfig config) {
    return config.uiLayoutAlpha.clamp(0, 100) / 100.0;
  }

  /// 计算面板表面色（带透明度）
  static Color surfaceColor(ThemeConfig config, Color color,
      {bool pressed = false}) {
    final alpha = (layoutAlpha(config) + (pressed ? 0.08 : 0.0)).clamp(0.0, 1.0);
    return color.withValues(alpha: alpha);
  }

  /// 计算描边色（根据亮度自动选择黑/白）
  static Color effectStrokeColor(Color color) {
    final luminance = color.computeLuminance();
    final base = luminance > 0.5 ? Colors.black : Colors.white;
    return base.withValues(alpha: 0.10);
  }

  /// 面板边框颜色（应用透明度）
  static Color? panelBorderColor(ThemeConfig config) {
    if (config.panelBorderColor == null) return null;
    final alpha = config.panelBorderAlpha.clamp(0, 100) * 255 ~/ 100;
    return config.panelBorderColor!.withValues(alpha: alpha / 255.0);
  }

  /// 面板圆角 BorderRadius
  static BorderRadius panelBorderRadius(ThemeConfig config) {
    return BorderRadius.circular(panelRadius(config));
  }

  /// 按钮圆角 BorderRadius
  static BorderRadius actionBorderRadius(ThemeConfig config) {
    return BorderRadius.circular(actionRadius(config));
  }

  /// 搜索框圆角 BorderRadius
  static BorderRadius searchBorderRadius(ThemeConfig config) {
    return BorderRadius.circular(searchRadius(config, DesignTokens.searchRadius));
  }
}
