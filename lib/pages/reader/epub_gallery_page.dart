import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;

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
/// - h3 gallery-title / .gallery-txt 不进入画廊页（多看 native 渲染管线
///   只生成 slider/slide/msg，稳定态实测首屏即第一个 cell）
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


/// ★ 多看画廊真实模型（2026-08-28 双字号实测定案）★
///
/// 画廊章 = h3 标题 + slide 块（图 contain + maintitle + subtitle）+
/// dotted + gallery-txt 的【随字号缩放的流式布局】，横向滑动 = 同视图内
/// 切换 slide（dotted 激活点位移证实），非翻页：
/// - 字号 46（对应基准 21px）：h3 大标题独占首页（字形顶 131.5），
///   slide 单独成页（图像区 244-411.5、maintitle 430、subtitle 476）
/// - 字号 20（对应基准 9.13px）：全部同屏（标题 91.5、图 199-361.5、
///   maintitle 372、subtitle 392、dotted 462.5、txt 481.5）
///
/// 作者原作 CSS 为纯 em 级联（body 无 px 基准），基准字号 = 阅读器字号
/// 设置（widget.baseFontSize）。以下垂直几何按双字号实测线性拟合
/// （锚点 A：base 21 / 锚点 B：base 9.13），base=21 时精确复现已验证
/// 的像素级对齐值。
///
/// 图像为 contain 原比例置于显示框内（非 cover 裁切！00.jpg contain
/// 163 < 框高 167.5@21，边框环仍为满框）。





