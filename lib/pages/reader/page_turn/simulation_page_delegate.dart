import 'dart:async';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'page_delegate.dart';
import 'horizontal_page_delegate.dart';

/// 仿真翻页代理
///
/// 完整复刻 legado SimulationPageDelegate 的算法：
/// - 贝塞尔曲线计算翻页弧度
/// - 三层绘制：当前页 + 下一页阴影 + 翻起页背面
/// - Matrix 镜像翻转背面
/// - GradientDrawable 等价的阴影渐变
///
/// 算法说明：
/// 1. 触摸点 (touchX, touchY) 对应一个页角 (cornerX, cornerY)
/// 2. 通过 touch 到 corner 的距离计算贝塞尔控制点
/// 3. 用 Path.quadTo 绘制贝塞尔曲线弧形边缘
/// 4. clipPath 裁剪出翻起页形状
/// 5. Matrix 矩阵变换镜像绘制背面
/// 6. 渐变阴影增强立体感
class SimulationPageDelegate extends HorizontalPageDelegate {
  // 不让 x,y 为 0，否则在点计算时会有问题
  double mTouchX = 0.1;
  double mTouchY = 0.1;

  // 拖拽点对应的页脚
  double mCornerX = 1;
  double mCornerY = 1;

  // 是否属于右上左下
  bool mIsRtOrLb = false;

  // 对角线长度
  double mMaxLength = 0;

  // 贝塞尔曲线点
  late final _BezierPoints _p = _BezierPoints();

  // 中点
  double mMiddleX = 0;
  double mMiddleY = 0;
  double mDegrees = 0;
  double mTouchToCornerDis = 0;

  // 阴影画笔
  final Paint _paint = Paint()..style = PaintingStyle.fill;

  // Scroller
  final PageScroller _scroller = PageScroller();

  // 动画刷新定时器
  Timer? _animTimer;

  SimulationPageDelegate() {
    _initShadowDrawables();
  }

  // 阴影渐变
  late final _ShadowDrawables _shadows = _ShadowDrawables();

  void _initShadowDrawables() {
    // 阴影初始化（用 LinearGradient 替代 GradientDrawable）
    // 实际使用时通过 Paint + gradient 绘制
  }

  @override
  void setViewSize(double width, double height) {
    super.setViewSize(width, height);
    mMaxLength = PageDelegateUtils.hypot(width, height);
  }

  /// 计算拖拽点对应的页脚
  void calcCornerXY(double x, double y) {
    mCornerX = x <= viewWidth / 2 ? 0 : viewWidth;
    mCornerY = y <= viewHeight / 2 ? 0 : viewHeight;
    mIsRtOrLb = (mCornerX == 0 && mCornerY == viewHeight) ||
        (mCornerY == 0 && mCornerX == viewWidth);
  }

  @override
  void setDirection(PageDirection dir) {
    super.setDirection(dir);
    switch (dir) {
      case PageDirection.prev:
        // 上一页滑动不出现对角
        if (startX > viewWidth / 2) {
          calcCornerXY(startX, viewHeight);
        } else {
          calcCornerXY(viewWidth - startX, viewHeight);
        }
        break;
      case PageDirection.next:
        if (viewWidth / 2 > startX) {
          calcCornerXY(viewWidth - startX, startY);
        }
        break;
      default:
        break;
    }
  }

  /// 设置触摸点（外部触摸时调用）
  @override
  void setTouchPoint(double x, double y) {
    super.setTouchPoint(x, y);
  }

