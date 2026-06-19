import 'package:flutter/material.dart';

/// UI 设计令牌系统
///
/// 参考 Legado-Rimchars 设计规范，统一全项目的圆角、间距、字号、边框等视觉参数。
/// 所有 UI 组件应优先使用此处的常量，避免硬编码数值。
///
/// 设计规律：
/// - 圆角：面板/卡片 10dp，按钮/标签 9dp，搜索框 18dp，胶囊=高度/2
/// - 间距：遵循 8dp 网格（4/8/12/16/20/24/32）
/// - 字号：正文 14sp，中标题 16sp，大标题 18sp，超大标题 21sp，标签 12sp
/// - 描边：统一 1dp，颜色用 divider（12% 黑）
class DesignTokens {
  DesignTokens._();

  // ===== 圆角令牌 =====

  /// 面板/卡片/弹出层圆角
  static const double panelRadius = 10.0;

  /// 按钮/标签/图标按钮圆角
  static const double actionRadius = 9.0;

  /// 搜索框圆角
  static const double searchRadius = 18.0;

  /// 毛玻璃卡片圆角
  static const double frostCardRadius = 20.0;

  /// 胶囊圆角（= 高度的一半）
  static double capsuleRadius(double height) => height / 2;

  // ===== 间距令牌（8dp 网格）=====

  /// 超小间距
  static const double spacingXs = 4.0;

  /// 小间距
  static const double spacingSm = 8.0;

  /// 中间距
  static const double spacingMd = 12.0;

  /// 大间距（标准水平内边距）
  static const double spacingLg = 16.0;

  /// 超大间距
  static const double spacingXl = 20.0;

  /// 双倍大间距
  static const double spacingXxl = 24.0;

  /// 三倍大间距
  static const double spacingXxxl = 32.0;

  // ===== 字号令牌 =====

  /// 标签/徽章字号
  static const double fontCaption = 12.0;

  /// 摘要/辅助说明字号
  static const double fontSummary = 13.0;

  /// 正文字号
  static const double fontBody = 14.0;

  /// 中标题字号（列表项标题）
  static const double fontSubtitle = 16.0;

  /// 大标题字号
  static const double fontTitle = 18.0;

  /// 超大标题字号（书名、页面标题）
  static const double fontLargeTitle = 21.0;

  // ===== 边框令牌 =====

  /// 统一描边宽度
  static const double borderWidth = 1.0;

  /// 分隔线高度
  static const double dividerHeight = 0.5;

  // ===== 组件尺寸令牌 =====

  /// 顶栏高度
  static const double topBarHeight = 48.0;

  /// 底栏高度
  static const double bottomBarHeight = 48.0;

  /// 列表项最小高度
  static const double listItemMinHeight = 60.0;

  /// 列表项图标尺寸
  static const double listItemIconSize = 24.0;

  /// 搜索框高度
  static const double searchBarHeight = 42.0;

  /// 标签高度
  static const double tagHeight = 28.0;

  /// 空状态图标尺寸
  static const double emptyIconSize = 80.0;

  /// 弹窗内边距
  static const EdgeInsets dialogTitlePadding =
      EdgeInsets.fromLTRB(24, 24, 24, 20);
  static const EdgeInsets dialogContentPadding =
      EdgeInsets.fromLTRB(24, 0, 24, 24);
  static const EdgeInsets dialogInsetPadding =
      EdgeInsets.symmetric(horizontal: 40, vertical: 24);

  // ===== 颜色辅助 =====

  /// 分隔线颜色（12% 黑）
  static Color dividerColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? const Color(0x1FFFFFFF)
        : const Color(0x1F000000);
  }

  /// 毛玻璃面板颜色
  static Color frostColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? const Color(0xDD1E1E1E)
        : const Color(0xDDF1F2F6);
  }

  /// 按钮按压态颜色（10% 主色）
  static Color pressColor(BuildContext context) {
    return Theme.of(context).colorScheme.primary.withValues(alpha: 0.1);
  }

  /// 列表项高亮颜色
  static Color highlightColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? const Color(0x634D4D4D)
        : const Color(0x63ACACAC);
  }
}
