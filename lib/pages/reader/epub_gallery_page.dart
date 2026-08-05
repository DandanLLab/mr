import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/local_book/epub_parser.dart';
import '../../utils/design_tokens.dart';

/// EPUB 多看画廊页面渲染器
///
/// 用于渲染含 `.duokan-image-gallery` 的章节。这类章节原本是多看阅读器的
/// 横向滑动画廊，标准 EPUB 阅读器无法用 column 分页正确处理，改由 Flutter
/// PageView 接管，每页展示一张图片及其标题/副标题。
///
/// 设计要点：
/// - PageView.builder 横向滑动，每页一张图（BoxFit.contain）
/// - 点击图片弹出全屏预览（InteractiveViewer 支持双指缩放）
/// - 滑到第一张继续往前 → onPreviousChapter 回调
/// - 滑到最后一张继续往后 → onNextChapter 回调
/// - 图片 src 支持两种形式：
///   - 本地绝对路径（解压模式）：用 Image.file
///   - data: URI（内嵌模式）：用 Image.memory 解析 base64
class EpubGalleryPage extends StatefulWidget {
  final List<EpubGalleryImage> images;
  final String chapterTitle;
  final Color backgroundColor;
  final Color textColor;

  /// 阅读器基础字号（px），作为 EPUB CSS em 值的基准
  /// 原作者 CSS 用 em 单位（如 font-size: 1.5em），em 相对当前字号，
  /// 这里传入阅读器的 provider.fontSize 让 em 计算与阅读器一致
  final double baseFontSize;

  /// 画廊章节级样式（背景图、gallery-title、cell 边框阴影、gallery-txt 等）
  /// 从 EPUB CSS 提取，null 时用兜底样式（白底 + 无标题）
  final EpubGalleryChapterStyle? chapterStyle;

  /// 是否从章节末尾进入（用于从下一章往前翻到本章最后一页）
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
  late PageController _pageController;
  late int _currentIndex;
  bool _isNavigating = false; // 防止章节切换重复触发

