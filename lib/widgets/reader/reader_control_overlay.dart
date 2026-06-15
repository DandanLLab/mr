import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Reader menu patterned after Legado: top book/source actions, center quick
/// actions, and bottom catalog/TTS/interface/settings entries.
class ReaderControlOverlay extends StatefulWidget {
  final String bookName;
  final String chapterTitle;
  final String? chapterUrl;
  final String sourceName;
  final bool hasBookSource;
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
  final VoidCallback onShowInterface;
  final VoidCallback onShowSettings;
  final VoidCallback? onOpenDetail;
  final VoidCallback? onOpenChapterUrl;
  final VoidCallback? onEditSource;
  final VoidCallback? onDisableSource;
  final ValueChanged<double> onSliderChanged;
  final ValueChanged<int> onSliderChangeEnd;
  final VoidCallback? onSliderChangeStart;

  const ReaderControlOverlay({
    super.key,
    required this.bookName,
    required this.chapterTitle,
    this.chapterUrl,
    required this.sourceName,
    this.hasBookSource = false,
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
    required this.onShowInterface,
    required this.onShowSettings,
    required this.onSliderChanged,
    required this.onSliderChangeEnd,
    this.onSliderChangeStart,
    this.onOpenDetail,
    this.onOpenChapterUrl,
    this.onEditSource,
    this.onDisableSource,
  });

  @override
  State<ReaderControlOverlay> createState() => _ReaderControlOverlayState();
}

