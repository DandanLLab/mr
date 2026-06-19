import 'package:flutter/material.dart';

/// UI 设计令牌系统
///
/// 完整移植自 Legado-Rimchars 的 dimens.xml / colors.xml / styles.xml。
/// 所有 UI 组件应优先使用此处的常量，避免硬编码数值。
///
/// 设计规律：
/// - 圆角：面板/卡片 10dp，按钮/标签 9dp，搜索框 18dp，胶囊=高度/2
/// - 间距：遵循 8dp 网格（4/8/12/16/20/24/32）
/// - 字号：正文 14sp，中标题 16sp，大标题 18sp，超大标题 21sp，标签 12sp
/// - 描边：统一 1dp，颜色用 divider（12% 黑）
class DesignTokens {
  DesignTokens._();

  // ===== 圆角令牌 (dimens.xml: ui_panel_radius, ui_action_radius) =====

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

  static const double spacingXs = 4.0;
  static const double spacingSm = 8.0;
  static const double spacingMd = 12.0;
  static const double spacingLg = 16.0;
  static const double spacingXl = 20.0;
  static const double spacingXxl = 24.0;
  static const double spacingXxxl = 32.0;

  // ===== 字号令牌 (dimens.xml: font_size_*) =====

  /// 标签/徽章字号
  static const double fontCaption = 12.0;

  /// 摘要/辅助说明字号 (manga_control_button_text_size)
  static const double fontSummary = 13.0;

  /// 正文字号 (font_size_normal)
  static const double fontBody = 14.0;

  /// 中标题字号 (font_size_middle)
  static const double fontSubtitle = 16.0;

  /// 大标题字号 (font_size_large)
  static const double fontTitle = 18.0;

  /// 超大标题字号（书名、页面标题）
  static const double fontLargeTitle = 21.0;

  // ===== 边框令牌 =====

  static const double borderWidth = 1.0;
  static const double dividerHeight = 0.5;

  // ===== 底部导航栏令牌 (dimens.xml: main_bottom_*) =====

  /// 底部浮动栏高度
  static const double bottomBarHeight = 48.0;

  /// 底部浮动栏圆角
  static const double bottomBarCornerRadius = 24.0;

  /// 底部栏间距
  static const double bottomBarGap = 10.0;

  /// 底部导航图标尺寸
  static const double bottomNavIconSize = 23.0;

  /// 底部标准高度（含指示器）
  static const double bottomStandardHeight = 66.0;

  /// 底部标准图标尺寸
  static const double bottomStandardIconSize = 24.0;

  /// 底部指示器宽度
  static const double bottomIndicatorWidth = 52.0;

  /// 底部指示器高度
  static const double bottomIndicatorHeight = 40.0;

  /// 底部指示器圆角
  static const double bottomIndicatorCornerRadius = 20.0;

  /// 底部导航水平内边距
  static const double bottomNavHorizontalPadding = 6.0;

  // ===== 书架标签栏令牌 (dimens.xml: bookshelf_tag_*) =====

  /// 标签栏高度
  static const double tagBarHeight = 38.0;

  /// 标签项高度
  static const double tagHeight = 28.0;

  /// 标签项最小宽度
  static const double tagItemMinWidth = 36.0;

  /// 标签项最大宽度
  static const double tagItemMaxWidth = 96.0;

  /// 标签项水平内边距
  static const double tagItemPaddingHorizontal = 12.0;

  /// 书架操作按钮尺寸
  static const double bookshelfActionButtonSize = 34.0;

  /// 书架标题选择高度
  static const double bookshelfTitleSelectHeight = 42.0;

  /// 书架标题箭头尺寸
  static const double bookshelfTitleArrowSize = 18.0;

  // ===== 侧边栏令牌 (dimens.xml: main_sidebar_*) =====

  /// 侧边栏行高
  static const double listItemMinHeight = 60.0;

  /// 侧边栏搜索框高度
  static const double searchBarHeight = 42.0;

  /// 侧边栏项图标尺寸
  static const double sidebarItemIconSize = 44.0;

  /// 侧边栏项图标内边距
  static const double sidebarItemIconPadding = 11.0;

  /// 侧边栏项文字间距
  static const double sidebarItemTextMarginStart = 14.0;

  // ===== 搜索/AI 悬浮球令牌 =====

  /// 搜索按钮尺寸
  static const double searchButtonSize = 48.0;

  /// AI 悬浮球尺寸
  static const double aiFloatingBallSize = 52.0;

  /// AI 悬浮球安全边距
  static const double aiFloatingBallSafeMargin = 24.0;

  // ===== 瀑布流卡片令牌 =====

  /// 瀑布流卡片间距
  static const double waterfallCardGap = 8.0;

