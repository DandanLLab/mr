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
        color: widget.backgroundColor,
        alignment: Alignment.center,
        child: Text('画廊无图片', style: TextStyle(color: widget.textColor)),
      );
    }

    return Container(
      color: widget.backgroundColor,
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildPageView()),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  /// 顶部：章节标题 + 返回提示
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DesignTokens.spacingMd,
        vertical: DesignTokens.spacingSm,
      ),
      child: Text(
        widget.chapterTitle,
        style: TextStyle(
          color: widget.textColor,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    );
  }

  /// 底部：页码指示器 + 滑动提示
  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: DesignTokens.spacingMd,
        vertical: DesignTokens.spacingSm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_currentIndex + 1} / ${widget.images.length}',
            style: TextStyle(
              color: widget.textColor.withValues(alpha: 0.7),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '滑动切换，点击放大',
            style: TextStyle(
              color: widget.textColor.withValues(alpha: 0.5),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  /// 主体：PageView 横向滑动
  Widget _buildPageView() {
    return GestureDetector(
      // 检测边界滑动意图：在第一页往左滑或最后一页往右滑
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        // velocity > 0 表示往右滑（对应往前一章），< 0 表示往左滑（对应往后一章）
        if (velocity > 200 && _currentIndex == 0) {
          _handlePreviousBoundary();
        } else if (velocity < -200 &&
            _currentIndex == widget.images.length - 1) {
          _handleNextBoundary();
        }
      },
      child: PageView.builder(
        controller: _pageController,
        itemCount: widget.images.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          final image = widget.images[index];
          return _GalleryImageItem(
            image: image,
            index: index,
            textColor: widget.textColor,
            onTap: () => _showFullScreenPreview(index),
          );
        },
      ),
    );
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

  const _GalleryImageItem({
    required this.image,
    required this.index,
    required this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: DesignTokens.spacingMd,
          vertical: DesignTokens.spacingSm,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(child: _buildImage()),
            if (image.maintitle.isNotEmpty || image.subtitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: DesignTokens.spacingSm),
                child: Column(
                  children: [
                    if (image.maintitle.isNotEmpty)
                      Text(
                        image.maintitle,
                        // 使用从 EPUB CSS 提取的原作者样式，
                        // 缺失时用兜底样式（黑体风格、居中）
                        style: _buildMaintitleStyle(),
                        textAlign: _resolveTextAlign(
                          image.maintitleStyle?.textAlign,
                          TextAlign.center,
                        ),
                      ),
                    if (image.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        image.subtitle,
                        // 使用从 EPUB CSS 提取的原作者样式，
                        // 缺失时用兜底样式（细黑体风格、居中）
                        style: _buildSubtitleStyle(),
                        textAlign: _resolveTextAlign(
                          image.subtitleStyle?.textAlign,
                          TextAlign.center,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 构建 maintitle 的 TextStyle
  ///
  /// 优先使用从 EPUB CSS 提取的原作者样式（字号/颜色/字重/行高），
  /// 缺失的属性用兜底值。字号 em 乘以基础字号 16px 得到实际 px。
  TextStyle _buildMaintitleStyle() {
    final style = image.maintitleStyle;
    // 基础字号 16px（与 EPUB 根字号一致）
    const baseFontSize = 16.0;
    // 兜底：0.9em（对齐多看 .duokan-image-maintitle 默认字号）
    final fontSizeEm = style?.fontSizeEm ?? 0.9;
    // 兜底：深色背景用阅读器 textColor，浅色背景用 #1F4150
    final color = style?.color != null
        ? Color(style!.color!)
        : (_isLightBg(textColor)
            ? const Color(0xFF1F4150)
            : textColor);
    // 兜底：w600（对齐黑体风格）
    final fontWeight = style?.fontWeight != null
        ? FontWeight.values[(style!.fontWeight! / 100).round().clamp(0, 8)]
        : FontWeight.w600;
    // 兜底：1.25
    final height = style?.lineHeight ?? 1.25;

    return TextStyle(
      color: color,
      fontSize: fontSizeEm * baseFontSize,
      fontWeight: fontWeight,
      height: height,
    );
  }

  /// 构建 subtitle 的 TextStyle
  TextStyle _buildSubtitleStyle() {
    final style = image.subtitleStyle;
    const baseFontSize = 16.0;
    // 兜底：0.7em（对齐多看 .duokan-image-subtitle 默认字号）
    final fontSizeEm = style?.fontSizeEm ?? 0.7;
    final color = style?.color != null
        ? Color(style!.color!)
        : (_isLightBg(textColor)
            ? const Color(0xFF3A3348)
            : textColor.withValues(alpha: 0.7));
    // 兜底：w400
    final fontWeight = style?.fontWeight != null
        ? FontWeight.values[(style!.fontWeight! / 100).round().clamp(0, 8)]
        : FontWeight.w400;
    // 兜底：1.5
    final height = style?.lineHeight ?? 1.5;

    return TextStyle(
      color: color,
      fontSize: fontSizeEm * baseFontSize,
      fontWeight: fontWeight,
      height: height,
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

  const _GalleryFullScreenViewer({
    required this.images,
    required this.initialIndex,
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
          // 右下角：信息面板（AnimatedSwitcher 动画）
          _buildInfoPanel(),
        ],
      ),
    );
  }

  /// 构建可缩放的单张图片
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

  /// 右下角信息面板
  ///
  /// 使用 AnimatedSwitcher 在切换图片时实现淡入淡出 + 上滑动画。
  /// easeInOutCubicEmphasized：比 easeOutCubic 更柔和，有"弹性"感。
  /// 大标题用大字号粗体，副标题用小字号常规。
  Widget _buildInfoPanel() {
    final image = widget.images[_currentIndex];
    final hasInfo =
        image.maintitle.isNotEmpty || image.subtitle.isNotEmpty;
    if (!hasInfo) return const SizedBox.shrink();

    return Positioned(
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.88,
          ),
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black.withValues(alpha: 0.75),
              ],
            ),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            // easeInOutCubicEmphasized：Material 3 推荐曲线，比 easeOutCubic 更柔和
            switchInCurve: Curves.easeInOutCubicEmphasized,
            switchOutCurve: Curves.easeInOutCubicEmphasized.flipped,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.3),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: Column(
              key: ValueKey(_currentIndex),
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (image.maintitle.isNotEmpty)
                  Text(
                    image.maintitle,
                    // 全屏预览用白色系（黑底），但保留原作者字号/字重/行高
                    style: _buildFullScreenMaintitleStyle(image.maintitleStyle),
                    textAlign: _resolveTextAlign(
                      image.maintitleStyle?.textAlign,
                      TextAlign.right,
                    ),
                  ),
                if (image.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    image.subtitle,
                    style: _buildFullScreenSubtitleStyle(image.subtitleStyle),
                    textAlign: _resolveTextAlign(
                      image.subtitleStyle?.textAlign,
                      TextAlign.right,
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

  /// 全屏预览的 maintitle 样式
  ///
  /// 黑底白字，但保留原作者的字号/字重/行高。
  /// 字号放大 1.2 倍（全屏预览比画廊小图更大），上限 24px。
  TextStyle _buildFullScreenMaintitleStyle(EpubGalleryTextStyle? style) {
    const baseFontSize = 16.0;
    final fontSizeEm = style?.fontSizeEm ?? 0.9;
    // 全屏放大 1.2 倍，上限 24px
    final fontSize = (fontSizeEm * baseFontSize * 1.2).clamp(14.0, 24.0);
    final fontWeight = style?.fontWeight != null
        ? FontWeight.values[(style!.fontWeight! / 100).round().clamp(0, 8)]
        : FontWeight.w600;
    final height = style?.lineHeight ?? 1.3;
    return TextStyle(
      color: Colors.white,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: height,
    );
  }

  /// 全屏预览的 subtitle 样式
  TextStyle _buildFullScreenSubtitleStyle(EpubGalleryTextStyle? style) {
    const baseFontSize = 16.0;
    final fontSizeEm = style?.fontSizeEm ?? 0.7;
    // 全屏放大 1.2 倍，上限 18px
    final fontSize = (fontSizeEm * baseFontSize * 1.2).clamp(11.0, 18.0);
    final fontWeight = style?.fontWeight != null
        ? FontWeight.values[(style!.fontWeight! / 100).round().clamp(0, 8)]
        : FontWeight.w400;
    final height = style?.lineHeight ?? 1.5;
    return TextStyle(
      color: Colors.white.withValues(alpha: 0.85),
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: height,
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
