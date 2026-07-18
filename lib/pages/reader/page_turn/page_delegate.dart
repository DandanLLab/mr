import 'dart:math' as math;
import 'package:flutter/material.dart';

/// 翻页方向
enum PageDirection { none, prev, next }

/// 翻页回调
class PageDelegateCallbacks {
  /// 翻页动画完成（成功翻到目标页）
  final void Function(PageDirection direction)? onAnimStop;

  /// 翻页被取消（用户回拖，未完成翻页）
  final void Function()? onAnimCancel;

  /// 状态变化（用于触发重绘）
  final void Function()? onStateChanged;

  /// 请求外部 Ticker 开始驱动动画（每帧调用 computeScroll）
  ///
  /// delegate 自己不持有 Ticker，因为 Ticker 必须由
  /// TickerProvider（如 SingleTickerProviderStateMixin）创建。
  /// delegate 在 onAnimStart 中调用此回调，让外部启动 Ticker；
  /// 在 onAnimStop/abortAnim 中调用 [onRequestTickerStop] 停止。
  final void Function()? onRequestTickerStart;

  /// 请求外部 Ticker 停止
  final void Function()? onRequestTickerStop;

  const PageDelegateCallbacks({
    this.onAnimStop,
    this.onAnimCancel,
    this.onStateChanged,
    this.onRequestTickerStart,
    this.onRequestTickerStop,
  });
}

/// 翻页代理基类
///
/// 参考 legado PageDelegate 架构：
/// - 子类实现 onDraw 绘制翻页动画
/// - 子类实现 onAnimStart/onAnimStop 处理动画起止
/// - 子类实现 onTouch 处理触摸事件
/// - computeScroll 处理自动滚动（Scroller 等价物）
///
/// 截图策略：
/// - 子类通过 setBitmap 获取当前页/上一页/下一页的图像
/// - 图像来源由外部注入（通常是 RepaintBoundary 截图）
abstract class PageDelegate {
  /// 视口宽度
  double viewWidth = 0;

  /// 视口高度
  double viewHeight = 0;

  /// 起始点（触摸开始位置）
  double startX = 0;
  double startY = 0;

  /// 上一个触碰点
  double lastX = 0;
  double lastY = 0;

  /// 当前触碰点
  double touchX = 0;
  double touchY = 0;

  /// 是否移动了
  bool isMoved = false;

  /// 是否正在运行动画
  bool isRunning = false;

  /// 动画是否已启动
  bool isStarted = false;

  /// 是否取消（用户回拖，不完成翻页）
  bool isCancel = false;

  /// 翻页方向
  PageDirection direction = PageDirection.none;

  /// 动画速度（ms）
  final int defaultAnimationSpeed = 300;

  /// 触摸阈值平方（超过此距离才算移动）
  double slopSquare = 16.0;

  PageDelegateCallbacks? _callbacks;

  void setCallbacks(PageDelegateCallbacks callbacks) {
    _callbacks = callbacks;
  }

  /// 通知状态变化（触发重绘）
  void notifyStateChanged() {
    _callbacks?.onStateChanged?.call();
  }

  /// 通知翻页完成
  void notifyAnimStop() {
    if (!isCancel) {
      _callbacks?.onAnimStop?.call(direction);
    } else {
      _callbacks?.onAnimCancel?.call();
    }
  }

  /// 请求外部 Ticker 启动（子类在 onAnimStart 中调用）
  void startTicker() {
    _callbacks?.onRequestTickerStart?.call();
  }

  /// 请求外部 Ticker 停止（子类在 onAnimStop/abortAnim/onDestroy 中调用）
  void stopTicker() {
    _callbacks?.onRequestTickerStop?.call();
  }

  /// 设置视口尺寸
  void setViewSize(double width, double height) {
    viewWidth = width;
    viewHeight = height;
  }

  /// 设置起始点
  void setStartPoint(double x, double y) {
    startX = x;
    startY = y;
    lastX = x;
    lastY = y;
    touchX = x;
    touchY = y;
  }

  /// 设置当前触摸点
  void setTouchPoint(double x, double y) {
    lastX = touchX;
    lastY = touchY;
    touchX = x;
    touchY = y;
  }

  /// 设置方向
  void setDirection(PageDirection dir) {
    direction = dir;
  }

  /// 触摸事件处理
  void onTouch(PointerEvent event);

