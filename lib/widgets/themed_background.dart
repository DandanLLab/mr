import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';

/// 全局背景图片组件 - 参考 legados 的背景图片应用方式
/// legados 使用 Bitmap.resizeAndRecycle 将图片缩放到屏幕大小
/// Flutter 中使用 BoxFit.cover 实现类似效果
///
/// 优化说明：
/// 1. 使用 context.select 只监听需要的属性，避免不必要的重建
/// 2. 使用 RepaintBoundary 优化重绘
class ThemedBackground extends StatelessWidget {
  final Widget child;
  final bool applyOverlay; // 是否应用半透明遮罩

  const ThemedBackground({
    super.key,
    required this.child,
    this.applyOverlay = true,
  });

  @override
  Widget build(BuildContext context) {
    // 使用 context.select 只监听需要的属性，避免不必要的重建
    final backgroundImage = context.select<AppProvider, String?>(
      (provider) => provider.currentBackgroundImage,
    );
    final backgroundBlur = context.select<AppProvider, int>(
      (provider) => provider.currentBackgroundBlur,
    );
    final brightness = context.select<AppProvider, Brightness>(
      (provider) => provider.themeMode == ThemeMode.dark
          ? Brightness.dark
          : Brightness.light,
    );

    // 如果没有背景图片，直接返回子组件
    if (backgroundImage == null || backgroundImage.isEmpty) {
      return child;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // 背景图片层 - 使用 RepaintBoundary 优化重绘
        Positioned.fill(
          child: RepaintBoundary(
            child: _BackgroundImageWidget(
              imagePath: backgroundImage,
              blur: backgroundBlur,
              brightness: brightness,
            ),
          ),
        ),
        // 半透明遮罩层 - 使用 RepaintBoundary 优化重绘
        if (applyOverlay)
          Positioned.fill(
            child: RepaintBoundary(
              child: _OverlayWidget(brightness: brightness),
            ),
          ),
        // 内容层
        child,
      ],
    );
  }
}

/// 背景图片组件 - 独立出来避免不必要的重建
class _BackgroundImageWidget extends StatelessWidget {
  final String imagePath;
  final int blur;
  final Brightness brightness;

  const _BackgroundImageWidget({
    required this.imagePath,
    required this.blur,
    required this.brightness,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    ImageProvider imageProvider;

    try {
      if (imagePath.startsWith('http://') || imagePath.startsWith('https://')) {
        // 网络图片
        imageProvider = NetworkImage(imagePath);
      } else if (imagePath.startsWith('assets://')) {
        // 资源图片
        imageProvider = AssetImage(imagePath.replaceFirst('assets://', ''));
      } else {
        // 本地文件
        imageProvider = FileImage(File(imagePath));
      }

      Widget imageWidget = Image(
        image: imageProvider,
        fit: BoxFit.cover, // 关键：使用 cover 填充整个屏幕，保持比例
        alignment: Alignment.center, // 居中对齐
        errorBuilder: (context, error, stackTrace) {
          return Container(
            color: colorScheme.background,
          );
        },
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Container(
            color: colorScheme.background,
            child: Center(
              child: CircularProgressIndicator(
                value: loadingProgress.expectedTotalBytes != null
                    ? loadingProgress.cumulativeBytesLoaded /
                        loadingProgress.expectedTotalBytes!
                    : null,
                strokeWidth: 2,
              ),
            ),
          );
        },
      );

      // 如果有模糊度，应用模糊效果
      if (blur > 0) {
        return ImageFiltered(
          imageFilter: ImageFilter.blur(
            sigmaX: blur.toDouble(),
            sigmaY: blur.toDouble(),
          ),
          child: imageWidget,
        );
      }

      return imageWidget;
    } catch (e) {
      return Container(
        color: colorScheme.background,
      );
    }
  }
}

/// 遮罩层组件 - 独立出来避免不必要的重建
class _OverlayWidget extends StatelessWidget {
  final Brightness brightness;

  const _OverlayWidget({required this.brightness});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: _getOverlayGradientColors(),
          stops: const [0.0, 0.3, 0.7, 1.0],
        ),
      ),
    );
  }

  /// 获取遮罩渐变颜色 - 参考 legados 的背景图片遮罩效果
  /// 使用渐变遮罩，使内容更易读
  List<Color> _getOverlayGradientColors() {
    if (brightness == Brightness.dark) {
      // 夜间模式：使用深色渐变遮罩
      return [
        Colors.black.withOpacity(0.15),
        Colors.black.withOpacity(0.20),
        Colors.black.withOpacity(0.25),
        Colors.black.withOpacity(0.30),
      ];
    } else {
      // 日间模式：使用浅色渐变遮罩
      return [
        Colors.white.withOpacity(0.10),
        Colors.white.withOpacity(0.15),
        Colors.white.withOpacity(0.20),
        Colors.white.withOpacity(0.25),
      ];
    }
  }
}

/// 背景图片预览组件 - 用于主题设置页面预览
class BackgroundImagePreview extends StatelessWidget {
  final String? imagePath;
  final int blur;
  final double width;
  final double height;

  const BackgroundImagePreview({
    super.key,
    this.imagePath,
    this.blur = 0,
    this.width = 100,
    this.height = 150,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (imagePath == null || imagePath!.isEmpty) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.image_not_supported_outlined,
          color: colorScheme.onSurfaceVariant,
          size: 32,
        ),
      );
    }

    ImageProvider imageProvider;

    try {
      if (imagePath!.startsWith('http://') || imagePath!.startsWith('https://')) {
        imageProvider = NetworkImage(imagePath!);
      } else if (imagePath!.startsWith('assets://')) {
        imageProvider = AssetImage(imagePath!.replaceFirst('assets://', ''));
      } else {
        imageProvider = FileImage(File(imagePath!));
      }

      Widget imageWidget = Image(
        image: imageProvider,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.broken_image_outlined,
              color: colorScheme.onSurfaceVariant,
              size: 32,
            ),
          );
        },
      );

      if (blur > 0) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: width,
            height: height,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: blur.toDouble(),
                sigmaY: blur.toDouble(),
              ),
              child: imageWidget,
            ),
          ),
        );
      }

      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: width,
          height: height,
          child: imageWidget,
        ),
      );
    } catch (e) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.error_outline,
          color: colorScheme.onSurfaceVariant,
          size: 32,
        ),
      );
    }
  }
}
