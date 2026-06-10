import 'package:flutter/material.dart';

/// 滑动动作数据
class SwipeAction {
  final Widget icon;
  final Color backgroundColor;
  final VoidCallback onAction;

  const SwipeAction({
    required this.icon,
    required this.backgroundColor,
    required this.onAction,
  });
}

/// 滑动动作容器 - 模仿原版 legados 的实现
class SwipeActionContainer extends StatefulWidget {
  final Widget child;
  final List<SwipeAction>? startActions;
  final List<SwipeAction>? endActions;

  const SwipeActionContainer({
    super.key,
    required this.child,
    this.startActions,
    this.endActions,
  });

  @override
  State<SwipeActionContainer> createState() => _SwipeActionContainerState();
}

class _SwipeActionContainerState extends State<SwipeActionContainer>
    with SingleTickerProviderStateMixin {
  double _offsetX = 0;
  late AnimationController _controller;
  late Animation<double> _animation;

  static const double _actionWidth = 72.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _controller.addListener(() {
      setState(() {
        _offsetX = _animation.value;
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _animateTo(double target) {
    _animation = Tween<double>(
      begin: _offsetX,
      end: target,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));
    _controller.forward(from: 0);
  }

  void _onDragEnd(DragEndDetails details) {
    final totalStartWidth = _actionWidth * (widget.startActions?.length ?? 0);
    final totalEndWidth = _actionWidth * (widget.endActions?.length ?? 0);

    final velocity = details.primaryVelocity ?? 0;

    bool shouldTriggerStart = _offsetX > totalStartWidth / 2 || velocity > 600;
    bool shouldTriggerEnd = _offsetX < -totalEndWidth / 2 || velocity < -600;

    if (shouldTriggerEnd && (widget.endActions?.isNotEmpty ?? false)) {
      widget.endActions!.first.onAction();
    } else if (shouldTriggerStart && (widget.startActions?.isNotEmpty ?? false)) {
      widget.startActions!.first.onAction();
    }

    _animateTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final totalStartWidth = _actionWidth * (widget.startActions?.length ?? 0);
    final totalEndWidth = _actionWidth * (widget.endActions?.length ?? 0);

    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        setState(() {
          _offsetX = (_offsetX + details.delta.dx).clamp(-totalEndWidth, totalStartWidth);
        });
      },
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: () => _animateTo(0),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 开始动作（左侧删除按钮）
          if (widget.startActions != null && _offsetX > 0)
            Positioned(
              left: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: widget.startActions!.map((action) {
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: action.backgroundColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: action.icon,
                    );
                  }).toList(),
                ),
              ),
            ),
          // 结束动作（右侧）
          if (widget.endActions != null && _offsetX < 0)
            Positioned(
              right: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: widget.endActions!.map((action) {
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: action.backgroundColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: action.icon,
                    );
                  }).toList(),
                ),
              ),
            ),
          // 内容
          Transform.translate(
            offset: Offset(_offsetX, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

/// 创建删除动作
SwipeAction createSwipeDeleteAction(BuildContext context, VoidCallback onDelete) {
  return SwipeAction(
    icon: Icon(
      Icons.delete,
      size: 22,
      color: Theme.of(context).colorScheme.error,
    ),
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
    onAction: onDelete,
  );
}