  /// 计算所有贝塞尔曲线点
  void calcPoints() {
    mTouchX = touchX;
    mTouchY = touchY;

    mMiddleX = (mTouchX + mCornerX) / 2;
    mMiddleY = (mTouchY + mCornerY) / 2;

    // 控制点1
    final dx = mCornerX - mMiddleX;
    final dy = mCornerY - mMiddleY;
    if (dx.abs() < 0.001) {
      _p.control1 = Offset(mMiddleX, mCornerY);
    } else {
      final cx = mMiddleX - dy * dy / dx;
      _p.control1 = Offset(cx, mCornerY);
    }
    _p.control2 = Offset(mCornerX, 0);

    // 控制点2
    final f4 = mCornerY - mMiddleY;
    if (f4.abs() < 0.001) {
      _p.control2 = Offset(mCornerX, mMiddleY - dx * dx / 0.1);
    } else {
      _p.control2 = Offset(mCornerX, mMiddleY - dx * dx / f4);
    }

    // 起点1
    _p.start1 = Offset(_p.control1.dx - (mCornerX - _p.control1.dx) / 2, mCornerY);

    // 限制起点1在视口内
    if (mTouchX > 0 && mTouchX < viewWidth) {
      if (_p.start1.dx < 0 || _p.start1.dx > viewWidth) {
        if (_p.start1.dx < 0) {
          _p.start1 = Offset(viewWidth - _p.start1.dx, _p.start1.dy);
        }
        final f1 = (mCornerX - mTouchX).abs();
        final f2 = viewWidth * f1 / _p.start1.dx;
        mTouchX = (mCornerX - f2).abs();
        final f3 = (mCornerX - mTouchX).abs() * (mCornerY - mTouchY).abs() / f1;
        mTouchY = (mCornerY - f3).abs();

        mMiddleX = (mTouchX + mCornerX) / 2;
        mMiddleY = (mTouchY + mCornerY) / 2;

        final dx2 = mCornerX - mMiddleX;
        final dy2 = mCornerY - mMiddleY;
        _p.control1 = Offset(mMiddleX - dy2 * dy2 / dx2, mCornerY);
        _p.control2 = Offset(mCornerX, 0);

        final f5 = mCornerY - mMiddleY;
        if (f5.abs() < 0.001) {
          _p.control2 = Offset(mCornerX, mMiddleY - dx2 * dx2 / 0.1);
        } else {
          _p.control2 = Offset(mCornerX, mMiddleY - dx2 * dx2 / f5);
        }
        _p.start1 =
            Offset(_p.control1.dx - (mCornerX - _p.control1.dx) / 2, mCornerY);
      }
    }

    // 起点2
    _p.start2 = Offset(
        mCornerX, _p.control2.dy - (mCornerY - _p.control2.dy) / 2);

    mTouchToCornerDis =
        PageDelegateUtils.hypot(mTouchX - mCornerX, mTouchY - mCornerY);

    _p.end1 = PageDelegateUtils.getCross(
        Offset(mTouchX, mTouchY), _p.control1, _p.start1, _p.start2);
    _p.end2 = PageDelegateUtils.getCross(
        Offset(mTouchX, mTouchY), _p.control2, _p.start1, _p.start2);

    _p.vertex1 = Offset(
      (_p.start1.dx + 2 * _p.control1.dx + _p.end1.dx) / 4,
      (2 * _p.control1.dy + _p.start1.dy + _p.end1.dy) / 4,
    );
    _p.vertex2 = Offset(
      (_p.start2.dx + 2 * _p.control2.dx + _p.end2.dx) / 4,
      (2 * _p.control2.dy + _p.start2.dy + _p.end2.dy) / 4,
    );
  }

  /// 主绘制入口
  @override
  void paint(Canvas canvas, Size size) {
    if (!isRunning) return;

    switch (direction) {
      case PageDirection.next:
        calcPoints();
        _drawCurrentPageArea(canvas, curBitmap);
        _drawNextPageAreaAndShadow(canvas, nextBitmap);
        _drawCurrentPageShadow(canvas);
        _drawCurrentBackArea(canvas, curBitmap);
        break;
      case PageDirection.prev:
        calcPoints();
        _drawCurrentPageArea(canvas, prevBitmap);
        _drawNextPageAreaAndShadow(canvas, curBitmap);
        _drawCurrentPageShadow(canvas);
        _drawCurrentBackArea(canvas, prevBitmap);
        break;
      default:
        return;
    }
  }

