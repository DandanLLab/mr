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

  /// 释放所有图像引用并 dispose
  ///
  /// 用于取消翻页 / 动画结束 / widget 销毁时回收 ui.Image 资源。
  ///
  /// 注意：不能直接调用 `setBitmaps(cur: null, prev: null, next: null)` 来清空，
  /// 因为 setBitmaps 内部对 null 参数不做处理（保持现有引用）。
  /// 这是为了避免动画进行中用 `setBitmaps(cur: newCur)` 更新当前页时
  /// 把 prev/next 误 dispose 掉。清空场景必须用本方法。
  void recycleBitmaps() {
    curBitmap?.dispose();
    prevBitmap?.dispose();
    nextBitmap?.dispose();
    curBitmap = null;
    prevBitmap = null;
    nextBitmap = null;
  }

  /// 设置图像（外部调用，注入截图结果）
  ///
  /// null 参数会被忽略（不清空也不 dispose）。
  /// 这是为了让动画进行中可以单独更新某一图层而不影响其他图层。
  /// 清空所有图层用 recycleBitmaps()。
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

  /// 把 bitmap 完整绘制到 canvas 的 (0,0)-(viewWidth,viewHeight) 矩形
  ///
  /// 自适应截图精准修复：
  /// - src 矩形用 bitmap 物理尺寸（image.width × image.height）
  ///   之前用 Size(viewWidth, viewHeight) 是错的——bitmap 由
  ///   RepaintBoundary.toImage(pixelRatio: 3.0) 生成，物理尺寸是
  ///   viewWidth*3 × viewHeight*3，用 viewWidth/viewHeight 作 src 只截取
  ///   了 1/9 区域再拉伸到 dst，导致内容变形、模糊、不完整
  /// - dst 矩形用 viewWidth/viewHeight（canvas 逻辑像素尺寸）
  /// - 这样无论 pixelRatio 是 1.0/2.0/3.0/4.0，bitmap 都能精准填充 canvas
  ///
  /// [dst] 可选，默认填满整个 canvas；用于 cover/slide 等需要自定义目标矩形的场景
  /// [paint] 可选，用于 simulation 的 colorFilter 等自定义画笔
  void drawBitmapFull(
    Canvas canvas,
    ui.Image? bitmap, {
    Rect? dst,
    Paint? paint,
  }) {
    if (bitmap == null) return;
    final src =
        Offset.zero & Size(bitmap.width.toDouble(), bitmap.height.toDouble());
    final target = dst ?? (Offset.zero & Size(viewWidth, viewHeight));
    canvas.drawImageRect(bitmap, src, target, paint ?? Paint());
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
      // isCancel: 基于「相对起点」的总位移方向判断，避免单帧抖动误判
      // - direction=next（向左翻下一页）：sumX > startX 表示用户已回到起点右侧，取消
      // - direction=prev（向右翻上一页）：sumX < startX 表示用户已回到起点左侧，取消
      // 旧实现 `sumX > lastX / sumX < lastX` 只看单帧方向：
      // 用户向左滑到一半再向右微调（仍在起点左侧）就被误判为取消，导致松手不跳转
      isCancel = (direction == PageDirection.next)
          ? sumX > startX
          : sumX < startX;
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
    recycleBitmaps();
  }
}
