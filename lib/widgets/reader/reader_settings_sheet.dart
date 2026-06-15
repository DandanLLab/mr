import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class ReaderSettingsSheet extends StatefulWidget {
  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final double paragraphSpacing;
  final double horizontalPadding;
  final double verticalPadding;
  final String paragraphIndent;
  final int fontWeightIndex;
  final String fontFamily;
  final Color backgroundColor;
  final String? backgroundImagePath;
  final bool showReadingInfo;
  final bool showChapterTitle;
  final bool showClock;
  final bool showProgress;
  final int pageAnim;
  final int pageAnimDurationMs;
  final double screenBrightness;
  final bool keepScreenOn;
  final bool enableVolumeKeyPage;
  final bool volumeKeyPageOnTts;
  final bool enableLongPressMenu;
  final int autoScrollSpeed;
  final int autoPageIntervalSeconds;
  final List<int> tapZones;
  final bool isNightMode;

  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<double> onLineHeightChanged;
  final ValueChanged<double> onLetterSpacingChanged;
  final ValueChanged<double> onParagraphSpacingChanged;
  final ValueChanged<double> onHorizontalPaddingChanged;
  final ValueChanged<double> onVerticalPaddingChanged;
  final ValueChanged<String> onParagraphIndentChanged;
  final ValueChanged<int> onFontWeightChanged;
  final ValueChanged<String> onFontFamilyChanged;
  final ValueChanged<Color> onBackgroundColorChanged;
  final ValueChanged<String?> onBackgroundImageChanged;
  final ValueChanged<bool> onShowReadingInfoChanged;
  final ValueChanged<bool> onShowChapterTitleChanged;
  final ValueChanged<bool> onShowClockChanged;
  final ValueChanged<bool> onShowProgressChanged;
  final ValueChanged<int> onPageAnimChanged;
  final ValueChanged<int> onPageAnimDurationChanged;
  final ValueChanged<double> onScreenBrightnessChanged;
  final ValueChanged<bool> onKeepScreenOnChanged;
  final ValueChanged<bool> onEnableVolumeKeyPageChanged;
  final ValueChanged<bool> onVolumeKeyPageOnTtsChanged;
  final ValueChanged<bool> onEnableLongPressMenuChanged;
  final ValueChanged<int> onAutoScrollSpeedChanged;
  final ValueChanged<int> onAutoPageIntervalChanged;
  final ValueChanged<List<int>> onTapZonesChanged;
  final ValueChanged<bool> onNightModeChanged;
  final VoidCallback? onClose;

  const ReaderSettingsSheet({
    super.key,
    required this.fontSize,
    required this.lineHeight,
    required this.letterSpacing,
    required this.paragraphSpacing,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.paragraphIndent,
    required this.fontWeightIndex,
    required this.fontFamily,
    required this.backgroundColor,
    this.backgroundImagePath,
    required this.showReadingInfo,
    required this.showChapterTitle,
    required this.showClock,
    required this.showProgress,
    required this.pageAnim,
    required this.pageAnimDurationMs,
    required this.screenBrightness,
    required this.keepScreenOn,
    required this.enableVolumeKeyPage,
    required this.volumeKeyPageOnTts,
    required this.enableLongPressMenu,
    required this.autoScrollSpeed,
    required this.autoPageIntervalSeconds,
    required this.tapZones,
    required this.isNightMode,
    required this.onFontSizeChanged,
    required this.onLineHeightChanged,
    required this.onLetterSpacingChanged,
    required this.onParagraphSpacingChanged,
    required this.onHorizontalPaddingChanged,
    required this.onVerticalPaddingChanged,
    required this.onParagraphIndentChanged,
    required this.onFontWeightChanged,
    required this.onFontFamilyChanged,
    required this.onBackgroundColorChanged,
    required this.onBackgroundImageChanged,
    required this.onShowReadingInfoChanged,
    required this.onShowChapterTitleChanged,
    required this.onShowClockChanged,
    required this.onShowProgressChanged,
    required this.onPageAnimChanged,
    required this.onPageAnimDurationChanged,
    required this.onScreenBrightnessChanged,
    required this.onKeepScreenOnChanged,
    required this.onEnableVolumeKeyPageChanged,
    required this.onVolumeKeyPageOnTtsChanged,
    required this.onEnableLongPressMenuChanged,
    required this.onAutoScrollSpeedChanged,
    required this.onAutoPageIntervalChanged,
    required this.onTapZonesChanged,
    required this.onNightModeChanged,
    this.onClose,
  });

  static const List<Color> presetColors = [
    Color(0xFFFFF8E1),
    Color(0xFFE8F5E9),
    Color(0xFFE3F2FD),
    Color(0xFFFFF3E0),
    Color(0xFFF3E5F5),
    Color(0xFFFFFFFF),
    Color(0xFFF5F5F5),
    Color(0xFF1A1A1A),
  ];

  static const Map<int, String> pageAnimLabels = {
    2: '覆盖',
    1: '滑动',
    3: '仿真',
    0: '滚动',
    4: '无',
  };

  @override
  State<ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<ReaderSettingsSheet> {
  late double _fontSize;
  late double _lineHeight;
  late double _letterSpacing;
  late double _paragraphSpacing;
  late double _horizontalPadding;
  late double _verticalPadding;
  late String _paragraphIndent;
  late int _fontWeightIndex;
  late String _fontFamily;
  late Color _backgroundColor;
  String? _backgroundImagePath;
  late bool _showReadingInfo;
  late bool _showChapterTitle;
  late bool _showClock;
  late bool _showProgress;
  late int _pageAnim;
  late int _pageAnimDurationMs;
  late double _screenBrightness;
  late bool _keepScreenOn;
  late bool _enableVolumeKeyPage;
  late bool _volumeKeyPageOnTts;
  late bool _enableLongPressMenu;
  late int _autoScrollSpeed;
  late int _autoPageIntervalSeconds;

  bool get _isDark =>
      _backgroundColor.computeLuminance() < 0.2 || widget.isNightMode;
  Color get _panelColor =>
      _isDark ? const Color(0xFF1B1B1B) : const Color(0xFFF5F5F5);
  Color get _controlColor =>
      _isDark ? const Color(0xFF252525) : const Color(0xFFEDEDED);
  Color get _textColor =>
      _isDark ? Colors.white.withValues(alpha: 0.86) : Colors.black87;
  Color get _subColor => _isDark ? Colors.white60 : Colors.black54;

  @override
  void initState() {
    super.initState();
    _fontSize = widget.fontSize;
    _lineHeight = widget.lineHeight;
    _letterSpacing = widget.letterSpacing;
    _paragraphSpacing = widget.paragraphSpacing;
    _horizontalPadding = widget.horizontalPadding;
    _verticalPadding = widget.verticalPadding;
    _paragraphIndent = widget.paragraphIndent;
    _fontWeightIndex = widget.fontWeightIndex;
    _fontFamily = widget.fontFamily;
    _backgroundColor = widget.backgroundColor;
    _backgroundImagePath = widget.backgroundImagePath;
    _showReadingInfo = widget.showReadingInfo;
    _showChapterTitle = widget.showChapterTitle;
    _showClock = widget.showClock;
    _showProgress = widget.showProgress;
    _pageAnim = widget.pageAnim;
    _pageAnimDurationMs = widget.pageAnimDurationMs;
    _screenBrightness = widget.screenBrightness;
    _keepScreenOn = widget.keepScreenOn;
    _enableVolumeKeyPage = widget.enableVolumeKeyPage;
    _volumeKeyPageOnTts = widget.volumeKeyPageOnTts;
    _enableLongPressMenu = widget.enableLongPressMenu;
    _autoScrollSpeed = widget.autoScrollSpeed;
    _autoPageIntervalSeconds = widget.autoPageIntervalSeconds;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: _panelColor,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(0, 12, 0, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _topButtons(),
                const SizedBox(height: 6),
                _detailSlider(
                  title: '文字大小',
                  valueText: _fontSize.round().toString(),
                  value: _fontSize,
                  min: 5,
                  max: 50,
                  onChanged: (v) {
                    final value = v.roundToDouble();
                    setState(() => _fontSize = value);
                    widget.onFontSizeChanged(value);
                  },
                ),
                _detailSlider(
                  title: '字间距',
                  valueText: _letterSpacing.toStringAsFixed(2),
                  value: ((_letterSpacing + 0.5) * 100).clamp(0, 100),
                  min: 0,
                  max: 100,
                  onChanged: (v) {
                    final value = v / 100 - 0.5;
                    setState(() => _letterSpacing = value);
                    widget.onLetterSpacingChanged(value);
                  },
                ),
                _detailSlider(
                  title: '行间距',
                  valueText: _lineHeight.toStringAsFixed(1),
                  value: ((_lineHeight - 1.0) * 10).clamp(0, 20),
                  min: 0,
                  max: 20,
                  onChanged: (v) {
                    final value = 1.0 + v / 10;
                    setState(() => _lineHeight = value);
                    widget.onLineHeightChanged(value);
                  },
                ),
                _detailSlider(
                  title: '段落间距',
                  valueText: (_paragraphSpacing / 10).toStringAsFixed(1),
                  value: _paragraphSpacing.clamp(0, 20),
                  min: 0,
                  max: 20,
                  onChanged: (v) {
                    setState(() => _paragraphSpacing = v);
                    widget.onParagraphSpacingChanged(v);
                  },
                ),
                _divider(),
                _pageAnimGroup(),
                _divider(),
                _styleHeader(),
                const SizedBox(height: 8),
                _styleList(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _smallButton(_fontWeightLabel(), _cycleFontWeight),
          const Spacer(),
          _smallButton('字体', _showFontDialog),
          const Spacer(),
          _smallButton('缩进', _showIndentDialog),
          const Spacer(),
          _smallButton('繁简', _showConverterHint),
          const Spacer(),
          _smallButton('边距', _showPaddingDialog),
          const Spacer(),
          _smallButton('信息', _showInfoDialog),
        ],
      ),
    );
  }

  Widget _smallButton(String text, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(3),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 42),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: _controlColor,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: _subColor.withValues(alpha: 0.14)),
        ),
        child: Text(text, style: TextStyle(color: _textColor, fontSize: 14)),
      ),
    );
  }

  String _fontWeightLabel() {
    switch (_fontWeightIndex) {
      case 0:
        return '细体';
      case 2:
        return '粗体';
      default:
        return '常规';
    }
  }

  void _cycleFontWeight() {
    final value = (_fontWeightIndex + 1) % 3;
    setState(() => _fontWeightIndex = value);
    widget.onFontWeightChanged(value);
  }

  Widget _detailSlider({
    required String title,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(
              title,
              style: TextStyle(color: _textColor, fontSize: 14),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.toDouble().clamp(min, max),
              min: min,
              max: max,
              divisions: (max - min).round(),
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              valueText,
              textAlign: TextAlign.end,
              style: TextStyle(color: _subColor, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() {
    return Container(
      height: 0.8,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      color: _subColor.withValues(alpha: 0.18),
    );
  }

  Widget _pageAnimGroup() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('翻页动画', style: TextStyle(color: _subColor, fontSize: 12)),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: Row(
            children: ReaderSettingsSheet.pageAnimLabels.entries.map((entry) {
              final selected = _pageAnim == entry.key;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(3),
                    onTap: () {
                      setState(() => _pageAnim = entry.key);
                      widget.onPageAnimChanged(entry.key);
                    },
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      decoration: BoxDecoration(
                        color: selected
                            ? Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.20)
                            : _controlColor,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : _subColor.withValues(alpha: 0.12),
                        ),
                      ),
                      child: Text(
                        entry.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : _textColor,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _styleHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '背景样式',
              style: TextStyle(color: _subColor, fontSize: 12),
            ),
          ),
          Text('共享排版', style: TextStyle(color: _textColor, fontSize: 14)),
          const SizedBox(width: 6),
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(
              value: false,
              onChanged: (_) {},
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  Widget _styleList() {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: ReaderSettingsSheet.presetColors.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          if (index == ReaderSettingsSheet.presetColors.length) {
            return _addStyleButton();
          }
          final color = ReaderSettingsSheet.presetColors[index];
          final selected =
              _backgroundImagePath == null &&
              color.toARGB32() == _backgroundColor.toARGB32();
          return GestureDetector(
            onTap: () {
              setState(() {
                _backgroundColor = color;
                _backgroundImagePath = null;
              });
              widget.onBackgroundColorChanged(color);
              widget.onBackgroundImageChanged(null);
            },
            onLongPress: _showBackgroundDialog,
            child: Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : _textColor,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: Text(
                '文字',
                style: TextStyle(
                  color: color.computeLuminance() < 0.3
                      ? Colors.white70
                      : Colors.black87,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _addStyleButton() {
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: _showBackgroundDialog,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: _textColor),
        ),
        child: Icon(Icons.add, color: _textColor),
      ),
    );
  }

  void _showFontDialog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelColor,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetOption('默认字体', _fontFamily.isEmpty, () => _setFont('')),
            _sheetOption(
              'Serif',
              _fontFamily == 'serif',
              () => _setFont('serif'),
            ),
            _sheetOption(
              'Sans Serif',
              _fontFamily == 'sans-serif',
              () => _setFont('sans-serif'),
            ),
            _sheetOption(
              'Monospace',
              _fontFamily == 'monospace',
              () => _setFont('monospace'),
            ),
          ],
        ),
      ),
    );
  }

  void _setFont(String family) {
    Navigator.pop(context);
    setState(() => _fontFamily = family);
    widget.onFontFamilyChanged(family);
  }

  void _showIndentDialog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelColor,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetOption('无缩进', _paragraphIndent.isEmpty, () => _setIndent('')),
            _sheetOption(
              '一字缩进',
              _paragraphIndent == '\u3000',
              () => _setIndent('\u3000'),
            ),
            _sheetOption(
              '两字缩进',
              _paragraphIndent == '\u3000\u3000',
              () => _setIndent('\u3000\u3000'),
            ),
          ],
        ),
      ),
    );
  }

  void _setIndent(String indent) {
    Navigator.pop(context);
    setState(() => _paragraphIndent = indent);
    widget.onParagraphIndentChanged(indent);
  }

  Widget _sheetOption(String title, bool selected, VoidCallback onTap) {
    return ListTile(
      title: Text(title, style: TextStyle(color: _textColor)),
      trailing: selected
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }

  void _showPaddingDialog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelColor,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogTitle('正文边距'),
              _dialogSlider('上', _verticalPadding, 0, 60, (v) {
                setState(() => _verticalPadding = v);
                widget.onVerticalPaddingChanged(v);
              }),
              _dialogSlider('下', _verticalPadding, 0, 60, (v) {
                setState(() => _verticalPadding = v);
                widget.onVerticalPaddingChanged(v);
              }),
              _dialogSlider('左', _horizontalPadding, 0, 60, (v) {
                setState(() => _horizontalPadding = v);
                widget.onHorizontalPaddingChanged(v);
              }),
              _dialogSlider('右', _horizontalPadding, 0, 60, (v) {
                setState(() => _horizontalPadding = v);
                widget.onHorizontalPaddingChanged(v);
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dialogTitle(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          color: _textColor,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _dialogSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 24,
          child: Text(label, style: TextStyle(color: _textColor)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: (max - min).round(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.end,
            style: TextStyle(color: _subColor),
          ),
        ),
      ],
    );
  }

  void _showInfoDialog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelColor,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _switchTile('显示阅读信息', _showReadingInfo, (v) {
              setState(() => _showReadingInfo = v);
              widget.onShowReadingInfoChanged(v);
            }),
            _switchTile('章节标题', _showChapterTitle, (v) {
              setState(() => _showChapterTitle = v);
              widget.onShowChapterTitleChanged(v);
            }),
            _switchTile('时间', _showClock, (v) {
              setState(() => _showClock = v);
              widget.onShowClockChanged(v);
            }),
            _switchTile('进度', _showProgress, (v) {
              setState(() => _showProgress = v);
              widget.onShowProgressChanged(v);
            }),
          ],
        ),
      ),
    );
  }

  Widget _switchTile(String title, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      title: Text(title, style: TextStyle(color: _textColor)),
      value: value,
      onChanged: onChanged,
    );
  }

  void _showBackgroundDialog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelColor,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _switchTile('夜间模式', widget.isNightMode, widget.onNightModeChanged),
            ListTile(
              leading: Icon(Icons.image_outlined, color: _textColor),
              title: Text('选择背景图片', style: TextStyle(color: _textColor)),
              onTap: () async {
                Navigator.pop(context);
                await _pickBackgroundImage();
              },
            ),
            if (_backgroundImagePath != null)
              ListTile(
                leading: Icon(Icons.delete_outline, color: _textColor),
                title: Text('清除背景图片', style: TextStyle(color: _textColor)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _backgroundImagePath = null);
                  widget.onBackgroundImageChanged(null);
                },
              ),
            _switchTile('保持屏幕常亮', _keepScreenOn, (v) {
              setState(() => _keepScreenOn = v);
              widget.onKeepScreenOnChanged(v);
            }),
            _switchTile('音量键翻页', _enableVolumeKeyPage, (v) {
              setState(() => _enableVolumeKeyPage = v);
              widget.onEnableVolumeKeyPageChanged(v);
            }),
            _switchTile('朗读时音量键翻页', _volumeKeyPageOnTts, (v) {
              setState(() => _volumeKeyPageOnTts = v);
              widget.onVolumeKeyPageOnTtsChanged(v);
            }),
            _switchTile('启用长按菜单', _enableLongPressMenu, (v) {
              setState(() => _enableLongPressMenu = v);
              widget.onEnableLongPressMenuChanged(v);
            }),
            _dialogSlider(
              '亮度',
              _screenBrightness < 0
                  ? 100
                  : (_screenBrightness * 100).clamp(0, 100),
              0,
              100,
              (v) {
                final value = v / 100;
                setState(() => _screenBrightness = value);
                widget.onScreenBrightnessChanged(value);
              },
            ),
            _dialogSlider('自动滚动', _autoScrollSpeed.toDouble(), 10, 100, (v) {
              final value = v.round();
              setState(() => _autoScrollSpeed = value);
              widget.onAutoScrollSpeedChanged(value);
            }),
            _dialogSlider('自动翻页', _autoPageIntervalSeconds.toDouble(), 0, 60, (
              v,
            ) {
              final value = v.round();
              setState(() => _autoPageIntervalSeconds = value);
              widget.onAutoPageIntervalChanged(value);
            }),
            _detailSlider(
              title: '动画时长',
              valueText: '${_pageAnimDurationMs}ms',
              value: _pageAnimDurationMs.toDouble(),
              min: 120,
              max: 800,
              onChanged: (v) {
                final value = v.round();
                setState(() => _pageAnimDurationMs = value);
                widget.onPageAnimDurationChanged(value);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickBackgroundImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      final sourcePath = result?.files.single.path;
      if (sourcePath == null) return;

      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory(
        '${appDir.path}${Platform.pathSeparator}reader_backgrounds',
      );
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final ext = sourcePath.split('.').last.toLowerCase();
      final fileName = 'bg_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final destPath = '${dir.path}${Platform.pathSeparator}$fileName';
      await File(sourcePath).copy(destPath);

      setState(() => _backgroundImagePath = destPath);
      widget.onBackgroundImageChanged(destPath);
    } catch (e) {
      debugPrint('[ReaderSettings] pick background image failed: $e');
    }
  }

  void _showConverterHint() {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('繁简转换设置暂未接入')));
  }
}
