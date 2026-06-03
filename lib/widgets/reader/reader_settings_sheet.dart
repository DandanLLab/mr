import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

/// 阅读器增强版设置面板
/// 复刻 legado_flutter 的 ReaderSettingsSheet 设计
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
  });

  static const List<Color> presetColors = [
    Color(0xFFFFF8E1), // 羊皮纸
    Color(0xFFE8F5E9), // 护眼绿
    Color(0xFFE3F2FD), // 淡蓝
    Color(0xFFFFF3E0), // 暖橙
    Color(0xFFF3E5F5), // 淡紫
    Color(0xFF1A1A1A), // 夜间
    Color(0xFFFFFFFF), // 白
    Color(0xFFF5F5F5), // 灰
  ];

  static const Map<int, String> pageAnimLabels = {
    0: '无动画',
    1: '滑动',
    2: '覆盖',
    3: '仿真',
    4: '淡入',
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
  late List<int> _tapZones;
  late bool _isNightMode;

  @override
  void initState() {
    super.initState();
    _initFromWidget();
  }

  void _initFromWidget() {
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
    _tapZones = List.from(widget.tapZones);
    _isNightMode = widget.isNightMode;
  }

  void _update() {
    widget.onFontSizeChanged(_fontSize);
    widget.onLineHeightChanged(_lineHeight);
    widget.onLetterSpacingChanged(_letterSpacing);
    widget.onParagraphSpacingChanged(_paragraphSpacing);
    widget.onHorizontalPaddingChanged(_horizontalPadding);
    widget.onVerticalPaddingChanged(_verticalPadding);
    widget.onParagraphIndentChanged(_paragraphIndent);
    widget.onFontWeightChanged(_fontWeightIndex);
    widget.onFontFamilyChanged(_fontFamily);
    widget.onBackgroundColorChanged(_backgroundColor);
    widget.onBackgroundImageChanged(_backgroundImagePath);
    widget.onShowReadingInfoChanged(_showReadingInfo);
    widget.onShowChapterTitleChanged(_showChapterTitle);
    widget.onShowClockChanged(_showClock);
    widget.onShowProgressChanged(_showProgress);
    widget.onPageAnimChanged(_pageAnim);
    widget.onPageAnimDurationChanged(_pageAnimDurationMs);
    widget.onScreenBrightnessChanged(_screenBrightness);
    widget.onKeepScreenOnChanged(_keepScreenOn);
    widget.onEnableVolumeKeyPageChanged(_enableVolumeKeyPage);
    widget.onVolumeKeyPageOnTtsChanged(_volumeKeyPageOnTts);
    widget.onEnableLongPressMenuChanged(_enableLongPressMenu);
    widget.onAutoScrollSpeedChanged(_autoScrollSpeed);
    widget.onAutoPageIntervalChanged(_autoPageIntervalSeconds);
    widget.onTapZonesChanged(_tapZones);
    widget.onNightModeChanged(_isNightMode);
  }

  Future<void> _pickBackgroundImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      if (result == null || result.files.isEmpty) return;
      final sourcePath = result.files.single.path;
      if (sourcePath == null) return;
      
      // Copy to app directory
      final dir = Directory('/data/user/0/com.example.app/files/reader_backgrounds');
      if (!await dir.exists()) await dir.create(recursive: true);
      final filename = 'bg_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final destPath = '${dir.path}/$filename';
      await File(sourcePath).copy(destPath);
      
      setState(() {
        _backgroundImagePath = destPath;
      });
      _update();
    } catch (e) {
      debugPrint('[ReaderSettings] pick background image failed: $e');
    }
  }

  void _clearBackgroundImage() {
    setState(() {
      _backgroundImagePath = null;
    });
    _update();
  }

  @override
  Widget build(BuildContext ctx) {
    final labelStyle = TextStyle(color: _isNightMode ? Colors.white : Colors.black87, fontSize: 14);
    final chipStyle = const TextStyle(fontSize: 12);

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: BoxDecoration(
        color: _isNightMode ? const Color(0xFF1A1A1A) : Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 字号
            Text('字号: ${_fontSize.round()}', style: labelStyle),
            Slider(
              value: _fontSize,
              min: 12,
              max: 30,
              divisions: 18,
              onChanged: (v) => setState(() {
                _fontSize = v;
                _update();
              }),
            ),
            const SizedBox(height: 12),
            
            // 字重
            Text('字重', style: labelStyle),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('细', style: TextStyle(fontSize: 12))),
                ButtonSegment(value: 1, label: Text('正常', style: TextStyle(fontSize: 12))),
                ButtonSegment(value: 2, label: Text('粗', style: TextStyle(fontSize: 12))),
              ],
              selected: {_fontWeightIndex},
              onSelectionChanged: (v) => setState(() {
                _fontWeightIndex = v.first;
                _update();
              }),
            ),
            const SizedBox(height: 12),
            
            // 字距
            Text('字距: ${_letterSpacing.toStringAsFixed(1)}', style: labelStyle),
            Slider(
              value: _letterSpacing,
              min: -1,
              max: 5,
              divisions: 60,
              onChanged: (v) => setState(() {
                _letterSpacing = v;
                _update();
              }),
            ),
            
            // 行距
            Text('行距: ${_lineHeight.toStringAsFixed(1)}', style: labelStyle),
            Slider(
              value: _lineHeight,
              min: 1.0,
              max: 3.5,
              divisions: 25,
              onChanged: (v) => setState(() {
                _lineHeight = v;
                _update();
              }),
            ),
            
            // 段距
            Text('段距: ${_paragraphSpacing.round()}', style: labelStyle),
            Slider(
              value: _paragraphSpacing,
              min: 0,
              max: 30,
              divisions: 30,
              onChanged: (v) => setState(() {
                _paragraphSpacing = v;
                _update();
              }),
            ),
            
            // 左右边距
            Text('左右边距: ${_horizontalPadding.round()}', style: labelStyle),
            Slider(
              value: _horizontalPadding,
              min: 0,
              max: 60,
              divisions: 30,
              onChanged: (v) => setState(() {
                _horizontalPadding = v;
                _update();
              }),
            ),
            
            // 上下边距
            Text('上下边距: ${_verticalPadding.round()}', style: labelStyle),
            Slider(
              value: _verticalPadding,
              min: 0,
              max: 60,
              divisions: 30,
              onChanged: (v) => setState(() {
                _verticalPadding = v;
                _update();
              }),
            ),
            const SizedBox(height: 12),
            
            // 段首缩进
            Text('段首缩进', style: labelStyle),
            const SizedBox(height: 4),
            Row(children: [
              ChoiceChip(
                label: Text('无', style: chipStyle),
                selected: _paragraphIndent.isEmpty,
                onSelected: (_) => setState(() {
                  _paragraphIndent = '';
                  _update();
                }),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text('2全角', style: chipStyle),
                selected: _paragraphIndent == '\u3000\u3000',
                onSelected: (_) => setState(() {
                  _paragraphIndent = '\u3000\u3000';
                  _update();
                }),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text('4半角', style: chipStyle),
                selected: _paragraphIndent == '    ',
                onSelected: (_) => setState(() {
                  _paragraphIndent = '    ';
                  _update();
                }),
              ),
            ]),
            const SizedBox(height: 12),
            
            // 阅读信息
            Text('阅读信息', style: labelStyle),
            SwitchListTile(
              title: Text('显示阅读信息', style: labelStyle),
              value: _showReadingInfo,
              dense: true,
              activeColor: Colors.blue,
              onChanged: (v) => setState(() {
                _showReadingInfo = v;
                _update();
              }),
            ),
            SwitchListTile(
              title: Text('章节标题', style: labelStyle),
              value: _showChapterTitle,
              dense: true,
              activeColor: Colors.blue,
              onChanged: (v) => setState(() {
                _showChapterTitle = v;
                _update();
              }),
            ),
            SwitchListTile(
              title: Text('时间', style: labelStyle),
              value: _showClock,
              dense: true,
              activeColor: Colors.blue,
              onChanged: (v) => setState(() {
                _showClock = v;
                _update();
              }),
            ),
            SwitchListTile(
              title: Text('进度', style: labelStyle),
              value: _showProgress,
              dense: true,
              activeColor: Colors.blue,
              onChanged: (v) => setState(() {
                _showProgress = v;
                _update();
              }),
            ),
            const SizedBox(height: 12),
            
            // 背景图片
            Text('背景图片', style: labelStyle),
            const SizedBox(height: 4),
            Row(children: [
              ElevatedButton.icon(
                onPressed: _pickBackgroundImage,
                icon: const Icon(Icons.image, size: 18),
                label: const Text('选择'),
              ),
              const SizedBox(width: 8),
              if (_backgroundImagePath != null)
                OutlinedButton(
                  onPressed: _clearBackgroundImage,
                  child: const Text('清除'),
                ),
            ]),
            const SizedBox(height: 12),
            
            // 背景色
            Text('背景色', style: labelStyle),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: ReaderSettingsSheet.presetColors.map((c) => GestureDetector(
                onTap: () => setState(() {
                  _backgroundColor = c;
                  _backgroundImagePath = null;
                  _update();
                }),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: c,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _backgroundColor == c.value && _backgroundImagePath == null
                          ? Colors.blue
                          : Colors.grey,
                      width: 2,
                    ),
                  ),
                ),
              )).toList(),
            ),
            const SizedBox(height: 12),
            
            // 翻页动画
            Text('翻页动画', style: labelStyle),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: ReaderSettingsSheet.pageAnimLabels.entries.map((e) => ChoiceChip(
                label: Text(e.value, style: chipStyle),
                selected: _pageAnim == e.key,
                onSelected: (sel) {
                  if (sel) setState(() {
                    _pageAnim = e.key;
                    _update();
                  });
                },
              )).toList(),
            ),
            const SizedBox(height: 12),
            
            // 翻页动画时长
            Text('翻页动画时长: $_pageAnimDurationMs ms', style: labelStyle),
            Slider(
              value: _pageAnimDurationMs.toDouble(),
              min: 200,
              max: 1000,
              divisions: 16,
              label: '$_pageAnimDurationMs ms',
              onChanged: (v) => setState(() {
                _pageAnimDurationMs = v.round();
                _update();
              }),
            ),
            const SizedBox(height: 12),
            
            // 屏幕设置
            Text('屏幕', style: labelStyle),
            const SizedBox(height: 4),
            SwitchListTile(
              title: Text('跟随系统亮度', style: labelStyle),
              value: _screenBrightness < 0,
              dense: true,
              activeColor: Colors.blue,
              onChanged: (v) => setState(() {
                _screenBrightness = v ? -1.0 : 0.7;
                _update();
              }),
            ),
            if (_screenBrightness >= 0) ...[
              Text('屏幕亮度: ${(_screenBrightness * 100).round()}%', style: labelStyle),
              Slider(
                value: (_screenBrightness * 100).clamp(0.0, 100.0),
                min: 0,
                max: 100,
                divisions: 100,
                label: '${(_screenBrightness * 100).round()}%',
                onChanged: (v) => setState(() {
                  _screenBrightness = v / 100.0;
                  _update();
                }),
              ),
            ],
            SwitchListTile(
              title: Text('屏幕常亮', style: labelStyle),
              subtitle: Text(
                '阅读时不熄屏',
                style: TextStyle(color: _isNightMode ? Colors.white60 : Colors.black54, fontSize: 12),
              ),
              value: _keepScreenOn,
              dense: true,
              activeColor: Colors.blue,
              onChanged: (v) => setState(() {
                _keepScreenOn = v;
                _update();
              }),
            ),
            const SizedBox(height: 12),
            
            // 按键设置
            Text('按键', style: labelStyle),
            const SizedBox(height: 4),
            SwitchListTile(
              title: Text('音量键翻页', style: labelStyle),
              subtitle: Text(
                '音量+ 上一页 / 音量- 下一页',
                style: TextStyle(color: _isNightMode ? Colors.white60 : Colors.black54, fontSize: 12),
              ),
              value: _enableVolumeKeyPage,
              dense: true,
              activeColor: Colors.blue,
              onChanged: (v) => setState(() {
                _enableVolumeKeyPage = v;
                _update();
              }),
            ),
            SwitchListTile(
              title: Text('朗读时音量键也翻页', style: labelStyle),
              subtitle: Text(
                '默认关闭，朗读中音量键控制系统音量',
                style: TextStyle(color: _isNightMode ? Colors.white60 : Colors.black54, fontSize: 12),
              ),
              value: _volumeKeyPageOnTts,
              dense: true,
              activeColor: Colors.blue,
              onChanged: (v) => setState(() {
                _volumeKeyPageOnTts = v;
                _update();
              }),
            ),
            const SizedBox(height: 12),
            
            // 长按菜单
            Text('长按菜单', style: labelStyle),
            const SizedBox(height: 4),
            SwitchListTile(
              title: Text('启用长按菜单', style: labelStyle),
              subtitle: Text(
                '长按弹复制/分享/朗读',
                style: TextStyle(color: _isNightMode ? Colors.white60 : Colors.black54, fontSize: 12),
              ),
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeColor: Colors.blue,
              value: _enableLongPressMenu,
              onChanged: (v) => setState(() {
                _enableLongPressMenu = v;
                _update();
              }),
            ),
            const SizedBox(height: 16),
            
            // 夜间模式
            Text('模式', style: labelStyle),
            const SizedBox(height: 4),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('日间'),
                  selected: !_isNightMode,
                  onSelected: (sel) {
                    if (sel) setState(() {
                      _isNightMode = false;
                      _backgroundColor = const Color(0xFFFFF8E1);
                      _update();
                    });
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('夜间'),
                  selected: _isNightMode,
                  onSelected: (sel) {
                    if (sel) setState(() {
                      _isNightMode = true;
                      _backgroundColor = const Color(0xFF1A1A1A);
                      _update();
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
