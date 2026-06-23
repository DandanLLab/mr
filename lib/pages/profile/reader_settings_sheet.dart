import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/reader_provider.dart';
import '../../utils/design_tokens.dart';

class ReaderSettingsSheet extends StatelessWidget {
  const ReaderSettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<ReaderProvider>();
    return Container(
      padding: const EdgeInsets.all(DesignTokens.spacingLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('阅读设置', style: theme.textTheme.titleLarge),
          const SizedBox(height: DesignTokens.spacingLg),
          // 默认翻页方式
          ListTile(
            title: const Text('默认翻页方式'),
            subtitle: Text(_pageModeLabel(provider.pageMode)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showPageModeDialog(context, provider),
          ),
          // 字体大小
          ListTile(
            title: const Text('字体大小'),
            subtitle: Text('${provider.fontSize.toInt()}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showFontSizeDialog(context, provider),
          ),
          // 背景色
          ListTile(
            title: const Text('背景色'),
            trailing: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: provider.backgroundColor,
                border: Border.all(color: theme.colorScheme.outline),
                borderRadius:
                    BorderRadius.circular(DesignTokens.actionRadius),
              ),
            ),
            onTap: () => _showBackgroundColorDialog(context, provider),
          ),
          // 屏幕常亮
          SwitchListTile(
            title: const Text('屏幕常亮'),
            value: provider.keepScreenOn,
            onChanged: (value) {
              provider.setKeepScreenOn(value);
            },
          ),
          // 音量键翻页
          SwitchListTile(
            title: const Text('音量键翻页'),
            value: provider.enableVolumeKeyPage,
            onChanged: (value) {
              provider.setEnableVolumeKeyPage(value);
            },
          ),
        ],
      ),
    );
  }

  String _pageModeLabel(PageMode mode) {
    switch (mode) {
      case PageMode.simulation:
        return '仿真翻页';
      case PageMode.slide:
        return '滑动翻页';
      case PageMode.scroll:
        return '滚动翻页';
      case PageMode.none:
        return '无动画';
      case PageMode.cover:
        return '覆盖翻页';
    }
  }

  void _showPageModeDialog(BuildContext context, ReaderProvider provider) {
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择翻页方式'),
        children: PageMode.values.map((mode) {
          return SimpleDialogOption(
            onPressed: () {
              provider.setPageMode(mode);
              Navigator.pop(context);
            },
            child: Row(
              children: [
                Text(_pageModeLabel(mode)),
                const Spacer(),
                if (provider.pageMode == mode)
                  Icon(Icons.check,
                      color: Theme.of(context).colorScheme.primary),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  void _showFontSizeDialog(BuildContext context, ReaderProvider provider) {
    double tempSize = provider.fontSize;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('字体大小'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${tempSize.toInt()}',
                  style: const TextStyle(fontSize: 24)),
              Slider(
                value: tempSize,
                min: 12,
                max: 36,
                divisions: 24,
                onChanged: (value) => setState(() => tempSize = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                provider.setFontSize(tempSize);
                Navigator.pop(context);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  void _showBackgroundColorDialog(BuildContext context, ReaderProvider provider) {
    final colors = <Color, String>{
      const Color(0xFFFFF8E1): '羊皮纸',
      const Color(0xFFFFFFFF): '白色',
      const Color(0xFFE8E8E8): '浅灰',
      const Color(0xFF1A1A1A): '夜间',
      const Color(0xFFF5DEB3): '护眼',
    };
    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择背景色'),
        children: colors.entries.map((entry) {
          return SimpleDialogOption(
            onPressed: () {
              provider.setBackgroundColor(entry.key);
              Navigator.pop(context);
            },
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: entry.key,
                    border: Border.all(
                        color: Theme.of(context).colorScheme.outline),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 12),
                Text(entry.value),
                const Spacer(),
                if (provider.backgroundColor == entry.key)
                  Icon(Icons.check,
                      color: Theme.of(context).colorScheme.primary),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}
