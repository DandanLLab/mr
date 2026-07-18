import 'dart:async' show Timer;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/scheduler.dart' show Ticker;
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

  /// 翻页动画 Ticker（跟随 vsync，替代 Timer.periodic）
  ///
  /// 60Hz 屏 vsync 周期是 16.67ms，120Hz 是 8.33ms。
  /// Timer.periodic(16ms) 与 vsync 不同步会掉帧；
  /// Ticker 由 SchedulerBinding 驱动，与 vsync 完美同步。
  late final Ticker _ticker;

  /// 动画覆盖层是否显示
  bool _showAnimationLayer = false;

  /// 是否正在执行翻页流程（截图→跳页→截图→动画）
  bool _isTurning = false;

  /// _finalizeTurn 是否已被调用（防止 _startTurnSequence 未完成时松手重复触发）
  bool _finalizeStarted = false;

  /// 翻页 token：每次新翻页自增，防止并发翻页
  int _turnToken = 0;

  Offset? _downPosition;

  /// PointerUp 兜底定时器
  ///
  /// 背景：InAppWebView (PlatformView) 在 Texture Layer 模式下有时会吞掉
  /// pointerUp 事件（特别是当 WebView 内部触发了 click 事件合成时），
  /// 导致 _finalizeTurn 不触发，simulation 拖拽卡住。
  /// 策略：onPointerDown 启动 timer，onPointerMove 重置（用户还在拖），
  /// onPointerUp/onPointerCancel 取消；若 timer 触发说明 up 被吞，
  /// 强制走 _finalizeTurn 收尾。
  Timer? _pointerUpFallbackTimer;
  static const Duration _pointerUpFallbackDelay = Duration(milliseconds: 600);

  @override
  void initState() {
    super.initState();
    _ticker = Ticker(_onTick);
    // Ticker 默认 muted=false，必须显式 mute 防止未启动时被断言
    // （muted=true 时即便 start() 也不会真正注册到 SchedulerBinding）
    // 这里不 mute：start() 后正常注册，stop() 后正常解绑。
    _delegate = _createDelegate(widget.pageModeIndex);
    _delegate.setCallbacks(_buildCallbacks());
  }

  /// Ticker 回调：每帧推进 delegate 动画
  void _onTick(Duration elapsed) {
    if (!mounted) {
      _ticker.stop();
      return;
    }
    // computeScroll 返回 false 表示动画结束
    if (!_delegate.computeScroll()) {
      _ticker.stop();
    }
  }

  PageDelegateCallbacks _buildCallbacks() {
    return PageDelegateCallbacks(
      onAnimStop: _onAnimStop,
      onAnimCancel: _onAnimCancel,
      onStateChanged: () {
        if (mounted) setState(() {});
      },
      onRequestTickerStart: () {
        if (mounted) _ticker.start();
      },
      onRequestTickerStop: () {
        _ticker.stop();
      },
    );
  }

  @override
  void didUpdateWidget(ReaderPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageModeIndex != widget.pageModeIndex) {
      // 切 delegate：先记录是否有翻页在进行，再停 ticker + 销毁旧 delegate
      // + 重置所有翻页状态（中 5 修复：避免新 delegate 接到脏状态白屏）
      final wasTurning = _isTurning || _showAnimationLayer;

      // 取消 pointerUp 兜底 timer（避免切换后误触发 _onPointerUpFallback）
      _pointerUpFallbackTimer?.cancel();
      _pointerUpFallbackTimer = null;
      // 自增 token 让正在进行的异步操作（_startTurnSequence/_finalizeTurn 的
      // await 链）失效，避免它们在新 delegate 创建后还注入旧 bitmap
      _turnToken++;
      _ticker.stop();
      _delegate.onDestroy();
      _delegate = _createDelegate(widget.pageModeIndex);
      _delegate.setCallbacks(_buildCallbacks());

      // 重置翻页状态：新 delegate 是干净的，不能继承旧 delegate 的状态
      _showAnimationLayer = false;
      _isTurning = false;
      _finalizeStarted = false;
      _downPosition = null;

      // 通知外部取消（如果有翻页在进行，外部可能需要回滚进度等）
      if (wasTurning) {
        widget.onPageTurnCancelled?.call();
      }

      setState(() {});
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
    _finalizeStarted = false;
    _delegate.onDown();
    _delegate.setStartPoint(event.position.dx, event.position.dy);
    _delegate.onTouch(event);
    // 启动 pointerUp 兜底定时器（onPointerUp 可能被 WebView 吞）
    _pointerUpFallbackTimer?.cancel();
    _pointerUpFallbackTimer = Timer(_pointerUpFallbackDelay, _onPointerUpFallback);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (widget.isScrollMode) return;
    if (_downPosition == null) return;
    if (_isTurning) return; // 翻页中不响应新移动

    // 用户在拖动，重置 pointerUp 兜底定时器
    _pointerUpFallbackTimer?.cancel();
    _pointerUpFallbackTimer = Timer(_pointerUpFallbackDelay, _onPointerUpFallback);

    // delegate.onTouch 内部 _onScroll 会判断 isMoved 并设置 isRunning=true
    _delegate.onTouch(event);

    // NoAnimPageDelegate 不需要截图覆盖层 —— 松手时直接跳页
    if (_delegate is NoAnimPageDelegate) return;

    // 用户已滑动一定距离且未启动截图 → 启动截图序列（异步）
    if (_delegate.isMoved && !_showAnimationLayer) {
      _startTurnSequence();
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (widget.isScrollMode) return;
    if (_downPosition == null) return;

    _pointerUpFallbackTimer?.cancel();
    _pointerUpFallbackTimer = null;

    // tap 召唤菜单不再由 Flutter Listener 处理 —— InAppWebView 是 PlatformView
    // 会吃掉 pointerUp，所以 tap 改由 JS click 事件回传到 _onWebviewJsTap
    if (_delegate.isMoved && !_finalizeStarted) {
      _finalizeStarted = true;
      _finalizeTurn();
    }
    _downPosition = null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointerUpFallbackTimer?.cancel();
    _pointerUpFallbackTimer = null;
    if (_isTurning) {
      _delegate.abortAnim();
      _cancelTurn();
    }
    _downPosition = null;
  }

  /// PointerUp 兜底：当 InAppWebView 吞掉 onPointerUp 时，timer 触发强制收尾
  void _onPointerUpFallback() {
    if (!mounted) return;
    if (_downPosition == null) return;
    if (!_delegate.isMoved) {
      // 用户没真正拖动，可能是被吞的 tap。直接重置，等 JS click 通道处理菜单
      _downPosition = null;
      return;
    }
    if (_finalizeStarted) return;
    _finalizeStarted = true;
    debugPrint('[ReaderPageView] pointerUp 兜底触发（被 WebView 吞）');
    _finalizeTurn();
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

    // 截图当前页（耗时 50-100ms）
    final curBitmap = await _captureBoundary();
    if (curBitmap == null) {
      // 截图失败：如果用户已松手，让 _finalizeTurn 处理；否则重置状态
      if (!_finalizeStarted && token == _turnToken) {
        _isTurning = false;
      }
      return;
    }
    if (token != _turnToken) {
      curBitmap.dispose();
      return;
    }

    // 用户已松手：_finalizeTurn 会自己接管截图（_finalizeTurn 不再轮询等待
    // _startTurnSequence 完成），这里 dispose 当前截图避免泄漏，不注入
    // （_finalizeTurn 后续会自己 _captureBoundary 作为 curBitmap）
    //
    // 这样做的好处：
    // - 去掉 _finalizeTurn 的 200ms 轮询等待，改为自己截图（50-100ms 更快）
    // - 避免双份截图（_startTurnSequence 注入后 _finalizeTurn 又截图造成闪烁）
    if (_finalizeStarted) {
      curBitmap.dispose();
      return;
    }

    // 显示动画覆盖层，注入 curBitmap
    setState(() {
      _delegate.setBitmaps(cur: curBitmap);
      _showAnimationLayer = true;
    });
  }

  /// 结束翻页流程（用户松手时调用）
  ///
  /// 统一时序控制：不管 _startTurnSequence 是否完成，都从这里串行处理。
  ///
  /// 步骤：
  /// 1. 等待 _startTurnSequence 完成（如果有）—— 通过 _isTurning 标记
  /// 2. 判断 isCancel：回拖取消，跑回弹动画
  /// 3. 截图当前页（如果 _startTurnSequence 没截到，这里补截）
  /// 4. 调用 onPerformPageTurn 让 WebView 跳页
  /// 5. 等帧 + 截图目标页
  /// 6. 注入 delegate + 启动动画
  Future<void> _finalizeTurn() async {
    final token = _turnToken;

    // 用户回拖取消：不翻页，直接回弹动画
    if (_delegate.isCancel) {
      // 等 _startTurnSequence 截图完成（如果有），否则 delegate 没图可画
      // 简化：如果 _showAnimationLayer=false，说明截图还没完成或失败，
      // 此时直接取消，不跑回弹动画
      if (!_showAnimationLayer) {
        _cancelTurn();
        return;
      }
      _delegate.onAnimStart(_delegate.defaultAnimationSpeed);
      setState(() {});
      return;
    }

    // NoAnimPageDelegate：不需要截图，直接跳页
    if (_delegate is NoAnimPageDelegate) {
      bool ok = true;
      try {
        ok = await widget.onPerformPageTurn(_delegate.direction);
      } catch (e) {
        debugPrint('[ReaderPageView] onPerformPageTurn 异常: $e');
        ok = false;
      }
      if (!ok || token != _turnToken || !mounted) {
        if (token == _turnToken) _cancelTurn();
        return;
      }
      _isTurning = false;
      _finalizeStarted = false;
      widget.onPageTurnCompleted?.call(_delegate.direction);
      _delegate.onDown(); // 重置 delegate 状态
      return;
    }

    // 确保 curBitmap 已注入（_finalizeTurn 时序简化）
    //
    // - 慢拖：_startTurnSequence 已完成，_showAnimationLayer=true，跳过自己截图
    // - 快松：_startTurnSequence 还没截完，_finalizeStarted=true 让它后续
    //   dispose return（不再注入），这里自己 _captureBoundary 作为 curBitmap
    //
    // 优化：原代码用 200ms 轮询（10ms × 20 次）等 _startTurnSequence 完成，
    // 现在直接自己截图（耗时 50-100ms，比 200ms 轮询快）。
    if (!_showAnimationLayer) {
      final curBitmap = await _captureBoundary();
      if (token != _turnToken || !mounted) {
        curBitmap?.dispose();
        return;
      }
      if (curBitmap == null) {
        _cancelTurn();
        return;
      }
      _delegate.setBitmaps(cur: curBitmap);
      setState(() {
        _showAnimationLayer = true;
      });
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

    // 截图目标页（此时 WebView 已跳到目标页，覆盖层仍显示挡住用户视线）
    final targetBitmap = await _captureBoundary();
    if (token != _turnToken || !mounted) {
      targetBitmap?.dispose();
      return;
    }
    if (targetBitmap == null) {
      _cancelTurn();
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
    _ticker.stop(); // 保险：防止 delegate 自己没停干净
    _isTurning = false;
    _finalizeStarted = false;
    setState(() {
      _showAnimationLayer = false;
    });
    // 真正 dispose 所有 ui.Image 资源（不能调 setBitmaps(cur:null,...)，
    // setBitmaps 对 null 参数不做处理，会导致内存泄漏）
    _delegate.recycleBitmaps();
    widget.onPageTurnCancelled?.call();
  }

  void _onAnimStop(PageDirection direction) {
    _ticker.stop(); // delegate.onAnimStop 已停过，这里再保险一次
    _isTurning = false;
    _finalizeStarted = false;
    setState(() {
      _showAnimationLayer = false;
    });
    // 动画结束：dispose 所有截图资源（同 _cancelTurn）
    _delegate.recycleBitmaps();
    widget.onPageTurnCompleted?.call(direction);
  }

  void _onAnimCancel() {
    _cancelTurn();
  }

  @override
  void dispose() {
    _pointerUpFallbackTimer?.cancel();
    _ticker.dispose();
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
              // 顶层：动画覆盖层
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