  /// 绘制翻起页背面（镜像翻转）
  void _drawCurrentBackArea(Canvas canvas, ui.Image? bitmap) {
    if (bitmap == null) return;

    final i = ((_p.start1.dx + _p.control1.dx) / 2).toInt();
    final f1 = (i - _p.control1.dx).abs();
    final i1 = ((_p.start2.dy + _p.control2.dy) / 2).toInt();
    final f2 = (i1 - _p.control2.dy).abs();
    final f3 = math.min(f1, f2);

    final path1 = Path()
      ..moveTo(_p.vertex2.dx, _p.vertex2.dy)
      ..lineTo(_p.vertex1.dx, _p.vertex1.dy)
      ..lineTo(_p.end1.dx, _p.end1.dy)
      ..lineTo(mTouchX, mTouchY)
      ..lineTo(_p.end2.dx, _p.end2.dy)
      ..close();

    double left;
    double right;
    LinearGradient shadowGradient;
    if (mIsRtOrLb) {
      left = _p.start1.dx - 1;
      right = _p.start1.dx + f3 + 1;
      shadowGradient = _shadows.folderLR;
    } else {
      left = _p.start1.dx - f3 - 1;
      right = _p.start1.dx + 1;
      shadowGradient = _shadows.folderRL;
    }

    canvas.save();
    // 裁剪到翻起页背面区域
    canvas.clipPath(_buildPath0());
    canvas.clipPath(path1);

    // 镜像矩阵计算
    final dis = PageDelegateUtils.hypot(
        mCornerX - _p.control1.dx, _p.control2.dy - mCornerY);
    final f8 = (mCornerX - _p.control1.dx) / dis;
    final f9 = (_p.control2.dy - mCornerY) / dis;

    // 绘制镜像 bitmap（用 Matrix4 计算变换后应用）
    // 镜像矩阵（沿翻起边对称翻转）
    final matrix = Matrix4.identity();
    matrix.setEntry(0, 0, 1 - 2 * f9 * f9);
    matrix.setEntry(0, 1, 2 * f8 * f9);
    matrix.setEntry(1, 0, 2 * f8 * f9);
    matrix.setEntry(1, 1, 1 - 2 * f8 * f8);

    _paint.colorFilter = const ColorFilter.matrix([
      1, 0, 0, 0, 0, //
      0, 1, 0, 0, 0, //
      0, 0, 1, 0, 0, //
      0, 0, 0, 1, 0, //
    ]);
    // 用变换矩阵绘制 bitmap
    canvas.save();
    canvas.transform(matrix.storage);
    canvas.drawImage(bitmap, Offset.zero, _paint);
    canvas.restore();
    _paint.colorFilter = null;

    // 翻折阴影
    canvas.save();
    // Flutter 的 canvas.rotate 只接受弧度单一参数，需先 translate 再 rotate
    canvas.translate(_p.start1.dx, _p.start1.dy);
    canvas.rotate(mDegrees * math.pi / 180);
    canvas.translate(-_p.start1.dx, -_p.start1.dy);
    final shadowRect = Rect.fromLTRB(
        left, _p.start1.dy, right, _p.start1.dy + mMaxLength);
    _paint.shader =
        shadowGradient.createShader(shadowRect);
    canvas.drawRect(shadowRect, _paint);
    _paint.shader = null;
    canvas.restore();

    canvas.restore();
  }

