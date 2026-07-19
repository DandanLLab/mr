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
  State<ReaderPageView> createState() => ReaderPageViewState();
}

class ReaderPageViewState extends State<ReaderPageView>
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

  /// 截图期间缓存的最新 move 位置（Phase 2.1 丝滑度修复）
  ///
  /// 背景：_startTurnSequence 在 await 截图期间（_isTurning=true 但
  /// _showAnimationLayer=false），_onPointerMove 会被忽略以避免 delegate
  /// 没图可画导致空白。但截图耗时 50-100ms，期间用户的拖动事件被丢弃，
  /// 截图完成后 delegate 拿到的是截图开始时的位置 → 翻折效果"跳一下"。
  ///
  /// 修复：截图期间缓存最新 move 位置，截图完成后立即补一次 _delegate.onTouch
  /// 让 delegate 跳到最新位置，消除"丢帧"感。
  Offset? _pendingMoveDuringCapture;

  /// 截图像素比（自适应屏幕 DPR，上限 2.5）
  ///
  /// 之前硬编码 3.0：
  /// - 高 DPR 设备（4.0）：截图清晰度 < 设备渲染清晰度，翻页时图片模糊
  /// - 低 DPR 设备（1.5/2.0）：截图清晰度 > 设备渲染清晰度，浪费内存
  ///
  /// 修复：用 View.of(context).devicePixelRatio 取真实 DPR，
  /// 截图清晰度 = 设备渲染清晰度，1:1 还原屏幕显示。
  ///
  /// Phase 2.2 速度优化：上限限制到 2.5
  /// - 4.0 DPR 设备：原 1440×2560 截图（14MB+，耗时 100ms+）→ 现 900×1600（5.7MB，耗时 ~60ms）
  /// - 静态时 WebView 仍按真实 4.0 DPR 渲染（清晰），翻页瞬间用 2.5 倍截图（轻微降清）
  /// - 视觉几乎无感（翻页是动态过程），但速度提升 ~40%，丝滑度显著改善
  /// - 2.5 是经验值：实测 >= 2.5 文字无明显锯齿，< 2.5 截图明显模糊
  /// 兜底默认 3.0（与原实现一致，保证旧设备行为不变）。
  double _devicePixelRatio = 3.0;

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
      _pendingMoveDuringCapture = null;

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
      // pixelRatio 自适应屏幕 DPR（之前硬编码 3.0）
      // - DPR=2 设备：截图 = 720×1280 物理像素（原 1080×1920 省 50% 内存）
      // - DPR=3 设备：截图 = 1080×1920（与原行为一致）
      // - DPR=4 设备：截图 = 1440×2560（比原 1080×1920 更清晰）
      // 配合 drawBitmapFull 的 src=bitmap 物理尺寸，绘制时精准 1:1 还原
      return await boundary.toImage(pixelRatio: _devicePixelRatio);
    } catch (e) {
      debugPrint('[ReaderPageView] 截图失败: $e');
      return null;
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (widget.isScrollMode) return;

    // 快速翻页支持：如果上一次翻页动画还在跑（_isTurning=true），立即结束
    // 这样用户能立刻开始新一次翻页，实现「秒翻页」手感。
    // 不强制结束的话，后续 _onPointerMove 会被 `if (_isTurning) return` 拦截，
    // 用户感觉「翻页速度慢，得等动画结束」。
    if (_isTurning) {
      _forceFinishCurrentTurn();
    }

    _downPosition = event.position;
    _finalizeStarted = false;
    // 防御性清理：理论上 _startTurnSequence 完成时会清空，
    // 但若上一手势异常退出（如截图失败+token 失效路径）可能残留，
    // 不清的话下一手势截图完成后会用旧位置补帧
    _pendingMoveDuringCapture = null;
    _delegate.onDown();
    _delegate.setStartPoint(event.position.dx, event.position.dy);
    _delegate.onTouch(event);
    // 启动 pointerUp 兜底定时器（onPointerUp 可能被 WebView 吞）
    _pointerUpFallbackTimer?.cancel();
    _pointerUpFallbackTimer = Timer(_pointerUpFallbackDelay, _onPointerUpFallback);
  }

  /// 强制结束当前翻页（用户快速连续翻页时调用）
  ///
  /// 触发场景：上一次翻页动画还在跑（_isTurning=true），用户已经开始新一次
  /// pointerDown。如果不强制结束，新 pointerMove 会被 `if (_isTurning) return`
  /// 拦截 → 用户感觉「翻页速度慢，得等动画结束」。
  ///
  /// 策略：
  /// 1. 中断 ticker + abortAnim（停止动画推进）
  /// 2. 自增 _turnToken 让正在进行的 _startTurnSequence/_finalizeTurn 失效
  /// 3. 清理覆盖层（_showAnimationLayer=false）+ 回收 bitmap
  /// 4. 重置状态（_isTurning=false, _finalizeStarted=false）
  /// 5. 通知外部：根据 _finalizeStarted 判断
  ///    - true：_finalizeTurn 已执行到 onPerformPageTurn 阶段（WebView 已跳页）
  ///      → 通知 onPageTurnCompleted（保存进度）
  ///    - false：还在 _startTurnSequence 阶段（WebView 没跳页）
  ///      → 通知 onPageTurnCancelled（回滚）
  ///
  /// 注：hadFinalized=true 时 WebView 已跳页是大概率情况，但若 _finalizeTurn
  /// 还在 await _captureBoundary（curBitmap 截图 50-100ms）阶段就强结束，
  /// 实际 WebView 还没跳页。此时通知 onPageTurnCompleted 会多保存一次进度，
  /// 但 _onPageTurnCompleted 只做 _isPageTurning=false + setState，无副作用。
  void _forceFinishCurrentTurn() {
    _ticker.stop();
    _delegate.abortAnim();
    final direction = _delegate.direction;
    final hadFinalized = _finalizeStarted;
    // 自增 token：让正在 await 的 _startTurnSequence/_finalizeTurn 失效
    // （它们会检查 token != _turnToken，return 不再注入 bitmap 或调用 callback）
    _turnToken++;
    _isTurning = false;
    _finalizeStarted = false;
    // 清理跨手势残留：上一手势截图期间缓存的 move 位置不能带到下一手势
    // 否则下一手势的 _startTurnSequence 截图完成后会用旧位置补帧（视觉跳跃）
    _pendingMoveDuringCapture = null;
    setState(() {
      _showAnimationLayer = false;
    });
    _delegate.recycleBitmaps();
    // 通知外部上一次翻页的最终状态
    if (hadFinalized) {
      widget.onPageTurnCompleted?.call(direction);
    } else {
      widget.onPageTurnCancelled?.call();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (widget.isScrollMode) return;
    if (_downPosition == null) return;
    // _startTurnSequence 在 await 截图期间（_isTurning=true 但 _showAnimationLayer=false）
    // 暂时忽略 move，避免 delegate 没图可画导致空白
    // 但缓存最新位置，截图完成后立即补一次，避免"丢帧"感（Phase 2.1 修复）
    if (_isTurning && !_showAnimationLayer) {
      _pendingMoveDuringCapture = event.position;
      return;
    }

    _applyPointerMove(event.position);
  }

  /// 把 PointerMoveEvent 位置应用到 delegate（Phase 2.1 抽出，便于补帧复用）
  void _applyPointerMove(Offset position) {
    // 用户在拖动，重置 pointerUp 兜底定时器
    _pointerUpFallbackTimer?.cancel();
    _pointerUpFallbackTimer = Timer(_pointerUpFallbackDelay, _onPointerUpFallback);

    // 用合成 PointerMoveEvent 调 delegate（保留事件类型让 _onScroll 分支生效）
    _delegate.onTouch(PointerMoveEvent(
      position: position,
      delta: Offset.zero,
      timeStamp: Duration.zero,
      pointer: 0,
    ));

    // NoAnimPageDelegate 不需要截图覆盖层 —— 松手时直接跳页
    if (_delegate is NoAnimPageDelegate) return;

    // 用户已滑动一定距离且未启动截图 → 启动截图序列（异步）
    // 必须加 !_isTurning 检查：截图期间 _isTurning=true 但 _showAnimationLayer=false，
    // 不加检查会重复触发 _startTurnSequence，token 不断自增导致状态混乱
    if (_delegate.isMoved && !_showAnimationLayer && !_isTurning) {
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
    _pendingMoveDuringCapture = null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointerUpFallbackTimer?.cancel();
    _pointerUpFallbackTimer = null;
    if (_isTurning) {
      _delegate.abortAnim();
      _cancelTurn();
    }
    _downPosition = null;
    _pendingMoveDuringCapture = null;
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
      if (!_finalizeStarted && token == _turnToken) {
        _isTurning = false;
        setState(() {
          _showAnimationLayer = false;
        });
      }
      return;
    }
    if (token != _turnToken) {
      curBitmap.dispose();
      return;
    }

    // 用户已松手：_finalizeTurn 会自己接管跳页流程
    // 但仍然注入截图 + 显示覆盖层，让 _finalizeTurn 复用（避免它再截一次图）
    //
    // 为什么要注入而不是 dispose：
    // - _finalizeTurn 非 NoAnim 分支需要覆盖层挡住 WebView 跳页瞬间
    // - 如果 _startTurnSequence dispose 截图，_finalizeTurn 必须自己再截一次
    //   （50-100ms），期间 WebView 跳页已完成，用户看到白屏闪烁
    // - 注入截图后 _finalizeTurn 检查 _showAnimationLayer=true，直接跳页
    //
    // 但要处理 _finalizeTurn 已完成的情况（_isTurning=false）：
    // - 此时覆盖层已被 _finalizeTurn 销毁，再注入会导致覆盖层残留
    // - 检查 _isTurning=false 时 dispose 截图，不注入
    if (_finalizeStarted) {
      if (!_isTurning) {
        // _finalizeTurn 已完成，dispose 截图避免泄漏
        curBitmap.dispose();
        return;
      }
      // _finalizeTurn 还在 await onPerformPageTurn，注入截图供其使用
      setState(() {
        _delegate.setBitmaps(cur: curBitmap);
        _showAnimationLayer = true;
      });
      return;
    }

    // 显示动画覆盖层，注入 curBitmap
    setState(() {
      _delegate.setBitmaps(cur: curBitmap);
      _showAnimationLayer = true;
    });

    // Phase 2.1 丝滑度修复：截图期间缓存的最新 move 位置立即补一次
    // - 截图耗时 50-100ms，期间用户继续拖动，_onPointerMove 把位置缓存到
    //   _pendingMoveDuringCapture（不直接调 delegate 因为没图可画会空白）
    // - 截图完成覆盖层显示后，立即把 delegate 跳到最新位置，消除"丢帧"感
    // - 若用户在截图期间已松手（_finalizeStarted=true），_finalizeTurn 会
    //   走自己的路径（直接销毁覆盖层或调 onPerformPageTurn），不需要补帧
    if (_pendingMoveDuringCapture != null && !_finalizeStarted) {
      final pending = _pendingMoveDuringCapture!;
      _pendingMoveDuringCapture = null;
      _applyPointerMove(pending);
    }
  }

  /// 结束翻页流程（用户松手时调用）
  ///
  /// 设计变更（用户原话「只要用户触摸，就有动画；没摸就没动画」）：
  /// - 触摸时：delegate.onTouch 实时绘制翻折效果跟随手指
  /// - 松手时：直接跳到目标页，不播放完成动画
  ///
  /// 不再做的步骤：
  /// - 截图 targetBitmap（不播完成动画就不需要目标页截图）
  /// - _delegate.onAnimStart / 启动 ticker（不播完成动画）
  /// - 回弹动画（isCancel 时直接销毁，不跑回弹）
  Future<void> _finalizeTurn() async {
    final token = _turnToken;

    // 用户回拖取消：立即销毁覆盖层，不跑回弹动画
    // （符合「没摸就没动画」原则：松手瞬间不再有任何自动播放的动画）
    if (_delegate.isCancel) {
      _cancelTurn();
      return;
    }

    // NoAnimPageDelegate：直接跳页（none 模式无动画，原逻辑保留）
    if (_delegate is NoAnimPageDelegate) {
      bool ok = true;
      try {
        ok = await widget.onPerformPageTurn(_delegate.direction);
      } catch (e) {
        debugPrint('[ReaderPageView] onPerformPageTurn 异常: $e');
        ok = false;
      }
      if (!ok || token != _turnToken || !mounted) {
        // mounted 守卫：widget 销毁后 _cancelTurn 内部 setState 会抛异常
        if (token == _turnToken && mounted) _cancelTurn();
        return;
      }
      _isTurning = false;
      _finalizeStarted = false;
      widget.onPageTurnCompleted?.call(_delegate.direction);
      _delegate.onDown(); // 重置 delegate 状态
      return;
    }

    // 非 NoAnim：确保覆盖层显示，避免 WebView 跳页时视觉跳跃
    // 场景：用户在 _startTurnSequence 截图完成前松手（_showAnimationLayer=false），
    // 若直接调 onPerformPageTurn 让 WebView 跳页，用户会看到白屏闪一下
    // 修复：_finalizeTurn 自己截图作为覆盖层，等覆盖层显示后再跳页
    if (!_showAnimationLayer) {
      final curBitmap = await _captureBoundary();
      if (curBitmap == null) {
        if (token == _turnToken && mounted) _cancelTurn();
        return;
      }
      // 截图完成后再次检查：
      // - _startTurnSequence 可能在 await 期间完成了截图注入，此时复用它的
      // - token 不匹配或 widget 销毁：dispose 并退出
      if (_showAnimationLayer) {
        curBitmap.dispose();
      } else if (token != _turnToken || !mounted) {
        curBitmap.dispose();
        return;
      } else {
        setState(() {
          _delegate.setBitmaps(cur: curBitmap);
          _showAnimationLayer = true;
        });
      }
    }

    // 让 WebView 立即跳页（覆盖层仍显示挡住跳页瞬间，避免视觉跳跃）
    bool ok = true;
    try {
      ok = await widget.onPerformPageTurn(_delegate.direction);
    } catch (e) {
      debugPrint('[ReaderPageView] onPerformPageTurn 异常: $e');
      ok = false;
    }

    if (!ok || token != _turnToken || !mounted) {
      // 章节边界或 token 失效：取消翻页
      // mounted 守卫：同上
      if (token == _turnToken && mounted) _cancelTurn();
      return;
    }

    // 立即销毁覆盖层 + 重置 delegate
    // （用户已松手，按「没摸就没动画」原则不再播放任何完成动画）
    _isTurning = false;
    _finalizeStarted = false;
    if (mounted) {
      setState(() {
        _showAnimationLayer = false;
      });
    }
    _delegate.recycleBitmaps();
    if (mounted) {
      widget.onPageTurnCompleted?.call(_delegate.direction);
    }
    _delegate.onDown(); // 重置 delegate 状态供下次翻页
  }

  /// 取消翻页（用户回拖或外部中断）
  void _cancelTurn() {
    _turnToken++; // 使正在进行的截图/切换失效
    _ticker.stop(); // 保险：防止 delegate 自己没停干净
    _isTurning = false;
    _finalizeStarted = false;
    // 清理跨手势残留：同 _forceFinishCurrentTurn
    _pendingMoveDuringCapture = null;
    // mounted 检查：_cancelTurn 可能在 _finalizeTurn 的 await 之后被调用，
    // 此时 widget 可能已销毁，setState 会抛 setState() called after dispose()
    if (mounted) {
      setState(() {
        _showAnimationLayer = false;
      });
    }
    // 真正 dispose 所有 ui.Image 资源（不能调 setBitmaps(cur:null,...)，
    // setBitmaps 对 null 参数不做处理，会导致内存泄漏）
    _delegate.recycleBitmaps();
    if (mounted) {
      widget.onPageTurnCancelled?.call();
    }
  }

  void _onAnimStop(PageDirection direction) {
    _ticker.stop(); // delegate.onAnimStop 已停过，这里再保险一次
    // mounted 检查：widget 在动画期间被销毁（页面切换/父级移除 ReaderPageView）
    // 时，delegate 仍会通过 notifyAnimStop 触发本方法，setState 会抛异常
    if (!mounted) return;
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

  /// JS touchend 回调入口（由父级通过 GlobalKey 调用）
  ///
  /// 背景：InAppWebView 是 PlatformView，会吞掉 Flutter 的 PointerUpEvent，
  /// 导致 _onPointerUp 不被调用，_finalizeTurn 不触发，翻页动画覆盖层
  /// 一直显示，用户必须再点一次屏幕（触发 _onPointerDown → _forceFinishCurrentTurn）
  /// 才能销毁覆盖层。
  ///
  /// 修复：JS 端 touchend 监听器 → controller handler → 父级 → 本方法
  /// → 复用 _onPointerUp 的核心逻辑，即时触发 _finalizeTurn。
  ///
  /// 与 _onPointerUp 的区别：
  /// - 没有 PointerUpEvent 参数（JS 不传坐标）
  /// - _downPosition==null 时直接 return（_onPointerUp 已被 Flutter 触发过）
  /// - 仍保留 _pointerUpFallbackTimer 作为最后兜底（防 JS handler 也丢失）
  void handleTouchEnd() {
    if (!mounted) return;
    if (widget.isScrollMode) return;
    // _downPosition==null 说明 _onPointerUp 已被 Flutter 正常触发，
    // 不需要 JS 兜底，避免重复 _finalizeTurn
    if (_downPosition == null) return;
    // _finalizeStarted=true 说明 _finalizeTurn 已在进行中（可能是 _onPointerUp
    // 或 _pointerUpFallbackTimer 触发的），不要重复触发
    if (_finalizeStarted) return;

    _pointerUpFallbackTimer?.cancel();
    _pointerUpFallbackTimer = null;

    if (_delegate.isMoved) {
      _finalizeStarted = true;
      _finalizeTurn();
    }
    _downPosition = null;
    _pendingMoveDuringCapture = null;
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
    // 自适应屏幕 DPR：取真实设备像素比，截图清晰度 = 设备渲染清晰度
    // View.of 比 MediaQuery.devicePixelRatio 更轻量（不依赖 MediaQuery），
    // 在 LayoutBuilder 内部也可用，且不会因父级 MediaQuery 重建而被动刷新
    _devicePixelRatio = View.of(context).devicePixelRatio.clamp(1.0, 2.5);

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
