import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/local_book/epub_parser.dart';

/// EPUB 多看画廊页面渲染器（Flutter 原生实现）
///
/// ★ 基于多看阅读器反汇编全面移植 ★
///
/// 多看画廊渲染分两层（反汇编证据见 .tmp/gallery_full_disasm_report.md）：
/// 1. native 层（libddlayoutkit.so）：CBookRender::RenderGallery 把原作竖向
///    gallery.xhtml 转成 HTML snippet（slider/slide_group/slide/msg 结构）
/// 2. UI 层（dex）：DocImagesView 横向滑动翻页；点击图片进入
///    DocImageWatchingView（ZoomView + MultiTouchImageView）全屏预览
///
/// 我们的移植方案（Flutter 原生，避开 WebView CSS 兼容性问题）：
/// - 非全屏画廊：PageView 横向滑动翻页（对应多看 slider/slide/msg）
/// - 全屏预览：PageView + InteractiveViewer（对应 ZoomView + MultiTouchImageView）
/// - 原作视觉样式：从 rawCss 解析关键字段，用 Flutter 手动应用
class EpubGalleryPage extends StatefulWidget {
  final List<EpubGalleryImage> images;
  final String chapterTitle;
  final Color backgroundColor;
  final Color textColor;

  /// 画廊章节级样式（含 rawCss 原始 CSS 全文、背景图、gallery-title 等）
  final EpubGalleryChapterStyle? chapterStyle;

  /// 是否从章节末尾进入（用于从下一章往前翻到本章最后一张）
  final bool initialPageToEnd;

  /// 滑到第一张继续往前时触发（由 NovelReaderPage 切换到上一章）
  final VoidCallback onPreviousChapter;

  /// 滑到最后一张继续往后时触发（由 NovelReaderPage 切换到下一章）
  final VoidCallback onNextChapter;

  const EpubGalleryPage({
    super.key,
    required this.images,
    required this.chapterTitle,
    required this.backgroundColor,
    required this.textColor,
    this.chapterStyle,
    this.initialPageToEnd = false,
    required this.onPreviousChapter,
    required this.onNextChapter,
  });

  @override
  State<EpubGalleryPage> createState() => _EpubGalleryPageState();
}

/// dotted 指示器高度（圆点 6px + 上下 padding 各 8px = 22px）
///
/// 对齐多看 .dotted 的 absolute 定位（gallery_full_disasm_report.md 5.1）：
/// 多看 .dotted 用 position:absolute 悬浮在 .slider 底部，高度由设备 theme 注入。
/// Flutter 移植固定为 22px，PageView 底部留此高度避免 cell 内容被 dotted 遮挡。
const _kDottedHeight = 22.0;

/// ★ 多看画廊基准字号（实测锚定）★
///
/// 多看 DkeGallery 原生布局不随阅读器字号设置缩放，以固定基准渲染：
/// - 标题页 h3 字形实测 63 physical = 31.5 logical = 1.5em × 21
/// - gallery-txt 字形实测 29 physical = 14.5 logical = 0.7em × 21
/// - maintitle 字形实测 36 physical = 18.9 logical = 0.9em × 21
/// 故基准字号 = 21 logical（dk_g1/dk_prev/dk5 像素测量）。
const _kGalleryBaseFontSize = 21.0;

/// 多看 DocImagesView 顶部起始偏移（实测对齐）
///
/// 多看 DocImagesView 矩形绝对顶 = 59 logical（= 多看内容区顶 60 ≈
/// 状态栏 30 physical + 固定留白），图像在 (59, 592) 高 533 的区域内
/// 垂直居中（图像顶 244 = 59 + (533-163)/2，00.jpg/01.jpg 恒定）。
/// MR 侧 SafeArea 顶 = 24 logical，故相对 cell 顶 = 35。
///
/// gallery-txt「滑动切换，点击放大」文本顶实测 y=154 physical
/// （77 logical）= DocImagesView 顶 59 + 18（多看把 CSS margin 1em
/// 按 18 logical 折算，非按基准 21——实测字形 14.5 是 0.7em×21 但
/// 1em margin 落点为 18，像素级锚定不深究内部折算）。
const _kGalleryTxtExtraTop = 35.0;
const _kGalleryTxtMarginTop = 18.0;

/// 多看标题页 h3「画廊图」字形顶实测 y=263 physical（131.5 logical）。
///
/// 多看把 gallery.xhtml 的 h3 独立分页（dk_g1 实测：页面上仅 h3 居中，
/// 下方全空），DocImagesView slider 页不显示标题。
/// MR 侧：SafeArea 24 + h3 的 2em CSS margin（2×21=42）+ 固定留白
/// 65.5 logical = 131.5 ✓（字形顶精确命中，字形高 31.5）。
const _kTitlePageExtraTop = 65.5;

/// 多看 DkeGallery 图像页排版（逻辑 px，基准 21，稳定态实测锚定）。
///
/// ★ 稳定态实测（dk_launch1/dk_p00b/dk_p00：00/01/02.jpg 三页一致）★
/// - 图像显示区 = 页宽-36 × 167.5 固定（x18-342、y244-411.5），全部图片
///   cover 等比缩放裁边填满（非 contain！01.jpg 等比 149.5 高但显示 167.5）
/// - maintitle 字形顶 = 430（= 图像显示区底 411.5 + 18.5）
/// - subtitle 首行字形顶 = 476，行距 40.5（行1 476 → 行2 518 → 行3 558）
///
/// Flutter 实现（height 1.15 下沉 1.575 / subtitle 下沉 10.8）：
/// - maintitle box 顶 = 显示区底 + 17 → 字形顶 = 411.5+17+1.575 = 430.075
/// - subtitle box 顶 = maintitle box 底 + 15 → 行1 字形顶 = 476.035
/// 图像显示区固定高（多看稳定态实测：所有图 cover 于 324×167.5）
const _kGalleryImageDisplayHeight = 167.5;

