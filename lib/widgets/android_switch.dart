import 'package:flutter/material.dart';

/// Android风格Switch组件 - 分别控制thumb和track尺寸
/// 参考原版 SwitchCompat：thumb约20dp，track约34x14dp
class AndroidSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color? accentColor;
  final bool isDark;
  final bool enabled;

  const AndroidSwitch({
    super.key,
    required this.value,
    this.onChanged,
    this.accentColor,
    this.isDark = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    // thumb尺寸 - 圆圈直径约20dp
    const thumbSize = 20.0;
    // track尺寸 - 长方形约34x14dp
    const trackWidth = 34.0;
    const trackHeight = 14.0;

    // 获取主题色
    final effectiveAccentColor = accentColor ?? Theme.of(context).colorScheme.primary;

    // 颜色 - 参考原版TintHelper
    final thumbColor = enabled
        ? (value ? effectiveAccentColor : (isDark ? const Color(0xFFBDBDBD) : const Color(0xFFFAFAFA)))
        : (isDark ? const Color(0xFF424242) : const Color(0xFFBDBDBD));

    final trackColor = enabled
        ? (value ? effectiveAccentColor.withOpacity(0.5) : (isDark ? const Color(0x4DFFFFFF) : const Color(0x43000000)))
        : (isDark ? const Color(0x1AFFFFFF) : const Color(0x1F000000));

    return GestureDetector(
      onTap: enabled ? () => onChanged?.call(!value) : null,
      child: SizedBox(
        width: trackWidth,
        height: thumbSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // track - 长方形横条
            Container(
              width: trackWidth,
              height: trackHeight,
              decoration: BoxDecoration(
                color: trackColor,
                borderRadius: BorderRadius.circular(trackHeight / 2),
              ),
            ),
            // thumb - 圆圈
            AnimatedAlign(
              duration: const Duration(milliseconds: 200),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: thumbSize,
                height: thumbSize,
                decoration: BoxDecoration(
                  color: thumbColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}