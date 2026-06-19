import 'package:flutter/material.dart';
import '../../utils/design_tokens.dart';

class ReaderSettingsSheet extends StatelessWidget {
  const ReaderSettingsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(DesignTokens.spacingLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('阅读设置', style: theme.textTheme.titleLarge),
          const SizedBox(height: DesignTokens.spacingLg),
          ListTile(
            title: const Text('默认翻页方式'),
            subtitle: const Text('仿真翻页'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          ),
          ListTile(
            title: const Text('字体大小'),
            subtitle: const Text('18'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          ),
          ListTile(
            title: const Text('背景色'),
            trailing: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                border: Border.all(color: Colors.grey),
                borderRadius:
                    BorderRadius.circular(DesignTokens.actionRadius),
              ),
            ),
            onTap: () {},
          ),
          SwitchListTile(
            title: const Text('屏幕常亮'),
            value: true,
            onChanged: (value) {},
          ),
          SwitchListTile(
            title: const Text('音量键翻页'),
            value: false,
            onChanged: (value) {},
          ),
        ],
      ),
    );
  }
}