/// 图像显示区顶相对 SafeArea = 220（绝对 244 = SafeArea 24 + 220；
/// 多看 DocImagesView 顶 59 + 图像区距 DocImagesView 顶 185）
const _kGalleryImageTopGap = 220.0;

const _kMaintitlePaddingTop = 17.0;
const _kMaintitleLineHeight = 1.15;
const _kSubtitlePaddingTop = 15.0;
const _kSubtitleLineHeight = 40.5 / 18.9;

class _EpubGalleryPageState extends State<EpubGalleryPage> {
  late final PageController _pageController;
  late final _GalleryCellStyle _cellStyle;
  late final _GalleryTitleStyle _titleStyle;
  late final _GalleryTxtStyle _txtStyle;
  int _currentIndex = 0;
  bool _isNavigating = false;

  /// 是否有独立标题页（gallery.xhtml 的 h3 对齐多看分页：首页单独一页）
  late final bool _hasTitlePage;

  /// 标题页文本（chapterStyle.galleryTitle ?? chapterTitle）
  late final String _titleText;

  /// gallery-txt 提示文本（无则不显示悬浮提示）
  late final String _txtText;

  /// 渲染值诊断用 GlobalKey（仅挂载在当前页，避免多页重复 key）
  final _titleKey = GlobalKey();
  final _txtKey = GlobalKey();
  final _dottedKey = GlobalKey();
  final _imageKey = GlobalKey();
  final _maintitleKey = GlobalKey();
  final _subtitleKey = GlobalKey();

  /// PageView 总页数 = 标题页（可选）+ 图片页
  int get _itemCount => widget.images.length + (_hasTitlePage ? 1 : 0);

  /// 当前是否处于图片页（标题页不显示 gallery-txt / dotted）
  bool get _isImagePage => _currentIndex >= (_hasTitlePage ? 1 : 0);

  /// 当前图片索引（标题页时为 0，仅 _isImagePage 时有效）
  int get _imageIndex => _currentIndex - (_hasTitlePage ? 1 : 0);

