import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_provider.dart';

/// Keeps the app wallpaper outside the navigator's page transitions.
class ThemedBackground extends StatelessWidget {
  final Widget child;

  const ThemedBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const Positioned.fill(
          child: RepaintBoundary(child: _BackgroundLayer()),
        ),
        child,
      ],
    );
  }
}

class _BackgroundLayer extends StatelessWidget {
  const _BackgroundLayer();

  @override
  Widget build(BuildContext context) {
    final settings = context.select<AppProvider, _BackgroundSettings>(
      (provider) => _BackgroundSettings(
        imagePath: provider.currentBackgroundImage,
        blur: provider.currentBackgroundBlur,
      ),
    );

    final imagePath = settings.imagePath;
    if (imagePath == null || imagePath.isEmpty) {
      return const SizedBox.shrink();
    }

    return _StableBackgroundImage(imagePath: imagePath, blur: settings.blur);
  }
}

class _BackgroundSettings {
  final String? imagePath;
  final int blur;

  const _BackgroundSettings({required this.imagePath, required this.blur});

  @override
  bool operator ==(Object other) {
    return other is _BackgroundSettings &&
        other.imagePath == imagePath &&
        other.blur == blur;
  }

  @override
  int get hashCode => Object.hash(imagePath, blur);
}

/// Resolves the wallpaper once and keeps the decoded frame while pages rebuild.
class _StableBackgroundImage extends StatefulWidget {
  final String imagePath;
  final int blur;

  const _StableBackgroundImage({required this.imagePath, required this.blur});

  @override
  State<_StableBackgroundImage> createState() => _StableBackgroundImageState();
}

class _StableBackgroundImageState extends State<_StableBackgroundImage> {
  ImageStream? _imageStream;
  ImageStreamListener? _imageStreamListener;
  ui.Image? _image;
  Object? _loadError;
  bool _hasResolvedImage = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_hasResolvedImage) {
      _resolveImage();
    }
  }

  @override
  void didUpdateWidget(_StableBackgroundImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imagePath != widget.imagePath) {
      _resolveImage();
    }
  }

  @override
  void dispose() {
    _stopListening();
    _image?.dispose();
    super.dispose();
  }

  void _resolveImage() {
    _hasResolvedImage = true;
    _loadError = null;
    _stopListening();

    final provider = _createImageProvider(widget.imagePath);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (imageInfo, synchronousCall) {
        if (!mounted || _imageStream != stream) {
          imageInfo.dispose();
          return;
        }
        if (_image == imageInfo.image && _loadError == null) {
          imageInfo.dispose();
          return;
        }
        final decodedImage = imageInfo.image.clone();
        imageInfo.dispose();
        final previousImage = _image;
        setState(() {
          _image = decodedImage;
          _loadError = null;
        });
        previousImage?.dispose();
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!mounted || _imageStream != stream) {
          return;
        }
        setState(() {
          _loadError = error;
        });
      },
    );

    _imageStream = stream;
    _imageStreamListener = listener;
    stream.addListener(listener);
  }

  void _stopListening() {
    final stream = _imageStream;
    final listener = _imageStreamListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _imageStream = null;
    _imageStreamListener = null;
  }

  ImageProvider _createImageProvider(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return NetworkImage(path);
    }
    if (path.startsWith('assets://')) {
      return AssetImage(path.replaceFirst('assets://', ''));
    }
    return FileImage(File(path));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final image = _image;

    if (image == null || _loadError != null) {
      return ColoredBox(color: colorScheme.surface);
    }

    Widget imageLayer = RawImage(
      image: image,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      filterQuality: FilterQuality.medium,
    );

    if (widget.blur > 0) {
      imageLayer = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: widget.blur.toDouble(),
          sigmaY: widget.blur.toDouble(),
          tileMode: TileMode.clamp,
        ),
        child: imageLayer,
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        imageLayer,
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: isDark
                  ? [
                      Colors.black.withValues(alpha: 0.15),
                      Colors.black.withValues(alpha: 0.20),
                      Colors.black.withValues(alpha: 0.25),
                      Colors.black.withValues(alpha: 0.30),
                    ]
                  : [
                      Colors.white.withValues(alpha: 0.10),
                      Colors.white.withValues(alpha: 0.15),
                      Colors.white.withValues(alpha: 0.20),
                      Colors.white.withValues(alpha: 0.25),
                    ],
              stops: const [0.0, 0.3, 0.7, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

/// Small wallpaper preview used by theme settings.
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
    final path = imagePath;

    if (path == null || path.isEmpty) {
      return _buildFallback(colorScheme, Icons.image_not_supported_outlined);
    }

    final ImageProvider<Object> imageProvider;
    if (path.startsWith('http://') || path.startsWith('https://')) {
      imageProvider = NetworkImage(path);
    } else if (path.startsWith('assets://')) {
      imageProvider = AssetImage(path.replaceFirst('assets://', ''));
    } else {
      imageProvider = FileImage(File(path));
    }

    Widget imageWidget = Image(
      image: imageProvider,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) {
        return _buildFallback(colorScheme, Icons.broken_image_outlined);
      },
    );

    if (blur > 0) {
      imageWidget = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: blur.toDouble(),
          sigmaY: blur.toDouble(),
        ),
        child: imageWidget,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.hardEdge,
      child: SizedBox(width: width, height: height, child: imageWidget),
    );
  }

  Widget _buildFallback(ColorScheme colorScheme, IconData icon) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: colorScheme.onSurfaceVariant, size: 32),
    );
  }
}
