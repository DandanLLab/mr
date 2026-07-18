import 'package:flutter/material.dart';
import 'page_delegate.dart';
import 'horizontal_page_delegate.dart';

/// 滑动翻页代理
///
/// 参考 legado SlidePageDelegate：
/// - 当前页和目标页同时平移
/// - 当前页滑出，目标页滑入
/// - 无阴影、无 3D 效果，最简单的翻页方式
class SlidePageDelegate extends HorizontalPageDelegate {
  final PageScroller _scroller = PageScroller();

  @override
  void paint(Canvas canvas, Size size) {
    if (!isRunning) return;

    final offsetX = touchX - startX;

    // 反向移动不处理
    if ((direction == PageDirection.next && offsetX > 0) ||
        (direction == PageDirection.prev && offsetX < 0)) {
      return;
    }

    final distanceX =
        offsetX > 0 ? offsetX - viewWidth : offsetX + viewWidth;

    if (direction == PageDirection.prev) {
      // 当前页向右滑出，上一页从左边滑入
      if (curBitmap != null) {
        canvas.save();
        canvas.translate(distanceX + viewWidth, 0);
        drawBitmapFull(canvas, curBitmap);
        canvas.restore();
      }
      if (prevBitmap != null) {
        canvas.save();
        canvas.translate(distanceX, 0);
        drawBitmapFull(canvas, prevBitmap);
        canvas.restore();
      }
    } else if (direction == PageDirection.next) {
      // 当前页向左滑出，下一页从右边滑入
      if (nextBitmap != null) {
        canvas.save();
        canvas.translate(distanceX, 0);
        drawBitmapFull(canvas, nextBitmap);
        canvas.restore();
      }
      if (curBitmap != null) {
        canvas.save();
        canvas.translate(distanceX - viewWidth, 0);
        drawBitmapFull(canvas, curBitmap);
        canvas.restore();
      }
    }
  }

  @override
  void onAnimStart(int animationSpeed) {
    double distanceX;
    if (direction == PageDirection.next) {
      distanceX = isCancel
          ? (viewWidth - startX + touchX).clamp(0.0, viewWidth)
          : -(touchX + (viewWidth - startX));
      // 取补：viewWidth - dis
      if (isCancel) {
        distanceX = viewWidth - distanceX;
      }
    } else {
      distanceX = isCancel
          ? -(touchX - startX)
          : viewWidth - (touchX - startX);
    }

    final duration = (animationSpeed * distanceX.abs() / viewWidth).round();
    _scroller.startScroll(
      touchX,
      0,
      distanceX,
      0,
      // 时长范围 200-450ms，比之前 50-500ms 更平滑
      // 用 Curves.easeOutCubic 让结束阶段更自然减速
      duration < 200 ? 200 : (duration > 450 ? 450 : duration),
      curve: Curves.easeOutCubic,
    );

    isRunning = true;
    isStarted = true;
    // 由外部 ReaderPageView 的 Ticker 驱动 computeScroll（跟随 vsync）
    startTicker();
  }

  @override
  bool computeScroll() {
    if (_scroller.computeScrollOffset()) {
      setTouchPoint(_scroller.currX, touchY);
      notifyStateChanged();
      return true;
    } else if (isStarted) {
      onAnimStop();
      return false;
    }
    return false;
  }

  @override
  void onAnimStop() {
    stopTicker();
    notifyAnimStop();
    isRunning = false;
    isStarted = false;
    isMoved = false;
  }

  @override
  void abortAnim() {
    stopTicker();
    if (!_scroller.isFinished) {
      _scroller.abortAnimation();
      if (!isCancel) {
        notifyAnimStop();
      }
    }
    isStarted = false;
    isMoved = false;
    isRunning = false;
  }

  @override
  void onDestroy() {
    stopTicker();
    super.onDestroy();
  }
}

/// 覆盖翻页代理
///
/// 参考 legado CoverPageDelegate：
/// - 当前页不动，目标页从侧边滑入覆盖
/// - 带边缘阴影（30px 宽度，渐变从 40% 黑到透明）
class CoverPageDelegate extends HorizontalPageDelegate {
  final PageScroller _scroller = PageScroller();

  /// 边缘阴影宽度（视觉上像 legado 的翻页阴影）
  static const double _shadowWidth = 30.0;

  /// 阴影画笔（颜色和 shader 在 _addShadow 中动态设置）
  final Paint _shadowPaint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    if (!isRunning) return;

    final offsetX = touchX - startX;

    if ((direction == PageDirection.next && offsetX > 0) ||
        (direction == PageDirection.prev && offsetX < 0)) {
      return;
    }

