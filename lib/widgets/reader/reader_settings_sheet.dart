import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class ReaderSettingsSheet extends StatefulWidget {
  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final double paragraphSpacing;
  final String paragraphIndent;
  final int fontWeightIndex;
  final String fontFamily;
  final Color backgroundColor;
  final String? backgroundImagePath;
  final bool showReadingInfo;
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
  final int chineseConverterType;
  final bool fontWeightFine;
  final int textBoldFine;
  final int titleBoldFine;
  final int titleMode;
  final int titleSize;
  final int titleTopSpacing;
  final int titleBottomSpacing;
  final double paddingTop;
  final double paddingBottom;
  final double paddingLeft;
  final double paddingRight;
  final double headerPaddingTop;
  final double headerPaddingBottom;
  final double headerPaddingLeft;
  final double headerPaddingRight;
  final double footerPaddingTop;
  final double footerPaddingBottom;
  final double footerPaddingLeft;
  final double footerPaddingRight;
  final bool showHeaderLine;
  final bool showFooterLine;
  final int headerMode;
  final int footerMode;
  final int tipHeaderLeft;
  final int tipHeaderMiddle;
  final int tipHeaderRight;
  final int tipFooterLeft;
  final int tipFooterMiddle;
  final int tipFooterRight;
  final int headerFontSize;
  final int footerFontSize;

  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<double> onLineHeightChanged;
  final ValueChanged<double> onLetterSpacingChanged;
  final ValueChanged<double> onParagraphSpacingChanged;
  final ValueChanged<String> onParagraphIndentChanged;
  final ValueChanged<int> onFontWeightChanged;
  final ValueChanged<String> onFontFamilyChanged;
  final ValueChanged<Color> onBackgroundColorChanged;
  final ValueChanged<String?> onBackgroundImageChanged;
  final ValueChanged<bool> onShowReadingInfoChanged;
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
  final ValueChanged<int> onChineseConverterTypeChanged;
  final ValueChanged<bool> onFontWeightFineChanged;
  final ValueChanged<int> onTextBoldFineChanged;
  final ValueChanged<int> onTitleBoldFineChanged;
  final ValueChanged<int> onTitleModeChanged;
  final ValueChanged<int> onTitleSizeChanged;
  final ValueChanged<int> onTitleTopSpacingChanged;
  final ValueChanged<int> onTitleBottomSpacingChanged;
  final ValueChanged<double> onPaddingTopChanged;
  final ValueChanged<double> onPaddingBottomChanged;
  final ValueChanged<double> onPaddingLeftChanged;
  final ValueChanged<double> onPaddingRightChanged;
  final ValueChanged<double> onHeaderPaddingTopChanged;
  final ValueChanged<double> onHeaderPaddingBottomChanged;
  final ValueChanged<double> onHeaderPaddingLeftChanged;
  final ValueChanged<double> onHeaderPaddingRightChanged;
  final ValueChanged<double> onFooterPaddingTopChanged;
  final ValueChanged<double> onFooterPaddingBottomChanged;
  final ValueChanged<double> onFooterPaddingLeftChanged;
  final ValueChanged<double> onFooterPaddingRightChanged;
  final ValueChanged<bool> onShowHeaderLineChanged;
  final ValueChanged<bool> onShowFooterLineChanged;
  final ValueChanged<int> onHeaderModeChanged;
  final ValueChanged<int> onFooterModeChanged;
  final ValueChanged<int> onTipHeaderLeftChanged;
  final ValueChanged<int> onTipHeaderMiddleChanged;
  final ValueChanged<int> onTipHeaderRightChanged;
  final ValueChanged<int> onTipFooterLeftChanged;
  final ValueChanged<int> onTipFooterMiddleChanged;
  final ValueChanged<int> onTipFooterRightChanged;
  final ValueChanged<int> onHeaderFontSizeChanged;
  final ValueChanged<int> onFooterFontSizeChanged;
  final VoidCallback? onClose;

  const ReaderSettingsSheet({
    super.key,
    required this.fontSize,
    required this.lineHeight,
    required this.letterSpacing,
    required this.paragraphSpacing,
    required this.paragraphIndent,
    required this.fontWeightIndex,
    required this.fontFamily,
    required this.backgroundColor,
    this.backgroundImagePath,
    required this.showReadingInfo,
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
    required this.chineseConverterType,
    required this.fontWeightFine,
    required this.textBoldFine,
    required this.titleBoldFine,
    required this.titleMode,
    required this.titleSize,
    required this.titleTopSpacing,
    required this.titleBottomSpacing,
    required this.paddingTop,
    required this.paddingBottom,
    required this.paddingLeft,
    required this.paddingRight,
    required this.headerPaddingTop,
    required this.headerPaddingBottom,
    required this.headerPaddingLeft,
    required this.headerPaddingRight,
    required this.footerPaddingTop,
    required this.footerPaddingBottom,
    required this.footerPaddingLeft,
    required this.footerPaddingRight,
    required this.showHeaderLine,
    required this.showFooterLine,
    required this.headerMode,
    required this.footerMode,
    required this.tipHeaderLeft,
    required this.tipHeaderMiddle,
    required this.tipHeaderRight,
    required this.tipFooterLeft,
    required this.tipFooterMiddle,
    required this.tipFooterRight,
    required this.headerFontSize,
    required this.footerFontSize,
    required this.onFontSizeChanged,
    required this.onLineHeightChanged,
    required this.onLetterSpacingChanged,
    required this.onParagraphSpacingChanged,
    required this.onParagraphIndentChanged,
    required this.onFontWeightChanged,
    required this.onFontFamilyChanged,
    required this.onBackgroundColorChanged,
    required this.onBackgroundImageChanged,
    required this.onShowReadingInfoChanged,
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
    required this.onChineseConverterTypeChanged,
    required this.onFontWeightFineChanged,
    required this.onTextBoldFineChanged,
    required this.onTitleBoldFineChanged,
    required this.onTitleModeChanged,
    required this.onTitleSizeChanged,
    required this.onTitleTopSpacingChanged,
    required this.onTitleBottomSpacingChanged,
    required this.onPaddingTopChanged,
    required this.onPaddingBottomChanged,
    required this.onPaddingLeftChanged,
    required this.onPaddingRightChanged,
    required this.onHeaderPaddingTopChanged,
    required this.onHeaderPaddingBottomChanged,
    required this.onHeaderPaddingLeftChanged,
    required this.onHeaderPaddingRightChanged,
    required this.onFooterPaddingTopChanged,
    required this.onFooterPaddingBottomChanged,
    required this.onFooterPaddingLeftChanged,
    required this.onFooterPaddingRightChanged,
    required this.onShowHeaderLineChanged,
    required this.onShowFooterLineChanged,
    required this.onHeaderModeChanged,
    required this.onFooterModeChanged,
    required this.onTipHeaderLeftChanged,
    required this.onTipHeaderMiddleChanged,
    required this.onTipHeaderRightChanged,
    required this.onTipFooterLeftChanged,
    required this.onTipFooterMiddleChanged,
    required this.onTipFooterRightChanged,
    required this.onHeaderFontSizeChanged,
    required this.onFooterFontSizeChanged,
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
  late int _pageAnim;
  late int _pageAnimDurationMs;
  late double _screenBrightness;
  late bool _keepScreenOn;
  late bool _enableVolumeKeyPage;
  late bool _volumeKeyPageOnTts;
  late bool _enableLongPressMenu;
  late int _autoScrollSpeed;
  late int _autoPageIntervalSeconds;
  late int _chineseConverterType;
  late bool _fontWeightFine;
  late int _textBoldFine;
  late int _titleBoldFine;
  late int _titleMode;
  late int _titleSize;
  late int _titleTopSpacing;
  late int _titleBottomSpacing;
  late double _paddingTop;
  late double _paddingBottom;
  late double _paddingLeft;
  late double _paddingRight;
  late double _headerPaddingTop;
  late double _headerPaddingBottom;
  late double _headerPaddingLeft;
  late double _headerPaddingRight;
  late double _footerPaddingTop;
  late double _footerPaddingBottom;
  late double _footerPaddingLeft;
  late double _footerPaddingRight;
  late bool _showHeaderLine;
  late bool _showFooterLine;
  late int _headerMode;
  late int _footerMode;
  late int _tipHeaderLeft;
  late int _tipHeaderMiddle;
  late int _tipHeaderRight;
  late int _tipFooterLeft;
  late int _tipFooterMiddle;
  late int _tipFooterRight;
  late int _headerFontSize;
  late int _footerFontSize;

  bool get _isDark =>
      _backgroundColor.computeLuminance() < 0.2 || widget.isNightMode;
  Color get _panelColor =>
      _isDark ? const Color(0xFF1B1B1B) : const Color(0xFFF5F5F5);
  Color get _controlColor =>
      _isDark ? const Color(0xFF252525) : const Color(0xFFEDEDED);
  Color get _textColor =>
      _isDark ? Colors.white.withValues(alpha: 0.86) : Colors.black87;
  Color get _subColor => _isDark ? Colors.white60 : Colors.black54;
  ButtonStyle get _segmentedStyle => ButtonStyle(
    foregroundColor: WidgetStateProperty.resolveWith((states) {
      return states.contains(WidgetState.selected)
          ? Theme.of(context).colorScheme.primary
          : _textColor;
    }),
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      return states.contains(WidgetState.selected)
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.16)
          : _controlColor;
    }),
  );

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
    _pageAnim = widget.pageAnim;
    _pageAnimDurationMs = widget.pageAnimDurationMs;
    _screenBrightness = widget.screenBrightness;
    _keepScreenOn = widget.keepScreenOn;
    _enableVolumeKeyPage = widget.enableVolumeKeyPage;
    _volumeKeyPageOnTts = widget.volumeKeyPageOnTts;
    _enableLongPressMenu = widget.enableLongPressMenu;
    _autoScrollSpeed = widget.autoScrollSpeed;
    _autoPageIntervalSeconds = widget.autoPageIntervalSeconds;
    _chineseConverterType = widget.chineseConverterType;
    _fontWeightFine = widget.fontWeightFine;
    _textBoldFine = widget.textBoldFine;
    _titleBoldFine = widget.titleBoldFine;
    _titleMode = widget.titleMode;
    _titleSize = widget.titleSize;
    _titleTopSpacing = widget.titleTopSpacing;
    _titleBottomSpacing = widget.titleBottomSpacing;
    _paddingTop = widget.paddingTop;
    _paddingBottom = widget.paddingBottom;
    _paddingLeft = widget.paddingLeft;
    _paddingRight = widget.paddingRight;
    _headerPaddingTop = widget.headerPaddingTop;
    _headerPaddingBottom = widget.headerPaddingBottom;
    _headerPaddingLeft = widget.headerPaddingLeft;
    _headerPaddingRight = widget.headerPaddingRight;
    _footerPaddingTop = widget.footerPaddingTop;
    _footerPaddingBottom = widget.footerPaddingBottom;
    _footerPaddingLeft = widget.footerPaddingLeft;
    _footerPaddingRight = widget.footerPaddingRight;
    _showHeaderLine = widget.showHeaderLine;
    _showFooterLine = widget.showFooterLine;
    _headerMode = widget.headerMode;
    _footerMode = widget.footerMode;
    _tipHeaderLeft = widget.tipHeaderLeft;
    _tipHeaderMiddle = widget.tipHeaderMiddle;
    _tipHeaderRight = widget.tipHeaderRight;
    _tipFooterLeft = widget.tipFooterLeft;
    _tipFooterMiddle = widget.tipFooterMiddle;
    _tipFooterRight = widget.tipFooterRight;
    _headerFontSize = widget.headerFontSize;
    _footerFontSize = widget.footerFontSize;
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
          _smallButton(_fontWeightLabel(), _showFontWeightDialog),
          const Spacer(),
          _smallButton('字体', _showFontDialog),
          const Spacer(),
          _smallButton('缩进', _showIndentDialog),
          const Spacer(),
          _smallButton(_converterLabel(), _showConverterDialog),
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

  String _converterLabel() {
    return switch (_chineseConverterType) {
      1 => '简→繁',
      2 => '繁→简',
      _ => '繁简',
    };
  }

  void _showFontWeightDialog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelColor,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: StatefulBuilder(
          builder: (context, setSheetState) {
            void update(VoidCallback callback) {
              setState(callback);
              setSheetState(() {});
            }

            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(child: _dialogTitle('字体粗细')),
                      Text('精细模式', style: TextStyle(color: _textColor)),
                      Switch(
                        value: _fontWeightFine,
                        onChanged: (value) {
                          update(() => _fontWeightFine = value);
                          widget.onFontWeightFineChanged(value);
                        },
                      ),
                    ],
                  ),
                  if (!_fontWeightFine)
                    SegmentedButton<int>(
                      style: _segmentedStyle,
                      segments: const [
                        ButtonSegment(value: 0, label: Text('细体')),
                        ButtonSegment(value: 1, label: Text('常规')),
                        ButtonSegment(value: 2, label: Text('粗体')),
                      ],
                      selected: {_fontWeightIndex},
                      onSelectionChanged: (values) {
                        final value = values.first;
                        update(() => _fontWeightIndex = value);
                        widget.onFontWeightChanged(value);
                      },
                    )
                  else ...[
                    _dialogSlider('正文', _textBoldFine.toDouble(), 100, 900, (
                      value,
                    ) {
                      final weight = (value / 100).round() * 100;
                      update(() => _textBoldFine = weight);
                      widget.onTextBoldFineChanged(weight);
                    }),
                    _dialogSlider('标题', _titleBoldFine.toDouble(), 100, 900, (
                      value,
                    ) {
                      final weight = (value / 100).round() * 100;
                      update(() => _titleBoldFine = weight);
                      widget.onTitleBoldFineChanged(weight);
                    }),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _showConverterDialog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _panelColor,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _sheetOption('不转换', _chineseConverterType == 0, () {
              _setConverterType(0);
            }),
            _sheetOption('简体转繁体', _chineseConverterType == 1, () {
              _setConverterType(1);
            }),
            _sheetOption('繁体转简体', _chineseConverterType == 2, () {
              _setConverterType(2);
            }),
          ],
        ),
      ),
    );
  }

  void _setConverterType(int value) {
    Navigator.pop(context);
    setState(() => _chineseConverterType = value);
    widget.onChineseConverterTypeChanged(value);
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
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text('背景样式', style: TextStyle(color: _subColor, fontSize: 12)),
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
      isScrollControlled: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.82,
        child: SafeArea(
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              void update(VoidCallback callback) {
                setState(callback);
                setSheetState(() {});
              }

              Widget slider(
                String label,
                double value,
                ValueChanged<double> onChanged,
              ) {
                return _dialogSlider(label, value, 0, 60, onChanged);
              }

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                children: [
                  _dialogTitle('正文边距'),
                  slider('上边距', _paddingTop, (value) {
                    update(() => _paddingTop = value);
                    widget.onPaddingTopChanged(value);
                  }),
                  slider('下边距', _paddingBottom, (value) {
                    update(() => _paddingBottom = value);
                    widget.onPaddingBottomChanged(value);
                  }),
                  slider('左边距', _paddingLeft, (value) {
                    update(() => _paddingLeft = value);
                    widget.onPaddingLeftChanged(value);
                  }),
                  slider('右边距', _paddingRight, (value) {
                    update(() => _paddingRight = value);
                    widget.onPaddingRightChanged(value);
                  }),
                  _divider(),
                  _dialogTitle('页眉边距'),
                  slider('上边距', _headerPaddingTop, (value) {
                    update(() => _headerPaddingTop = value);
                    widget.onHeaderPaddingTopChanged(value);
                  }),
                  slider('下边距', _headerPaddingBottom, (value) {
                    update(() => _headerPaddingBottom = value);
                    widget.onHeaderPaddingBottomChanged(value);
                  }),
                  slider('左边距', _headerPaddingLeft, (value) {
                    update(() => _headerPaddingLeft = value);
                    widget.onHeaderPaddingLeftChanged(value);
                  }),
                  slider('右边距', _headerPaddingRight, (value) {
                    update(() => _headerPaddingRight = value);
                    widget.onHeaderPaddingRightChanged(value);
                  }),
                  _switchTile('显示页眉分隔线', _showHeaderLine, (value) {
                    update(() => _showHeaderLine = value);
                    widget.onShowHeaderLineChanged(value);
                  }),
                  _divider(),
                  _dialogTitle('页脚边距'),
                  slider('上边距', _footerPaddingTop, (value) {
                    update(() => _footerPaddingTop = value);
                    widget.onFooterPaddingTopChanged(value);
                  }),
                  slider('下边距', _footerPaddingBottom, (value) {
                    update(() => _footerPaddingBottom = value);
                    widget.onFooterPaddingBottomChanged(value);
                  }),
                  slider('左边距', _footerPaddingLeft, (value) {
                    update(() => _footerPaddingLeft = value);
                    widget.onFooterPaddingLeftChanged(value);
                  }),
                  slider('右边距', _footerPaddingRight, (value) {
                    update(() => _footerPaddingRight = value);
                    widget.onFooterPaddingRightChanged(value);
                  }),
                  _switchTile('显示页脚分隔线', _showFooterLine, (value) {
                    update(() => _showFooterLine = value);
                    widget.onShowFooterLineChanged(value);
                  }),
                ],
              );
            },
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
          width: 68,
          child: Text(label, style: TextStyle(color: _textColor)),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: _isDark ? const Color(0xFF6EA8FF) : null,
              inactiveTrackColor: _isDark
                  ? Colors.white.withValues(alpha: 0.28)
                  : null,
              thumbColor: _isDark ? const Color(0xFFBFD7FF) : null,
              overlayColor: _isDark
                  ? const Color(0xFF6EA8FF).withValues(alpha: 0.16)
                  : null,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: (max - min).round(),
              onChanged: onChanged,
            ),
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
      isScrollControlled: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.86,
        child: SafeArea(
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              void update(VoidCallback callback) {
                setState(callback);
                setSheetState(() {});
              }

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  _dialogTitle('章节标题'),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    style: _segmentedStyle,
                    segments: const [
                      ButtonSegment(value: 0, label: Text('居左')),
                      ButtonSegment(value: 1, label: Text('居中')),
                      ButtonSegment(value: 3, label: Text('居右')),
                      ButtonSegment(value: 2, label: Text('隐藏')),
                    ],
                    selected: {_titleMode},
                    onSelectionChanged: (values) {
                      final value = values.first;
                      update(() {
                        _titleMode = value;
                      });
                      widget.onTitleModeChanged(value);
                    },
                  ),
                  _dialogSlider('标题增量', _titleSize.toDouble(), -2, 12, (value) {
                    final size = value.round();
                    update(() => _titleSize = size);
                    widget.onTitleSizeChanged(size);
                  }),
                  _dialogSlider('标题上距', _titleTopSpacing.toDouble(), 0, 60, (
                    value,
                  ) {
                    final spacing = value.round();
                    update(() => _titleTopSpacing = spacing);
                    widget.onTitleTopSpacingChanged(spacing);
                  }),
                  _dialogSlider('标题下距', _titleBottomSpacing.toDouble(), 0, 60, (
                    value,
                  ) {
                    final spacing = value.round();
                    update(() => _titleBottomSpacing = spacing);
                    widget.onTitleBottomSpacingChanged(spacing);
                  }),
                  _divider(),
                  _dialogTitle('页眉'),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    style: _segmentedStyle,
                    segments: const [
                      ButtonSegment(value: 0, label: Text('自动')),
                      ButtonSegment(value: 1, label: Text('显示')),
                      ButtonSegment(value: 2, label: Text('隐藏')),
                    ],
                    selected: {_headerMode},
                    onSelectionChanged: (values) {
                      final value = values.first;
                      update(() => _headerMode = value);
                      widget.onHeaderModeChanged(value);
                    },
                  ),
                  _tipSelector('左侧', _tipHeaderLeft, (value) {
                    update(() => _tipHeaderLeft = value);
                    widget.onTipHeaderLeftChanged(value);
                  }),
                  _tipSelector('中间', _tipHeaderMiddle, (value) {
                    update(() => _tipHeaderMiddle = value);
                    widget.onTipHeaderMiddleChanged(value);
                  }),
                  _tipSelector('右侧', _tipHeaderRight, (value) {
                    update(() => _tipHeaderRight = value);
                    widget.onTipHeaderRightChanged(value);
                  }),
                  _dialogSlider('页眉字号', _headerFontSize.toDouble(), 8, 20, (
                    value,
                  ) {
                    final size = value.round();
                    update(() => _headerFontSize = size);
                    widget.onHeaderFontSizeChanged(size);
                  }),
                  _divider(),
                  _dialogTitle('页脚'),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    style: _segmentedStyle,
                    segments: const [
                      ButtonSegment(value: 0, label: Text('显示')),
                      ButtonSegment(value: 1, label: Text('隐藏')),
                    ],
                    selected: {_footerMode},
                    onSelectionChanged: (values) {
                      final value = values.first;
                      update(() => _footerMode = value);
                      widget.onFooterModeChanged(value);
                    },
                  ),
                  _tipSelector('左侧', _tipFooterLeft, (value) {
                    update(() => _tipFooterLeft = value);
                    widget.onTipFooterLeftChanged(value);
                  }),
                  _tipSelector('中间', _tipFooterMiddle, (value) {
                    update(() => _tipFooterMiddle = value);
                    widget.onTipFooterMiddleChanged(value);
                  }),
                  _tipSelector('右侧', _tipFooterRight, (value) {
                    update(() => _tipFooterRight = value);
                    widget.onTipFooterRightChanged(value);
                  }),
                  _dialogSlider('页脚字号', _footerFontSize.toDouble(), 8, 20, (
                    value,
                  ) {
                    final size = value.round();
                    update(() => _footerFontSize = size);
                    widget.onFooterFontSizeChanged(size);
                  }),
                  _switchTile('显示阅读信息', _showReadingInfo, (value) {
                    update(() => _showReadingInfo = value);
                    widget.onShowReadingInfoChanged(value);
                  }),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _tipSelector(String label, int value, ValueChanged<int> onChanged) {
    const options = <int, String>{
      0: '无',
      7: '书名',
      1: '章节名',
      2: '时间',
      4: '页码',
      5: '总进度',
      6: '页码 / 总页数',
    };
    final selected = options.containsKey(value) ? value : 0;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DropdownButtonFormField<int>(
        initialValue: selected,
        dropdownColor: _controlColor,
        style: TextStyle(color: _textColor),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: _subColor),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: options.entries
            .map(
              (entry) =>
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            )
            .toList(),
        onChanged: (newValue) {
          if (newValue != null) onChanged(newValue);
        },
      ),
    );
  }

  Widget _switchTile(String title, bool value, ValueChanged<bool> onChanged) {
    final onTrack = _isDark ? const Color(0xFF2E7D32) : null;
    final offTrack = _isDark ? Colors.white.withValues(alpha: 0.18) : null;
    final offThumb = _isDark ? Colors.white.withValues(alpha: 0.7) : null;
    return SwitchListTile(
      title: Text(title, style: TextStyle(color: _textColor)),
      value: value,
      onChanged: onChanged,
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return Colors.white;
        return offThumb;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return onTrack;
        return offTrack;
      }),
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
}
