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

  /// 阅读器基础字号（px），作为 EPUB CSS em 值的基准
  final double baseFontSize;

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
    this.baseFontSize = 18.0,
    this.chapterStyle,
    this.initialPageToEnd = false,
    required this.onPreviousChapter,
    required this.onNextChapter,
  });

  @override
  State<EpubGalleryPage> createState() => _EpubGalleryPageState();
}

class _EpubGalleryPageState extends State<EpubGalleryPage> {
  late final PageController _pageController;
  late final _GalleryCellStyle _cellStyle;
  late final _GalleryTitleStyle _titleStyle;
  late final _GalleryTxtStyle _txtStyle;
  int _currentIndex = 0;
  bool _isNavigating = false;

  @override
  void initState() {
    super.initState();
    final initialIdx =
        widget.initialPageToEnd ? widget.images.length - 1 : 0;
    _currentIndex = initialIdx;
    _pageController = PageController(initialPage: initialIdx);
    final rawCss = widget.chapterStyle?.rawCss ?? '';
    _cellStyle = _parseCellStyle(rawCss);
    _titleStyle = _parseTitleStyle(rawCss);
    _txtStyle = _parseTxtStyle(rawCss);
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
      subtitleMarginBottom: _parseMargin(subtitleBlock)?.$2 ?? 0.5,
      cellMarginVertical: _parseMarginPx(cellBlock)?.$1 ?? 10.0,
      maintitleFontSize: _parseFloat(maintitleBlock, 'font-size') ?? 0.9,
      subtitleFontSize: _parseFloat(subtitleBlock, 'font-size') ?? 0.9,
      subtitleLineHeight: _parseFloat(subtitleBlock, 'line-height') ?? 1.35,
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
          _currentIndex == widget.images.length - 1) {
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

    return Container(
      color: hasBgImage ? null : _resolveBgColor(),
      decoration: hasBgImage ? _buildBackgroundDecoration() : null,
      child: SafeArea(
        child: Column(
          children: [
            _buildGalleryTitle(),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  _handleEdgeScroll(notification);
                  return false;
                },
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: widget.images.length,
                  onPageChanged: _onPageChanged,
                  allowImplicitScrolling: true,
                  itemBuilder: (context, index) {
                    return _GalleryCell(
                      image: widget.images[index],
                      style: _cellStyle,
                      baseFontSize: widget.baseFontSize,
                      textColor: widget.textColor,
                      onTap: () => _showFullScreenPreview(index),
                    );
                  },
                ),
              ),
            ),
            _buildDottedIndicator(),
            _buildGalleryTxt(),
          ],
        ),
      ),
    );
  }

  /// 画廊标题（对齐原作 .gallery-title）
  /// 原作 CSS: margin: 2em auto; font-size: 1.5em; font-weight: bold;
  ///   text-align: center; text-shadow: 0 1 1px #fff
  Widget _buildGalleryTitle() {
    final title = widget.chapterStyle?.galleryTitle;
    if (title == null || title.isEmpty) return const SizedBox.shrink();

    final shadows = _titleStyle.textShadow != null
        ? [_titleStyle.textShadow!]
        : <Shadow>[];

    return Padding(
      padding: EdgeInsets.only(
        top: widget.baseFontSize * _titleStyle.marginTop,
        bottom: widget.baseFontSize * _titleStyle.marginBottom,
        left: 16,
        right: 16,
      ),
      child: Text(
        title,
        style: TextStyle(
          fontSize: widget.baseFontSize * _titleStyle.fontSize,
          fontWeight: _titleStyle.bold ? FontWeight.bold : FontWeight.normal,
          color: _titleStyle.color ?? widget.textColor,
          decoration: TextDecoration.none,
          shadows: shadows,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  /// 底部提示文本（对齐原作 .gallery-txt）
  /// 原作 CSS: margin: 1em auto; font-size: 0.7em; text-align: center;
  ///   text-shadow: 0 1 1px #fff
  Widget _buildGalleryTxt() {
    final txt = widget.chapterStyle?.galleryTxt;
    if (txt == null || txt.isEmpty) return const SizedBox.shrink();

    final shadows = _txtStyle.textShadow != null
        ? [_txtStyle.textShadow!]
        : <Shadow>[];

    return Padding(
      padding: EdgeInsets.only(
        top: widget.baseFontSize * _txtStyle.marginTop,
        bottom: widget.baseFontSize * _txtStyle.marginBottom,
        left: 16,
        right: 16,
      ),
      child: Text(
        txt,
        style: TextStyle(
          fontSize: widget.baseFontSize * _txtStyle.fontSize,
          color: _txtStyle.color ?? widget.textColor,
          decoration: TextDecoration.none,
          shadows: shadows,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  /// 点点点指示器（对齐多看 .dotted > span）
  Widget _buildDottedIndicator() {
    if (widget.images.length <= 1) return const SizedBox.shrink();

    final textRgb = widget.textColor.toARGB32();
    final r = (textRgb >> 16) & 0xFF;
    final g = (textRgb >> 8) & 0xFF;
    final b = textRgb & 0xFF;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(widget.images.length, (i) {
          final isActive = i == _currentIndex;
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
}

/// 单张图片单元格（对齐多看 .msg > .duokan-image-gallery-cell）
///
/// 原作 CSS：
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
  final double baseFontSize;
  final Color textColor;
  final VoidCallback onTap;

  const _GalleryCell({
    required this.image,
    required this.style,
    required this.baseFontSize,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        // 水平 24px 让内容不贴边；垂直用原作 cell margin（10px 0）
        padding: EdgeInsets.symmetric(
          horizontal: 24,
          vertical: style.cellMarginVertical,
        ),
        // ★ Center 松约束：PageView 页面是 tight 约束，若不加 Center，
        //   Column 子元素会被强制撑满页面宽度，边框/阴影框比图片大。
        //   加 Center 后约束变 loose，边框容器收缩到图片实际渲染宽度，
        //   修复「画廊 cell 外层框被放大」（f4eec31 回归丢失 3fdcbe2 修复）
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 图片（对齐 .gallery-pic img { width: 100% }，等比缩放）
              // 边框+阴影容器放 Flexible 内：宽度跟随图片实际渲染宽度，
              // 高度受剩余空间约束（FlexFit.loose），与 3fdcbe2 的
              // IntrinsicWidth 方案等价但更稳健（不依赖图片 intrinsic 计算）
              Flexible(
                fit: FlexFit.loose,
                child: Container(
                  // 原作 .duokan-image-gallery-cell 的 border + box-shadow
                  decoration: BoxDecoration(
                    border: Border.all(
                      width: style.borderWidth,
                      color: style.borderColor ?? const Color(0xFF000000),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: style.boxShadowColor ?? const Color(0xFF888888),
                        offset: Offset(style.boxShadowDx, style.boxShadowDy),
                        blurRadius: style.boxShadowBlur,
                      ),
                    ],
                  ),
                  child: ClipRect(
                    child: _buildImage(),
                  ),
                ),
              ),
              // maintitle（对齐 .duokan-image-maintitle）
              // 原作 margin: 1em auto -0.5em auto：
              // - top 1em：与图片之间 1em 间距
              // - bottom -0.5em：与 subtitle 减少 0.5em 间距（Flutter 用
              //   subtitle top=0 近似：maintitle bottom=0 + subtitle top=0
              //   = 零间距，近似 -0.5em 的紧凑效果）
              if (image.maintitle.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(
                    top: baseFontSize * style.maintitleMarginTop,
                    bottom: 0,
                    left: 12,
                    right: 12,
                  ),
                  child: Text(
                    image.maintitle,
                    style: TextStyle(
                      fontSize: baseFontSize * style.maintitleFontSize,
                      color: style.maintitleColor,
                      decoration: TextDecoration.none,
                      height: 1.2,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              // subtitle（对齐 .duokan-image-subtitle）
              // 原作无 margin，紧接 maintitle（maintitle 负下 margin 效果）
              if (image.subtitle.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(
                    top: 0,
                    bottom: baseFontSize * style.subtitleMarginBottom,
                    left: 12,
                    right: 12,
                  ),
                  child: Text(
                    image.subtitle,
                    style: TextStyle(
                      fontSize: baseFontSize * style.subtitleFontSize,
                      color: style.subtitleColor,
                      height: style.subtitleLineHeight,
                      decoration: TextDecoration.none,
                    ),
                    textAlign: TextAlign.justify,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImage() {
    final src = image.src;
    // ★ 不能设 width: double.infinity：会把图片强制拉满父容器宽度，
    //   导致边框框比图片大（外层框放大）。不设宽度时 Image 按
    //   RenderImage._sizeForConstraints 以自然尺寸渲染，受外层
    //   loose 约束（maxWidth/maxHeight）等比缩放，边框框紧贴图片。
    if (src.startsWith('data:')) {
      return Image.memory(
        _parseDataUri(src),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) =>
            _buildErrorWidget(),
      );
    }
    return Image.file(
      File(src),
      fit: BoxFit.contain,
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
  /// subtitle 下 margin（em 值，原作无 margin，默认 0.5em 收尾间距）
  final double subtitleMarginBottom;
  /// cell 上下 margin（px 值，原作 10px 0）
  final double cellMarginVertical;
  /// maintitle 字号（em 值，原作 0.9em）
  final double maintitleFontSize;
  /// subtitle 字号（em 值，原作 0.9em）
  final double subtitleFontSize;
  /// subtitle 行高（原作 1.35em）
  final double subtitleLineHeight;

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
    this.subtitleMarginBottom = 0.5,
    this.cellMarginVertical = 10.0,
    this.maintitleFontSize = 0.9,
    this.subtitleFontSize = 0.9,
    this.subtitleLineHeight = 1.35,
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

  const _GalleryTitleStyle({
    this.fontSize = 1.5,
    this.bold = true,
    this.color,
    this.textShadow,
    this.marginTop = 2.0,
    this.marginBottom = 2.0,
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

  const _GalleryTxtStyle({
    this.fontSize = 0.7,
    this.color,
    this.textShadow,
    this.marginTop = 1.0,
    this.marginBottom = 1.0,
  });
}

/// 解析 data: URI 为 Uint8List
Uint8List _parseDataUri(String dataUri) {
  final commaIdx = dataUri.indexOf(',');
  if (commaIdx < 0) return Uint8List(0);
  final base64Str = dataUri.substring(commaIdx + 1);
  return base64Decode(base64Str);
}
