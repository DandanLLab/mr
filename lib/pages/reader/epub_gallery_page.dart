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

/// dotted 指示器高度（圆点 6px + 上下 padding 各 8px = 22px）
///
/// 对齐多看 .dotted 的 absolute 定位（gallery_full_disasm_report.md 5.1）：
/// 多看 .dotted 用 position:absolute 悬浮在 .slider 底部，高度由设备 theme 注入。
/// Flutter 移植固定为 22px，PageView 底部留此高度避免 cell 内容被 dotted 遮挡。
const _kDottedHeight = 22.0;

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

/// 多看画廊首页 h3 标题字形顶随基准字号：62.6 + 3.28×base
/// （21→131.5、9.13→92.5 实测拟合）。MR 侧 = SafeArea 24 + 2em + extraTop，
/// 故 extraTop = 38.6 + 1.28×base（21 → 65.5）。
double _titleExtraTopOf(double base) => 38.6 + 1.28 * base;

/// 图像显示框高随基准字号：158.7 + 0.42×base（21 → 167.5、9.13 → 162.5）
double _imageFrameHeightOf(double base) => 158.7 + 0.42 * base;

/// 图像区顶相对 SafeArea 随基准字号：140.4 + 3.791×base（21 → 220.0、
/// 9.13 → 175.0，绝对 244/199 实测拟合）
double _imageTopGapOf(double base) => 140.4 + 3.791 * base;

/// maintitle/subtitle 内边距：以多看墨顶线（maintitle 327.4+4.886B、
/// subtitle 327.4+7.075B）为目标，对 MR 自身渲染偏差两点重拟合
/// （21 处精确退化回已验证的 15.5/15.0）
double _maintitlePadOf(double base) => 4.3 + 0.532 * base;
double _subtitlePadOf(double base) => 1.93 + 0.6225 * base;

const _kMaintitleLineHeight = 1.15;
const _kSubtitleLineHeight = 40.5 / 18.9;

/// dotted 圆点行几何（多看 20号/52号 实拍逐像素拟合，同屏形态）。
/// ★ 一律为 SafeArea 内相对坐标（实拍绝对值 − SafeArea 24）★：
/// - 行顶（圆点墨顶）= 369.0 + 7.61B（绝对 462.5@9.13、578.0@24.3）
/// - 点距 = 0.4615B + 0.287（9.13→4.5、24.3→11.5）
/// - 非激活点径 = 0.297B − 1.212（9.13→1.5、24.3→6.0）
/// - 激活点径 = 2.19 + 0.198B（9.13→4.0、24.3→7.0）
double _dottedInkTopOf(double base) => 369.0 + 7.61 * base;
double _dotPitchOf(double base) => 0.4615 * base + 0.287;
double _dotSizeOf(double base) => (0.297 * base - 1.212).clamp(1.0, 12.0);
double _dotActiveSizeOf(double base) => 2.19 + 0.198 * base;

