import 'dart:ui';
import 'package:flutter/material.dart';

/// 液态玻璃效果视图 - 参考 legado-main 的 StableLiquidGlassView
/// 实现高级的模糊、折射、色散效果
class LiquidGlassView extends StatefulWidget {
  final Widget? child;
  final double cornerRadius;
  final double blurRadius;
  final double dispersion;
  final double tintAlpha;
  final Color? tintColor;
  final double refractionHeight;
  final double refractionOffset;
  final bool elasticEnabled;
  final bool touchEffectEnabled;

  const LiquidGlassView({
    super.key,
    this.child,
    this.cornerRadius = 20.0,
    this.blurRadius = 20.0,
    this.dispersion = 0.3,
    this.tintAlpha = 0.1,
    this.tintColor,
    this.refractionHeight = 30.0,
    this.refractionOffset = 60.0,
    this.elasticEnabled = true,
    this.touchEffectEnabled = true,
  });

  @override
  State<LiquidGlassView> createState() => LiquidGlassViewState();
}

class LiquidGlassViewState extends State<LiquidGlassView>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  bool _isPressed = false;
  Offset? _touchPosition;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void setBlurRadius(double radius) {
    if (widget.blurRadius != radius) {
      setState(() {});
    }
  }

  void setTintAlpha(double alpha) {
    if (widget.tintAlpha != alpha) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.touchEffectEnabled
          ? (details) {
              setState(() {
                _isPressed = true;
                _touchPosition = details.localPosition;
              });
            }
          : null,
      onTapUp: widget.touchEffectEnabled
          ? (_) {
              setState(() {
                _isPressed = false;
                _touchPosition = null;
              });
            }
          : null,
      onTapCancel: widget.touchEffectEnabled
          ? () {
              setState(() {
                _isPressed = false;
                _touchPosition = null;
              });
            }
          : null,
      child: AnimatedBuilder(
        animation: _pulseAnimation,
        builder: (context, child) {
          return CustomPaint(
            painter: LiquidGlassPainter(
              pulseValue: _pulseAnimation.value,
              cornerRadius: widget.cornerRadius,
              blurRadius: widget.blurRadius,
              dispersion: widget.dispersion,
              tintAlpha: widget.tintAlpha,
              tintColor: widget.tintColor ?? Theme.of(context).colorScheme.surface,
              refractionHeight: widget.refractionHeight,
              refractionOffset: widget.refractionOffset,
              isPressed: _isPressed,
              touchPosition: _touchPosition,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.cornerRadius),
              clipBehavior: Clip.hardEdge,
              child: widget.child,
            ),
          );
        },
      ),
    );
  }
}

class LiquidGlassPainter extends CustomPainter {
  final double pulseValue;
  final double cornerRadius;
  final double blurRadius;
  final double dispersion;
  final double tintAlpha;
  final Color tintColor;
  final double refractionHeight;
  final double refractionOffset;
  final bool isPressed;
  final Offset? touchPosition;

  LiquidGlassPainter({
    required this.pulseValue,
    required this.cornerRadius,
    required this.blurRadius,
    required this.dispersion,
    required this.tintAlpha,
    required this.tintColor,
    required this.refractionHeight,
    required this.refractionOffset,
    required this.isPressed,
    this.touchPosition,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(cornerRadius));

    // 绘制多层玻璃效果
    _drawGlassLayers(canvas, size, rrect);
    
    // 绘制折射高光
    _drawRefraction(canvas, size, rrect);
    
    // 绘制边框
    _drawBorder(canvas, size, rrect);
    
    // 绘制触摸效果
    if (isPressed && touchPosition != null) {
      _drawTouchEffect(canvas, size, rrect);
    }
  }