  /// 按下
  void onDown() {
    isMoved = false;
    isRunning = false;
    isCancel = false;
    direction = PageDirection.none;
  }

  /// 判断是否移动
  bool checkMoved(double x, double y) {
    final dx = x - startX;
    final dy = y - startY;
    return dx * dx + dy * dy > slopSquare;
  }

  /// 滚动时回调
  void onScroll() {}

  /// 自动滚动计算（每帧调用）
  /// 返回 true 表示仍在动画中，false 表示动画结束
  bool computeScroll();

  /// 绘制
  void paint(Canvas canvas, Size size);

  /// 开始动画
  void onAnimStart(int animationSpeed);

  /// 动画停止
  void onAnimStop();

  /// 中止动画
  void abortAnim();

  /// 下一页（带动画）
  void nextPageByAnim(int animationSpeed);

  /// 上一页（带动画）
  void prevPageByAnim(int animationSpeed);

  /// 销毁
  void onDestroy() {}
}

/// 工具函数
class PageDelegateUtils {
  /// 两点距离
  static double hypot(double x, double y) {
    return math.sqrt(x * x + y * y);
  }

  /// 两点距离平方
  static double hypot2(double x, double y) {
    return x * x + y * y;
  }

  /// 求直线 P1P2 和 P3P4 的交点
  static Offset getCross(Offset p1, Offset p2, Offset p3, Offset p4) {
    // y = a*x + b
    final a1 = (p2.dy - p1.dy) / (p2.dx - p1.dx);
    final b1 = (p1.dx * p2.dy - p2.dx * p1.dy) / (p1.dx - p2.dx);
    final a2 = (p4.dy - p3.dy) / (p4.dx - p3.dx);
    final b2 = (p3.dx * p4.dy - p4.dx * p3.dy) / (p3.dx - p4.dx);
    final x = (b2 - b1) / (a1 - a2);
    final y = a1 * x + b1;
    return Offset(x, y);
  }
}

/// 简单的 Scroller 等价物
///
/// 参考 legado 的 Scroller.startScroll / fling
/// 自动从 startX/Y 滑动到 startX+dx / startY+dy
class PageScroller {
  bool _finished = true;
  double _startX = 0;
  double _startY = 0;
  double _finalX = 0;
  double _finalY = 0;
  double _currX = 0;
  double _currY = 0;
  int _startTime = 0;
  int _duration = 0;
  Curve _curve = Curves.linear;

  bool get isFinished => _finished;
  double get currX => _currX;
  double get currY => _currY;

  /// 开始滚动
  void startScroll(
    double startX,
    double startY,
    double dx,
    double dy,
    int duration, {
    Curve curve = Curves.linear,
  }) {
    _finished = false;
    _startX = startX;
    _startY = startY;
    _finalX = startX + dx;
    _finalY = startY + dy;
    _currX = startX;
    _currY = startY;
    _startTime = DateTime.now().millisecondsSinceEpoch;
    _duration = duration;
    _curve = curve;
  }

  /// fling（带初速度的滑动）
  void fling(
    double startX,
    double startY,
    double velocityX,
    double velocityY,
    double minX,
    double maxX,
    double minY,
    double maxY, {
    Curve curve = Curves.decelerate,
  }) {
    _finished = false;
    _startX = startX;
    _startY = startY;
    _currX = startX;
    _currY = startY;

    // 根据速度计算终点和时长
    final speed = PageDelegateUtils.hypot(velocityX, velocityY);
    final duration = (speed * 2).round().clamp(200, 800);
    _finalX = (startX + velocityX * 0.3).clamp(minX, maxX);
    _finalY = (startY + velocityY * 0.3).clamp(minY, maxY);
    _startTime = DateTime.now().millisecondsSinceEpoch;
    _duration = duration;
    _curve = curve;
  }

  /// 计算当前偏移（每帧调用）
  /// 返回 true 表示还在动画中
  bool computeScrollOffset() {
    if (_finished) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _startTime;
    if (elapsed >= _duration) {
      _currX = _finalX;
      _currY = _finalY;
      _finished = true;
      return false;
    }
    final t = elapsed / _duration;
    final eased = _curve.transform(t);
    _currX = _startX + (_finalX - _startX) * eased;
    _currY = _startY + (_finalY - _startY) * eased;
    return true;
  }

  /// 中止动画
  void abortAnimation() {
    _finished = true;
    _currX = _finalX;
    _currY = _finalY;
  }
}
