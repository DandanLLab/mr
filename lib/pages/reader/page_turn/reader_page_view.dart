import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'page_delegate.dart';
import 'horizontal_page_delegate.dart';
import 'simulation_page_delegate.dart';
import 'other_page_delegates.dart';

/// 阅读器翻页视图（单 child + 动态截图覆盖层）
///
/// 设计思想（参考 lumina + legado）：
/// - 内部只有一个 child（通常是 WebView），文字选择由 child 自身处理
/// - 静止状态：用户看到的是 child 本身（活的，能选文字）
/// - 翻页状态：
///   1. 截图当前 child → curBitmap
///   2. 调用 onPerformPageTurn 让外部切换 child 内容到目标页
///   3. 等下一帧截图 → targetBitmap
///   4. 注入 SimulationPageDelegate 开始动画
///   5. 动画期间 CustomPaint 叠在最上层（用户看到截图，不能选文字，但用户在翻页时也不需要选）
///   6. 动画结束：CustomPaint 隐藏，用户看到的就是新的 child 内容
///
/// 关键点：
/// - 不需要三个 WebView，只需一个
/// - 文字选择完全由 child 处理，本组件不干涉
/// - 截图通过 RepaintBoundary.toImage 实现
class ReaderPageView extends StatefulWidget {
  /// 唯一子组件（通常是 WebView）
  final Widget child;

  /// 是否是滚动模式（滚动模式不使用翻页动画）
  final bool isScrollMode;

  /// 翻页模式
  /// 0=scroll, 1=slide, 2=cover, 3=simulation, 4=none
  final int pageModeIndex;

  /// 执行翻页（外部切换 WebView 内容到下一页/上一页）
  ///
  /// 参数 direction 表示翻页方向：
  /// - PageDirection.next: 翻到下一页
  /// - PageDirection.prev: 翻到上一页
  ///
  /// 外部应在此回调中：
  /// 1. 判断是否是章节边界（如果是，返回 false，外部自行处理章节切换）
  /// 2. 调用 WebView.jumpToPage(targetPage) 让 WebView 切换到目标页
  /// 3. 等待 WebView 渲染完成（可用 onPageCountReady 或固定延迟）
  ///
  /// 返回 true 表示正常翻页（ReaderPageView 继续截图 + 动画）
  /// 返回 false 表示取消翻页（章节边界等，ReaderPageView 取消动画）
  final Future<bool> Function(PageDirection direction) onPerformPageTurn;

  /// 翻页完成通知（动画结束后触发，外部可保存进度等）
  final void Function(PageDirection direction)? onPageTurnCompleted;

  /// 翻页取消通知（用户回拖未完成翻页）
  final VoidCallback? onPageTurnCancelled;

  const ReaderPageView({
    super.key,
    required this.child,
    required this.isScrollMode,
    required this.pageModeIndex,
    required this.onPerformPageTurn,
    this.onPageTurnCompleted,
    this.onPageTurnCancelled,
  });

  @override
  State<ReaderPageView> createState() => _ReaderPageViewState();
}

