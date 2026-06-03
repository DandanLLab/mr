import 'package:flutter/material.dart';

/// TTS朗读控制条
/// 复刻 legado_flutter 的 ReaderTtsBar 设计
class ReaderTtsBar extends StatelessWidget {
  final bool isSpeaking;
  final bool isPaused;
  final int paragraphIndex;
  final int paragraphTotal;
  final double fontSize;
  final Color textColor;
  final Color backgroundColor;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;
  final VoidCallback onCycleSpeed;
  final ValueChanged<double> onSpeedChanged;
  final double speed;

  const ReaderTtsBar({
    super.key,
    required this.isSpeaking,
    required this.isPaused,
    required this.paragraphIndex,
    required this.paragraphTotal,
    required this.fontSize,
    required this.textColor,
    required this.backgroundColor,
    required this.onPrev,
    required this.onNext,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onCycleSpeed,
    required this.onSpeedChanged,
    this.speed = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: cs.surface,
        elevation: 8,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 进度条
              _buildProgressBar(cs),
              const SizedBox(height: 8),
              // 控制按钮
              _buildControls(cs),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar(ColorScheme cs) {
    final progress = paragraphTotal > 0 
        ? (paragraphIndex + 1) / paragraphTotal 
        : 0.0;
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          LinearProgressIndicator(
            value: progress,
            backgroundColor: cs.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '第 ${paragraphIndex + 1} / $paragraphTotal 段',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControls(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 语速
          _buildSpeedButton(cs),
          // 上一段
          IconButton(
            icon: const Icon(Icons.skip_previous),
            onPressed: paragraphIndex > 0 ? onPrev : null,
            color: cs.onSurfaceVariant,
          ),
          // 播放/暂停
          IconButton(
            icon: Icon(
              isSpeaking && !isPaused ? Icons.pause : Icons.play_arrow,
            ),
            iconSize: 32,
            onPressed: isSpeaking && !isPaused ? onPause : onResume,
            color: cs.primary,
          ),
          // 下一段
          IconButton(
            icon: const Icon(Icons.skip_next),
            onPressed: paragraphIndex < paragraphTotal - 1 ? onNext : null,
            color: cs.onSurfaceVariant,
          ),
          // 停止
          IconButton(
            icon: const Icon(Icons.stop),
            onPressed: isSpeaking ? onStop : null,
            color: cs.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Widget _buildSpeedButton(ColorScheme cs) {
    return GestureDetector(
      onTap: onCycleSpeed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          '${speed.toStringAsFixed(1)}x',
          style: TextStyle(
            fontSize: 12,
            color: cs.onPrimaryContainer,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
