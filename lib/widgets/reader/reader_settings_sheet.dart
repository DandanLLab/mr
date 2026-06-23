import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../providers/reader_provider.dart';

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
  final ReaderProvider? provider;
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
    this.provider,
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
  // 新增配置（来自 provider，无 provider 时使用默认值）
  int _chineseConverterType = 0;
  bool _fontWeightFine = false;
  int _textBoldFine = 400;
  int _titleBoldFine = 700;
  int _titleMode = 0;
  int _titleSize = 0;
  int _titleTopSpacing = 0;
  int _titleBottomSpacing = 0;
  double _paddingTop = 6.0;
  double _paddingBottom = 6.0;
  double _paddingLeft = 16.0;
  double _paddingRight = 16.0;
  double _headerPaddingTop = 0.0;
  double _headerPaddingBottom = 0.0;
  double _headerPaddingLeft = 16.0;
  double _headerPaddingRight = 16.0;
  double _footerPaddingTop = 6.0;
  double _footerPaddingBottom = 6.0;
  double _footerPaddingLeft = 16.0;
  double _footerPaddingRight = 16.0;
  bool _showHeaderLine = false;
  bool _showFooterLine = true;
  int _headerMode = 1;
  int _footerMode = 0;
  int _tipHeaderLeft = 2;
  int _tipHeaderMiddle = 0;
  int _tipHeaderRight = 3;
  int _tipFooterLeft = 1;
  int _tipFooterMiddle = 0;
  int _tipFooterRight = 6;
  int _headerFontSize = 12;
  int _footerFontSize = 12;
  int _tipColor = 0;
  int _tipDividerColor = -1;

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
    _loadProviderConfig();
  }

  void _loadProviderConfig() {
    final p = widget.provider;
    if (p == null) return;
    _chineseConverterType = p.chineseConverterType;
    _fontWeightFine = p.fontWeightFine;
    _textBoldFine = p.textBoldFine;
    _titleBoldFine = p.titleBoldFine;
    _titleMode = p.titleMode;
    _titleSize = p.titleSize;
    _titleTopSpacing = p.titleTopSpacing;
    _titleBottomSpacing = p.titleBottomSpacing;
    _paddingTop = p.paddingTop;
    _paddingBottom = p.paddingBottom;
    _paddingLeft = p.paddingLeft;
    _paddingRight = p.paddingRight;
    _headerPaddingTop = p.headerPaddingTop;
    _headerPaddingBottom = p.headerPaddingBottom;
    _headerPaddingLeft = p.headerPaddingLeft;
    _headerPaddingRight = p.headerPaddingRight;
    _footerPaddingTop = p.footerPaddingTop;
    _footerPaddingBottom = p.footerPaddingBottom;
    _footerPaddingLeft = p.footerPaddingLeft;
    _footerPaddingRight = p.footerPaddingRight;
    _showHeaderLine = p.showHeaderLine;
    _showFooterLine = p.showFooterLine;
    _headerMode = p.headerMode;
    _footerMode = p.footerMode;
    _tipHeaderLeft = p.tipHeaderLeft;
    _tipHeaderMiddle = p.tipHeaderMiddle;
    _tipHeaderRight = p.tipHeaderRight;
    _tipFooterLeft = p.tipFooterLeft;
    _tipFooterMiddle = p.tipFooterMiddle;
    _tipFooterRight = p.tipFooterRight;
    _headerFontSize = p.headerFontSize;
    _footerFontSize = p.footerFontSize;
    _tipColor = p.tipColor;
    _tipDividerColor = p.tipDividerColor;
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
                  title: '字号',
                  valueText: _fontSize.round().toString(),
                  value: _fontSize,
                  min: 5,
                  max: 50,
                  step: 1,
                  onChanged: (v) {
                    final value = v.roundToDouble();
                    setState(() => _fontSize = value);
                    widget.onFontSizeChanged(value);
                  },
                ),
                _detailSlider(
                  title: '字距',
                  valueText: _letterSpacing.toStringAsFixed(2),
                  value: ((_letterSpacing + 0.5) * 100).clamp(0, 100),
                  min: 0,
                  max: 100,
                  step: 1,
                  onChanged: (v) {
                    final value = v / 100 - 0.5;
                    setState(() => _letterSpacing = value);
                    widget.onLetterSpacingChanged(value);
                  },
                ),
                _detailSlider(
                  title: '行距',
                  valueText: _lineHeight.toStringAsFixed(1),
                  value: ((_lineHeight - 1.0) * 10).clamp(0, 20),
                  min: 0,
                  max: 20,
                  step: 1,
                  onChanged: (v) {
                    final value = 1.0 + v / 10;
                    setState(() => _lineHeight = value);
                    widget.onLineHeightChanged(value);
                  },
                ),
                _detailSlider(
                  title: '段距',
                  valueText: (_paragraphSpacing / 10).toStringAsFixed(1),
                  value: _paragraphSpacing.clamp(0, 20),
                  min: 0,
                  max: 20,
                  step: 1,
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
          _smallButton(_fontWeightLabel(), _cycleFontWeight, onLongPress: () {
            setState(() => _fontWeightFine = !_fontWeightFine);
            final p = widget.provider;
            if (p != null) p.setFontWeightFine(_fontWeightFine);
          }),
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

  Widget _smallButton(String text, VoidCallback onTap, {VoidCallback? onLongPress}) {
    return InkWell(
      borderRadius: BorderRadius.circular(3),
      onTap: onTap,
      onLongPress: onLongPress,
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
    if (_fontWeightFine) return '字重$_textBoldFine';
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
    if (_fontWeightFine) {
      _showFontWeightFineDialog();
      return;
    }
    final value = (_fontWeightIndex + 1) % 3;
    setState(() => _fontWeightIndex = value);
    widget.onFontWeightChanged(value);
  }

  void _showFontWeightFineDialog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelColor,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dialogTitle('字重（精细）'),
                _detailSlider(
                  title: '正文',
                  valueText: _textBoldFine.toString(),
                  value: _textBoldFine.toDouble(),
                  min: 100,
                  max: 900,
                  step: 100,
                  onChanged: (v) {
                    final value = v.round();
                    setSheet(() {});
                    setState(() => _textBoldFine = value);
                    final p = widget.provider;
                    if (p != null) {
                      p.setTextBoldFine(value);
                    }
                  },
                ),
                _detailSlider(
                  title: '标题',
                  valueText: _titleBoldFine.toString(),
                  value: _titleBoldFine.toDouble(),
                  min: 100,
                  max: 900,
                  step: 100,
                  onChanged: (v) {
                    final value = v.round();
                    setSheet(() {});
                    setState(() => _titleBoldFine = value);
                    final p = widget.provider;
                    if (p != null) {
                      p.setTitleBoldFine(value);
                    }
                  },
                ),
                ListTile(
                  title: Text('切换为粗略模式', style: TextStyle(color: _textColor)),
                  onTap: () {
                    Navigator.pop(context);
                    setState(() {
                      _fontWeightFine = false;
                    });
                    final p = widget.provider;
                    if (p != null) p.setFontWeightFine(false);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailSlider({
    required String title,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required double step,
    required ValueChanged<double> onChanged,
  }) {
    final current = value.toDouble().clamp(min, max);
    final canDecrease = current > min;
    final canIncrease = current < max;
    void adjust(double delta) {
      onChanged((current + delta).clamp(min, max).toDouble());
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          SizedBox(
            width: 38,
            child: Text(
              title,
              style: TextStyle(color: _textColor, fontSize: 14),
            ),
          ),
          _seekStepButton('-', canDecrease ? () => adjust(-step) : null),
          const SizedBox(width: 4),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: current,
                min: min,
                max: max,
                divisions: (max - min).round(),
                onChanged: onChanged,
              ),
            ),
          ),
          const SizedBox(width: 4),
          _seekStepButton('+', canIncrease ? () => adjust(step) : null),
          SizedBox(
            width: 38,
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

  Widget _seekStepButton(String text, VoidCallback? onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Center(
          child: Text(
            text,
            style: TextStyle(
              color: onTap == null
                  ? _subColor.withValues(alpha: 0.35)
                  : _textColor,
              fontSize: 20,
              height: 1,
            ),
          ),
        ),
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogTitle('字体'),
              _sheetOption('默认字体', _fontFamily.isEmpty, () => _setFont('')),
              _sheetOption('Serif 衬线', _fontFamily == 'serif', () => _setFont('serif')),
              _sheetOption('Sans Serif 无衬线', _fontFamily == 'sans-serif', () => _setFont('sans-serif')),
              _sheetOption('Monospace 等宽', _fontFamily == 'monospace', () => _setFont('monospace')),
              _sheetOption('Cursive 手写体', _fontFamily == 'cursive', () => _setFont('cursive')),
              _sheetOption('Fantasy 装饰体', _fontFamily == 'fantasy', () => _setFont('fantasy')),
            ],
          ),
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
            _dialogTitle('段落缩进'),
            _sheetOption('无缩进', _paragraphIndent.isEmpty, () => _setIndent('')),
            _sheetOption('一字缩进', _paragraphIndent == '\u3000', () => _setIndent('\u3000')),
            _sheetOption('两字缩进', _paragraphIndent == '\u3000\u3000', () => _setIndent('\u3000\u3000')),
            _sheetOption('三字缩进', _paragraphIndent == '\u3000\u3000\u3000', () => _setIndent('\u3000\u3000\u3000')),
            _sheetOption('四字缩进', _paragraphIndent == '\u3000\u3000\u3000\u3000', () => _setIndent('\u3000\u3000\u3000\u3000')),
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
    double sheetTop = 0, sheetBottom = 0, sheetLeft = 0, sheetRight = 0;
    double hTop = _headerPaddingTop, hBottom = _headerPaddingBottom;
    double hLeft = _headerPaddingLeft, hRight = _headerPaddingRight;
    double fTop = _footerPaddingTop, fBottom = _footerPaddingBottom;
    double fLeft = _footerPaddingLeft, fRight = _footerPaddingRight;
    bool showHeaderLine = _showHeaderLine, showFooterLine = _showFooterLine;
    sheetTop = _paddingTop; sheetBottom = _paddingBottom;
    sheetLeft = _paddingLeft; sheetRight = _paddingRight;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelColor,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _dialogTitle('正文边距'),
                _dialogSlider('上', sheetTop, 0, 60, (v) {
                  setSheet(() => sheetTop = v);
                  setState(() => _paddingTop = v);
                  final p = widget.provider;
                  if (p != null) p.setPaddingTop(v);
                }),
                _dialogSlider('下', sheetBottom, 0, 60, (v) {
                  setSheet(() => sheetBottom = v);
                  setState(() => _paddingBottom = v);
                  final p = widget.provider;
                  if (p != null) p.setPaddingBottom(v);
                }),
                _dialogSlider('左', sheetLeft, 0, 60, (v) {
                  setSheet(() => sheetLeft = v);
                  setState(() => _paddingLeft = v);
                  final p = widget.provider;
                  if (p != null) p.setPaddingLeft(v);
                }),
                _dialogSlider('右', sheetRight, 0, 60, (v) {
                  setSheet(() => sheetRight = v);
                  setState(() => _paddingRight = v);
                  final p = widget.provider;
                  if (p != null) p.setPaddingRight(v);
                }),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('页眉边距', style: TextStyle(color: _subColor, fontSize: 14)),
                ),
                _dialogSlider('上', hTop, 0, 60, (v) {
                  setSheet(() => hTop = v);
                  setState(() => _headerPaddingTop = v);
                  final p = widget.provider;
                  if (p != null) p.setHeaderPaddingTop(v);
                }),
                _dialogSlider('下', hBottom, 0, 60, (v) {
                  setSheet(() => hBottom = v);
                  setState(() => _headerPaddingBottom = v);
                  final p = widget.provider;
                  if (p != null) p.setHeaderPaddingBottom(v);
                }),
                _dialogSlider('左', hLeft, 0, 60, (v) {
                  setSheet(() => hLeft = v);
                  setState(() => _headerPaddingLeft = v);
                  final p = widget.provider;
                  if (p != null) p.setHeaderPaddingLeft(v);
                }),
                _dialogSlider('右', hRight, 0, 60, (v) {
                  setSheet(() => hRight = v);
                  setState(() => _headerPaddingRight = v);
                  final p = widget.provider;
                  if (p != null) p.setHeaderPaddingRight(v);
                }),
                SwitchListTile(
                  title: Text('显示页眉分隔线', style: TextStyle(color: _textColor)),
                  value: showHeaderLine,
                  onChanged: (v) {
                    setSheet(() => showHeaderLine = v);
                    setState(() => _showHeaderLine = v);
                    final p = widget.provider;
                    if (p != null) p.setShowHeaderLine(v);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('页脚边距', style: TextStyle(color: _subColor, fontSize: 14)),
                ),
                _dialogSlider('上', fTop, 0, 60, (v) {
                  setSheet(() => fTop = v);
                  setState(() => _footerPaddingTop = v);
                  final p = widget.provider;
                  if (p != null) p.setFooterPaddingTop(v);
                }),
                _dialogSlider('下', fBottom, 0, 60, (v) {
                  setSheet(() => fBottom = v);
                  setState(() => _footerPaddingBottom = v);
                  final p = widget.provider;
                  if (p != null) p.setFooterPaddingBottom(v);
                }),
                _dialogSlider('左', fLeft, 0, 60, (v) {
                  setSheet(() => fLeft = v);
                  setState(() => _footerPaddingLeft = v);
                  final p = widget.provider;
                  if (p != null) p.setFooterPaddingLeft(v);
                }),
                _dialogSlider('右', fRight, 0, 60, (v) {
                  setSheet(() => fRight = v);
                  setState(() => _footerPaddingRight = v);
                  final p = widget.provider;
                  if (p != null) p.setFooterPaddingRight(v);
                }),
                SwitchListTile(
                  title: Text('显示页脚分隔线', style: TextStyle(color: _textColor)),
                  value: showFooterLine,
                  onChanged: (v) {
                    setSheet(() => showFooterLine = v);
                    setState(() => _showFooterLine = v);
                    final p = widget.provider;
                    if (p != null) p.setShowFooterLine(v);
                  },
                ),
              ],
            ),
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

  static const List<String> _tipNames = [
    '无', '书名', '章节标题', '时间', '电量', '内置电量', '电量百分比',
    '页码', '总进度', '总进度1', '页码/总页数', '时间电量', '时间电量图标', '时间电量百分比',
  ];
  static const List<int> _tipValues = [
    0, 7, 1, 2, 3, 12, 10, 4, 5, 11, 6, 8, 13, 9,
  ];

  String _tipName(int value) {
    final i = _tipValues.indexOf(value);
    if (i < 0) return '无';
    return _tipNames[i];
  }

  Widget _tipSelectorTile(String label, int value, ValueChanged<int> onPick) {
    return ListTile(
      title: Text(label, style: TextStyle(color: _textColor)),
      trailing: Text(_tipName(value), style: TextStyle(color: _subColor, fontSize: 13)),
      onTap: () {
        showModalBottomSheet<void>(
          context: context,
          backgroundColor: _panelColor,
          builder: (ctx) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 0; i < _tipNames.length; i++)
                    _sheetOption(_tipNames[i], value == _tipValues[i], () {
                      Navigator.pop(ctx);
                      onPick(_tipValues[i]);
                    }),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showInfoDialog() {
    final p = widget.provider;
    int titleMode = _titleMode, titleSize = _titleSize;
    int titleTop = _titleTopSpacing, titleBottom = _titleBottomSpacing;
    int headerMode = _headerMode, footerMode = _footerMode;
    int tipHL = _tipHeaderLeft, tipHM = _tipHeaderMiddle, tipHR = _tipHeaderRight;
    int tipFL = _tipFooterLeft, tipFM = _tipFooterMiddle, tipFR = _tipFooterRight;
    int hfs = _headerFontSize, ffs = _footerFontSize;
    bool showInfo = _showReadingInfo, showTitle = _showChapterTitle;
    bool showClock = _showClock, showProgress = _showProgress;

    void clearRepeat(int repeat, StateSetter setSheet) {
      if (repeat == 0) return;
      setSheet(() {
        if (tipHL == repeat) tipHL = 0;
        if (tipHM == repeat) tipHM = 0;
        if (tipHR == repeat) tipHR = 0;
        if (tipFL == repeat) tipFL = 0;
        if (tipFM == repeat) tipFM = 0;
        if (tipFR == repeat) tipFR = 0;
      });
    }

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelColor,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _dialogTitle('阅读信息'),

                // 标题设置
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('标题', style: TextStyle(color: _subColor, fontSize: 14)),
                ),
                Row(
                  children: [
                    _segButton('居左', titleMode == 0, () { setSheet(() => titleMode = 0); setState(() => _titleMode = 0); if (p != null) p.setTitleMode(0); }),
                    _segButton('居中', titleMode == 1, () { setSheet(() => titleMode = 1); setState(() => _titleMode = 1); if (p != null) p.setTitleMode(1); }),
                    _segButton('隐藏', titleMode == 2, () { setSheet(() => titleMode = 2); setState(() => _titleMode = 2); if (p != null) p.setTitleMode(2); }),
                  ],
                ),
                _infoSlider('标题字号(0=跟随)', titleSize.toDouble(), 0, 40, (v) {
                  final value = v.round();
                  setSheet(() => titleSize = value);
                  setState(() => _titleSize = value);
                  if (p != null) p.setTitleSize(value);
                }),
                _infoSlider('标题上间距', titleTop.toDouble(), 0, 40, (v) {
                  final value = v.round();
                  setSheet(() => titleTop = value);
                  setState(() => _titleTopSpacing = value);
                  if (p != null) p.setTitleTopSpacing(value);
                }),
                _infoSlider('标题下间距', titleBottom.toDouble(), 0, 40, (v) {
                  final value = v.round();
                  setSheet(() => titleBottom = value);
                  setState(() => _titleBottomSpacing = value);
                  if (p != null) p.setTitleBottomSpacing(value);
                }),

                // 页眉
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('页眉', style: TextStyle(color: _subColor, fontSize: 14)),
                ),
                Row(
                  children: [
                    _segButton('状态栏时隐藏', headerMode == 0, () { setSheet(() => headerMode = 0); setState(() => _headerMode = 0); if (p != null) p.setHeaderMode(0); }),
                    _segButton('显示', headerMode == 1, () { setSheet(() => headerMode = 1); setState(() => _headerMode = 1); if (p != null) p.setHeaderMode(1); }),
                    _segButton('隐藏', headerMode == 2, () { setSheet(() => headerMode = 2); setState(() => _headerMode = 2); if (p != null) p.setHeaderMode(2); }),
                  ],
                ),
                _tipSelectorTile('页眉左', tipHL, (v) { setSheet(() => tipHL = v); setState(() => _tipHeaderLeft = v); clearRepeat(v, setSheet); if (p != null) p.setTipHeaderLeft(v); }),
                _tipSelectorTile('页眉中', tipHM, (v) { setSheet(() => tipHM = v); setState(() => _tipHeaderMiddle = v); clearRepeat(v, setSheet); if (p != null) p.setTipHeaderMiddle(v); }),
                _tipSelectorTile('页眉右', tipHR, (v) { setSheet(() => tipHR = v); setState(() => _tipHeaderRight = v); clearRepeat(v, setSheet); if (p != null) p.setTipHeaderRight(v); }),
                _infoSlider('页眉字号', hfs.toDouble(), 8, 30, (v) {
                  final value = v.round();
                  setSheet(() => hfs = value);
                  setState(() => _headerFontSize = value);
                  if (p != null) p.setHeaderFontSize(value);
                }),

                // 页脚
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('页脚', style: TextStyle(color: _subColor, fontSize: 14)),
                ),
                Row(
                  children: [
                    _segButton('显示', footerMode == 0, () { setSheet(() => footerMode = 0); setState(() => _footerMode = 0); if (p != null) p.setFooterMode(0); }),
                    _segButton('隐藏', footerMode == 1, () { setSheet(() => footerMode = 1); setState(() => _footerMode = 1); if (p != null) p.setFooterMode(1); }),
                  ],
                ),
                _tipSelectorTile('页脚左', tipFL, (v) { setSheet(() => tipFL = v); setState(() => _tipFooterLeft = v); clearRepeat(v, setSheet); if (p != null) p.setTipFooterLeft(v); }),
                _tipSelectorTile('页脚中', tipFM, (v) { setSheet(() => tipFM = v); setState(() => _tipFooterMiddle = v); clearRepeat(v, setSheet); if (p != null) p.setTipFooterMiddle(v); }),
                _tipSelectorTile('页脚右', tipFR, (v) { setSheet(() => tipFR = v); setState(() => _tipFooterRight = v); clearRepeat(v, setSheet); if (p != null) p.setTipFooterRight(v); }),
                _infoSlider('页脚字号', ffs.toDouble(), 8, 30, (v) {
                  final value = v.round();
                  setSheet(() => ffs = value);
                  setState(() => _footerFontSize = value);
                  if (p != null) p.setFooterFontSize(value);
                }),

                // 信息颜色
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text('颜色', style: TextStyle(color: _subColor, fontSize: 14)),
                ),
                ListTile(
                  title: Text('信息文字颜色', style: TextStyle(color: _textColor)),
                  trailing: Text(_tipColor == 0 ? '跟随正文' : '#${_tipColor.toRadixString(16).padLeft(8, '0')}', style: TextStyle(color: _subColor, fontSize: 13)),
                  onTap: () {
                    showModalBottomSheet<void>(
                      context: context,
                      backgroundColor: _panelColor,
                      builder: (ctx) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _sheetOption('跟随正文', _tipColor == 0, () { Navigator.pop(ctx); setState(() => _tipColor = 0); final p = widget.provider; if (p != null) p.setTipColor(0); }),
                            _sheetOption('自定义颜色', _tipColor != 0, () async {
                              Navigator.pop(ctx);
                              final color = await _pickColor(context, _tipColor == 0 ? 0xFF888888 : _tipColor);
                              if (color != null) {
                                setState(() => _tipColor = color);
                                final p = widget.provider;
                                if (p != null) p.setTipColor(color);
                              }
                            }),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  title: Text('分隔线颜色', style: TextStyle(color: _textColor)),
                  trailing: Text(_tipDividerColor == -1 ? '跟随正文' : (_tipDividerColor == 0 ? '无' : '#${_tipDividerColor.toRadixString(16).padLeft(8, '0')}'), style: TextStyle(color: _subColor, fontSize: 13)),
                  onTap: () {
                    showModalBottomSheet<void>(
                      context: context,
                      backgroundColor: _panelColor,
                      builder: (ctx) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _sheetOption('跟随正文', _tipDividerColor == -1, () { Navigator.pop(ctx); setState(() => _tipDividerColor = -1); final p = widget.provider; if (p != null) p.setTipDividerColor(-1); }),
                            _sheetOption('无分隔线', _tipDividerColor == 0, () { Navigator.pop(ctx); setState(() => _tipDividerColor = 0); final p = widget.provider; if (p != null) p.setTipDividerColor(0); }),
                            _sheetOption('自定义颜色', _tipDividerColor > 0, () async {
                              Navigator.pop(ctx);
                              final color = await _pickColor(context, _tipDividerColor > 0 ? _tipDividerColor : 0xFF888888);
                              if (color != null) {
                                setState(() => _tipDividerColor = color);
                                final p = widget.provider;
                                if (p != null) p.setTipDividerColor(color);
                              }
                            }),
                          ],
                        ),
                      ),
                    );
                  },
                ),

                _switchTile('显示阅读信息', showInfo, (v) { setSheet(() => showInfo = v); setState(() => _showReadingInfo = v); widget.onShowReadingInfoChanged(v); }),
                _switchTile('章节标题', showTitle, (v) { setSheet(() => showTitle = v); setState(() => _showChapterTitle = v); widget.onShowChapterTitleChanged(v); }),
                _switchTile('时间', showClock, (v) { setSheet(() => showClock = v); setState(() => _showClock = v); widget.onShowClockChanged(v); }),
                _switchTile('进度', showProgress, (v) { setSheet(() => showProgress = v); setState(() => _showProgress = v); widget.onShowProgressChanged(v); }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _segButton(String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(3),
          onTap: onTap,
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.20) : _controlColor,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: selected ? Theme.of(context).colorScheme.primary : _subColor.withValues(alpha: 0.12)),
            ),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: selected ? Theme.of(context).colorScheme.primary : _textColor, fontSize: 12)),
          ),
        ),
      ),
    );
  }

  Widget _infoSlider(String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 100, child: Text(label, style: TextStyle(color: _textColor, fontSize: 13))),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: (max - min).round(),
              onChanged: onChanged,
            ),
          ),
          SizedBox(width: 32, child: Text(value.round().toString(), textAlign: TextAlign.end, style: TextStyle(color: _subColor, fontSize: 12))),
        ],
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
              step: 10,
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
    final options = ['不转换', '简体转繁体', '繁体转简体'];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelColor,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogTitle('繁简转换'),
            for (int i = 0; i < options.length; i++)
              _sheetOption(options[i], _chineseConverterType == i, () {
                Navigator.pop(context);
                setState(() => _chineseConverterType = i);
                final p = widget.provider;
                if (p != null) {
                  p.setChineseConverterType(i);
                }
              }),
          ],
        ),
      ),
    );
  }

  Future<int?> _pickColor(BuildContext context, int initial) async {
    // 简易颜色选择：预设色板
    const palette = [0xFF888888, 0xFFE53935, 0xFF43A047, 0xFF1E88E5, 0xFFFB8C00, 0xFF8E24AA, 0xFF000000, 0xFFFFFFFF];
    int? picked;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择颜色'),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: palette.map((c) {
            return InkWell(
              onTap: () { picked = c; Navigator.pop(ctx); },
              child: Container(width: 36, height: 36, decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle, border: Border.all(color: Colors.black26))),
            );
          }).toList(),
        ),
      ),
    );
    return picked;
  }

}
