import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/local_book/epub_parser.dart';

/// EPUB 多看画廊页面渲染器（Flutter 原生实现）
///
/// ★ 非全屏极简页模型（2026-09-09 多看真机逐像素重测定案，
///   .tmp/verify/gallery_evidence_0909.md）★
///
/// 非全屏画廊 = 正常阅读页（页码体系内一页）：
/// - 背景图 cover 全屏 + 唯一画框（左 18css / 宽 324css / 白 1px 描边）
/// - 框内图 cover 铺满，框内横滑 = 覆盖式切 slide
/// - 框外点击：右缘=翻出章（下一章），其余=上一章；框外横滑无反应
/// - 非全屏不渲染 h3/maintitle/subtitle/dotted/gallery-txt（实拍定案）
/// - 点击图 = 全屏预览（黑底 contain + 左下两行白字 maintitle+num5）
/// - 章节边界：第一/最后一张继续滑 = 触发上一章/下一章（onPrevious/Next）
class EpubGalleryPage extends StatefulWidget {
  final List<EpubGalleryImage> images;
  final String chapterTitle;
  final Color backgroundColor;
  final Color textColor;

  /// 画廊基准字号（逻辑 px）= 阅读器字号设置
  ///
  /// 作者原作 CSS 为纯 em 级联（body 无 px 基准），基准字号由阅读器决定：
  /// 阅读器设多少号，画廊 h3(1.5em)/maintitle(0.9em)/subtitle(0.9em) 及
  /// 垂直几何全部随动。传 ReaderProvider.fontSize。
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
    this.baseFontSize = 21.0,
    this.chapterStyle,
    this.initialPageToEnd = false,
    required this.onPreviousChapter,
    required this.onNextChapter,
  });

  @override
  State<EpubGalleryPage> createState() => _EpubGalleryPageState();
}

/// ★ 非全屏极简页模型（2026-09-09 多看真机逐像素重测定案，
///   .tmp/verify/gallery_evidence_0909.md）★
///
/// 非全屏画廊 = 正常阅读页（页码体系内一页，框外可点击翻页）：
/// - 背景：作者章节背景图 cover 铺满全屏（.zhizuosm 保留）
/// - 画框：左 18css、宽 324css、白 1px 描边，高随字号（框内图 cover 铺满，
///   横竖图一律 cover，横图左右裁切实测确认）
/// - 框内横滑 = 切 slide（覆盖式，sheet 从框缘滑入盖住当前图）
/// - 框外横滑 = 无反应（实验矩阵确认）；框外点击：右缘=下一页翻出章，
///   其余框外=上一页
/// - 非全屏不渲染 h3/maintitle/subtitle/dotted/gallery-txt（实拍：框外
///   只有背景+页眉书名+页码，文字全在全屏预览里）
/// - 点击图片 = 全屏预览（黑底 contain + 左下两行白字 maintitle+num5）
///
/// 图像显示框高随基准字号：158.7 + 0.42×base（21 → 167.5、9.13 → 162.5）
double _imageFrameHeightOf(double base) => 158.7 + 0.42 * base;

/// 图像区顶相对 SafeArea 随基准字号：140.4 + 3.791×base（21 → 220.0、
/// 9.13 → 175.0，绝对 244/199 实测拟合）
double _imageTopGapOf(double base) => 140.4 + 3.791 * base;