    final distanceX =
        offsetX > 0 ? offsetX - viewWidth : offsetX + viewWidth;

    if (direction == PageDirection.prev) {
      if (offsetX <= viewWidth) {
        // 上一页从左边滑入
        if (prevBitmap != null) {
          canvas.save();
          canvas.translate(distanceX, 0);
          drawBitmapFull(canvas, prevBitmap);
          canvas.restore();
        }
        _addShadow(distanceX, canvas);
      } else if (prevBitmap != null) {
        drawBitmapFull(canvas, prevBitmap);
      }
    } else if (direction == PageDirection.next) {
      // 下一页从右边滑入，裁剪只显示已滑入部分
      if (nextBitmap != null) {
        canvas.save();
        final clipRect = Rect.fromLTWH(
            viewWidth + offsetX, 0, -offsetX, viewHeight);
        canvas.clipRect(clipRect);
        drawBitmapFull(canvas, nextBitmap);
        canvas.restore();
      }
      // 当前页跟随移动
      if (curBitmap != null) {
        canvas.save();
        canvas.translate(distanceX - viewWidth, 0);
        drawBitmapFull(canvas, curBitmap);
        canvas.restore();
      }
      _addShadow(distanceX, canvas);
    }
  }

  void _addShadow(double left, Canvas canvas) {
    if (left == 0) return;
    final dx = left < 0 ? left + viewWidth : left;
    canvas.save();
    canvas.translate(dx, 0);
    final shadowRect =
        Rect.fromLTWH(0, 0, _shadowWidth, viewHeight);
    // 阴影渐变：从 40% 黑色（紧贴翻起页边缘）渐变到透明
    // 比 legado 原版略深，让翻页立体感更强
    _shadowPaint.shader = const LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [Color(0x66111111), Color(0x00000000)],
    ).createShader(shadowRect);
    canvas.drawRect(shadowRect, _shadowPaint);
    canvas.restore();
  }

  @override
  void onAnimStart(int animationSpeed) {
    double distanceX;
    if (direction == PageDirection.next) {
      distanceX = isCancel
          ? (viewWidth - startX + touchX).clamp(0.0, viewWidth)
          : -(touchX + (viewWidth - startX));
      if (isCancel) {
        distanceX = viewWidth - distanceX;
      }
    } else {
      distanceX = isCancel
          ? -(touchX - startX)
          : viewWidth - (touchX - startX);
    }

    final duration = (animationSpeed * distanceX.abs() / viewWidth).round();
    _scroller.startScroll(
      touchX,
      0,
      distanceX,
      0,
      // 时长范围 200-450ms，与 SlidePageDelegate 保持一致
      duration < 200 ? 200 : (duration > 450 ? 450 : duration),
      curve: Curves.easeOutCubic,
    );

    isRunning = true;
    isStarted = true;
    // 由外部 ReaderPageView 的 Ticker 驱动 computeScroll（跟随 vsync）
    startTicker();
  }

  @override
  bool computeScroll() {
    if (_scroller.computeScrollOffset()) {
      setTouchPoint(_scroller.currX, touchY);
      notifyStateChanged();
      return true;
    } else if (isStarted) {
      onAnimStop();
      return false;
    }
    return false;
  }

  @override
  void onAnimStop() {
    stopTicker();
    notifyAnimStop();
    isRunning = false;
    isStarted = false;
    isMoved = false;
  }

  @override
  void abortAnim() {
    stopTicker();
    if (!_scroller.isFinished) {
      _scroller.abortAnimation();
      if (!isCancel) {
        notifyAnimStop();
      }
    }
    isStarted = false;
    isMoved = false;
    isRunning = false;
  }

  @override
  void onDestroy() {
    stopTicker();
    super.onDestroy();
  }
}

/// 无动画翻页代理
///
/// 参考 legado NoAnimPageDelegate：
/// - 直接切换，无过渡动画
/// - 用于进度跳转、章节切换等场景
class NoAnimPageDelegate extends HorizontalPageDelegate {
  @override
  void paint(Canvas canvas, Size size) {
    // 无动画，不绘制
  }

  @override
  void onAnimStart(int animationSpeed) {
    isRunning = false;
    isStarted = false;
    notifyAnimStop();
  }

  @override
  bool computeScroll() => false;

  @override
  void onAnimStop() {
    isRunning = false;
    isStarted = false;
    isMoved = false;
  }

  @override
  void abortAnim() {
    isStarted = false;
    isMoved = false;
    isRunning = false;
  }
}