class _ReaderPageViewState extends State<ReaderPageView>
    with SingleTickerProviderStateMixin {
  final GlobalKey _boundaryKey = GlobalKey();

  late HorizontalPageDelegate _delegate;

  /// 动画覆盖层是否显示
  bool _showAnimationLayer = false;

  /// 是否正在执行翻页流程（截图→切换→截图→动画）
  bool _isTurning = false;

  /// 翻页 token：每次新翻页自增，防止并发翻页
  int _turnToken = 0;

  Offset? _downPosition;

  @override
  void initState() {
    super.initState();
    _delegate = _createDelegate(widget.pageModeIndex);
    _delegate.setCallbacks(PageDelegateCallbacks(
      onAnimStop: _onAnimStop,
      onAnimCancel: _onAnimCancel,
      onStateChanged: () {
        if (mounted) setState(() {});
      },
    ));
  }

  @override
  void didUpdateWidget(ReaderPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageModeIndex != widget.pageModeIndex) {
      _delegate.onDestroy();
      _delegate = _createDelegate(widget.pageModeIndex);
      _delegate.setCallbacks(PageDelegateCallbacks(
        onAnimStop: _onAnimStop,
        onAnimCancel: _onAnimCancel,
        onStateChanged: () {
          if (mounted) setState(() {});
        },
      ));
    }
  }

  HorizontalPageDelegate _createDelegate(int pageModeIndex) {
    switch (pageModeIndex) {
      case 1:
        return SlidePageDelegate();
      case 2:
        return CoverPageDelegate();
      case 3:
        return SimulationPageDelegate();
      default:
        return NoAnimPageDelegate();
    }
  }

  /// 截图 RepaintBoundary 内容为 ui.Image
  Future<ui.Image?> _captureBoundary() async {
    final renderObj = _boundaryKey.currentContext?.findRenderObject();
    final boundary = renderObj is RenderRepaintBoundary ? renderObj : null;
    if (boundary == null || boundary.size.isEmpty) return null;
    try {
      // pixelRatio: 3.0 参考 lumina，保证清晰度
      return await boundary.toImage(pixelRatio: 3.0);
    } catch (e) {
      debugPrint('[ReaderPageView] 截图失败: $e');
      return null;
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (widget.isScrollMode) return;

    _downPosition = event.position;
    _delegate.onDown();
    _delegate.setStartPoint(event.position.dx, event.position.dy);
    _delegate.onTouch(event);
    // 不再启动长按计时器 —— InAppWebView 是 PlatformView 会吃掉 pointerUp，
    // 长按选文字由 WebView 自身处理，菜单召唤靠 JS click 事件回传
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (widget.isScrollMode) return;
    if (_downPosition == null) return;
    if (_isTurning) return; // 翻页中不响应新移动

    // delegate.onTouch 内部 _onScroll 会判断 isMoved 并设置 isRunning=true
    // 但 isRunning=true 只表示"用户开始滑动"，不代表"动画启动"
    // paint 内部会检查 curBitmap != null 才绘制，所以提前 isRunning=true 无害
    _delegate.onTouch(event);

    // NoAnimPageDelegate 不需要截图覆盖层 —— 松手时直接跳页
    // 这里提前 return 避免截图开销，并保持 _showAnimationLayer=false
    // 让 WebView 持续可交互（文字选择不受影响）
    if (_delegate is NoAnimPageDelegate) return;

    // 用户已滑动一定距离且未启动截图 → 启动截图序列
    if (_delegate.isMoved && !_showAnimationLayer) {
      _startTurnSequence();
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (widget.isScrollMode) return;
    if (_downPosition == null) return;

    // tap 召唤菜单不再由 Flutter Listener 处理 —— InAppWebView 是 PlatformView
    // 会吃掉 pointerUp，所以 tap 改由 JS click 事件回传到 _onWebviewJsTap
    if (_delegate.isMoved) {
      // 滑动结束，开始自动动画
      _finalizeTurn();
    }
    _downPosition = null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_isTurning) {
      _delegate.abortAnim();
      _cancelTurn();
    }
    _downPosition = null;
  }

  /// 开始翻页流程（用户开始滑动时调用）
  ///
  /// 仅做截图 + 显示覆盖层，不调用 onPerformPageTurn。
  /// 原因：用户可能回拖取消，若此时已让 WebView 跳页则无法回滚。
  /// onPerformPageTurn 推迟到 _finalizeTurn（用户松手后）才调用。
  ///
  /// 步骤：
  /// 1. 截图当前页 → curBitmap
  /// 2. 显示动画覆盖层（盖住 WebView，用户看到的是 curBitmap 静态图）
  /// 3. 用户继续滑动，delegate 实时绘制（isRunning 由 _onScroll 设为 true）
  Future<void> _startTurnSequence() async {
    final token = ++_turnToken;
    _isTurning = true;

    // 截图当前页
    final curBitmap = await _captureBoundary();
    if (curBitmap == null) {
      _isTurning = false;
      return;
    }
    if (token != _turnToken) {
      curBitmap.dispose();
      return;
    }

    // 显示动画覆盖层，注入 curBitmap
    // 注意：此时 delegate.isRunning 可能仍为 false（_onScroll 尚未触发），
    // 但 build 中 CustomPaint 显示条件只看 _showAnimationLayer，
    // delegate.paint 内部会检查 isRunning，未启动时返回不绘制，
    // 等用户继续滑动 _onScroll 设 isRunning=true 后自然开始绘制。
    setState(() {
      _delegate.setBitmaps(cur: curBitmap);
      _showAnimationLayer = true;
    });
  }

  /// 结束翻页流程（用户松手时调用）
  ///
  /// 步骤：
  /// 1. 调用 onPerformPageTurn 让外部切换 WebView 到目标页（此处才真正翻页）
  /// 2. 如果返回 false（章节边界），取消翻页
  /// 3. 截图 → targetBitmap
  /// 4. 注入 delegate
  /// 5. 启动 delegate.onAnimStart 自动动画
  Future<void> _finalizeTurn() async {
    final token = _turnToken;

    // 用户回拖取消：不翻页，直接回弹动画
    // isCancel=true 时仍需启动 onAnimStart 让 delegate 跑回弹动画，
    // 但不能调用 onPerformPageTurn（WebView 不该跳页）
    if (_delegate.isCancel) {
      _delegate.onAnimStart(_delegate.defaultAnimationSpeed);
      setState(() {});
      return;
    }

    // 调用外部翻页（此处才真正让 WebView 跳页）
    bool ok = true;
    try {
      ok = await widget.onPerformPageTurn(_delegate.direction);
    } catch (e) {
      debugPrint('[ReaderPageView] onPerformPageTurn 异常: $e');
      ok = false;
    }

    if (!ok || token != _turnToken || !mounted) {
      // 章节边界或 token 失效：取消翻页
      if (token == _turnToken) _cancelTurn();
      return;
    }

    // NoAnimPageDelegate 不需要截图目标页 —— 跳页后直接完成
    // 否则会多余截图（约 50-100ms 开销），让用户感知延迟
    if (_delegate is NoAnimPageDelegate) {
      _isTurning = false;
      widget.onPageTurnCompleted?.call(_delegate.direction);
      _delegate.onDown(); // 重置 delegate 状态
      return;
    }

    // 截图目标页
    final targetBitmap = await _captureBoundary();
    if (token != _turnToken || !mounted) {
      targetBitmap?.dispose();
      return;
    }

    // 注入目标页截图
    if (_delegate.direction == PageDirection.next) {
      _delegate.setBitmaps(next: targetBitmap);
    } else {
      _delegate.setBitmaps(prev: targetBitmap);
    }

    // 启动自动动画
    _delegate.onAnimStart(_delegate.defaultAnimationSpeed);
    setState(() {});
  }

  /// 取消翻页（用户回拖或外部中断）
  void _cancelTurn() {
    _turnToken++; // 使正在进行的截图/切换失效
    _isTurning = false;
    setState(() {
      _showAnimationLayer = false;
    });
    _delegate.setBitmaps(cur: null, prev: null, next: null);
    widget.onPageTurnCancelled?.call();
  }

  void _onAnimStop(PageDirection direction) {
    _isTurning = false;
    setState(() {
      _showAnimationLayer = false;
    });
    _delegate.setBitmaps(cur: null, prev: null, next: null);
    widget.onPageTurnCompleted?.call(direction);
  }

  void _onAnimCancel() {
    _cancelTurn();
  }

  @override
  void dispose() {
    _delegate.onDestroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 滚动模式：直接返回 child，不包裹任何翻页逻辑
    if (widget.isScrollMode) {
      return widget.child;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _delegate.setViewSize(constraints.maxWidth, constraints.maxHeight);

        return Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerCancel,
          behavior: HitTestBehavior.translucent,
          child: Stack(
            children: [
              // 底层：活的 child（WebView），文字选择由它处理
              RepaintBoundary(
                key: _boundaryKey,
                child: widget.child,
              ),
              // 顶层：动画覆盖层（_startTurnSequence 完成后立即显示，
              // 即使 delegate.isRunning=false 也显示，因为 paint 内部会
              // 自行检查 isRunning，未启动时返回不绘制，等用户继续滑动
              // 触发 _onScroll 设 isRunning=true 后自然开始绘制）
              if (_showAnimationLayer)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _DelegatePainter(_delegate),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 把 PageDelegate 包装成 CustomPainter
class _DelegatePainter extends CustomPainter {
  final HorizontalPageDelegate delegate;

  _DelegatePainter(this.delegate);

  @override
  void paint(Canvas canvas, Size size) {
    delegate.paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