/// 作者 CSS local() 字体链的语义映射（style.css @font-face 声明的流派 →
/// Flutter 系统近似族）。多看内建字体（DK-HEITI 等）Flutter 拿不到文件，
/// 按作者 local 链的字体流派映射系统族兜底。
const Map<String, String> _fontStackLocalMap = <String, String>{
  // 宋体族
  'dk-songti': 'serif', 'st': 'serif', '宋体': 'serif', '明体': 'serif',
  '明朝': 'serif', 'songti': 'serif', 'songti sc': 'serif',
  // 仿宋族
  'dk-fangsong': 'serif', 'fs': 'serif', '仿宋': 'serif', 'fangsong': 'serif',
  // 小标宋族（标题）
  'dk-xiaobiaosong': 'serif', 'h3': 'serif', '方正小标宋_gbk': 'serif',
  '方正小标宋简体': 'serif', '方正小标宋繁体': 'serif',
  // 楷体族
  'dk-kaiti': 'serif', 'kt': 'serif', '楷体': 'serif', 'kaiti': 'serif',
  'kaiti sc': 'serif',
  // 黑体族
  'dk-heiti': 'sans-serif', 'ht': 'sans-serif', '微软雅黑': 'sans-serif',
  '黑体': 'sans-serif', 'heiti': 'sans-serif', 'heiti sc': 'sans-serif',
  'sthei': 'sans-serif',
  // 圆体/细黑族
  'dk-xiheiti': 'sans-serif', 'yt': 'sans-serif', '圆体': 'sans-serif',
  'yuanti': 'sans-serif', 'styuanti': 'sans-serif',
};

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




  /// 渲染值诊断用 GlobalKey（静态层恒挂载；图片 key 挂当前框内图层）
  final _titleKey = GlobalKey();
  final _dottedKey = GlobalKey();
  final _imageKey = GlobalKey();
  final _maintitleKey = GlobalKey();
  final _subtitleKey = GlobalKey();

  /// 图片总数
  int get _itemCount => widget.images.length;

  /// 框宽（逻辑 px，对齐多看 DocImagesView 宽 324）
  static const double _frameW = 324.0;

  @override
  void initState() {
    super.initState();
    _imageIndex = widget.initialPageToEnd ? _itemCount - 1 : 0;
    final embeddedFonts = widget.chapterStyle?.embeddedFonts ?? const {};
    _cellStyle = _parseCellStyle(widget.chapterStyle?.rawCss ?? '', embeddedFonts);
    _settle = AnimationController(vsync: this, duration: const Duration(milliseconds: 220))
      ..addListener(_onSettleTick);
    // 注册作者内嵌字体（@font-face url 文件）+ 首帧导出渲染值/预热相邻图
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _registerEmbeddedFonts();
      if (mounted) _precacheNeighbors();
      _dumpLayout('init');
    });
  }

  /// 注册作者内嵌字体（@font-face { src: url(...) } 的字体文件），
  /// 注册后 font-family 栈命中该 family 名即可直接渲染作者字体
  Future<void> _registerEmbeddedFonts() async {
    final fonts = widget.chapterStyle?.embeddedFonts;
    if (fonts == null || fonts.isEmpty) return;
    for (final entry in fonts.entries) {
      try {
        final ByteData bytes;
        if (entry.value.startsWith('data:')) {
          final list = _parseDataUri(entry.value);
          bytes = ByteData.view(list.buffer);
        } else {
          final f = File(entry.value);
          if (!f.existsSync()) continue;
          bytes = ByteData.view(f.readAsBytesSync().buffer);
        }
        final loader = FontLoader(entry.key)..addFont(Future.value(bytes));
        await loader.load();
      } catch (_) {
        // 单个字体注册失败不影响其他字体与整体渲染
      }
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  /// 解析 font-family 栈原文（如 "DK-HEITI","ht",sans-serif → 栈字符串）
  String _parseFontFamilyStack(String? block, String fallback) {
    if (block == null) return fallback;
    final m = RegExp(r'font-family\s*:\s*([^;}]+)').firstMatch(block);
    if (m == null) return fallback;
    final stack = m.group(1)!.trim();
    return stack.isEmpty ? fallback : stack;
  }

  /// font-family 栈解析 → Flutter fontFamily（作者 CSS 是唯一真相）：
  /// ① 栈中名字命中内嵌字体表（@font-face url 加载注册的作者字体）→ 直接用
  /// ② 命中 local 语义映射（作者 local 链声明的字体流派）→ 系统近似族
  /// ③ 栈尾 generic（serif/sans-serif/monospace）直接用
  String _resolveFontFamily(String stack, Map<String, String> embedded) {
    for (final raw in stack.split(',')) {
      final name = raw.trim().replaceAll('"', '').replaceAll("'", '');
      if (name.isEmpty) continue;
      if (embedded.containsKey(name)) return name;
      final mapped = _fontStackLocalMap[name.toLowerCase()];
      if (mapped != null) return mapped;
      final lower = name.toLowerCase();
      if (lower == 'serif' || lower == 'sans-serif' || lower == 'monospace') {
        return lower;
      }
    }
    return 'sans-serif';
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
  _GalleryCellStyle _parseCellStyle(
    String rawCss,
    Map<String, String> embeddedFonts,
  ) {
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
      // 字体族：font-family 栈解析（作者 CSS 原设，style.css 331/340）：
      // maintitle = "DK-HEITI","ht",sans-serif（黑体，0.9em）
      // subtitle  = "DK-KAITI","kt",serif（楷体，0.9em）
      // 内嵌字体命中 → 用作者字体；否则按 local 语义映射系统近似族
      maintitleFontFamily: _resolveFontFamily(
        _parseFontFamilyStack(maintitleBlock, 'sans-serif'), embeddedFonts),
      subtitleFontFamily: _resolveFontFamily(
        _parseFontFamilyStack(subtitleBlock, 'serif'), embeddedFonts),
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



  Color _resolveBgColor() {
    final bgClr = widget.chapterStyle?.backgroundColor;
    if (bgClr != null) return Color(bgClr);
    return widget.backgroundColor;
  }

  void _onSlideCommitted(int index) {
    _isNavigating = false;
    _precacheNeighbors();
    // slide 提交后导出渲染值（文字层内容切换验证）
    _dumpLayout('slide$index');
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _dumpLayout('slide${index}settle');
    });
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

    // ★ 多看画廊实测模型（2026-09-09 红米容器逐像素定案，
    //   memory/2026-09-09-画廊多看证据.md）★
    // 1. 画布全屏纯黑：作者 CSS 全部丢弃（gallery margin / cell 1px 边框 /
    //    box-shadow / maintitle zt1 字体 / num5 棕底标签 / 章节背景图）
    // 2. 图片等比 aspect-fit 居中：可用区 = 全屏（SafeArea 锁顶 24），
    //    竖图按高铺满、横图按宽铺满上下留黑；没有 324 固定框
    // 3. 文字层屏幕固定位置（不随图片）：maintitle 白字墨顶 523css、
    //    subtitle 灰白 548css，左对齐 x8，黑体，字形高 16.5css（33物理）
    // 4. 交互：图上滑动=切图（覆盖式）；最后一张继续滑=翻出画廊章；
    //    无 dotted 圆点（反汇编报告的 dotted 实拍未出现）
    final safeIndex = _imageIndex.clamp(0, _itemCount - 1);
    final current = widget.images[safeIndex];
    final screenW = MediaQuery.sizeOf(context).width;

    // 文字层固定几何（css，物理/2）：墨顶 523/548 实拍锚定。
    // 屏幕较矮时整体上移让位（文字块高 ≈ 25css + 16.5css + 底距 8css）
    final pageHcss = MediaQuery.sizeOf(context).height / 2;
    const mtInkH = 16.5;
    var mtTopCss = 523.0;
    var stTopCss = 548.0;
    if (mtTopCss + mtInkH > pageHcss - 8) {
      mtTopCss = pageHcss - 8 - mtInkH - 25;
      stTopCss = mtTopCss + 25;
    }
    final safeTop = MediaQuery.paddingOf(context).top;

    return Container(
      // ★ 纯黑画布：多看画廊不渲染作者背景（beijing1.jpg 等不生效）
      color: Colors.black,
      // ★ 顶部锁 24：多看全部位置公式按 safeTop 24 校准；沉浸式隐藏状态
      //   栏后 MediaQuery.safeTop 归零会导致整体上移，minimum 锁定几何
      child: SafeArea(
        minimum: const EdgeInsets.only(top: 24),
        child: Stack(
          children: [
            // ★ 全屏手势层：多看画布 = 整个屏幕，图内图外均可滑动切图；
            //   第一/最后一张继续滑触发章节切换（onPrevious/NextChapter）
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: _onDragStart,
                onHorizontalDragUpdate: _onDragUpdate,
                onHorizontalDragEnd: _onDragEnd,
                onTap: () => _showFullScreenPreview(_imageIndex),
                child: ClipRect(
                  child: Stack(
                    children: [
                      // 底层：当前图 aspect-fit 居中（静止不动）
                      Positioned.fill(
                        child: _FrameImage(
                          image: current,
                          style: _cellStyle,
                          textColor: widget.textColor,
                          imageKey: _imageKey,
                        ),
                      ),
                      // 入场 sheet：拖向下一张（v<0）时从右缘滑入盖住
                      if (_dragVector < 0)
                        Positioned(
                          left: screenW + _dragVector,
                          top: 0,
                          width: screenW,
                          height: double.infinity,
                          child: _FrameImage(
                            image: widget.images[safeIndex + 1],
                            style: _cellStyle,
                            textColor: widget.textColor,
                          ),
                        ),
                      // 入场 sheet：拖向上一张（v>0）时从左缘滑入盖住
                      if (_dragVector > 0)
                        Positioned(
                          left: -screenW + _dragVector,
                          top: 0,
                          width: screenW,
                          height: double.infinity,
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
            // maintitle（屏幕固定位置：白字黑体左对齐，随 slide 换内容）
            Positioned(
              top: safeTop + mtTopCss * 2,
              left: 16,
              right: 16,
              child: Text(
                current.maintitle,
                key: _maintitleKey,
                style: const TextStyle(
                  fontSize: 33,
                  fontFamily: 'sans-serif',
                  color: Colors.white,
                  decoration: TextDecoration.none,
                  height: 1.0,
                ),
                textAlign: TextAlign.left,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // subtitle（屏幕固定位置：灰白字同字号下一行，随 slide 换内容）
            if (current.subtitle.isNotEmpty)
              Positioned(
                top: safeTop + stTopCss * 2,
                left: 16,
                right: 16,
                child: Text(
                  current.subtitle,
                  key: _subtitleKey,
                  style: const TextStyle(
                    fontSize: 33,
                    fontFamily: 'sans-serif',
                    color: Color(0xFF9A9A9A),
                    decoration: TextDecoration.none,
                    height: 1.0,
                  ),
                  textAlign: TextAlign.left,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
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
      sb.write(' itemCount=$_itemCount idx=$_imageIndex drag=$_dragVector');

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
/// 框内单张图片图层（aspect-fit 居中于全屏可用区）
///
/// ★ 多看实测模型（2026-09-09）：图片等比适配居中，竖图按高铺满、
/// 横图按宽铺满上下留黑；cell 边框/阴影被多看丢弃，不渲染。
/// 滑动 = 入场图层从屏缘平移盖住当前图层（覆盖式滑动）。
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
          // 图片层：aspect-fit 居中（多看实拍：竖图顶满高，横图顶满宽留黑）
          _buildImage(),
        ],
      ),
    );
  }

  Widget _buildImage() {
    final src = image.src;
    // ★ aspect-fit（BoxFit.contain）：等比适配居中，图片完整可见；
    //   404 竖图(0.61)按高铺满、天阳道人横图(0.93)按宽铺满上下留黑
    if (src.startsWith('data:')) {
      return Image.memory(
        _parseDataUri(src),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => _buildErrorWidget(),
      );
    }
    return Image.file(
      File(src),
      fit: BoxFit.contain,
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
              widget.images[_currentIndex].subtitle.isNotEmpty)
            _buildBottomDescription(),
        ],
      ),
    );
  }

  /// 底部图注（对齐多看 DocImageWatchingView 实拍：白字左对齐、无胶囊
  /// 背景，maintitle ~18px / subtitle ~14.5px，块底距屏底 ~87 逻辑px，
  /// 顶部无页码/关闭 UI——点击图片即退出）
  Widget _buildBottomDescription() {
    final img = widget.images[_currentIndex];
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      // 沉浸式全屏（无系统栏），块底距屏底 87 逻辑 = 多看实拍
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
                  fontSize: 18,
                  height: 1.35,
                  decoration: TextDecoration.none,
                ),
              ),
            if (img.subtitle.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                img.subtitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14.5,
                  height: 1.35,
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

/// 解析 data: URI 为 Uint8List
Uint8List _parseDataUri(String dataUri) {
  final commaIdx = dataUri.indexOf(',');
  if (commaIdx < 0) return Uint8List(0);
  final base64Str = dataUri.substring(commaIdx + 1);
  return base64Decode(base64Str);
}