/// gallery-txt 提示行：墨顶 = dotted 墨顶 + 2.081B（绝对 481.5@9.13 实拍），
/// 字号 0.7em；页内放不下则不显示（多看 52号 实拍同样无提示）
double _txtInkTopOf(double base) =>
    _dottedInkTopOf(base) + 2.081 * base;

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
  late final _GalleryTitleStyle _titleStyle;

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

  /// 是否有 h3 标题（所有页同屏恒显）
  late final bool _hasTitlePage;

  /// 标题文本（chapterStyle.galleryTitle ?? chapterTitle）
  late final String _titleText;

  /// gallery-txt 提示文本（无则不显示；dotted 下方）
  late final String _txtText;

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
    _titleText =
        (widget.chapterStyle?.galleryTitle ?? widget.chapterTitle).trim();
    _hasTitlePage = _titleText.isNotEmpty;
    _txtText = widget.chapterStyle?.galleryTxt?.trim() ?? '';
    _imageIndex = widget.initialPageToEnd ? _itemCount - 1 : 0;
    final embeddedFonts = widget.chapterStyle?.embeddedFonts ?? const {};
    _cellStyle = _parseCellStyle(widget.chapterStyle?.rawCss ?? '', embeddedFonts);
    _titleStyle = _parseTitleStyle(widget.chapterStyle?.rawCss ?? '', embeddedFonts);
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

  /// 解析 .gallery-title 规则块（原作：2em auto / 1.5em / bold /
  /// DK-XIAOBIAOSONG,serif / text-shadow 0 1 1px #fff）
  _GalleryTitleStyle _parseTitleStyle(
    String rawCss,
    Map<String, String> embeddedFonts,
  ) {
    final block = _extractRuleBlock(rawCss, 'gallery-title');
    final margins = _parseMargin(block);
    return _GalleryTitleStyle(
      fontSize: _parseFloat(block, 'font-size') ?? 1.5,
      bold: _containsKeyword(block, 'bold') || _containsKeyword(block, '700'),
      color: _parseColor(block, 'color'),
      textShadow: _parseTextShadow(block),
      marginTop: margins?.$1 ?? 2.0,
      marginBottom: margins?.$2 ?? 2.0,
      fontFamily: _parseFontFamily(block) ?? 'serif',
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

  bool _containsKeyword(String? block, String keyword) {
    if (block == null) return false;
    return block.toLowerCase().contains(keyword.toLowerCase());
  }

  /// 解析 text-shadow（原作 h3: 0 1 1px #fff）
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

    final hasBgImage = widget.chapterStyle?.backgroundImageSrc != null &&
        widget.chapterStyle!.backgroundImageSrc!.isNotEmpty;

    // ★ 单框模型（对齐多看 dksw1 中间帧 + 20号/52号 静止态逐像素）★
    // 全画廊只有一个框（DocImagesView 窗口：左 18、宽 324、高随字号），
    // ClipRect 固定不动；图片条在框内滑动：
    // - 每张图 cover 铺满整个框（内容顶满内边框，21 号档像素实证）
    // - 拖动向量的捕捉驱动：下一张 sheet 从框右缘滑入盖住当前图
    //   （当前图不动，dksw1 实证），上一张从左缘滑入；提交瞬间文字层
    //   换内容（多看 P1/P2 实拍标题同位、中间帧 maintitle 纹丝不动）
    final showDotted = widget.images.length > 1;
    final base = widget.baseFontSize;
    final frameH = _imageFrameHeightOf(base);
    // 标题恒显：图像框顶不低于标题块底部+4，防超大字号重叠
    final titleBottom = _hasTitlePage
        ? base * _titleStyle.marginTop +
            _titleExtraTopOf(base) +
            base * _titleStyle.fontSize +
            base * _titleStyle.marginBottom
        : 0.0;
    final frameTop = (_imageTopGapOf(base) < titleBottom + 4)
        ? titleBottom + 4
        : _imageTopGapOf(base);
    final imgBottomRel = frameTop + frameH;
    final maintitleTop = imgBottomRel + _maintitlePadOf(base);
    final subtitleTop = maintitleTop +
        base * _cellStyle.maintitleFontSize * _kMaintitleLineHeight +
        _subtitlePadOf(base);
    final current = widget.images[_imageIndex];

    return Container(
      color: hasBgImage ? null : _resolveBgColor(),
      decoration: hasBgImage ? _buildBackgroundDecoration() : null,
      child: SafeArea(
        child: Stack(
          children: [
            // h3 标题（静态层，恒显——多看 P1/P2 实拍标题同位）
            if (_hasTitlePage)
              Positioned(
                top: base * _titleStyle.marginTop + _titleExtraTopOf(base),
                left: 0,
                right: 0,
                child: _buildTitleText(titleKey: _titleKey),
              ),
            // ★ 唯一的框：固定窗口，图片条在框内滑动（ClipRect 裁剪）
            Positioned(
              top: frameTop,
              left: 18,
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
                            image: widget.images[_imageIndex + 1],
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
                            image: widget.images[_imageIndex - 1],
                            style: _cellStyle,
                            textColor: widget.textColor,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            // maintitle（静态层，内容随当前 slide 切换；324 列宽对齐图像列）
            if (current.maintitle.isNotEmpty)
              Positioned(
                top: maintitleTop,
                left: 18,
                right: 18,
                child: Text(
                  current.maintitle,
                  key: _maintitleKey,
                  style: TextStyle(
                    fontSize: base * _cellStyle.maintitleFontSize,
                    fontFamily: _cellStyle.maintitleFontFamily,
                    color: _cellStyle.maintitleColor,
                    decoration: TextDecoration.none,
                    height: _kMaintitleLineHeight,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            // subtitle（静态层，内容随当前 slide 切换；324 列宽 justify）
            if (current.subtitle.isNotEmpty)
              Positioned(
                top: subtitleTop,
                left: 18,
                right: 18,
                child: Text(
                  current.subtitle,
                  key: _subtitleKey,
                  style: TextStyle(
                    fontSize: base * _cellStyle.subtitleFontSize,
                    fontFamily: _cellStyle.subtitleFontFamily,
                    color: _cellStyle.subtitleColor,
                    height: _kSubtitleLineHeight,
                    decoration: TextDecoration.none,
                  ),
                  textAlign: TextAlign.justify,
                ),
              ),
            // 点点点指示器 + gallery-txt 提示：同屏形态随字号公式
            // 定位（20号→462.5/481.5、52号→578 实拍锚定），放不下
            // 的元素自动贴底/隐藏
            if (showDotted)
              Positioned(
                left: 0,
                right: 0,
                top: _dottedPositionedTopOf(context),
                child: _buildDottedIndicator(),
              ),
            if (_showGalleryTxt(context))
              Positioned(
                left: 0,
                right: 0,
                top: _galleryTxtPositionedTopOf(context),
                child: _buildGalleryTxt(),
              ),
          ],
        ),
      ),
    );
  }

  /// dotted 行的 Positioned top：圆点墨顶（SafeArea 相对）− 圆点在行内
  /// 的垂直居中偏移；放不下则贴底兜底
  double _dottedPositionedTopOf(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final pageH = MediaQuery.sizeOf(context).height - safe.top - safe.bottom;
    final base = widget.baseFontSize;
    final inkTop = _dottedInkTopOf(base);
    final centering =
        (_dotActiveSizeOf(base) - _dotSizeOf(base)) / 2;
    const dotRow = 6.0;
    if (inkTop + dotRow > pageH - 2) {
      return pageH - dotRow - 2 - centering;
    }
    return inkTop - centering;
  }

  /// gallery-txt 是否显示（0.7em 行塞进页内才显示）
  bool _showGalleryTxt(BuildContext context) {
    if (_txtText.isEmpty) return false;
    final safe = MediaQuery.paddingOf(context);
    final pageH = MediaQuery.sizeOf(context).height - safe.top - safe.bottom;
    final txtH = widget.baseFontSize * 0.7;
    return _txtInkTopOf(widget.baseFontSize) + txtH <= pageH - 2;
  }

  /// gallery-txt 的 Positioned top（墨顶 − CJK 墨迹上留白约 1）
  double _galleryTxtPositionedTopOf(BuildContext context) =>
      _txtInkTopOf(widget.baseFontSize) - 1;

  /// dotted 是否占用 PageView 底部空间（多图时）
  double dottedHeightOf(bool showDotted) =>
      showDotted && widget.images.length > 1 ? _kDottedHeight : 0.0;

  /// gallery-txt 提示（原作 CSS: margin 1em auto / 0.7em / 居中 /
  /// DK-HEITI sans-serif / text-shadow 0 1 1px #fff；
  /// 多看 20号 实拍「滑动切换，点击放大」墨顶 481.5）
  Widget _buildGalleryTxt() {
    return Text(
      _txtText,
      style: TextStyle(
        fontSize: widget.baseFontSize * 0.7,
        fontFamily: 'sans-serif',
        color: widget.textColor,
        decoration: TextDecoration.none,
        height: 1.0,
      ),
      textAlign: TextAlign.center,
    );
  }

  /// 画廊 h3 标题文本（首页与第一张图同屏，对齐多看小字号形态）
  ///
  /// 原作 CSS: margin: 2em auto; font-size: 1.5em; bold; 居中;
  /// DK-XIAOBIAOSONG serif; text-shadow 0 1 1px #fff。
  /// 字形顶 = SafeArea 24 + 2em + extraTop（随字号公式，dk 实测锚定）。
  /// ★ Text height 1.0：行盒 = 字形高，galleryDump 的 title.y 直接等于
  /// 多看字形顶，可像素级对比。定位（Positioned top）由 itemBuilder 完成。
  Widget _buildTitleText({Key? titleKey}) {
    final shadows = _titleStyle.textShadow != null
        ? [_titleStyle.textShadow!]
        : <Shadow>[];

    return Text(
      _titleText,
      key: titleKey,
      style: TextStyle(
        fontSize: widget.baseFontSize * _titleStyle.fontSize,
        fontWeight: _titleStyle.bold ? FontWeight.bold : FontWeight.normal,
        fontFamily: _titleStyle.fontFamily,
        color: _titleStyle.color ?? widget.textColor,
        decoration: TextDecoration.none,
        height: 1.0,
        shadows: shadows,
      ),
      textAlign: TextAlign.center,
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
  /// - span 尺寸由实拍拟合（2026-08-29 dk 20号/52号 逐像素）：
  ///   点距 = 0.4615B+0.287、非激活点径 = 0.297B−1.212、
  ///   激活点径 = 2.19+0.198B（激活更大更深）
  ///
  /// 本方法只负责圆点行本身；定位由 build() 的 Positioned 按公式完成。
  Widget _buildDottedIndicator() {
    if (widget.images.length <= 1) return const SizedBox.shrink();

    final textRgb = widget.textColor.toARGB32();
    final r = (textRgb >> 16) & 0xFF;
    final g = (textRgb >> 8) & 0xFF;
    final b = textRgb & 0xFF;
    final activeDot = _imageIndex;
    final base = widget.baseFontSize;
    final pitch = _dotPitchOf(base);
    final inactive = _dotSizeOf(base);
    final active = _dotActiveSizeOf(base);

    return Row(
      key: _dottedKey,
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(widget.images.length, (i) {
        final isActive = i == activeDot;
        final size = isActive ? active : inactive;
        return SizedBox(
          width: pitch,
          height: active,
          child: Center(
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive
                    ? Color.fromARGB(255, r, g, b)
                    : Color.fromARGB(110, r, g, b),
              ),
            ),
          ),
        );
      }),
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
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 8, 63),
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

/// 画廊标题页 h3 样式（原作 .gallery-title：2em auto / 1.5em / bold /
/// DK-XIAOBIAOSONG serif / text-shadow 0 1 1px #fff）
class _GalleryTitleStyle {
  final double fontSize;
  final bool bold;
  final Color? color;
  final Shadow? textShadow;
  final double marginTop;
  final double marginBottom;
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