class _EpubGalleryPageState extends State<EpubGalleryPage>
    with TickerProviderStateMixin {
  late final _GalleryCellStyle _cellStyle;

  /// 当前 slide 索引
  int _imageIndex = 0;
  bool _isNavigating = false;

  /// ★ 捕捉到的拖动向量的水平投影（多看覆盖式滑动的驱动量）★
  /// >0 拖向下一张（下一张 sheet 从框右缘滑入盖住当前图）、
  /// <0 拖向上一张（上一张 sheet 从框左缘滑入）、0 = 静止；
  /// 绝对值上限 = 框宽（sheet 完全盖住框）。文字层内容在提交瞬间才切换。
  double _dragVector = 0;

  /// 拖动中的原始位移累计（章节边界判定用：第一/最后一张拖出但不产生
  /// sheet 位移时，按位移触发上一章/下一章）
  double _rawDx = 0;

  /// 释放后的 snap 动画（滑向 ±框宽 提交，或回弹 0）
  late final AnimationController _settle;
  double _settleFrom = 0;
  double _settleTo = 0;
  int? _settleCommit;

  /// 渲染值诊断用 GlobalKey（图片 key 挂当前框内图层）
  final _imageKey = GlobalKey();

  /// 图片总数
  int get _itemCount => widget.images.length;

  /// 框宽（逻辑 px，对齐多看 DocImagesView 宽 324）
  static const double _frameW = 324.0;

  @override
  void initState() {
    super.initState();
    _imageIndex = widget.initialPageToEnd ? _itemCount - 1 : 0;
    _cellStyle = _parseCellStyle(widget.chapterStyle?.rawCss ?? '');
    _settle = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
      ..addListener(_onSettleTick);
    // 预热相邻图（避免拖动时 sheet 首次读盘闪白）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _precacheNeighbors();
    });
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  /// 预热相邻两张图（替代 PageView allowImplicitScrolling 的预加载，
  /// 避免拖动时 sheet 首次读盘闪白）
  void _precacheNeighbors() {
    final context = this.context;
    for (final i in [_imageIndex + 1, _imageIndex - 1]) {
      if (i < 0 || i >= _itemCount) continue;
      final src = widget.images[i].src;
      try {
        if (src.startsWith('data:')) {
          precacheImage(MemoryImage(_parseDataUri(src)), context);
        } else {
          precacheImage(FileImage(File(src)), context);
        }
      } catch (_) {
        // 预热失败不影响渲染，拖动时正常加载
      }
    }
  }

  /// snap 动画驱动：插值拖动向量，提交时切换索引并清零（文字层随之换内容）
  void _onSettleTick() {
    final t = Curves.easeOut.transform(_settle.value);
    if (!mounted) return;
    setState(() {
      _dragVector = _settleFrom + (_settleTo - _settleFrom) * t;
    });
    if (_settle.isCompleted && _settleCommit != null) {
      setState(() {
        _imageIndex = (_imageIndex + _settleCommit!).clamp(0, _itemCount - 1);
        _dragVector = 0;
        _settleCommit = null;
      });
      _onSlideCommitted(_imageIndex);
    }
  }

  // ---- 拖动向量的捕捉与提交（覆盖式滑动）----

  void _onDragStart(DragStartDetails details) {
    _settle.stop();
    _rawDx = 0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _rawDx += d.delta.dx;
    // 拖动向量 = 内容跟随手指：左滑（dx<0）→ 下一张，右滑（dx>0）→ 上一张
    final lo = _imageIndex < _itemCount - 1 ? -_frameW : 0.0;
    final hi = _imageIndex > 0 ? _frameW : 0.0;
    final next = (_dragVector + d.delta.dx).clamp(lo, hi);
    if (next != _dragVector) setState(() => _dragVector = next);
  }

  void _onDragEnd(DragEndDetails d) {
    if (_isNavigating) return; // 章节切换已触发，防重复
    final dxPerSec = d.velocity.pixelsPerSecond.dx;
    final fling = dxPerSec.abs() > 350;
    final passed = _dragVector.abs() > _frameW * 0.35;

    // 章节边界：第一张继续向右拖（回看上一章）/ 最后一张继续向左拖
    // （进看下一章）→ 切换章节
    if (_dragVector == 0 && _rawDx.abs() > 80) {
      if (_imageIndex == 0 && _rawDx > 0) {
        _isNavigating = true;
        widget.onPreviousChapter();
        return;
      }
      if (_imageIndex == _itemCount - 1 && _rawDx < 0) {
        _isNavigating = true;
        widget.onNextChapter();
        return;
      }
    }

    _settleFrom = _dragVector;
    if (passed || (fling && _dragVector.abs() > 8)) {
      // v<0 = 拖向下一张（+1）；v>0 = 拖向上一张（-1）
      _settleTo = _dragVector < 0 ? -_frameW : _frameW;
      _settleCommit = _dragVector < 0 ? 1 : -1;
    } else {
      _settleTo = 0;
      _settleCommit = null;
    }
    _settle.forward(from: 0);
  }

  /// 从 rawCss 解析 .duokan-image-gallery-cell 的框视觉样式
  ///
  /// 非全屏页只保留框本身的描边/阴影（2026-09-09 真机定案：白描边保留、
  /// 阴影丢弃），maintitle/subtitle 的字号/颜色/字体族不再拆解，
  /// 文字渲染已移入全屏预览（白字写死，多看实拍）。
  _GalleryCellStyle _parseCellStyle(String rawCss) {
    final cellBlock = _extractRuleBlock(rawCss, 'duokan-image-gallery-cell');

    return _GalleryCellStyle(
      borderWidth: _parseFloat(cellBlock, 'border-width') ?? 1.0,
      borderColor: _parseColor(cellBlock, 'border-color'),
      boxShadowDx: _parseBoxShadow(cellBlock)?.dx ?? 5.0,
      boxShadowDy: _parseBoxShadow(cellBlock)?.dy ?? 5.0,
      boxShadowBlur: _parseBoxShadow(cellBlock)?.blur ?? 5.0,
      boxShadowColor: _parseBoxShadow(cellBlock)?.color ?? const Color(0xFF888888),
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

  void _onSlideCommitted(int index) {
    _isNavigating = false;
    _precacheNeighbors();
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

    // ★ 非全屏极简页模型（2026-09-09 多看真机逐像素重测定案，
    //   .tmp/verify/gallery_evidence_0909.md）★
    // 全画廊只有一个框（DocImagesView 窗口：左 18、宽 324、高随字号），
    // ClipRect 固定不动；图片条在框内滑动：
    // - 每张图 cover 铺满整个框（横竖图均 cover，横图左右裁切实拍确认）
    // - 拖动向量的捕捉驱动：下一张 sheet 从框右缘滑入盖住当前图
    // - 非全屏页不渲染 h3/maintitle/subtitle/dotted/gallery-txt
    //   （多看实拍：画框外只有背景+页眉书名+页码，文字全在预览里）
    // - 框外点击：右侧缘=下一页（翻出章），其余框外=上一页；
    //   框外横滑无反应（实验矩阵确认）
    final base = widget.baseFontSize;
    final frameH = _imageFrameHeightOf(base);
    final frameTop = _imageTopGapOf(base);
    // 章节切换竞争防御：索引钳制到新章节图片范围内
    final safeIndex = _imageIndex.clamp(0, _itemCount - 1);
    final current = widget.images[safeIndex];

    return Container(
      color: hasBgImage ? null : _resolveBgColor(),
      decoration: hasBgImage ? _buildBackgroundDecoration() : null,
      // ★ 顶部锁 24：多看全部位置公式按 safeTop 24 校准；沉浸式隐藏状态
      //   栏后 MediaQuery.safeTop 归零会导致整体上移，minimum 锁定几何
      child: SafeArea(
        minimum: const EdgeInsets.only(top: 24),
        child: LayoutBuilder(builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          // 框外区域划分（多看实拍）：右缘条 = 下一页（翻出章），
          // 左缘条/顶部/底部 = 上一页；框身矩形留给框内手势层。
          const frameLeft = 18.0;
          const frameRight = frameLeft + _frameW;
          final frameBottom = frameTop + frameH;
          return Stack(
            children: [
              // 底层：框外点击捕获（左右中/顶/底四块，框身区域除外）
              // 左缘条（x < frameLeft）
              Positioned(
                left: 0,
                top: 0,
                width: frameLeft,
                height: h,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _onOutsideTap(false),
                ),
              ),
              // 右缘条（x > frameRight）——多看实拍翻出章的触发区
              Positioned(
                left: frameRight,
                top: 0,
                width: w - frameRight,
                height: h,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _onOutsideTap(true),
                ),
              ),
              // 顶部条（frameLeft..frameRight, y < frameTop）
              Positioned(
                left: frameLeft,
                top: 0,
                width: _frameW,
                height: frameTop,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _onOutsideTap(false),
                ),
              ),
              // 底部条（frameLeft..frameRight, y > frameBottom）
              Positioned(
                left: frameLeft,
                top: frameBottom,
                width: _frameW,
                height: h - frameBottom,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _onOutsideTap(false),
                ),
              ),
              // ★ 唯一的框：固定窗口，图片条在框内滑动（ClipRect 裁剪）
              Positioned(
                left: frameLeft,
                top: frameTop,
                width: _frameW,
                height: frameH,
                child: ClipRect(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: _onDragStart,
                    onHorizontalDragUpdate: _onDragUpdate,
                    onHorizontalDragEnd: _onDragEnd,
                    onTap: () => _showFullScreenPreview(_imageIndex),
                    child: Stack(
                      children: [
                        // 底层：当前图，cover 铺满整个框（静止不动）
                        Positioned.fill(
                          child: _FrameImage(
                            image: current,
                            style: _cellStyle,
                            textColor: widget.textColor,
                            imageKey: _imageKey,
                          ),
                        ),
                        // 入场 sheet：拖向下一张（v<0）时从框右缘滑入盖住
                        if (_dragVector < 0)
                          Positioned(
                            left: _frameW + _dragVector,
                            top: 0,
                            width: _frameW,
                            height: frameH,
                            child: _FrameImage(
                              image: widget.images[safeIndex + 1],
                              style: _cellStyle,
                              textColor: widget.textColor,
                            ),
                          ),
                        // 入场 sheet：拖向上一张（v>0）时从框左缘滑入盖住
                        if (_dragVector > 0)
                          Positioned(
                            left: -_frameW + _dragVector,
                            top: 0,
                            width: _frameW,
                            height: frameH,
                            child: _FrameImage(
                              image: widget.images[safeIndex - 1],
                              style: _cellStyle,
                              textColor: widget.textColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  /// 框外点击（多看实拍：右缘=下一页翻出章，其余框外=上一页）
  void _onOutsideTap(bool isRightEdge) {
    if (_isNavigating) return;
    _isNavigating = true;
    if (isRightEdge) {
      widget.onNextChapter();
    } else {
      widget.onPreviousChapter();
    }
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
/// 框内单张图片图层（cover 铺满整个框）
///
/// ★ 单框模型：全画廊只有一个框（DocImagesView 窗口），本图层即框内
/// 的内容——每张图 cover 填满 324×frameH，边框 1px 描边 + 阴影随图。
/// 滑动 = 入场图层从框缘平移盖住当前图层（唯一框，无新框创建）。
class _FrameImage extends StatelessWidget {
  final EpubGalleryImage image;
  final _GalleryCellStyle style;
  final Color textColor;

  /// 渲染值诊断 key（仅当前图层挂载）
  final Key? imageKey;

  const _FrameImage({
    required this.image,
    required this.style,
    required this.textColor,
    this.imageKey,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      key: imageKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 阴影层（最底）
          DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: style.boxShadowColor ?? const Color(0xFF888888),
                  offset: Offset(style.boxShadowDx, style.boxShadowDy),
                  blurRadius: style.boxShadowBlur,
                ),
              ],
            ),
          ),
          // 图片层（中）：cover 铺满框（内容顶满内边框）
          ClipRect(child: _buildImage()),
          // 边框层（最上）：1px 描边
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                width: style.borderWidth,
                color: style.borderColor ?? textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImage() {
    final src = image.src;
    // ★ 图片 cover 铺满整个框（用户定案：图片一定要全部覆盖框框；
    // 21 号档像素实证：内容 490-820 顶满内边框 490-820）
    if (src.startsWith('data:')) {
      return Image.memory(
        _parseDataUri(src),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => _buildErrorWidget(),
      );
    }
    return Image.file(
      File(src),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => _buildErrorWidget(),
    );
  }

  Widget _buildErrorWidget() {
    return Container(
      width: double.infinity,
      height: double.infinity,
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
          // 底部图注（多看全屏预览顶部无页码/关闭 UI，点击图片即退出）
          if (widget.images[_currentIndex].maintitle.isNotEmpty ||
              widget.images[_currentIndex].galleryHint.isNotEmpty ||
              widget.images[_currentIndex].subtitle.isNotEmpty)
            _buildBottomDescription(),
        ],
      ),
    );
  }

  /// 底部图注（对齐多看 DocImageWatchingView 真机实拍 2026-09-09：
  /// 两行白字左对齐、无胶囊/棕底背景，x≈8物理=4逻辑，首行顶 y1048物理
  /// =524逻辑，次行顶 y1102=551逻辑，行高≈33物理=16.5逻辑×1.6；
  /// maintitle 主体与 num5 提示各占一行，棕底标签被丢弃只留白字）
  Widget _buildBottomDescription() {
    final img = widget.images[_currentIndex];
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      // 沉浸式全屏（无系统栏）：首行顶 524逻辑 + 行盒约 29 + 次行 29
      // ≈ 底距 87 逻辑，与多看实拍对齐
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 8, 87),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (img.maintitle.isNotEmpty)
              Text(
                img.maintitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16.5,
                  height: 1.0,
                  decoration: TextDecoration.none,
                ),
              ),
            if (img.galleryHint.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                img.galleryHint,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16.5,
                  height: 1.0,
                  decoration: TextDecoration.none,
                ),
              ),
            ] else if (img.subtitle.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                img.subtitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16.5,
                  height: 1.0,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ],
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

  const _GalleryCellStyle({
    this.borderWidth = 1.0,
    this.borderColor,
    this.boxShadowDx = 5.0,
    this.boxShadowDy = 5.0,
    this.boxShadowBlur = 5.0,
    this.boxShadowColor,
  });
}

/// 解析 data: URI 为 Uint8List
Uint8List _parseDataUri(String dataUri) {
  final commaIdx = dataUri.indexOf(',');
  if (commaIdx < 0) return Uint8List(0);
  final base64Str = dataUri.substring(commaIdx + 1);
  return base64Decode(base64Str);
}