  /// 绘制翻起页的阴影
  void _drawCurrentPageShadow(Canvas canvas) {
    final degree = mIsRtOrLb
        ? math.pi / 4 -
            math.atan2(_p.control1.dy - mTouchY, mTouchX - _p.control1.dx)
        : math.pi / 4 -
            math.atan2(mTouchY - _p.control1.dy, mTouchX - _p.control1.dx);

    // 翻起页阴影顶点与 touch 点的距离
    final d1 = 25.0 * 1.414 * math.cos(degree);
    final d2 = 25.0 * 1.414 * math.sin(degree);
    final x = mTouchX + d1;
    final y = mIsRtOrLb ? mTouchY + d2 : mTouchY - d2;

    // 阴影区域 1
    final path1 = Path()
      ..moveTo(x, y)
      ..lineTo(mTouchX, mTouchY)
      ..lineTo(_p.control1.dx, _p.control1.dy)
      ..lineTo(_p.start1.dx, _p.start1.dy)
      ..close();

    canvas.save();
    // 裁剪掉 path0 外部
    _clipOutPath0(canvas);
    canvas.clipPath(path1);

    double leftX, rightX;
    LinearGradient shadowGradient;
    if (mIsRtOrLb) {
      leftX = _p.control1.dx;
      rightX = _p.control1.dx + 25;
      shadowGradient = _shadows.frontVLR;
    } else {
      leftX = _p.control1.dx - 25;
      rightX = _p.control1.dx + 1;
      shadowGradient = _shadows.frontVRL;
    }

    final rotateDegrees = math.atan2(
            mTouchX - _p.control1.dx, _p.control1.dy - mTouchY) *
        180 /
        math.pi;
    canvas.translate(_p.control1.dx, _p.control1.dy);
    canvas.rotate(rotateDegrees * math.pi / 180);
    canvas.translate(-_p.control1.dx, -_p.control1.dy);

    final shadowRect = Rect.fromLTRB(
        leftX, _p.control1.dy - mMaxLength, rightX, _p.control1.dy);
    _paint.shader = shadowGradient.createShader(shadowRect);
    canvas.drawRect(shadowRect, _paint);
    _paint.shader = null;
    canvas.restore();

    // 阴影区域 2
    final path2 = Path()
      ..moveTo(x, y)
      ..lineTo(mTouchX, mTouchY)
      ..lineTo(_p.control2.dx, _p.control2.dy)
      ..lineTo(_p.start2.dx, _p.start2.dy)
      ..close();

    canvas.save();
    _clipOutPath0(canvas);
    canvas.clipPath(path2);

    if (mIsRtOrLb) {
      leftX = _p.control2.dy;
      rightX = _p.control2.dy + 25;
      shadowGradient = _shadows.frontHTB;
    } else {
      leftX = _p.control2.dy - 25;
      rightX = _p.control2.dy + 1;
      shadowGradient = _shadows.frontHBT;
    }

    final rotateDegrees2 = math.atan2(
            _p.control2.dy - mTouchY, _p.control2.dx - mTouchX) *
        180 /
        math.pi;
    canvas.translate(_p.control2.dx, _p.control2.dy);
    canvas.rotate(rotateDegrees2 * math.pi / 180);
    canvas.translate(-_p.control2.dx, -_p.control2.dy);

    final temp = _p.control2.dy < 0
        ? _p.control2.dy - viewHeight
        : _p.control2.dy;
    final hmg = PageDelegateUtils.hypot(_p.control2.dx, temp);
    Rect shadowRect2;
    if (hmg > mMaxLength) {
      shadowRect2 = Rect.fromLTRB(
          _p.control2.dx - 25 - hmg, leftX, _p.control2.dx + mMaxLength - hmg, rightX);
    } else {
      shadowRect2 = Rect.fromLTRB(
          _p.control2.dx - mMaxLength, leftX, _p.control2.dx, rightX);
    }
    _paint.shader = shadowGradient.createShader(shadowRect2);
    canvas.drawRect(shadowRect2, _paint);
    _paint.shader = null;
    canvas.restore();
  }

