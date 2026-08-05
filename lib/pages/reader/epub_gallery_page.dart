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
  /// 全屏预览支持：
  /// - PageView 横向滑动切换图片
  /// - InteractiveViewer 双指缩放（1-4x）+ 拖动查看细节
  /// - 右下角信息面板（AnimatedSwitcher 淡入淡出）
  /// - 双击切换缩放（1.0 ↔ 2.5）
  /// - 点击空白关闭
  void _showFullScreenPreview(int initialIndex) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black87,
        transitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) {
          return _GalleryFullScreenViewer(
            images: widget.images,
            initialIndex: initialIndex,
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
            textColor: widget.textColor,
            onTap: () => _showFullScreenPreview(index),
          );
        },
      ),
    );
  }
}

/// 单张画廊图片 item
class _GalleryImageItem extends StatelessWidget {
  final EpubGalleryImage image;
  final Color textColor;
  final VoidCallback onTap;

  const _GalleryImageItem({
    required this.image,
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
                        style: TextStyle(
                          color: textColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    if (image.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        image.subtitle,
                        style: TextStyle(
                          color: textColor.withValues(alpha: 0.7),
                          fontSize: 12,
                          height: 1.4,
                        ),
                        textAlign: TextAlign.center,
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

  /// 根据图片 src 类型选择渲染方式
  ///
  /// - data: URI → Image.memory（base64 解码）
  /// - 本地路径 → Image.file
  /// - 其他（http/file://）→ Image.network 兜底
  Widget _buildImage() {
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
    // 本地绝对路径（解压模式）或 file:// URI
    final filePath = src.startsWith('file://') ? src.substring(7) : src;
    if (filePath.contains('/') || filePath.contains('\\')) {
      return Image.file(
        File(filePath),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _buildError(),
      );
    }
    // 兜底：当作 URL
    return Image.network(
      src,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => _buildError(),
    );
  }

  /// 解析 data: URI 为字节
  Uint8List? _decodeDataUri(String dataUri) {
    try {
      // data:image/jpeg;base64,<...>
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
/// - InteractiveViewer 双指缩放（1-4x）+ 拖动查看细节（scale > 1.0 时）
/// - 双击切换缩放（1.0 ↔ 2.5x），缩放后双击复位
/// - 右下角信息面板（AnimatedSwitcher 淡入淡出 + 上滑动画）
///   - 大标题：18px FontWeight.w600
///   - 副标题：13px FontWeight.w400 半透明
/// - 顶部页码指示器 + 关闭按钮
/// - 点击关闭按钮关闭
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
  }

  @override
  void dispose() {
    _pageController.dispose();
    _transformCtrl.dispose();
    super.dispose();
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
            physics: _currentScale > 1.05
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
            itemBuilder: (context, index) {
              return _buildZoomableImage(widget.images[index]);
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
  /// GestureDetector 检测双击缩放，InteractiveViewer 处理双指缩放和拖动。
  /// HitTestBehavior.opaque 让图片区域吸收点击，防止穿透到下层。
  Widget _buildZoomableImage(EpubGalleryImage image) {
    return GestureDetector(
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
          child: _buildImage(image),
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
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.4),
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
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                    textAlign: TextAlign.right,
                  ),
                if (image.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    image.subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.right,
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
}