  /// 瀑布流卡片最小宽度
  static const double waterfallCardMinWidth = 82.0;

  /// 瀑布流封面最小高度
  static const double waterfallCoverMinHeight = 108.0;

  // ===== 漫画阅读器控制栏令牌 =====

  /// 漫画控制栏高度
  static const double mangaControlBarHeight = 48.0;

  /// 漫画控制栏圆角
  static const double mangaControlBarRadius = 24.0;

  /// 漫画控制按钮最小宽度
  static const double mangaControlButtonMinWidth = 72.0;

  // ===== 通用组件尺寸 =====

  /// 顶栏高度
  static const double topBarHeight = 48.0;

  /// 列表项图标尺寸
  static const double listItemIconSize = 24.0;

  /// 空状态图标尺寸
  static const double emptyIconSize = 80.0;

  /// 阴影高度
  static const double shadowHeight = 10.0;

  /// 工具栏高度
  static const double toolbarElevation = 4.0;

  /// 快速滚动条宽度
  static const double fastScrollHandleWidth = 8.0;

  // ===== 弹窗内边距 =====

  static const EdgeInsets dialogTitlePadding =
      EdgeInsets.fromLTRB(24, 24, 24, 20);
  static const EdgeInsets dialogContentPadding =
      EdgeInsets.fromLTRB(24, 0, 24, 24);
  static const EdgeInsets dialogInsetPadding =
      EdgeInsets.symmetric(horizontal: 40, vertical: 24);

  // ===== 颜色辅助 (colors.xml) =====

  /// 分隔线颜色（12% 黑）
  static Color dividerColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? const Color(0x1FFFFFFF)
        : const Color(0x1F000000);
  }

  /// 毛玻璃面板颜色 (book_info_frost)
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

  // ===== 玻璃拟态颜色 (colors.xml: glass_*) =====

  /// 玻璃顶栏颜色
  static const Color glassBar = Color(0xA8D9E6F7);

  /// 玻璃顶栏阴影
  static const Color glassBarShadow = Color(0x260A1D35);

  /// 玻璃顶栏高亮
  static const Color glassBarHighlight = Color(0x52FFFFFF);

  /// 玻璃按钮颜色
  static const Color glassButton = Color(0xB5E5EFFB);

  /// 玻璃按钮按压态
  static const Color glassButtonPressed = Color(0xD05C9DFF);

  /// 玻璃覆盖层
  static const Color glassOverlay = Color(0x22FFFFFF);

  /// 玻璃描边
  static const Color glassStroke = Color(0x668FA8C8);

  // ===== 背景色系 (colors.xml) =====

  /// 亮色背景
  static const Color lightBackground = Color(0xFFF7F7FA);

  /// 亮色卡片背景
  static const Color lightBackgroundCard = Color(0xFFFFFFFF);

  /// 亮色菜单背景
  static const Color lightBackgroundMenu = Color(0xFFF1F2F6);

  /// 暗色背景
  static const Color darkBackground = Color(0xFF212121);

  /// 暗色卡片背景
  static const Color darkBackgroundCard = Color(0xFF2C2C2C);

  /// 暗色菜单背景
  static const Color darkBackgroundMenu = Color(0xFF1E1E1E);

  // ===== 文字颜色 (colors.xml) =====

  /// 主文字颜色 (87% 黑)
  static const Color lightPrimaryText = Color(0xDE000000);

  /// 次要文字颜色 (54% 黑)
  static const Color lightSecondaryText = Color(0x8A000000);

  /// 暗色主文字颜色
  static const Color darkPrimaryText = Color(0xFFFFFFFF);

  /// 暗色次要文字颜色 (70% 白)
  static const Color darkSecondaryText = Color(0xB3FFFFFF);

  /// 菜单默认颜色
  static const Color menuColorDefault = Color(0xFF383838);

  /// 高亮颜色 (highlight)
  static const Color highlightRed = Color(0xFFD3321B);

  // ===== 主题色 (colors.xml: primary, primaryDark, accent) =====

  /// 亮色主色 (md_brown_500)
  static const Color lightPrimary = Color(0xFF795548);

  /// 亮色强调色 (md_red_600)
  static const Color lightAccent = Color(0xFFD32F2F);

  /// 暗色主色 (md_blue_grey_600)
  static const Color darkPrimary = Color(0xFF546E7A);

  /// 暗色强调色 (md_deep_orange_800)
  static const Color darkAccent = Color(0xFFD84315);

  /// 品牌主色 (primary)
  static const Color brandPrimary = Color(0xFF3482FF);

  /// 品牌主色暗 (primaryDark)
  static const Color brandPrimaryDark = Color(0xFF1F6FE5);

  /// 品牌强调色 (accent)
  static const Color brandAccent = Color(0xFF0A84FF);
}
