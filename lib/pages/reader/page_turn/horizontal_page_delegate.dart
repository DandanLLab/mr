import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'page_delegate.dart';

/// 水平翻页代理基类
///
/// 参考 legado HorizontalPageDelegate：
/// - 处理水平方向的触摸移动
/// - 判断翻页方向（prev/next）
/// - 处理 isCancel（用户回拖）
/// - 提供 curRecorder/prevRecorder/nextRecorder 三个图像源
///
/// 子类只需实现：
/// - paint: 绘制具体效果（slide/cover/simulation）
/// - onAnimStart: 计算自动滚动距离
/// - onAnimStop: 翻页完成后的处理
/// - setBitmap: 截图时机回调（可选）
abstract class HorizontalPageDelegate extends PageDelegate {
  /// 当前页图像
  ui.Image? curBitmap;

  /// 上一页图像
  ui.Image? prevBitmap;

  /// 下一页图像
  ui.Image? nextBitmap;

  /// 截图回调（子类在 setDirection 后调用）
  /// 外部注入截图逻辑（通过 RepaintBoundary）
  void Function(PageDirection direction)? onSetBitmap;

  /// 释放图像
  void _recycleBitmaps() {
    curBitmap?.dispose();
    prevBitmap?.dispose();
    nextBitmap?.dispose();
    curBitmap = null;
    prevBitmap = null;
    nextBitmap = null;
  }

  /// 设置图像（外部调用，注入截图结果）
  void setBitmaps({
    ui.Image? cur,
    ui.Image? prev,
    ui.Image? next,
  }) {
    if (cur != null) {
      curBitmap?.dispose();
      curBitmap = cur;
    }
    if (prev != null) {
      prevBitmap?.dispose();
      prevBitmap = prev;
    }
    if (next != null) {
      nextBitmap?.dispose();
      nextBitmap = next;
    }
  }

  /// 触摸事件统一处理
  ///
  /// 注意：PointerUpEvent 不在此处自动调用 onAnimStart。
  /// 因为 ReaderPageView 采用「单 WebView + 动态截图」架构，
  /// 松手后需要先 await onPerformPageTurn 让 WebView 跳到目标页，
  /// 再截图目标页，最后才能启动动画。这套时序由 ReaderPageView 的
  /// _finalizeTurn 统一控制，不能让 delegate 自行启动 onAnimStart，
  /// 否则会用旧 curBitmap 绘制造成排版错乱。
  @override
  void onTouch(PointerEvent event) {
    if (event is PointerDownEvent) {
      abortAnim();
    } else if (event is PointerMoveEvent) {
      _onScroll(event);
    }
    // PointerUpEvent / PointerCancelEvent 由 ReaderPageView 接管
  }

  /// 移动处理
  void _onScroll(PointerMoveEvent event) {
    final sumX = event.position.dx;
    final sumY = event.position.dy;

    if (!isMoved) {
      final deltaX = sumX - startX;
      final deltaY = sumY - startY;
      final distance = deltaX * deltaX + deltaY * deltaY;
      isMoved = distance > slopSquare;
      if (isMoved) {
        if (sumX - startX > 0) {
          // 向右滑 -> 上一页
          setDirection(PageDirection.prev);
        } else {
          // 向左滑 -> 下一页
          setDirection(PageDirection.next);
        }
        // 重新设置起点（避免初始偏移过大）
        setStartPoint(event.position.dx, event.position.dy);
      }
    }
    if (isMoved) {
      // isCancel: 与当前方向反向移动
      isCancel = (direction == PageDirection.next)
          ? sumX > lastX
          : sumX < lastX;
      isRunning = true;
      setTouchPoint(sumX, sumY);
      notifyStateChanged();
    }
  }

  @override
  void abortAnim() {
    isStarted = false;
    isMoved = false;
    isRunning = false;
    // 子类如需通知取消，应重写此方法并在适当时机调用 notifyAnimCancel
  }

  /// 下一页（带动画）
  /// 由外部调用，用于点击翻页或自动翻页
  @override
  void nextPageByAnim(int animationSpeed) {
    abortAnim();
    setDirection(PageDirection.next);
    // 起点设在右侧 0.9 位置，模拟从右下角翻起
    final y = startY > viewHeight / 2 ? viewHeight * 0.9 : 1.0;
    setStartPoint(viewWidth * 0.9, y);
    onAnimStart(animationSpeed);
  }

  /// 上一页（带动画）
  @override
  void prevPageByAnim(int animationSpeed) {
    abortAnim();
    setDirection(PageDirection.prev);
    setStartPoint(0, viewHeight);
    onAnimStart(animationSpeed);
  }

  @override
  void onDestroy() {
    _recycleBitmaps();
  }
}
