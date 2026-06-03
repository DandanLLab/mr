import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 阅读器增强版控制面板
/// 复刻 legado_flutter 的 ReaderControlOverlay 设计
class ReaderControlOverlay extends StatelessWidget {
  final String bookName;
  final String chapterTitle;
  final String sourceName;
  final int currentChapter;
  final int totalChapters;
  final bool hasBookmark;
  final bool hasPrev;
  final bool hasNext;
  final bool isAutoScroll;
  final bool isNightMode;
  final double sliderValue;
  final VoidCallback onBack;
  final VoidCallback onChangeSource;
  final VoidCallback onRefresh;
  final VoidCallback onDownload;
  final VoidCallback onToggleBookmark;
  final VoidCallback onClose;
  final VoidCallback onPrevChapter;
  final VoidCallback onNextChapter;
  final VoidCallback onStartSearch;
  final VoidCallback onToggleAutoScroll;
  final VoidCallback onToggleNightMode;
  final VoidCallback onOpenReplaceRules;
  final VoidCallback onShowDirectory;
  final VoidCallback onStartTts;
  final VoidCallback onShowSettings;
  final ValueChanged<double> onSliderChanged;
  final ValueChanged<int> onSliderChangeEnd;

  const ReaderControlOverlay({
    super.key,
    required this.bookName,
    required this.chapterTitle,
    required this.sourceName,
    required this.currentChapter,
    required this.totalChapters,
    required this.hasBookmark,
    required this.hasPrev,
    required this.hasNext,
    required this.isAutoScroll,
    required this.isNightMode,
    required this.sliderValue,
    required this.onBack,
    required this.onChangeSource,
    required this.onRefresh,
    required this.onDownload,
    required this.onToggleBookmark,
    required this.onClose,
    required this.onPrevChapter,
    required this.onNextChapter,
    required this.onStartSearch,
    required this.onToggleAutoScroll,
    required this.onToggleNightMode,
    required this.onOpenReplaceRules,
    required this.onShowDirectory,
    required this.onStartTts,
    required this.onShowSettings,
    required this.onSliderChanged,
    required this.onSliderChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = cs.brightness == Brightness.dark;
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).padding.bottom;

    return Column(
      children: [
        // 顶部导航栏
        _buildTopBar(context, cs, isDark, topPad),
        // 中间悬浮按钮
        Expanded(
          child: Stack(
            children: [
              // 点击关闭
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onClose,
                ),
              ),
              // 悬浮按钮
              Positioned(
                left: 0,
                right: 0,
                bottom: 120,
                child: _buildCenterButtons(context, cs),
              ),
            ],
          ),
        ),
        // 底部控制栏
        _buildBottomBar(context, cs, botPad),
      ],
    );
  }

  Widget _buildTopBar(BuildContext context, ColorScheme cs, bool isDark, double topPad) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: cs.surface,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
      child: Material(
        color: cs.surface,
        child: Padding(
          padding: EdgeInsets.fromLTRB(8, topPad + 4, 4, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeaderRow1(context, cs),
              const SizedBox(height: 4),
              _buildHeaderRow2(cs),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderRow1(BuildContext context, ColorScheme cs) {
    final title = bookName.isNotEmpty ? bookName : (chapterTitle.isNotEmpty ? chapterTitle : '阅读');
    return Row(
      children: [
        _buildIconBtn(Icons.arrow_back, cs, tooltip: '返回', onTap: onBack),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: cs.onSurface,
            ),
          ),
        ),
        _buildIconBtn(Icons.swap_horiz, cs, tooltip: '换源', onTap: onChangeSource),
        _buildIconBtn(Icons.refresh, cs, tooltip: '刷新', onTap: onRefresh),
        _buildIconBtn(Icons.download, cs, tooltip: '缓存', onTap: onDownload),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: cs.onSurfaceVariant, size: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onSelected: (v) {
            if (v == 'bookmark') onToggleBookmark();
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'bookmark',
              child: Row(
                children: [
                  Icon(hasBookmark ? Icons.bookmark : Icons.bookmark_border, size: 20),
                  const SizedBox(width: 8),
                  const Text('书签'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHeaderRow2(ColorScheme cs) {
    final label = sourceName.isNotEmpty ? sourceName : '书源';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (chapterTitle.isNotEmpty)
                  Text(
                    chapterTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: cs.onPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCenterButtons(BuildContext context, ColorScheme cs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildFab(Icons.search, cs, onTap: onStartSearch),
        _buildFab(isAutoScroll ? Icons.pause : Icons.autorenew, cs, onTap: onToggleAutoScroll),
        _buildFab(isNightMode ? Icons.wb_sunny : Icons.nightlight_round, cs, onTap: onToggleNightMode),
        _buildFab(Icons.settings, cs, onTap: onShowSettings),
      ],
    );
  }

  Widget _buildBottomBar(BuildContext context, ColorScheme cs, double botPad) {
    return Material(
      color: cs.surface,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, 4, 12, botPad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgressBar(context, cs),
            const SizedBox(height: 8),
            _buildBottomNav(context, cs),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar(BuildContext context, ColorScheme cs) {
    final maxCh = (totalChapters - 1).toDouble();
    final maxChClamped = maxCh < 0 ? 0.0 : maxCh;
    final cur = (sliderValue >= 0 ? sliderValue : currentChapter.toDouble())
        .clamp(0.0, maxChClamped)
        .toDouble();

    return Row(
      children: [
        _buildLabelBtn('上一章', cs, hasPrev ? onPrevChapter : null),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              activeTrackColor: cs.primary,
              inactiveTrackColor: cs.surfaceContainerHighest,
              thumbColor: cs.primary,
            ),
            child: Slider(
              value: cur,
              min: 0,
              max: maxChClamped,
              divisions: totalChapters > 1 ? totalChapters - 1 : 1,
              onChanged: onSliderChanged,
              onChangeEnd: (v) {
                final idx = v.round().clamp(0, totalChapters - 1);
                onSliderChangeEnd(idx);
              },
            ),
          ),
        ),
        _buildLabelBtn('下一章', cs, hasNext ? onNextChapter : null),
      ],
    );
  }

  Widget _buildBottomNav(BuildContext context, ColorScheme cs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _buildNavBtn(Icons.list, '目录', cs, onShowDirectory),
        _buildNavBtn(Icons.headphones, '朗读', cs, onStartTts),
        _buildNavBtn(Icons.format_size, '界面', cs, onToggleNightMode),
        _buildNavBtn(Icons.settings, '设置', cs, onShowSettings),
      ],
    );
  }

  Widget _buildIconBtn(IconData icon, ColorScheme cs, {String? tooltip, required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Tooltip(
        message: tooltip ?? '',
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: cs.onSurfaceVariant, size: 24),
        ),
      ),
    );
  }

  Widget _buildLabelBtn(String label, ColorScheme cs, VoidCallback? onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            color: onTap != null ? cs.onSurfaceVariant : cs.onSurfaceVariant.withAlpha(0x40),
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildNavBtn(IconData icon, String label, ColorScheme cs, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: cs.onSurfaceVariant, size: 24),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _buildFab(IconData icon, ColorScheme cs, {required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: cs.surface,
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withAlpha(0x14),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, color: cs.onSurfaceVariant, size: 24),
      ),
    );
  }
}