  void _drawGlassLayers(Canvas canvas, Size size, RRect rrect) {
    // 基础玻璃层
    final basePaint = Paint()
      ..color = tintColor.withValues(alpha: tintAlpha)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(rrect, basePaint);

    // 渐变层 - 模拟玻璃的深度
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        tintColor.withValues(alpha: tintAlpha * 0.8),
        tintColor.withValues(alpha: tintAlpha * 0.4),
        tintColor.withValues(alpha: tintAlpha * 0.6),
      ],
      stops: const [0.0, 0.5, 1.0],
    );
    final gradientPaint = Paint()
      ..shader = gradient.createShader(rrect.outerRect)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(rrect, gradientPaint);

    // 色散效果 - 模拟光的分散
    if (dispersion > 0) {
      final dispersionPaint = Paint()
        ..color = tintColor.withValues(alpha: dispersion * 0.1)
        ..style = PaintingStyle.fill
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurRadius * 0.5);
      canvas.drawRRect(rrect, dispersionPaint);
    }
  }

  void _drawRefraction(Canvas canvas, Size size, RRect rrect) {
    // 顶部高光折射
    final refractionPath = Path();
    final topY = refractionOffset;
    final bottomY = topY + refractionHeight;
    
    refractionPath.moveTo(rrect.left + cornerRadius, topY);
    refractionPath.lineTo(rrect.right - cornerRadius, topY);
    refractionPath.lineTo(rrect.right - cornerRadius * 1.5, bottomY);
    refractionPath.lineTo(rrect.left + cornerRadius * 1.5, bottomY);
    refractionPath.close();

    final refractionGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.white.withValues(alpha: 0.15 + pulseValue * 0.05),
        Colors.white.withValues(alpha: 0.05),
        Colors.transparent,
      ],
    );
    final refractionPaint = Paint()
      ..shader = refractionGradient.createShader(
        Rect.fromLTWH(0, topY, size.width, refractionHeight),
      )
      ..style = PaintingStyle.fill;
    canvas.drawPath(refractionPath, refractionPaint);

    // 底部反射光
    final bottomReflectionPath = Path();
    final reflectTopY = size.height - refractionHeight * 0.6;
    final reflectBottomY = size.height - cornerRadius;
    
    bottomReflectionPath.moveTo(rrect.left + cornerRadius, reflectTopY);
    bottomReflectionPath.lineTo(rrect.right - cornerRadius, reflectTopY);
    bottomReflectionPath.lineTo(rrect.right - cornerRadius, reflectBottomY);
    bottomReflectionPath.lineTo(rrect.left + cornerRadius, reflectBottomY);
    bottomReflectionPath.close();

    final reflectionGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Colors.transparent,
        Colors.white.withValues(alpha: 0.08),
      ],
    );
    final reflectionPaint = Paint()
      ..shader = reflectionGradient.createShader(
        Rect.fromLTWH(0, reflectTopY, size.width, refractionHeight * 0.6),
      )
      ..style = PaintingStyle.fill;
    canvas.drawPath(bottomReflectionPath, reflectionPaint);
  }

  void _drawBorder(Canvas canvas, Size size, RRect rrect) {
    // 外边框 - 模拟玻璃边缘
    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRRect(rrect, borderPaint);

    // 内边框
    final innerBorderPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    final innerRrect = RRect.fromRectAndRadius(
      rrect.outerRect.deflate(0.5),
      Radius.circular(cornerRadius - 0.5),
    );
    canvas.drawRRect(innerRrect, innerBorderPaint);
  }

  void _drawTouchEffect(Canvas canvas, Size size, RRect rrect) {
    if (touchPosition == null) return;

    // 触摸涟漪效果
    final rippleRadius = 60.0;
    final ripplePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10);

    canvas.drawCircle(touchPosition!, rippleRadius * 0.5, ripplePaint);
  }

  @override
  bool shouldRepaint(LiquidGlassPainter oldDelegate) {
    return pulseValue != oldDelegate.pulseValue ||
        cornerRadius != oldDelegate.cornerRadius ||
        blurRadius != oldDelegate.blurRadius ||
        isPressed != oldDelegate.isPressed ||
        touchPosition != oldDelegate.touchPosition;
  }
}

/// 毛玻璃效果视图 - 简化版
class FrostedGlassView extends StatelessWidget {
  final Widget? child;
  final double blurRadius;
  final Color? backgroundColor;
  final double opacity;
  final double cornerRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  const FrostedGlassView({
    super.key,
    this.child,
    this.blurRadius = 10.0,
    this.backgroundColor,
    this.opacity = 0.7,
    this.cornerRadius = 16.0,
    this.padding,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = backgroundColor ?? Theme.of(context).colorScheme.surface;
    
    Widget content = ClipRRect(
      borderRadius: BorderRadius.circular(cornerRadius),
      clipBehavior: Clip.hardEdge,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurRadius, sigmaY: blurRadius),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: bgColor.withValues(alpha: opacity),
            borderRadius: BorderRadius.circular(cornerRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.2),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );

    if (margin != null) {
      content = Padding(padding: margin!, child: content);
    }

    return content;
  }
}

/// 导航指示器 - 选中项的动态指示器
class NavigationIndicator extends StatefulWidget {
  final int selectedIndex;
  final int itemCount;
  final double width;
  final double height;
  final Color? color;
  final double cornerRadius;

  const NavigationIndicator({
    super.key,
    required this.selectedIndex,
    required this.itemCount,
    this.width = 48.0,
    this.height = 4.0,
    this.color,
    this.cornerRadius = 2.0,
  });

  @override
  State<NavigationIndicator> createState() => NavigationIndicatorState();
}

class NavigationIndicatorState extends State<NavigationIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  double _position = 0.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void animateTo(double targetPosition) {
    if (_position == targetPosition) return;
    
    final startPosition = _position;
    _animation = Tween<double>(begin: startPosition, end: targetPosition).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Positioned(
          left: _animation.value,
          child: Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              color: widget.color ?? Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(widget.cornerRadius),
              boxShadow: [
                BoxShadow(
                  color: (widget.color ?? Theme.of(context).colorScheme.primary)
                      .withValues(alpha: 0.3),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