  /// 绘制下一页区域和阴影
  void _drawNextPageAreaAndShadow(Canvas canvas, ui.Image? bitmap) {
    if (bitmap == null) return;

    final path1 = Path()
      ..moveTo(_p.start1.dx, _p.start1.dy)
      ..lineTo(_p.vertex1.dx, _p.vertex1.dy)
      ..lineTo(_p.vertex2.dx, _p.vertex2.dy)
      ..lineTo(_p.start2.dx, _p.start2.dy)
      ..lineTo(mCornerX, mCornerY)
      ..close();

    mDegrees = math.atan2(_p.control1.dx - mCornerX, _p.control2.dy - mCornerY) *
        180 /
        math.pi;

    double leftX, rightX;
    LinearGradient shadowGradient;
    if (mIsRtOrLb) {
      leftX = _p.start1.dx;
      rightX = _p.start1.dx + mTouchToCornerDis / 4;
      shadowGradient = _shadows.backLR;
    } else {
      leftX = _p.start1.dx - mTouchToCornerDis / 4;
      rightX = _p.start1.dx;
      shadowGradient = _shadows.backRL;
    }

    canvas.save();
    canvas.clipPath(_buildPath0());
    canvas.clipPath(path1);

    // 绘制下一页内容
    canvas.drawImage(bitmap, Offset.zero, _paint);

    // 阴影
    canvas.save();
    canvas.translate(_p.start1.dx, _p.start1.dy);
    canvas.rotate(mDegrees * math.pi / 180);
    canvas.translate(-_p.start1.dx, -_p.start1.dy);
    final shadowRect = Rect.fromLTRB(
        leftX, _p.start1.dy, rightX, mMaxLength + _p.start1.dy);
    _paint.shader = shadowGradient.createShader(shadowRect);
    canvas.drawRect(shadowRect, _paint);
    _paint.shader = null;
    canvas.restore();

    canvas.restore();
  }

  /// 绘制当前页区域（被翻起的部分）
  void _drawCurrentPageArea(Canvas canvas, ui.Image? bitmap) {
    if (bitmap == null) return;

    canvas.save();
    // 裁剪掉 path0 外部（只绘制 path0 外的当前页内容）
    _clipOutPath0(canvas);
    canvas.drawImage(bitmap, Offset.zero, _paint);
    canvas.restore();
  }

  /// 构建 path0（翻起页区域）
  Path _buildPath0() {
    return Path()
      ..moveTo(_p.start1.dx, _p.start1.dy)
      ..quadraticBezierTo(
          _p.control1.dx, _p.control1.dy, _p.end1.dx, _p.end1.dy)
      ..lineTo(mTouchX, mTouchY)
      ..lineTo(_p.end2.dx, _p.end2.dy)
      ..quadraticBezierTo(
          _p.control2.dx, _p.control2.dy, _p.start2.dx, _p.start2.dy)
      ..lineTo(mCornerX, mCornerY)
      ..close();
  }

  /// 裁剪掉 path0 外部（绘制 path0 之外的当前页内容）
  void _clipOutPath0(Canvas canvas) {
    // Flutter 没有 clipOutPath，需要用 PathOperation.difference
    final fullPath = Path()
      ..addRect(Offset.zero & Size(viewWidth, viewHeight));
    final diff = Path.combine(PathOperation.difference, fullPath, _buildPath0());
    canvas.clipPath(diff);
  }

  @override
  bool computeScroll() {
    if (_scroller.computeScrollOffset()) {
      setTouchPoint(_scroller.currX, _scroller.currY);
      notifyStateChanged();
      return true;
    } else if (isStarted) {
      onAnimStop();
      return false;
    }
    return false;
  }