  // 边界章节切换手势追踪（指针级，不参与手势竞技场）
  // PageView 会消费水平拖动手势，外层 GestureDetector.onHorizontalDragEnd
  // 在边界回弹时不触发，改用 Listener 监听原始指针事件判断边界拖动意图
  Offset? _dragStartPosition;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialPageToEnd && widget.images.isNotEmpty
        ? widget.images.length - 1
        : 0;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
    // 章节边界衔接：滑到首张往前一章、滑到末张往后一章
    if (index == 0 && widget.images.length > 1) {
      // 已在第一张，用户继续往前滑（PageView 会回弹，但记录意图）
      // 实际触发时机：在第一张再次尝试往左滑
    }
  }

  /// 用户在第一页继续往前滑（手势结束时检测）
  void _handlePreviousBoundary() {
    if (_isNavigating) return;
    if (_currentIndex == 0) {
      _isNavigating = true;
      widget.onPreviousChapter();
    }
  }

  /// 用户在最后一页继续往后滑（手势结束时检测）
  void _handleNextBoundary() {
    if (_isNavigating) return;
    if (_currentIndex == widget.images.length - 1) {
      _isNavigating = true;
      widget.onNextChapter();
    }
  }

  /// 点击图片弹出全屏预览
  ///
  /// 进入动画：ScaleTransition(0.85→1.0) + FadeTransition，配合 Hero 图片过渡，
  /// 让图片从画廊小图平滑放大到全屏大图。
  ///
  /// 全屏预览支持：
  /// - PageView 横向滑动切换图片（预加载相邻图片避免白屏）
  /// - InteractiveViewer 双指缩放（1-4x）+ 拖动查看细节
  /// - 右下角信息面板（AnimatedSwitcher 淡入淡出 + 上滑动画）
  /// - 双击切换缩放（1.0 ↔ 2.5）
  /// - Hero 动画：图片从小图放大到全屏的平滑过渡
  void _showFullScreenPreview(int initialIndex) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        // 进入 300ms（比默认 200ms 稍慢，让 Hero + Scale 动画更丝滑）
        // 退出 250ms（退出稍快，避免拖沓）
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (context, animation, secondaryAnimation) {
          return _GalleryFullScreenViewer(
            images: widget.images,
            initialIndex: initialIndex,
            baseFontSize: widget.baseFontSize,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // Scale + Fade 组合：图片从 0.92 缩放到 1.0，同时淡入
          // 配合 Hero 动画，视觉上是"图片从小变大展开"的效果
          final scaleAnimation = Tween<double>(
            begin: 0.92,
            end: 1.0,
          ).animate(CurvedAnimation(
            parent: animation,
            // easeOutCubic：开始快、结束慢，符合自然减速感
            curve: Curves.easeOutCubic,
          ));
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: scaleAnimation,
              child: child,
            ),
          );
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

    // 还原作者排版：背景图铺底 + gallery-title 顶部 + PageView 主体 + gallery-txt 底部
    // 原作者 gallery.xhtml 结构：
    //   <body class="video-bg">
    //     <h3 class="gallery-title">画廊图</h3>
    //     <div class="duokan-image-gallery gallery-pic">...cells...</div>
    //     <p class="gallery-txt">滑动切换，点击放大</p>
    //   </body>
    // 这里用 Stack 铺背景图，Column 放标题/PageView/底部文字，1:1 还原
    return Stack(
      children: [
        // 背景层：原作者 .video-bg 的 background-image: cover
        Positioned.fill(child: _buildBackground()),
        // 内容层：SafeArea + 标题 + PageView + 底部提示
        SafeArea(
          child: Column(
            children: [
              if (_hasGalleryTitle()) _buildGalleryTitle(),
              Expanded(child: _buildPageView()),
              if (_hasGalleryTxt()) _buildGalleryTxt(),
              _buildPageIndicator(),
            ],
          ),
        ),
      ],
    );
  }

  /// 解析背景色：优先用 chapterStyle.backgroundColor，否则用阅读器 backgroundColor
  Color _resolveBgColor() {
    final bgClr = widget.chapterStyle?.backgroundColor;
    if (bgClr != null) return Color(bgClr);
    return widget.backgroundColor;
  }

  /// 构建背景层：还原作者 .video-bg 的 background-image: url(...) cover
  /// - 有背景图：Image.cover 铺满全屏
  /// - 无背景图但有背景色：纯色容器
  /// - 都无：阅读器背景色
  Widget _buildBackground() {
    final bgSrc = widget.chapterStyle?.backgroundImageSrc;
    final bgClr = widget.chapterStyle?.backgroundColor;

    // 有背景图：铺满全屏（cover 模式，对齐原作者 background-size: cover）
    if (bgSrc != null && bgSrc.isNotEmpty) {
      return _buildBgImage(bgSrc);
    }
    // 无背景图但有背景色：纯色
    if (bgClr != null) {
      return ColoredBox(color: Color(bgClr), child: const SizedBox.expand());
    }
    // 都无：阅读器背景色
    return ColoredBox(
      color: widget.backgroundColor,
      child: const SizedBox.expand(),
    );
  }

  /// 构建背景图（支持 file:// / 绝对路径 / data: URI）
  Widget _buildBgImage(String src) {
    final fit = widget.chapterStyle?.backgroundSize == 'contain'
        ? BoxFit.contain
        : BoxFit.cover;
    if (src.startsWith('data:')) {
      final bytes = _decodeDataUri(src);
      if (bytes != null) {
        return Image.memory(bytes, fit: fit, gaplessPlayback: true);
      }
      return ColoredBox(color: _resolveBgColor(), child: const SizedBox.expand());
    }
    final filePath = src.startsWith('file://') ? src.substring(7) : src;
    if (filePath.contains('/') || filePath.contains('\\')) {
      return Image.file(
        File(filePath),
        fit: fit,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => ColoredBox(
          color: _resolveBgColor(),
          child: const SizedBox.expand(),
        ),
      );
    }
    return Image.network(
      src,
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => ColoredBox(
        color: _resolveBgColor(),
        child: const SizedBox.expand(),
      ),
    );
  }

  /// 是否有 gallery-title（原作者 .gallery-title 标签文本）
  bool _hasGalleryTitle() {
    final title = widget.chapterStyle?.galleryTitle;
    return title != null && title.isNotEmpty;
  }

  /// 构建 gallery-title：还原作者 <h3 class="gallery-title"> 样式
  /// 原作者 CSS：font-family h3, font-weight bold, font-size 1.5em,
  /// text-align center, text-shadow 0 1 1px #fff, margin 2em auto
  Widget _buildGalleryTitle() {
    final style = widget.chapterStyle?.galleryTitleStyle;
    final baseFontSize = widget.baseFontSize;
    // 字号优先级：fontSizePx（原作者 px 绝对值）> fontSizeEm > 兜底 1.5em
    final fontSize = _resolveFontSize(
      style,
      baseFontSize: baseFontSize,
      defaultEm: 1.5,
    );
    // 浅色背景用深色文字，深色背景用浅色文字（兜底）
    final isLightBg = _isLightBg(widget.textColor);
    final color = style?.color != null
        ? Color(style!.color!)
        : (isLightBg ? const Color(0xFF1A1A1A) : widget.textColor);
    final fontWeight = style?.fontWeight != null
        ? FontWeight.values[(style!.fontWeight! / 100).round().clamp(0, 8)]
        : FontWeight.bold;
    final height = style?.lineHeight ?? 1.2;
    // margin: 2em auto → 上下各 2em（相对 baseFontSize）
    const marginEm = 2.0;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: DesignTokens.spacingMd,
        vertical: marginEm * baseFontSize,
      ),
      child: Text(
        widget.chapterStyle!.galleryTitle!,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
          height: height,
          shadows: const [
            Shadow(offset: Offset(0, 1), blurRadius: 1, color: Colors.white54),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: _resolveTextAlign(style?.textAlign, TextAlign.center),
      ),
    );
  }

  /// 是否有 gallery-txt（原作者 .gallery-txt 标签文本）
  bool _hasGalleryTxt() {
    final txt = widget.chapterStyle?.galleryTxt;
    return txt != null && txt.isNotEmpty;
  }

  /// 构建 gallery-txt：还原作者 <p class="gallery-txt"> 样式
  /// 原作者 CSS：font-family ht, font-size 0.7em, text-align center,
  /// text-indent 0, text-shadow 0 1 1px #fff, margin 1em auto
  Widget _buildGalleryTxt() {
    final style = widget.chapterStyle?.galleryTxtStyle;
    final baseFontSize = widget.baseFontSize;
    // 字号优先级：fontSizePx（原作者 px 绝对值）> fontSizeEm > 兜底 0.7em
    final fontSize = _resolveFontSize(
      style,
      baseFontSize: baseFontSize,
      defaultEm: 0.7,
    );
    final isLightBg = _isLightBg(widget.textColor);
    final color = style?.color != null
        ? Color(style!.color!)
        : (isLightBg ? const Color(0xFF1A1A1A) : widget.textColor);
    final fontWeight = style?.fontWeight != null
        ? FontWeight.values[(style!.fontWeight! / 100).round().clamp(0, 8)]
        : FontWeight.w400;
    final height = style?.lineHeight ?? 1.5;
    // margin: 1em auto → 上下各 1em（相对 baseFontSize）
    const marginEm = 1.0;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: DesignTokens.spacingMd,
        vertical: marginEm * baseFontSize,
      ),
      child: Text(
        widget.chapterStyle!.galleryTxt!,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
          height: height,
          shadows: const [
            Shadow(offset: Offset(0, 1), blurRadius: 1, color: Colors.white54),
          ],
        ),
        textAlign: _resolveTextAlign(style?.textAlign, TextAlign.center),
      ),
    );
  }

  /// 页码指示器：点点点（N 张图 N 个点，当前页高亮）
  ///
  /// 横向排列 N 个圆点，当前页用深色高亮，其他页用浅色半透明。
  /// 点点宽度 6px、间距 6px，紧凑不占太多底部空间。
  /// 配合 gallery-txt 的 text-shadow 风格（0 1 1px #fff）让点在背景图上清晰可见。
  Widget _buildPageIndicator() {
    const dotSize = 6.0;
    const dotSpacing = 6.0;
    final isLightBg = _isLightBg(widget.textColor);
    final activeColor = isLightBg
        ? const Color(0xFF1A1A1A)
        : widget.textColor.withValues(alpha: 0.9);
    final inactiveColor = widget.textColor.withValues(alpha: 0.3);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DesignTokens.spacingMd,
        vertical: DesignTokens.spacingXs,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: List.generate(widget.images.length, (i) {
          final isActive = i == _currentIndex;
          return Container(
            margin: EdgeInsets.symmetric(
              horizontal: i == 0 || i == widget.images.length - 1
                  ? 0
                  : dotSpacing / 2,
            ),
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              color: isActive ? activeColor : inactiveColor,
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(
                  offset: Offset(0, 1),
                  blurRadius: 1,
                  color: Colors.white54,
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  /// 解析原作者 CSS 字号为 Flutter fontSize（px）
  ///
  /// 优先级（高 → 低）：
  /// 1. fontSizePx（原作者明确写 px，绝对值直接用，不缩放）
  /// 2. fontSizeEm * baseFontSize（em 相对单位，跟随阅读器字号）
  /// 3. defaultEm * baseFontSize（兜底值）
  ///
  /// 设计意图：原作者明确设定的字号属于高优先级契约，应严格保留。
  /// px 值不被 baseFontSize 二次缩放，避免 16px 被阅读器字号 18 渲染成 18px。
  double _resolveFontSize(
    EpubGalleryTextStyle? style, {
    required double baseFontSize,
    required double defaultEm,
  }) {
    if (style?.fontSizePx != null) {
      return style!.fontSizePx!;
    }
    final em = style?.fontSizeEm ?? defaultEm;
    return em * baseFontSize;
  }

  /// 将 CSS text-align 值转为 Flutter TextAlign
  TextAlign _resolveTextAlign(String? cssAlign, TextAlign fallback) {
    switch (cssAlign) {
      case 'left':
        return TextAlign.left;
      case 'right':
        return TextAlign.right;
      case 'justify':
        return TextAlign.justify;
      case 'center':
        return TextAlign.center;
      default:
        return fallback;
    }
  }

  /// 判断当前背景是否为浅色（用于决定兜底文字色）
  bool _isLightBg(Color textColor) {
    // textColor 是阅读器的文字色，浅色背景 → 深色文字 → luminance 低
    return textColor.computeLuminance() < 0.5;
  }

  /// 主体：PageView 横向滑动
  ///
  /// 边界章节切换用 Listener（指针级）而非 GestureDetector：
  /// PageView 会赢得水平拖动手势竞技场，外层 GestureDetector.onHorizontalDragEnd
  /// 在边界回弹时不触发，导致"翻到底无法切下一章"。Listener 不参与竞技场，
  /// 始终能收到指针事件，通过位移+速度判断边界拖动意图。
  Widget _buildPageView() {
    return Listener(
      onPointerDown: (event) {
        _dragStartPosition = event.position;
      },
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerUp,
      child: PageView.builder(
        // AlwaysScrollableScrollPhysics：让边界处也能产生 overscroll，
        // 配合 Listener 检测边界拖动（PageView 回弹不影响指针位移计算）
        physics: const AlwaysScrollableScrollPhysics(),
        controller: _pageController,
        itemCount: widget.images.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          final image = widget.images[index];
          return _GalleryImageItem(
            image: image,
            index: index,
            textColor: widget.textColor,
            baseFontSize: widget.baseFontSize,
            chapterStyle: widget.chapterStyle,
            onTap: () => _showFullScreenPreview(index),
          );
        },
      ),
    );
  }

  /// 指针抬起时判断边界章节切换意图
  ///
  /// 判断条件（同时满足）：
  /// 1. 当前在第一页（或最后一页）
  /// 2. 拖动方向正确：第一页向右滑（dx>0）→ 上一章；最后一页向左滑（dx<0）→ 下一章
  /// 3. 水平位移占主导（|dx| > |dy|），避免纵向滚动误触
  /// 4. 拖动位移 ≥ 阈值（50px），避免点击/小幅拖动误触
  ///
  /// 不用速度判断：PointerUp 时速度计算不稳定（dt 接近 0），
  /// 且用户在边界回弹后松手也应触发切章。
  void _handlePointerUp(PointerEvent event) {
    final start = _dragStartPosition;
    _dragStartPosition = null;

    if (start == null) return;

    final dx = event.position.dx - start.dx;
    final dy = event.position.dy - start.dy;

    const distanceThreshold = 50.0;

    // 水平位移必须占主导（避免纵向滚动误触）
    if (dx.abs() <= dy.abs()) return;

    // 第一页向右滑（dx > 0）→ 上一章
    if (_currentIndex == 0 && dx > distanceThreshold) {
      _handlePreviousBoundary();
      return;
    }
    // 最后一页向左滑（dx < 0）→ 下一章
    if (_currentIndex == widget.images.length - 1 &&
        dx < -distanceThreshold) {
      _handleNextBoundary();
      return;
    }
  }

  /// 解码 data: URI 为字节（用于背景图 data URI）
  Uint8List? _decodeDataUri(String dataUri) {
    try {
      final commaIdx = dataUri.indexOf(',');
      if (commaIdx < 0) return null;
      return base64Decode(dataUri.substring(commaIdx + 1));
    } catch (_) {
      return null;
    }
  }
}

/// 单张画廊图片 item
///
/// 非全屏模式下的画廊图片展示。标题样式对齐原作者 CSS：
/// - maintitle: 黑体风格、90% 字号、#1F4150 色、居中、margin-top 1em
/// - subtitle: 细黑体风格、70% 字号、#3A3348 色、居中、margin-top 1em
///
/// 图片用 Hero 包裹（tag: gallery_image_$index），与全屏预览的 Hero 配对，
/// 实现点击图片时从小图平滑放大到全屏大图的过渡动画。
class _GalleryImageItem extends StatelessWidget {
  final EpubGalleryImage image;
  final int index;
  final Color textColor;
  final VoidCallback onTap;

  /// 阅读器基础字号（px），作为 EPUB CSS em 值的基准
  final double baseFontSize;

  /// 画廊章节级样式（用于 cell 边框/阴影/margin 装饰）
  final EpubGalleryChapterStyle? chapterStyle;

  const _GalleryImageItem({
    required this.image,
    required this.index,
    required this.textColor,
    required this.onTap,
    this.baseFontSize = 18.0,
    this.chapterStyle,
  });

  @override
  Widget build(BuildContext context) {
    final hasTitle =
        image.maintitle.isNotEmpty || image.subtitle.isNotEmpty;
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        // cell 外边距：还原作者 .duokan-image-gallery-cell { margin: 10px 0 }
        // 默认上下 10px（对齐原作者），左右保留设计间距让图片不贴边
        padding: EdgeInsets.symmetric(
          horizontal: DesignTokens.spacingMd,
          vertical: chapterStyle?.cellMargin ?? 10.0,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 图片最大高度：可用高度的 75%（有标题时）或 90%（无标题时）
            // 避免图片 contain 后撑满整个空间，留出标题和呼吸空间
            final maxImgHeight = constraints.maxHeight * (hasTitle ? 0.75 : 0.9);
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxImgHeight),
                  child: _buildCellWithDecoration(),
                ),
                if (hasTitle) ...[
                  // maintitle：还原作者 margin: 1em auto -0.5em auto
                  // 上方间距 = marginTopEm * baseFontSize（兜底 1em，对齐原作者）
                  if (image.maintitle.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(
                        top: (image.maintitleStyle?.marginTopEm ?? 1.0) *
                            baseFontSize,
                      ),
                      child: Text(
                        image.maintitle,
                        style: _buildMaintitleStyle(),
                        textAlign: _resolveTextAlign(
                          image.maintitleStyle?.textAlign,
                          TextAlign.center,
                        ),
                      ),
                    ),
                  // subtitle：相对 maintitle 的净间距 = maintitleMarginBottom + subtitleMarginTop
                  // 原作者 maintitle marginBottom=-0.5em + subtitle marginTop=0.5em(继承 p) → 净间距 0
                  // 负净间距用 Transform.translate 视觉上移（重叠 maintitle 底部），
                  // 正净间距用 Padding 顶间距
                  if (image.subtitle.isNotEmpty) _buildSubtitleWithMargin(),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// 构建 cell 容器（带原作者 border + box-shadow 装饰）
  ///
  /// 原作者 CSS：.duokan-image-gallery-cell {
  ///   margin: 10px 0; border-style: solid; border-width: 1px;
  ///   box-shadow: 5px 5px 5px #888888 }
  /// .duokan-image-gallery { text-align: center } → cell 水平居中
  ///
  /// 兜底策略：chapterStyle 为 null（非画廊章节或提取失败）时不加装饰；
  /// 否则用提取值，缺失字段用原作者默认值兜底（1px solid + 5px 5px 5px #888888）。
  /// 原作者 cell 未写 border-color，CSS 默认 currentColor（黑色），故兜底用黑。
  ///
  /// 自适应方案：用 IntrinsicWidth 让 cell 宽度紧贴图片实际渲染宽度，
  /// 而不是撑满父容器宽度。这样边框和阴影紧贴图片，1:1 还原作者 cell 装饰。
  Widget _buildCellWithDecoration() {
    final cs = chapterStyle;
    // chapterStyle 为 null（非画廊章节或提取失败）时不加 cell 装饰
    if (cs == null) {
      return Center(child: _buildImage());
    }

    // 兜底值对齐原作者 .duokan-image-gallery-cell 默认样式：
    // border-style: solid; border-width: 1px（无 border-color → currentColor 默认黑）
    // box-shadow: 5px 5px 5px #888888
    final borderWidth = cs.cellBorderWidth ?? 1.0;
    final borderColor = cs.cellBorderColor ?? 0xFF000000; // currentColor 默认黑
    final borderStyle = cs.cellBorderStyle ?? 'solid';
    final shadowColor = cs.cellShadowColor ?? 0xFF888888;
    final shadowDx = cs.cellShadowDx ?? 5.0;
    final shadowDy = cs.cellShadowDy ?? 5.0;
    final shadowBlur = cs.cellShadowBlur ?? 5.0;
    final hasBorder = borderWidth > 0;
    final hasRadius = cs.cellBorderRadius != null && cs.cellBorderRadius! > 0;

    // IntrinsicWidth 让 cell 宽度跟随图片实际渲染宽度（contain 后的宽度）
    // 配合外层 ConstrainedBox(maxHeight) 约束图片高度，图片宽度按比例自适应
    return Center(
      child: IntrinsicWidth(
        child: Container(
          // alignment 让图片在 cell 内居中
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: hasBorder
                ? Border.all(
                    color: Color(borderColor),
                    width: borderWidth,
                    style: _resolveBorderStyle(borderStyle),
                  )
                : null,
            borderRadius:
                hasRadius ? BorderRadius.circular(cs.cellBorderRadius!) : null,
            boxShadow: [
              BoxShadow(
                color: Color(shadowColor).withValues(alpha: 0.5),
                offset: Offset(shadowDx, shadowDy),
                blurRadius: shadowBlur,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius:
                hasRadius ? BorderRadius.circular(cs.cellBorderRadius!) : BorderRadius.zero,
            child: _buildImage(),
          ),
        ),
      ),
    );
  }

  /// 将 CSS border-style 值转为 Flutter BorderStyle
  BorderStyle _resolveBorderStyle(String? cssStyle) {
    switch (cssStyle) {
      case 'dashed':
        return BorderStyle.solid; // Flutter 不支持 dashed，退化为 solid
      case 'dotted':
        return BorderStyle.solid;
      case 'none':
        return BorderStyle.none;
      default:
        return BorderStyle.solid;
    }
  }

  /// 构建 maintitle 的 TextStyle
  ///
  /// 优先使用从 EPUB CSS 提取的原作者样式，缺失字段用兜底值（对齐原作者
  /// .duokan-image-maintitle 默认样式：#336633 深绿、0.9em、DK-HEITI 黑体、居中）。
  /// 字号优先级：fontSizePx（原作者 px 绝对值）> fontSizeEm > 兜底 0.9em。
  TextStyle _buildMaintitleStyle() {
    final style = image.maintitleStyle;
    final baseFontSize = this.baseFontSize;
    // 字号：fontSizePx 优先（原作者 px 高优先级契约），否则 fontSizeEm，再否则兜底 0.9em
    final fontSize = _resolveFontSize(
      style,
      baseFontSize: baseFontSize,
      defaultEm: 0.9,
    );
    // 兜底：#336633（原作者 maintitle color: #336633，深绿色）
    // 仅当 EPUB 未提取到 color 且阅读器为深色背景时，才用阅读器 textColor 保证可读性
    final color = style?.color != null
        ? Color(style!.color!)
        : (_isLightBg(textColor)
            ? const Color(0xFF336633)
            : textColor);
    // 字重：提取值优先，否则按 font-family 关键词映射（DK-HEITI→w700），再否则兜底 w700
    final fontWeight = _resolveFontWeight(
      style?.fontWeight, style?.fontFamily, FontWeight.w700,
    );
    // 兜底：1.5（原作者 maintitle 未写 line-height，继承 p 的 1.5em）
    final height = style?.lineHeight ?? 1.5;

    return TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: height,
    );
  }

  /// 构建 subtitle 的 TextStyle
  ///
  /// 优先使用从 EPUB CSS 提取的原作者样式，缺失字段用兜底值（对齐原作者
  /// .duokan-image-subtitle 默认样式：#333 深灰、0.9em、DK-KAITI 楷体、justify、1.35em 行高）
  /// 字号优先级：fontSizePx（原作者 px 绝对值）> fontSizeEm > 兜底 0.9em。
  TextStyle _buildSubtitleStyle() {
    final style = image.subtitleStyle;
    final baseFontSize = this.baseFontSize;
    // 字号：fontSizePx 优先（原作者 px 高优先级契约），否则 fontSizeEm，再否则兜底 0.9em
    final fontSize = _resolveFontSize(
      style,
      baseFontSize: baseFontSize,
      defaultEm: 0.9,
    );
    // 兜底：#333333（原作者 subtitle color: #333，深灰色）
    final color = style?.color != null
        ? Color(style!.color!)
        : (_isLightBg(textColor)
            ? const Color(0xFF333333)
            : textColor.withValues(alpha: 0.85));
    // 字重：提取值优先，否则按 font-family 映射（DK-KAITI→w400），再否则兜底 w400
    final fontWeight = _resolveFontWeight(
      style?.fontWeight, style?.fontFamily, FontWeight.w400,
    );
    // 兜底：1.35（原作者 subtitle line-height: 1.35em）
    final height = style?.lineHeight ?? 1.35;

    return TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: height,
    );
  }

  /// 根据提取的 font-weight 和 font-family 解析 Flutter FontWeight
  ///
  /// 优先用提取的 font-weight；若未提取到，则按 font-family 关键词映射
  /// （HEITI/黑体/BIAOSONG/标宋 → w700，KAITI/楷体 → w400），近似还原
  /// 多看字体的视觉字重（Flutter 无法直接加载 DK-HEITI 等多看字体）。
  FontWeight _resolveFontWeight(
    int? fontWeight, String? fontFamily, FontWeight fallback,
  ) {
    if (fontWeight != null) {
      return FontWeight.values[(fontWeight / 100).round().clamp(0, 8)];
    }
    final ff = fontFamily?.toUpperCase() ?? '';
    if (ff.contains('HEITI') ||
        ff.contains('黑体') ||
        ff.contains('BIAOSONG') ||
        ff.contains('标宋')) {
      return FontWeight.w700;
    }
    if (ff.contains('KAITI') || ff.contains('楷体')) {
      return FontWeight.w400;
    }
    return fallback;
  }

  /// 解析原作者 CSS 字号为 Flutter fontSize（px）
  ///
  /// 优先级（高 → 低）：
  /// 1. fontSizePx（原作者明确写 px，绝对值直接用，不缩放）—— 高优先级契约
  /// 2. fontSizeEm * baseFontSize（em 相对单位，跟随阅读器字号）
  /// 3. defaultEm * baseFontSize（兜底值）
  double _resolveFontSize(
    EpubGalleryTextStyle? style, {
    required double baseFontSize,
    required double defaultEm,
  }) {
    if (style?.fontSizePx != null) {
      return style!.fontSizePx!;
    }
    final em = style?.fontSizeEm ?? defaultEm;
    return em * baseFontSize;
  }

  /// 构建 subtitle，并应用 maintitle 负下边距 + subtitle 上边距的净间距
  ///
  /// 还原作者 CSS margin 折叠效果：
  /// - maintitle margin-bottom: -0.5em（负值，让下方元素上移重叠）
  /// - subtitle margin-top: 0.5em（继承 p，正值）
  /// - 净间距 = -0.5 + 0.5 = 0（maintitle 与 subtitle 紧贴）
  ///
  /// Flutter Padding 不支持负值，负净间距用 Transform.translate 视觉上移实现。
  /// Transform.translate 负偏移让 subtitle 视觉重叠 maintitle 底部，符合原作者负 margin 意图。
  Widget _buildSubtitleWithMargin() {
    final maintitleMb = image.maintitleStyle?.marginBottomEm ?? -0.5;
    final subtitleMt = image.subtitleStyle?.marginTopEm ?? 0.5;
    final netOffsetEm = maintitleMb + subtitleMt;

    final subtitleWidget = Text(
      image.subtitle,
      style: _buildSubtitleStyle(),
      // 兜底 justify（原作者 .duokan-image-subtitle text-align: justify）
      textAlign: _resolveTextAlign(
        image.subtitleStyle?.textAlign,
        TextAlign.justify,
      ),
    );

    if (netOffsetEm < 0) {
      // 负净间距：subtitle 视觉上移，重叠 maintitle 底部（还原负 margin 效果）
      return Transform.translate(
        offset: Offset(0, netOffsetEm * baseFontSize),
        child: subtitleWidget,
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: netOffsetEm * baseFontSize),
      child: subtitleWidget,
    );
  }

  /// 将 CSS text-align 值转为 Flutter TextAlign
  TextAlign _resolveTextAlign(String? cssAlign, TextAlign fallback) {
    switch (cssAlign) {
      case 'left':
        return TextAlign.left;
      case 'right':
        return TextAlign.right;
      case 'justify':
        return TextAlign.justify;
      case 'center':
        return TextAlign.center;
      default:
        return fallback;
    }
  }

  /// 判断当前背景是否为浅色（用于决定兜底文字色）
  bool _isLightBg(Color textColor) {
    // textColor 是阅读器的文字色，浅色背景 → 深色文字 → luminance 低
    // 深色背景 → 浅色文字 → luminance 高
    // 所以 textColor luminance 低 = 浅色背景 = 用原作者深色
    return textColor.computeLuminance() < 0.5;
  }

  /// 构建图片，用 Hero 包裹实现全屏过渡动画
  Widget _buildImage() {
    return Hero(
      tag: 'gallery_image_$index',
      child: _buildRawImage(),
    );
  }

  /// 根据图片 src 类型选择渲染方式
  Widget _buildRawImage() {
    final src = image.src;
    if (src.startsWith('data:')) {
      final bytes = _decodeDataUri(src);
      if (bytes != null) {
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        );
      }
      return _buildError();
    }
    final filePath = src.startsWith('file://') ? src.substring(7) : src;
    if (filePath.contains('/') || filePath.contains('\\')) {
      return Image.file(
        File(filePath),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _buildError(),
      );
    }
    return Image.network(
      src,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => _buildError(),
    );
  }

  Uint8List? _decodeDataUri(String dataUri) {
    try {
      final commaIdx = dataUri.indexOf(',');
      if (commaIdx < 0) return null;
      final base64Data = dataUri.substring(commaIdx + 1);
      return base64Decode(base64Data);
    } catch (_) {
      return null;
    }
  }

  Widget _buildError() {
    return Container(
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_outlined,
        size: 48,
        color: textColor.withValues(alpha: 0.4),
      ),
    );
  }
}

/// 全屏预览查看器
///
/// 支持多图横向滑动切换 + 双指缩放 + 拖动查看细节。
///
/// 交互设计：
/// - PageView 横向滑动切换图片（scale == 1.0 时启用）
///   - BouncingScrollPhysics：iOS 风格弹性滑动，更顺滑
///   - 预加载相邻图片：initState 中 precacheImage 前后图片
///   - KeepAlive：子页面保持状态，避免重建和重新解码
/// - InteractiveViewer 双指缩放（1-4x）+ 拖动查看细节（scale > 1.0 时）
/// - 双击切换缩放（1.0 ↔ 2.5x），缩放后双击复位
/// - Hero 动画：当前页图片用 Hero 包裹，与画廊页 Hero 配对
///   - 只有当前页有 Hero，避免与画廊页多个 Hero tag 冲突
/// - 右下角信息面板（AnimatedSwitcher 淡入淡出 + 上滑动画）
///   - easeInOutCubicEmphasized：更柔和的动画曲线
///   - 大标题：18px FontWeight.w600
///   - 副标题：13px FontWeight.w400 半透明
/// - 顶部页码指示器 + 关闭按钮
class _GalleryFullScreenViewer extends StatefulWidget {
  final List<EpubGalleryImage> images;
  final int initialIndex;

  /// 阅读器基础字号（px），作为 EPUB CSS em 值的基准
  final double baseFontSize;

  const _GalleryFullScreenViewer({
    required this.images,
    required this.initialIndex,
    this.baseFontSize = 18.0,
  });

  @override
  State<_GalleryFullScreenViewer> createState() =>
      _GalleryFullScreenViewerState();
}

class _GalleryFullScreenViewerState extends State<_GalleryFullScreenViewer> {
  late PageController _pageController;
  late TransformationController _transformCtrl;
  int _currentIndex = 0;
  double _currentScale = 1.0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _transformCtrl = TransformationController();
    // 预加载相邻图片，避免滑动时白屏等待
    _precacheAdjacentImages(_currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _transformCtrl.dispose();
    super.dispose();
  }

  /// 预加载相邻图片（前一张和后一张）
  ///
  /// 在切换页面前预先解码图片，滑动时直接显示已缓存的图片，
  /// 避免白屏等待。使用 WidgetsBinding.instance.addPostFrameCallback
  /// 确保在帧绘制后执行，不阻塞当前帧。
  void _precacheAdjacentImages(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = this.context;
      // 前一张
      if (index > 0) {
        final provider = _getImageProvider(widget.images[index - 1]);
        if (provider != null) {
          precacheImage(provider, context);
        }
      }
      // 后一张
      if (index < widget.images.length - 1) {
        final provider = _getImageProvider(widget.images[index + 1]);
        if (provider != null) {
          precacheImage(provider, context);
        }
      }
    });
  }

  /// 根据图片 src 获取 ImageProvider（用于 precacheImage）
  ImageProvider? _getImageProvider(EpubGalleryImage image) {
    final src = image.src;
    if (src.startsWith('data:')) {
      final bytes = _decodeDataUri(src);
      if (bytes != null) return MemoryImage(bytes);
      return null;
    }
    final filePath = src.startsWith('file://') ? src.substring(7) : src;
    if (filePath.contains('/') || filePath.contains('\\')) {
      return FileImage(File(filePath));
    }
    return NetworkImage(src);
  }

  /// 重置缩放到 1.0
  void _resetZoom() {
    _transformCtrl.value = Matrix4.identity();
    if (_currentScale != 1.0) {
      setState(() => _currentScale = 1.0);
    }
  }

  /// 双击切换缩放
  void _onDoubleTap() {
    if (_currentScale > 1.05) {
      _resetZoom();
    } else {
      _transformCtrl.value = Matrix4.diagonal3Values(2.5, 2.5, 1.0);
      setState(() => _currentScale = 2.5);
    }
  }

  void _onPageChanged(int index) {
    // 切换页时重置缩放，避免上一页的缩放状态影响下一页
    _resetZoom();
    setState(() => _currentIndex = index);
    // 预加载新的相邻图片
    _precacheAdjacentImages(index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 主体：PageView 横向滑动 + InteractiveViewer 缩放
          PageView.builder(
            controller: _pageController,
            itemCount: widget.images.length,
            onPageChanged: _onPageChanged,
            // scale > 1.0 时禁用 PageView 滑动，让 InteractiveViewer 处理拖动
            // scale == 1.0 时启用 PageView 滑动切换图片
            // PageScrollPhysics：保持分页吸附效果，滑动结束自动对齐到页边界
            physics: _currentScale > 1.05
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            itemBuilder: (context, index) {
              return _buildZoomableImage(widget.images[index], index);
            },
          ),
          // 顶部：页码指示器 + 关闭按钮
          _buildTopBar(),
          // 右下角：主标题 + 副标题信息面板（从下到上滑出动画）
          _buildInfoPanel(),
        ],
      ),
    );
  }

  /// 构建可缩放的单张图片（全屏预览）
  ///
  /// 全屏预览只显示图片，标题/副标题由右下角自定义信息面板展示
  /// （_buildInfoPanel），不复用原作者格式。
  ///
  /// - AutomaticKeepAliveClientMixin：保持页面状态，避免滑出视图后被销毁
  /// - GestureDetector 检测双击缩放
  /// - InteractiveViewer 处理双指缩放和拖动
  /// - Hero 包裹当前页图片（tag: gallery_image_$index），与画廊页 Hero 配对
  ///   只有当前显示的页面才有 Hero，避免与画廊页多个 Hero tag 冲突
  Widget _buildZoomableImage(EpubGalleryImage image, int index) {
    return _KeepAliveImage(
      child: GestureDetector(
        onDoubleTap: _onDoubleTap,
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: InteractiveViewer(
            transformationController: _transformCtrl,
            minScale: 1.0,
            maxScale: 4.0,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            onInteractionEnd: (_) {
              final scale = _transformCtrl.value.getMaxScaleOnAxis();
              if ((scale - _currentScale).abs() > 0.01) {
                setState(() => _currentScale = scale);
              }
            },
            // 只有当前页用 Hero 包裹，避免多 Hero tag 冲突
            child: index == _currentIndex
                ? Hero(
                    tag: 'gallery_image_$index',
                    child: _buildImage(image),
                  )
                : _buildImage(image),
          ),
        ),
      ),
    );
  }

  /// 右下角信息面板：主标题 + 副标题，从下到上滑出动画
  ///
  /// 自定义样式（非原作者格式），全屏预览专用：
  /// - 白色文字（确保在黑底图片上可见）
  /// - 主标题（标题）：18px FontWeight.w600
  /// - 副标题（详情信息）：13px FontWeight.w400 半透明
  /// - 切换图片时面板重新从下方滑出（SlideTransition + FadeTransition）
  /// - 半透明黑色背景圆角容器，右下角定位
  Widget _buildInfoPanel() {
    final image = widget.images[_currentIndex];
    final hasTitle =
        image.maintitle.isNotEmpty || image.subtitle.isNotEmpty;
    if (!hasTitle) return const SizedBox.shrink();

    return Positioned(
      right: 16,
      bottom: 16,
      child: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            // 从下到上滑出 + 淡入（Offset(0,1) → Offset(0,0)）
            final offset = Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ));
            return SlideTransition(
              position: offset,
              child: FadeTransition(
                opacity: animation,
                child: child,
              ),
            );
          },
          child: Container(
            key: ValueKey(_currentIndex),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (image.maintitle.isNotEmpty)
                  Text(
                    image.maintitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                if (image.subtitle.isNotEmpty) ...[
                  if (image.maintitle.isNotEmpty) const SizedBox(height: 4),
                  Text(
                    image.subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 顶部栏：页码指示器（左）+ 关闭按钮（右）
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
              // 页码指示器
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
                    ),
                  ),
                ),
              ),
              const Spacer(),
              // 关闭按钮
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

  /// 根据图片 src 类型选择渲染方式
  Widget _buildImage(EpubGalleryImage image) {
    final src = image.src;
    if (src.startsWith('data:')) {
      final bytes = _decodeDataUri(src);
      if (bytes != null) {
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        );
      }
      return const Icon(Icons.broken_image, color: Colors.white54, size: 64);
    }
    final filePath = src.startsWith('file://') ? src.substring(7) : src;
    if (filePath.contains('/') || filePath.contains('\\')) {
      return Image.file(
        File(filePath),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.broken_image, color: Colors.white54, size: 64),
      );
    }
    return Image.network(
      src,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) =>
          const Icon(Icons.broken_image, color: Colors.white54, size: 64),
    );
  }

  Uint8List? _decodeDataUri(String dataUri) {
    try {
      final commaIdx = dataUri.indexOf(',');
      if (commaIdx < 0) return null;
      return base64Decode(dataUri.substring(commaIdx + 1));
    } catch (_) {
      return null;
    }
  }
}

/// 保持 PageView 子页面状态的包装组件
///
/// AutomaticKeepAliveClientMixin 让 PageView 子页面在滑出视图后不被销毁，
/// 避免重新构建和重新解码图片。这对大图画廊尤为重要，能显著提升滑动流畅度。
class _KeepAliveImage extends StatefulWidget {
  final Widget child;

  const _KeepAliveImage({required this.child});

  @override
  State<_KeepAliveImage> createState() => _KeepAliveImageState();
}

class _KeepAliveImageState extends State<_KeepAliveImage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