class _ReaderControlOverlayState extends State<ReaderControlOverlay> {
  bool _isSliderDragging = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = cs.brightness == Brightness.dark;
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).padding.bottom;

    return Column(
      children: [
        _buildTopBar(context, cs, isDark, topPad),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _isSliderDragging ? null : widget.onClose,
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 120,
                child: _buildCenterButtons(cs),
              ),
            ],
          ),
        ),
        _buildBottomBar(context, cs, botPad),
      ],
    );
  }

  Widget _buildTopBar(
    BuildContext context,
    ColorScheme cs,
    bool isDark,
    double topPad,
  ) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: cs.surface,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
      child: Material(
        color: cs.surface,
        child: Padding(
          padding: EdgeInsets.fromLTRB(8, topPad, 4, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [_buildHeaderRow1(context, cs), _buildHeaderRow2(cs)],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderRow1(BuildContext context, ColorScheme cs) {
    final title = widget.bookName.isNotEmpty
        ? widget.bookName
        : (widget.chapterTitle.isNotEmpty ? widget.chapterTitle : '阅读');
    return Row(
      children: [
        _buildIconBtn(
          Icons.arrow_back,
          cs,
          tooltip: '返回',
          onTap: widget.onBack,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: InkWell(
            onTap: widget.onOpenDetail,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
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
                  const SizedBox(width: 4),
                  if (widget.onOpenDetail != null)
                    Icon(
                      Icons.chevron_right,
                      color: cs.onSurface.withValues(alpha: 0.54),
                      size: 20,
                    ),
                ],
              ),
            ),
          ),
        ),
        _buildIconBtn(
          Icons.swap_horiz,
          cs,
          tooltip: '换源',
          onTap: widget.onChangeSource,
        ),
        _buildIconBtn(
          Icons.refresh,
          cs,
          tooltip: '刷新',
          onTap: widget.onRefresh,
        ),
        _buildIconBtn(
          Icons.download,
          cs,
          tooltip: '缓存',
          onTap: widget.onDownload,
        ),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: cs.onSurfaceVariant, size: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          tooltip: '更多选项',
          offset: const Offset(0, 48),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onSelected: (v) {
            if (v == 'bookmark') widget.onToggleBookmark();
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'bookmark',
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    widget.hasBookmark ? Icons.bookmark : Icons.bookmark_border,
                    size: 20,
                  ),
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
    final label = widget.sourceName.isNotEmpty ? widget.sourceName : '书源';
    final hasUrl = widget.chapterUrl != null && widget.chapterUrl!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: InkWell(
              onTap: hasUrl ? widget.onOpenChapterUrl : null,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.chapterTitle.isNotEmpty
                                ? widget.chapterTitle
                                : '章节',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (hasUrl)
                          Icon(
                            Icons.open_in_new,
                            color: cs.onSurfaceVariant.withValues(alpha: 0.54),
                            size: 14,
                          ),
                      ],
                    ),
                    if (hasUrl)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          widget.chapterUrl!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                            fontSize: 11,
                            decoration: TextDecoration.underline,
                            decorationColor: cs.onSurfaceVariant.withValues(
                              alpha: 0.38,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            enabled: widget.hasBookSource,
            tooltip: '书源操作',
            offset: const Offset(0, 48),
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  widget.onEditSource?.call();
                  break;
                case 'disable':
                  widget.onDisableSource?.call();
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'edit',
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    const Text('编辑书源'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'disable',
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(Icons.block, size: 20, color: cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    const Text('禁用书源'),
                  ],
                ),
              ),
            ],
            child: Container(
              constraints: const BoxConstraints(maxWidth: 120, minHeight: 30),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: cs.primary.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.source, size: 11, color: cs.primary),
                  const SizedBox(width: 2),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.primary,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (widget.hasBookSource)
                    Icon(
                      Icons.arrow_drop_down,
                      size: 12,
                      color: cs.primary.withValues(alpha: 0.7),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCenterButtons(ColorScheme cs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildFab(Icons.search, cs, onTap: widget.onStartSearch),
        _buildFab(
          widget.isAutoScroll ? Icons.pause : Icons.autorenew,
          cs,
          onTap: widget.onToggleAutoScroll,
        ),
        _buildFab(Icons.find_replace, cs, onTap: widget.onOpenReplaceRules),
        _buildFab(
          widget.isNightMode ? Icons.wb_sunny : Icons.nightlight_round,
          cs,
          onTap: widget.onToggleNightMode,
        ),
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
            _buildProgressBar(cs),
            const SizedBox(height: 8),
            _buildBottomNav(cs),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar(ColorScheme cs) {
    final maxCh = (widget.totalChapters - 1).toDouble();
    final maxChClamped = maxCh < 0 ? 0.0 : maxCh;
    final cur =
        (widget.sliderValue >= 0
                ? widget.sliderValue
                : widget.currentChapter.toDouble())
            .clamp(0.0, maxChClamped)
            .toDouble();

    return Row(
      children: [
        _buildLabelBtn('上一章', cs, widget.hasPrev ? widget.onPrevChapter : null),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: cs.primary,
              inactiveTrackColor: cs.surfaceContainerHighest,
              thumbColor: cs.primary,
              overlayColor: cs.primary.withAlpha(0x20),
            ),
            child: Slider(
              value: cur,
              min: 0,
              max: maxChClamped > 0 ? maxChClamped : 1,
              onChanged: widget.onSliderChanged,
              onChangeStart: (_) {
                setState(() {
                  _isSliderDragging = true;
                });
                widget.onSliderChangeStart?.call();
              },
              onChangeEnd: (v) {
                setState(() {
                  _isSliderDragging = false;
                });
                final idx = v.round().clamp(0, widget.totalChapters - 1);
                widget.onSliderChangeEnd(idx);
              },
            ),
          ),
        ),
        _buildLabelBtn('下一章', cs, widget.hasNext ? widget.onNextChapter : null),
      ],
    );
  }

  Widget _buildBottomNav(ColorScheme cs) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _buildNavBtn(Icons.list, '目录', cs, widget.onShowDirectory),
        _buildNavBtn(Icons.headphones, '朗读', cs, widget.onStartTts),
        _buildNavBtn(Icons.format_size, '界面', cs, widget.onShowInterface),
        _buildNavBtn(Icons.settings, '设置', cs, widget.onShowSettings),
      ],
    );
  }

  Widget _buildIconBtn(
    IconData icon,
    ColorScheme cs, {
    String? tooltip,
    required VoidCallback onTap,
  }) {
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
            color: onTap != null ? cs.onSurface : cs.onSurface.withAlpha(0x40),
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildNavBtn(
    IconData icon,
    String label,
    ColorScheme cs,
    VoidCallback onTap,
  ) {
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
            Text(
              label,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFab(
    IconData icon,
    ColorScheme cs, {
    required VoidCallback onTap,
  }) {
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