  @override
  void initState() {
    super.initState();
    _titleText =
        (widget.chapterStyle?.galleryTitle ?? widget.chapterTitle).trim();
    _txtText = widget.chapterStyle?.galleryTxt?.trim() ?? '';
    _hasTitlePage = _titleText.isNotEmpty;
    final initialIdx = widget.initialPageToEnd ? _itemCount - 1 : 0;
    _currentIndex = initialIdx;
    _pageController = PageController(initialPage: initialIdx);
    final rawCss = widget.chapterStyle?.rawCss ?? '';
    _cellStyle = _parseCellStyle(rawCss);
    _titleStyle = _parseTitleStyle(rawCss);
    _txtStyle = _parseTxtStyle(rawCss);
    // 首帧后导出渲染值（logcat 抓取 galleryDump）
    WidgetsBinding.instance.addPostFrameCallback((_) => _dumpLayout('init'));
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 从 rawCss 解析 .duokan-image-gallery-cell 的视觉样式
  ///
  /// 原作 CSS（style.css）：
  /// ```css
  /// .duokan-image-gallery-cell {
  ///     margin: 10px 0;
  ///     border-style: solid;
  ///     border-width: 1px;
  ///     box-shadow: 5px 5px 5px #888888;
  /// }
  /// ```
  _GalleryCellStyle _parseCellStyle(String rawCss) {
    final cellBlock = _extractRuleBlock(rawCss, 'duokan-image-gallery-cell');
    final maintitleBlock = _extractRuleBlock(rawCss, 'duokan-image-maintitle');
    final subtitleBlock = _extractRuleBlock(rawCss, 'duokan-image-subtitle');

    // 解析 maintitle margin（原作 margin: 1em auto -0.5em auto）
    final maintitleMargins = _parseMargin(maintitleBlock);

    return _GalleryCellStyle(
      borderWidth: _parseFloat(cellBlock, 'border-width') ?? 1.0,
      borderColor: _parseColor(cellBlock, 'border-color'),
      boxShadowDx: _parseBoxShadow(cellBlock)?.dx ?? 5.0,
      boxShadowDy: _parseBoxShadow(cellBlock)?.dy ?? 5.0,
      boxShadowBlur: _parseBoxShadow(cellBlock)?.blur ?? 5.0,
      boxShadowColor: _parseBoxShadow(cellBlock)?.color ?? const Color(0xFF888888),
      maintitleColor: _parseColor(maintitleBlock, 'color') ??
          const Color(0xFF336633),
      subtitleColor: _parseColor(subtitleBlock, 'color') ??
          const Color(0xFF333333),
      maintitleMarginTop: maintitleMargins?.$1 ?? 1.0,
      maintitleMarginBottom: maintitleMargins?.$2 ?? -0.5,
      // 原著 .duokan-image-subtitle 无 margin 属性（style.css 第339-345行），
      // 默认 0；subtitle 紧接 maintitle，靠 maintitle 负下 margin 拉近间距。
      subtitleMarginBottom: _parseMargin(subtitleBlock)?.$2 ?? 0.0,
      cellMarginVertical: _parseMarginPx(cellBlock)?.$1 ?? 10.0,
      maintitleFontSize: _parseFloat(maintitleBlock, 'font-size') ?? 0.9,
      subtitleFontSize: _parseFloat(subtitleBlock, 'font-size') ?? 0.9,
      subtitleLineHeight: _parseFloat(subtitleBlock, 'line-height') ?? 1.35,
      // 字体族（对齐原著 style.css）
      // maintitle: DK-HEITI（黑体）→ sans-serif
      // subtitle: DK-KAITI（楷体）→ serif
      maintitleFontFamily: _parseFontFamily(maintitleBlock) ?? 'sans-serif',
      subtitleFontFamily: _parseFontFamily(subtitleBlock) ?? 'serif',
    );
  }

  _GalleryTitleStyle _parseTitleStyle(String rawCss) {
    final block = _extractRuleBlock(rawCss, 'gallery-title');
    final margins = _parseMargin(block);
    return _GalleryTitleStyle(
      fontSize: _parseFloat(block, 'font-size') ?? 1.5,
      bold: _containsKeyword(block, 'bold') || _containsKeyword(block, '700'),
      color: _parseColor(block, 'color'),
      textShadow: _parseTextShadow(block),
      marginTop: margins?.$1 ?? 2.0,
      marginBottom: margins?.$2 ?? 2.0,
      // 原作 font-family: "DK-XIAOBIAOSONG", "h3", serif → serif
      fontFamily: _parseFontFamily(block) ?? 'serif',
    );
  }

  _GalleryTxtStyle _parseTxtStyle(String rawCss) {
    final block = _extractRuleBlock(rawCss, 'gallery-txt');
    final margins = _parseMargin(block);
    return _GalleryTxtStyle(
      fontSize: _parseFloat(block, 'font-size') ?? 0.7,
      color: _parseColor(block, 'color'),
      textShadow: _parseTextShadow(block),
      marginTop: margins?.$1 ?? 1.0,
      marginBottom: margins?.$2 ?? 1.0,
      // 原作 font-family: "DK-HEITI", "ht", sans-serif → sans-serif
      fontFamily: _parseFontFamily(block) ?? 'sans-serif',
    );
  }

  /// 提取 CSS class 规则块内容
  String? _extractRuleBlock(String css, String className) {
    final pattern = RegExp(
      '\\.$className\\s*\\{([^}]*)\\}',
      multiLine: true,
    );
    return pattern.firstMatch(css)?.group(1);
  }

  /// 从 CSS 块中解析数值属性（如 font-size: 1.5em → 1.5）
  double? _parseFloat(String? block, String prop) {
    if (block == null) return null;
    final match = RegExp('$prop\\s*:\\s*([0-9.]+)').firstMatch(block);
    if (match == null) return null;
    return double.tryParse(match.group(1)!);
  }

  /// 从 CSS 块中解析颜色（如 color: #336633 → Color(0xFF336633)）
  Color? _parseColor(String? block, String prop) {
    if (block == null) return null;
    final match = RegExp('$prop\\s*:\\s*#([0-9a-fA-F]{3,8})').firstMatch(block);
    if (match == null) return null;
    final hex = match.group(1)!;
    if (hex.length == 6) {
      return Color(int.parse('FF$hex', radix: 16));
    }
    if (hex.length == 3) {
      final r = hex[0] * 2;
      final g = hex[1] * 2;
      final b = hex[2] * 2;
      return Color(int.parse('FF$r$g$b', radix: 16));
    }
    return null;
  }

  /// 从 CSS 块中解析 font-family（如 font-family: "DK-HEITI","ht",sans-serif → sans-serif）
  ///
  /// 多看 EPUB 用 DK-* 字体名（DK-HEITI=黑体, DK-KAITI=楷体, DK-SONGTI=宋体,
  /// DK-FANGSONG=仿宋, DK-XIAOBIAOSONG=小标宋, DK-XIHEITI=细黑体），
  /// 这些字体在多看设备上由系统注入，Flutter 侧用通用字体族兜底：
  /// - DK-HEITI/DK-XIHEITI → sans-serif（黑体/圆体）
  /// - DK-KAITI → serif（楷体，serif 衬线体更接近楷书笔画）
  /// - DK-SONGTI/DK-FANGSONG/DK-XIAOBIAOSONG → serif（宋体/仿宋/小标宋）
  String? _parseFontFamily(String? block) {
    if (block == null) return null;
    final match = RegExp(
      r'font-family\s*:\s*([^;]+)',
    ).firstMatch(block);
    if (match == null) return null;
    final family = match.group(1)!.toLowerCase();
    // 检测多看 DK-* 字体名 → 映射到通用字体族
    if (family.contains('heiti') || family.contains('xiheiti')) {
      return 'sans-serif';
    }
    if (family.contains('kaiti') ||
        family.contains('songti') ||
        family.contains('fangsong') ||
        family.contains('xiaobiaosong')) {
      return 'serif';
    }
    // 兜底：取最后一个字体名（去掉引号）
    final parts = family.split(',');
    if (parts.isEmpty) return null;
    // 正则匹配双引号或单引号；用非 raw 字符串转义单引号
    final last = parts.last.trim().replaceAll(RegExp('["\']'), '');
    return last.isEmpty ? null : last;
  }

  /// 解析 box-shadow: dx dy blur color
  _BoxShadow? _parseBoxShadow(String? block) {
    if (block == null) return null;
    final match = RegExp(
      r'box-shadow\s*:\s*([0-9.]+)px\s+([0-9.]+)px\s+([0-9.]+)px\s+#([0-9a-fA-F]{6})',
    ).firstMatch(block);
    if (match == null) return null;
    return _BoxShadow(
      dx: double.parse(match.group(1)!),
      dy: double.parse(match.group(2)!),
      blur: double.parse(match.group(3)!),
      color: Color(int.parse('FF${match.group(4)}', radix: 16)),
    );
  }

  bool _containsKeyword(String? block, String keyword) {
    if (block == null) return false;
    return block.toLowerCase().contains(keyword.toLowerCase());
  }

  /// 解析 CSS margin 的上下值（em 单位，如 margin: 1em auto -0.5em auto）
  ///
  /// 返回 (marginTop, marginBottom)，解析失败返回 null
  /// 支持格式：
  /// - `margin: top right bottom left`（4 值）
  /// - `margin: top bottom`（2 值）
  /// - `margin: all`（1 值）
  /// auto 值跳过（不参与上下 margin 计算）
  (double, double)? _parseMargin(String? block) {
    if (block == null) return null;
    final match = RegExp(r'margin\s*:\s*([^;]+)').firstMatch(block);
    if (match == null) return null;
    final parts = match.group(1)!.trim().split(RegExp(r'\s+'));
    final emValues = parts
        .map((p) => p.toLowerCase().endsWith('em')
            ? double.tryParse(p.replaceAll(RegExp(r'em$'), ''))
            : null)
        .whereType<double>()
        .toList();
    if (emValues.isEmpty) return null;
    if (emValues.length >= 4) {
      return (emValues[0], emValues[2]);
    } else if (emValues.length >= 2) {
      return (emValues[0], emValues[1]);
    } else {
      return (emValues[0], emValues[0]);
    }
  }

  /// 解析 CSS margin 的上下值（px 单位，如 margin: 10px 0）
  ///
  /// 返回 (marginTop, marginBottom)，解析失败返回 null
  (double, double)? _parseMarginPx(String? block) {
    if (block == null) return null;
    final match = RegExp(r'margin\s*:\s*([^;]+)').firstMatch(block);
    if (match == null) return null;
    final parts = match.group(1)!.trim().split(RegExp(r'\s+'));
    final pxValues = parts
        .map((p) => p.toLowerCase().endsWith('px')
            ? double.tryParse(p.replaceAll(RegExp(r'px$'), ''))
            : double.tryParse(p))
        .whereType<double>()
        .toList();
    if (pxValues.isEmpty) return null;
    if (pxValues.length >= 4) {
      return (pxValues[0], pxValues[2]);
    } else if (pxValues.length >= 2) {
      return (pxValues[0], pxValues[1]);
    } else {
      return (pxValues[0], pxValues[0]);
    }
  }

  /// 解析 CSS text-shadow（如 text-shadow: 0 1 1px #fff）
  ///
  /// 格式：offsetX offsetY blur color
  /// 原作 gallery-title / gallery-txt 均为 text-shadow: 0 1 1px #fff
  Shadow? _parseTextShadow(String? block) {
    if (block == null) return null;
    final match = RegExp(
      r'text-shadow\s*:\s*([0-9.-]+)\s+([0-9.-]+)\s*(?:([0-9.]+)px\s+)?#([0-9a-fA-F]{3,6})',
    ).firstMatch(block);
    if (match == null) return null;
    final dx = double.tryParse(match.group(1) ?? '0') ?? 0;
    final dy = double.tryParse(match.group(2) ?? '0') ?? 0;
    final blur = double.tryParse(match.group(3) ?? '0') ?? 0;
    final hex = match.group(4)!;
    final color = hex.length == 6
        ? Color(int.parse('FF$hex', radix: 16))
        : hex.length == 3
            ? Color(int.parse('FF${hex[0] * 2}${hex[1] * 2}${hex[2] * 2}',
                radix: 16))
            : const Color(0xFFFFFFFF);
    return Shadow(offset: Offset(dx, dy), blurRadius: blur, color: color);
  }

  Color _resolveBgColor() {
    final bgClr = widget.chapterStyle?.backgroundColor;
    if (bgClr != null) return Color(bgClr);
    return widget.backgroundColor;
  }

  /// 构建背景装饰（含背景图）
  Decoration? _buildBackgroundDecoration() {
    final bgSrc = widget.chapterStyle?.backgroundImageSrc;
    if (bgSrc == null || bgSrc.isEmpty) return null;

    final isDataUri = bgSrc.startsWith('data:');
    final imageProvider = isDataUri
        ? MemoryImage(_parseDataUri(bgSrc))
        : FileImage(File(bgSrc));

    final bgSize = widget.chapterStyle?.backgroundSize ?? 'cover';
    final bgPosition = widget.chapterStyle?.backgroundPosition ?? 'center';
    final bgRepeat = widget.chapterStyle?.backgroundRepeat ?? 'no-repeat';

    return BoxDecoration(
      color: _resolveBgColor(),
      image: DecorationImage(
        image: imageProvider as ImageProvider,
        fit: bgSize == 'cover' ? BoxFit.cover : BoxFit.contain,
        alignment: _parseAlignment(bgPosition),
        repeat: bgRepeat == 'repeat'
            ? ImageRepeat.repeat
            : bgRepeat == 'repeat-x'
                ? ImageRepeat.repeatX
                : bgRepeat == 'repeat-y'
                    ? ImageRepeat.repeatY
                    : ImageRepeat.noRepeat,
      ),
    );
  }

  Alignment _parseAlignment(String position) {
    final p = position.toLowerCase();
    if (p.contains('top')) {
      if (p.contains('left')) return Alignment.topLeft;
      if (p.contains('right')) return Alignment.topRight;
      return Alignment.topCenter;
    }
    if (p.contains('bottom')) {
      if (p.contains('left')) return Alignment.bottomLeft;
      if (p.contains('right')) return Alignment.bottomRight;
      return Alignment.bottomCenter;
    }
    if (p.contains('left')) return Alignment.centerLeft;
    if (p.contains('right')) return Alignment.centerRight;
    return Alignment.center;
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    _isNavigating = false;
    // 翻页后导出渲染值（标题页/图片页切换验证）
    _dumpLayout('page$index');
    // onPageChanged 在滑动越过 50% 时触发，此时页面仍在 settle 动画中，
    // 水平偏移导致 x 值不可信；600ms 后再导一次稳定态
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _dumpLayout('page${index}settle');
    });
  }

  /// 边界章节切换：在第一页继续往前 → 上一章，最后页继续往后 → 下一章
  void _handleEdgeScroll(ScrollNotification notification) {
    if (_isNavigating) return;

    if (notification is OverscrollNotification &&
        notification.metrics.axis == Axis.horizontal) {
      if (notification.overscroll < 0 && _currentIndex == 0) {
        _isNavigating = true;
        widget.onPreviousChapter();
      } else if (notification.overscroll > 0 &&
          _currentIndex == _itemCount - 1) {
        _isNavigating = true;
        widget.onNextChapter();
      }
    }
  }

  /// 点击图片弹出全屏预览
  ///
  /// ★ 对齐多看 DocImageWatchingView（ZoomView + MultiTouchImageView）★
  /// 反汇编 dex 报告证实多看全屏预览：
  /// - 不是独立 Activity，是阅读器内 View 切换
  /// - ZoomView（Matrix + 状态机 IDLE/PINCH/SMOOTH）支持双指缩放
  /// - MultiTouchImageView 支持双击缩放（setDoubleTap）
  /// - 横向滑动翻页（mWatchingAdapter 管理多张图片）
  void _showFullScreenPreview(int initialIndex) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (context, animation, secondaryAnimation) {
          return _GalleryFullScreenViewer(
            images: widget.images,
            initialIndex: initialIndex,
            backgroundColor: Colors.black,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty) {
      return Container(
        color: _resolveBgColor(),
        alignment: Alignment.center,
        child: Text('画廊无图片', style: TextStyle(color: widget.textColor)),
      );
    }

    final hasBgImage = widget.chapterStyle?.backgroundImageSrc != null &&
        widget.chapterStyle!.backgroundImageSrc!.isNotEmpty;

    // ★ 对齐多看画廊页结构（gallery_full_disasm_report.md 第二节/5.1 +
    //   真机实测 dk_g1/dk_prev/dk_s1）：
    //   1. 标题页独立分页：多看把 gallery.xhtml 的 h3 单独一页（页面上仅
    //      h3 居中，y=267-330），DocImagesView slider 页不显示标题
    //   2. gallery-txt 悬浮在 slider 页顶部（dk_prev 实测 y=154，文本顶
    //      77 logical = SafeArea 24 + 35 + 1em margin）
    //   3. 图片页：图片 + maintitle + subtitle 垂直居中（dk_s1 实测
    //      图片 648x326 @ x=36-683，即左右边距各 18 logical）
    //   4. dotted 悬浮底部，仅图片页显示（dk_s1 图片页无标题无 txt）
    final showDotted = widget.images.length > 1;

    return Container(
      color: hasBgImage ? null : _resolveBgColor(),
      decoration: hasBgImage ? _buildBackgroundDecoration() : null,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  // 滑动区：底部留出 dotted 高度，cell 内容不被遮挡
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: dottedHeightOf(showDotted)),
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (notification) {
                          _handleEdgeScroll(notification);
                          return false;
                        },
                        child: PageView.builder(
                          controller: _pageController,
                          itemCount: _itemCount,
                          onPageChanged: _onPageChanged,
                          allowImplicitScrolling: true,
                          itemBuilder: (context, index) {
                            if (_hasTitlePage && index == 0) {
                              return _buildGalleryTitle(
                                titleKey: _currentIndex == 0 ? _titleKey : null,
                              );
                            }
                            final imgIdx = _hasTitlePage ? index - 1 : index;
                            final isCurrent = index == _currentIndex;
                            return _GalleryCell(
                              image: widget.images[imgIdx],
                              style: _cellStyle,
                              textColor: widget.textColor,
                              onTap: () => _showFullScreenPreview(imgIdx),
                              imageKey: isCurrent ? _imageKey : null,
                              maintitleKey: isCurrent ? _maintitleKey : null,
                              subtitleKey: isCurrent ? _subtitleKey : null,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  // gallery-txt 顶部悬浮（对齐多看 DocImagesView 顶部 y=77）
                  // 只看图片页显示；标题页无（dk_g1 标题页仅 h3）
                  // 注意：Positioned 在 SafeArea 内的 Stack，top 相对
                  // SafeArea 顶，不要再加 safeTop（双重偏移实测落 101）
                  if (_isImagePage && _txtText.isNotEmpty)
                    Positioned(
                      top:
                          _kGalleryTxtExtraTop + _kGalleryTxtMarginTop,
                      left: 0,
                      right: 0,
                      child: _buildGalleryTxt(),
                    ),
                  // 点点点指示器：对齐多看 .dotted position:absolute bottom
                  // 仅图片页显示（标题页无 dotted）
                  if (_isImagePage && showDotted)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _buildDottedIndicator(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// dotted 是否占用 PageView 底部空间（仅图片页且多图时）
  double dottedHeightOf(bool showDotted) =>
      _isImagePage && showDotted ? _kDottedHeight : 0.0;

  /// 标题页（对齐多看 gallery.xhtml 首页：h3 独立分页）
  ///
  /// 原作 CSS: margin: 2em auto; font-size: 1.5em; font-weight: bold;
  ///   text-align: center; text-shadow: 0 1 1px #fff
  /// 多看实测（dk_g1）：h3 字形顶 y=263 physical（131.5 logical），
  ///   字形高 63 physical（31.5 = 1.5em × 基准 21），页面上无其他内容；
  ///   DocImagesView slider 页不显示标题。
  /// 定位：SafeArea 24 + 2em(42) + 65.5 = 131.5 ✓（字形顶精确命中）。
  /// ★ 必须用 Align(topCenter) 而非 Center：Center 会把文本垂直居中，
  ///   顶部的 2em+65.5 留白被抵消（实测标题落到了 y=344 而非 131.5）。
  /// ★ Text height 1.0：行盒 = 字形高，字形顶 = box 顶，galleryDump
  ///   的 title.y 直接等于多看字形顶 131.5，可像素级对比。
  Widget _buildGalleryTitle({Key? titleKey}) {
    final shadows = _titleStyle.textShadow != null
        ? [_titleStyle.textShadow!]
        : <Shadow>[];

    return Padding(
      padding: EdgeInsets.only(
        top: _kGalleryBaseFontSize * _titleStyle.marginTop + _kTitlePageExtraTop,
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: Text(
          _titleText,
          key: titleKey,
          style: TextStyle(
            fontSize: _kGalleryBaseFontSize * _titleStyle.fontSize,
            fontWeight: _titleStyle.bold ? FontWeight.bold : FontWeight.normal,
            fontFamily: _titleStyle.fontFamily,
            color: _titleStyle.color ?? widget.textColor,
            decoration: TextDecoration.none,
            height: 1.0,
            shadows: shadows,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  /// 顶部提示文本（对齐多看 DocImagesView gallery-txt）
  /// 原作 CSS: margin: 1em auto; font-size: 0.7em; text-align: center;
  ///   text-shadow: 0 1 1px #fff
  /// 位置由 build() 中 Positioned(top: 35 + 1em) 决定（SafeArea 内，绝对
  /// 顶 = 24 + 35 + 18 = 77）。
  Widget _buildGalleryTxt() {
    final shadows = _txtStyle.textShadow != null
        ? [_txtStyle.textShadow!]
        : <Shadow>[];

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
      ),
        child: Text(
          _txtText,
          key: _txtKey,
          style: TextStyle(
            fontSize: _kGalleryBaseFontSize * _txtStyle.fontSize,
          fontFamily: _txtStyle.fontFamily,
          color: _txtStyle.color ?? widget.textColor,
          decoration: TextDecoration.none,
          shadows: shadows,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  /// 点点点指示器（对齐多看 .dotted > span）
  ///
  /// 多看反编译（gallery_full_disasm_report.md 第二节/5.1）：
  /// - CGallery::getHtmlSnippet 生成 `<div class="dotted"><span></span>×N</div>`
  /// - span 数量 = 图片数量（obj+0x134）← 已对齐：List.generate(images.length)
  /// - dotted 的 style 由 setGalleryScrollRect 生成：
  ///     `position: absolute; left:%dpx; top:%dpx; width:%dpx; height:%dpx;`
  ///   ← 已对齐：build() 中用 Stack + Positioned(bottom:0) 悬浮在 PageView 底部
  /// - 多看未在 .rodata 中给出 span 的具体尺寸样式，由设备 theme 注入
  ///   ← Flutter 近似：圆点 6×6px，active alpha 230 / inactive alpha 77
  ///
  /// 本方法只负责圆点行本身；定位由 build() 的 Positioned 包裹完成。
  Widget _buildDottedIndicator() {
    if (widget.images.length <= 1) return const SizedBox.shrink();

    final textRgb = widget.textColor.toARGB32();
    final r = (textRgb >> 16) & 0xFF;
    final g = (textRgb >> 8) & 0xFF;
    final b = textRgb & 0xFF;
    final activeDot = _imageIndex;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        key: _dottedKey,
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(widget.images.length, (i) {
          final isActive = i == activeDot;
          return Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? Color.fromARGB(230, r, g, b)
                  : Color.fromARGB(77, r, g, b),
            ),
          );
        }),
      ),
    );
  }

  /// 导出画廊页渲染值到 logcat（[reader] galleryDump 前缀，domDump 同族诊断）
  ///
  /// 用户要求「看渲染的排版值」：Flutter 原生页无 DOM，用 GlobalKey +
  /// RenderBox 读取各元素全局坐标与实际渲染尺寸，与多看真机实测对比。
  void _dumpLayout(String reason) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final size = MediaQuery.sizeOf(context);
      final safe = MediaQuery.paddingOf(context);
      final sb = StringBuffer('[reader] galleryDump $reason');
      sb.write(' dpr=$dpr size=${size.width.round()}x${size.height.round()}');
      sb.write(' safeTop=${safe.top.round()} safeBottom=${safe.bottom.round()}');
      sb.write(' itemCount=$_itemCount idx=$_currentIndex imageIdx=$_imageIndex');
      sb.write(' hasTitlePage=$_hasTitlePage');

      void rectOf(GlobalKey key, String name) {
        final box = key.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.attached) {
          sb.write(' $name=null');
          return;
        }
        final pos = box.localToGlobal(Offset.zero);
        sb.write(' $name=x${pos.dx.round()}y${pos.dy.round()}'
            'w${box.size.width.round()}h${box.size.height.round()}');
      }

      rectOf(_titleKey, 'title');
      rectOf(_txtKey, 'txt');
      rectOf(_dottedKey, 'dotted');
      rectOf(_imageKey, 'img');
      rectOf(_maintitleKey, 'maintitle');
      rectOf(_subtitleKey, 'subtitle');
      debugPrint(sb.toString());
    });
  }
}

/// 单张图片单元格（对齐多看 DkeGallery 原生布局，非 CSS 流）
///
/// 多看反汇编（.tmp/gallery_dex_report.md）+ 真机实测（dk_s1/dk5）
/// 确立的原生几何（逻辑 px，基准字号 21）：
/// - DocImagesView 矩形 = 相对 cell 顶 35（绝对 59）、高 533、宽 324
/// - 图像在矩形内垂直居中：图像顶 = 35 + (533 - 显示高)/2（00.jpg
///   显示 324×163 → 顶 244，01.jpg 恒定 → 顶恒定不随滑动变化）
/// - maintitle 字形顶 = 图像显示区底 + 22.5（实测两页恒定）
/// - subtitle 首行字形顶 = maintitle 字形底 + 28.5；行距 40.5
///
/// 原作 CSS（仅作字号/颜色来源）：
/// ```css
/// .duokan-image-gallery-cell {
///     margin: 10px 0;
///     border-style: solid;
///     border-width: 1px;
///     box-shadow: 5px 5px 5px #888888;
/// }
/// .gallery-pic img { width: 100%; }
/// .duokan-image-maintitle {
///     margin: 1em auto -0.5em auto;
///     color: #336633;
///     text-align: center;
/// }
/// .duokan-image-subtitle {
///     color: #333;
///     line-height: 1.35em;
///     text-align: justify;
/// }
/// ```
class _GalleryCell extends StatelessWidget {
  final EpubGalleryImage image;
  final _GalleryCellStyle style;
  final Color textColor;
  final VoidCallback onTap;

  /// 渲染值诊断 key（仅当前页传入，避免 GlobalKey 重复挂载）
  final Key? imageKey;
  final Key? maintitleKey;
  final Key? subtitleKey;

  const _GalleryCell({
    required this.image,
    required this.style,
    required this.textColor,
    required this.onTap,
    this.imageKey,
    this.maintitleKey,
    this.subtitleKey,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      // 水平 18px 对齐多看图片左右边距：dk_s1 实测 00.jpg x=36-683
      // （648 wide = 720-72，即单边 36 physical = 18 logical）。
      // 垂直不留边距：图像顶由 DocImagesView 固定几何（35 + 居中留白）决定。
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 多看 DocImagesView 图像区：宽 = 页宽 - 36；图像 cover 于
            // 固定显示区（高 167.5，稳定态实测 00/01/02.jpg 均一致），
            // 等比缩放裁边填满，不随原图比例变化
            final dispW = constraints.maxWidth;
            const dispH = _kGalleryImageDisplayHeight;
            // 图像区顶留白 = 220（绝对 244 = SafeArea 24 + 220）
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: _kGalleryImageTopGap),
                // 边框+阴影装饰叠加层（原 .duokan-image-gallery-cell 的
                // border 1px + box-shadow 5px 5px 5px #888888）。
                // 用 Stack 叠加避免 border 向外扩展影响布局尺寸
                // （Flutter Container+border 实测 box 高 = 内容+2）。
                SizedBox(
                  key: imageKey,
                  width: dispW,
                  height: dispH,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRect(child: _buildImage()),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            width: style.borderWidth,
                            color: style.borderColor ?? textColor,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  style.boxShadowColor ?? const Color(0xFF888888),
                              offset: Offset(
                                  style.boxShadowDx, style.boxShadowDy),
                              blurRadius: style.boxShadowBlur,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // maintitle（对齐 .duokan-image-maintitle，稳定态实测
                // 字形顶 = 图像显示区底 + 18.5 = 430；box 顶取 17 =
                // 18.5 - 1.575（height 1.15 字形下沉））
                if (image.maintitle.isNotEmpty)
                  Padding(
                    key: maintitleKey,
                    padding: const EdgeInsets.only(top: _kMaintitlePaddingTop),
                    child: Text(
                      image.maintitle,
                      style: TextStyle(
                        fontSize:
                            _kGalleryBaseFontSize * style.maintitleFontSize,
                        fontFamily: style.maintitleFontFamily,
                        color: style.maintitleColor,
                        decoration: TextDecoration.none,
                        height: _kMaintitleLineHeight,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                // subtitle（对齐 .duokan-image-subtitle，稳定态实测首行
                // 字形顶 = 476 = maintitle box 底 + 15 + 下沉 10.8）
                // 原作 CSS 无 margin，行距 1.35em 被多看原生放大为 40.5
                if (image.subtitle.isNotEmpty)
                  Padding(
                    key: subtitleKey,
                    padding: const EdgeInsets.only(top: _kSubtitlePaddingTop),
                    child: Text(
                      image.subtitle,
                      style: TextStyle(
                        fontSize:
                            _kGalleryBaseFontSize * style.subtitleFontSize,
                        fontFamily: style.subtitleFontFamily,
                        color: style.subtitleColor,
                        height: _kSubtitleLineHeight,
                        decoration: TextDecoration.none,
                      ),
                      textAlign: TextAlign.justify,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildImage() {
    final src = image.src;
    // 外层 SizedBox 固定 324×167.5 显示区，cover 等比缩放裁边填满
    // （对齐多看稳定态：所有图 cover 于固定显示区）
    if (src.startsWith('data:')) {
      return Image.memory(
        _parseDataUri(src),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) =>
            _buildErrorWidget(),
      );
    }
    return Image.file(
      File(src),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) =>
          _buildErrorWidget(),
    );
  }

  Widget _buildErrorWidget() {
    return Container(
      width: double.infinity,
      height: 200,
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_outlined,
        color: textColor.withValues(alpha: 0.5),
        size: 64,
      ),
    );
  }
}

/// 全屏预览查看器（Flutter 原生实现）
///
/// ★ 对齐多看 DocImageWatchingView（ZoomView + MultiTouchImageView）★
class _GalleryFullScreenViewer extends StatefulWidget {
  final List<EpubGalleryImage> images;
  final int initialIndex;
  final Color backgroundColor;

  const _GalleryFullScreenViewer({
    required this.images,
    required this.initialIndex,
    required this.backgroundColor,
  });

  @override
  State<_GalleryFullScreenViewer> createState() =>
      _GalleryFullScreenViewerState();
}

class _GalleryFullScreenViewerState extends State<_GalleryFullScreenViewer> {
  late PageController _pageController;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.backgroundColor,
      body: Stack(
        children: [
          // PageView 横向滑动翻页
          Positioned.fill(
            child: PageView.builder(
              controller: _pageController,
              itemCount: widget.images.length,
              onPageChanged: _onPageChanged,
              allowImplicitScrolling: true,
              itemBuilder: (context, index) {
                return _FullScreenImage(
                  image: widget.images[index],
                  onTap: () => Navigator.of(context).pop(),
                );
              },
            ),
          ),
          // 顶部：页码指示器 + 关闭按钮
          _buildTopBar(),
          // 底部：图片描述
          if (widget.images[_currentIndex].maintitle.isNotEmpty ||
              widget.images[_currentIndex].subtitle.isNotEmpty)
            _buildBottomDescription(),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    '${_currentIndex + 1} / ${widget.images.length}',
                    key: ValueKey(_currentIndex),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomDescription() {
    final img = widget.images[_currentIndex];
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (img.maintitle.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    img.maintitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.none,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              if (img.subtitle.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    img.subtitle,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      height: 1.4,
                      decoration: TextDecoration.none,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 全屏单张图片查看器（支持双指缩放 + 双击缩放）
///
/// ★ 对齐多看 MultiTouchImageView ★
/// - setDoubleTap(MotionEvent) → GestureDetector.onDoubleTap
/// - setScale(ScaleGestureDetector) → InteractiveViewer
/// - PageScaleType.MATCH_INSIDE → BoxFit.contain
class _FullScreenImage extends StatefulWidget {
  final EpubGalleryImage image;
  final VoidCallback onTap;

  const _FullScreenImage({
    required this.image,
    required this.onTap,
  });

  @override
  State<_FullScreenImage> createState() => _FullScreenImageState();
}

class _FullScreenImageState extends State<_FullScreenImage>
    with SingleTickerProviderStateMixin {
  final TransformationController _controller = TransformationController();
  late AnimationController _animController;
  Animation<Matrix4>? _scaleAnimation;
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(() {
        if (_scaleAnimation != null) {
          _controller.value = _scaleAnimation!.value;
        }
      });
  }

  @override
  void dispose() {
    _animController.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 双击切换缩放（对应多看 MultiTouchImageView.setDoubleTap）
  void _handleDoubleTap() {
    if (_isZoomed) {
      _scaleAnimation = Matrix4Tween(
        begin: _controller.value,
        end: Matrix4.identity(),
      ).animate(CurvedAnimation(
        parent: _animController,
        curve: Curves.easeOutCubic,
      ));
      _animController.forward(from: 0);
      _isZoomed = false;
    } else {
      _scaleAnimation = Matrix4Tween(
        begin: _controller.value,
        end: Matrix4.diagonal3Values(2.5, 2.5, 1.0),
      ).animate(CurvedAnimation(
        parent: _animController,
        curve: Curves.easeOutCubic,
      ));
      _animController.forward(from: 0);
      _isZoomed = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: 1.0,
        maxScale: 4.0,
        boundaryMargin: const EdgeInsets.all(double.infinity),
        clipBehavior: Clip.none,
        onInteractionEnd: (details) {
          final scale = _controller.value.getMaxScaleOnAxis();
          _isZoomed = scale > 1.01;
        },
        child: Center(
          child: _buildImage(),
        ),
      ),
    );
  }

  Widget _buildImage() {
    final src = widget.image.src;
    if (src.startsWith('data:')) {
      return Image.memory(
        _parseDataUri(src),
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    }
    return Image.file(
      File(src),
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) {
        return const Icon(
          Icons.broken_image_outlined,
          color: Colors.white54,
          size: 64,
        );
      },
    );
  }
}

// === 辅助类 ===

class _BoxShadow {
  final double dx;
  final double dy;
  final double blur;
  final Color color;
  const _BoxShadow({
    required this.dx,
    required this.dy,
    required this.blur,
    required this.color,
  });
}

class _GalleryCellStyle {
  final double borderWidth;
  final Color? borderColor;
  final double boxShadowDx;
  final double boxShadowDy;
  final double boxShadowBlur;
  final Color? boxShadowColor;
  final Color maintitleColor;
  final Color subtitleColor;
  /// maintitle 上 margin（em 值，原作 1em）
  final double maintitleMarginTop;
  /// maintitle 下 margin（em 值，原作 -0.5em，负值=减少与 subtitle 间距）
  final double maintitleMarginBottom;
  /// subtitle 下 margin（em 值，原作无 margin，默认 0）
  final double subtitleMarginBottom;
  /// cell 上下 margin（px 值，原作 10px 0）
  final double cellMarginVertical;
  /// maintitle 字号（em 值，原作 0.9em）
  final double maintitleFontSize;
  /// subtitle 字号（em 值，原作 0.9em）
  final double subtitleFontSize;
  /// subtitle 行高（原作 1.35em）
  final double subtitleLineHeight;
  /// maintitle 字体族（原作 DK-HEITI → sans-serif）
  final String maintitleFontFamily;
  /// subtitle 字体族（原作 DK-KAITI → serif）
  final String subtitleFontFamily;

  const _GalleryCellStyle({
    this.borderWidth = 1.0,
    this.borderColor,
    this.boxShadowDx = 5.0,
    this.boxShadowDy = 5.0,
    this.boxShadowBlur = 5.0,
    this.boxShadowColor,
    this.maintitleColor = const Color(0xFF336633),
    this.subtitleColor = const Color(0xFF333333),
    this.maintitleMarginTop = 1.0,
    this.maintitleMarginBottom = -0.5,
    this.subtitleMarginBottom = 0.0,
    this.cellMarginVertical = 10.0,
    this.maintitleFontSize = 0.9,
    this.subtitleFontSize = 0.9,
    this.subtitleLineHeight = 1.35,
    this.maintitleFontFamily = 'sans-serif',
    this.subtitleFontFamily = 'serif',
  });
}

class _GalleryTitleStyle {
  final double fontSize;
  final bool bold;
  final Color? color;
  /// 文字阴影（原作 text-shadow: 0 1 1px #fff）
  final Shadow? textShadow;
  /// 上下 margin（em 值，原作 2em auto）
  final double marginTop;
  final double marginBottom;
  /// 字体族（原作 DK-XIAOBIAOSONG → serif）
  final String fontFamily;

  const _GalleryTitleStyle({
    this.fontSize = 1.5,
    this.bold = true,
    this.color,
    this.textShadow,
    this.marginTop = 2.0,
    this.marginBottom = 2.0,
    this.fontFamily = 'serif',
  });
}

class _GalleryTxtStyle {
  final double fontSize;
  final Color? color;
  /// 文字阴影（原作 text-shadow: 0 1 1px #fff）
  final Shadow? textShadow;
  /// 上下 margin（em 值，原作 1em auto）
  final double marginTop;
  final double marginBottom;
  /// 字体族（原作 DK-HEITI → sans-serif）
  final String fontFamily;

  const _GalleryTxtStyle({
    this.fontSize = 0.7,
    this.color,
    this.textShadow,
    this.marginTop = 1.0,
    this.marginBottom = 1.0,
    this.fontFamily = 'sans-serif',
  });
}

/// 解析 data: URI 为 Uint8List
Uint8List _parseDataUri(String dataUri) {
  final commaIdx = dataUri.indexOf(',');
  if (commaIdx < 0) return Uint8List(0);
  final base64Str = dataUri.substring(commaIdx + 1);
  return base64Decode(base64Str);
}