  @override
  void onAnimStart(int animationSpeed) {
    double dx, dy;

    if (isCancel) {
      dx = (mCornerX > 0 && direction == PageDirection.next)
          ? (viewWidth - touchX)
          : -touchX;
      if (direction != PageDirection.next) {
        dx = -(viewWidth + touchX);
      }
      dy = mCornerY > 0 ? (viewHeight - touchY) : -touchY;
    } else {
      dx = (mCornerX > 0 && direction == PageDirection.next)
          ? -(viewWidth + touchX)
          : viewWidth - touchX;
      dy = mCornerY > 0
          ? (viewHeight - touchY)
          : (1 - touchY); // 防止 touchY 最终变为 0
    }

    // 计算动画时长（按距离比例）
    final duration = dx != 0
        ? (animationSpeed * dx.abs()) ~/ viewWidth
        : (animationSpeed * dy.abs()) ~/ viewHeight;

    _scroller.startScroll(
        touchX.toInt().toDouble(),
        touchY.toInt().toDouble(),
        dx,
        dy,
        // 仿真翻页时长 200-500ms，比 slide/cover 略长以体现 3D 翻折感
        // 用 easeOutCubic 让翻页末段缓慢贴合，模拟纸张落下的物理感
        duration < 200 ? 200 : (duration > 500 ? 500 : duration),
        curve: Curves.easeOutCubic);

    isRunning = true;
    isStarted = true;
    _startAnimationLoop();
  }

  /// 启动动画循环
  void _startAnimationLoop() {
    _animTimer?.cancel();
    _animTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!computeScroll()) {
        timer.cancel();
        _animTimer = null;
      }
    });
  }

  @override
  void onAnimStop() {
    _animTimer?.cancel();
    _animTimer = null;
    notifyAnimStop();
    isRunning = false;
    isStarted = false;
    isMoved = false;
  }

  @override
  void abortAnim() {
    _animTimer?.cancel();
    _animTimer = null;
    if (!_scroller.isFinished) {
      _scroller.abortAnimation();
      if (!isCancel) {
        // 通知完成翻页
        notifyAnimStop();
      }
    }
    isStarted = false;
    isMoved = false;
    isRunning = false;
  }

  @override
  void onDestroy() {
    _animTimer?.cancel();
    _animTimer = null;
    super.onDestroy();
  }
}

/// 贝塞尔曲线点集合
class _BezierPoints {
  // 第一条贝塞尔曲线
  Offset start1 = Offset.zero;
  Offset control1 = Offset.zero;
  Offset vertex1 = Offset.zero;
  Offset end1 = Offset.zero;

  // 第二条贝塞尔曲线
  Offset start2 = Offset.zero;
  Offset control2 = Offset.zero;
  Offset vertex2 = Offset.zero;
  Offset end2 = Offset.zero;
}

/// 阴影渐变集合
///
/// 等价于 legado 的 GradientDrawable：
/// - folder: 翻折处的边缘阴影
/// - back: 翻起页背面的阴影
/// - front: 翻起页前面的阴影
class _ShadowDrawables {
  // 翻折处阴影（左右方向）
  final LinearGradient folderLR = const LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF333333), Color(0xB3333333)],
  );

  final LinearGradient folderRL = const LinearGradient(
    begin: Alignment.centerRight,
    end: Alignment.centerLeft,
    colors: [Color(0xFF333333), Color(0xB3333333)],
  );

  // 背面阴影（左右方向）
  final LinearGradient backLR = const LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF111112), Color(0xFFEEEEEF)],
  );

  final LinearGradient backRL = const LinearGradient(
    begin: Alignment.centerRight,
    end: Alignment.centerLeft,
    colors: [Color(0xFF111112), Color(0xFFEEEEEF)],
  );

  // 前面阴影（垂直方向）
  final LinearGradient frontVLR = const LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF111112), Color(0x80EEEEEF)],
  );

  final LinearGradient frontVRL = const LinearGradient(
    begin: Alignment.centerRight,
    end: Alignment.centerLeft,
    colors: [Color(0xFF111112), Color(0x80EEEEEF)],
  );

  // 前面阴影（水平方向）
  final LinearGradient frontHTB = const LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF111112), Color(0x80EEEEEF)],
  );

  final LinearGradient frontHBT = const LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xFF111112), Color(0x80EEEEEF)],
  );
}
