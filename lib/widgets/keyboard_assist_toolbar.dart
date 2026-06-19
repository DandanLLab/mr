import 'package:flutter/material.dart';

/// 辅助按键项
class KeyboardAssistItem {
  final String key;
  final String value;
  final String? tooltip;

  const KeyboardAssistItem({
    required this.key,
    required this.value,
    this.tooltip,
  });
}

/// 辅助按键工具栏回调接口
mixin class KeyboardAssistCallback {
  /// 获取帮助操作列表
  List<PopupMenuItem<String>> helpActions(BuildContext context) => [];

  /// 处理帮助操作选择
  void onHelpActionSelect(String action) {}

  /// 发送文本到当前焦点输入框
  void sendText(String text) {}

  /// 撤销操作（可选）
  void onUndoClicked() {}

  /// 重做操作（可选）
  void onRedoClicked() {}
}

/// 辅助按键工具栏
/// 参考 Legado 的 KeyboardToolPop 实现
/// 样式参考:
/// - popup_keyboard_tool.xml: RecyclerView 背景 background_card, padding 5dp
/// - item_fillet_text.xml: 按钮 margin 3dp, 圆角 16dp, padding 上下4dp左右12dp, 字号14sp
/// - shape_fillet_btn.xml: 正常背景 #63ACACAC
/// - shape_fillet_btn_press.xml: 按下背景 #63858585
class KeyboardAssistToolbar extends StatefulWidget {
  final KeyboardAssistCallback callback;
  final List<KeyboardAssistItem> assistItems;
  final bool showUndoRedo;
  final double keyboardHeight;

  const KeyboardAssistToolbar({
    super.key,
    required this.callback,
    this.assistItems = const [],
    this.showUndoRedo = true,
    this.keyboardHeight = 0,
  });

  /// 是否应该显示工具栏（键盘高度超过屏幕五分之一）
  bool shouldShow(double screenHeight) {
    return keyboardHeight > screenHeight / 5;
  }

  @override
  State<KeyboardAssistToolbar> createState() => _KeyboardAssistToolbarState();
}

class _KeyboardAssistToolbarState extends State<KeyboardAssistToolbar> {
  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    // 与原版 legados 逻辑一致：键盘高度超过屏幕五分之一时显示
    final showToolbar = widget.keyboardHeight > screenHeight / 5;

    if (!showToolbar) {
      return const SizedBox.shrink(); // 隐藏工具栏
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 原版背景色: background_card (浅色模式白色，深色模式深灰)
    final toolbarBgColor = isDark
        ? const Color(0xFF1E1E1E)  // 深色模式卡片背景
        : const Color(0xFFFFFFFF); // 浅色模式卡片背景

    return Container(
      // 原版 padding: 5dp
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: toolbarBgColor,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // 帮助按钮
            _buildAssistButton(
              context,
              '❓',
              tooltip: '帮助',
              onTap: () => _showHelpMenu(context),
            ),
            // 撤销/重做按钮
            if (widget.showUndoRedo) ...[
              _buildAssistButton(
                context,
                '↩️',
                tooltip: '撤销',
                onTap: () => widget.callback.onUndoClicked(),
              ),
              _buildAssistButton(
                context,
                '↪️',
                tooltip: '重做',
                onTap: () => widget.callback.onRedoClicked(),
              ),
            ],
            // 自定义辅助按键
            for (final item in widget.assistItems)
              _buildAssistButton(
                context,
                item.key,
                tooltip: item.tooltip ?? item.value,
                onTap: () => widget.callback.sendText(item.value),
              ),
          ],
        ),
      ),
    );
  }

  /// 构建辅助按键按钮
  /// 样式与原版 item_fillet_text.xml 完全一致
  Widget _buildAssistButton(
    BuildContext context,
    String label,
    {String? tooltip,
    VoidCallback? onTap}
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 原版按钮背景色
    // shape_fillet_btn.xml: #63ACACAC (半透明灰色)
    // shape_fillet_btn_press.xml: #63858585
    // 深色模式需要调整
    final normalBgColor = isDark
        ? const Color(0xFF3C3C3C)  // 深色模式
        : const Color(0x63ACACAC); // 浅色模式: #63ACACAC (39%透明度的灰色)

    // 原版文字颜色: primaryText
    final textColor = isDark
        ? const Color(0xDEFFFFFF)  // 深色模式: 87%白色
        : const Color(0xDE000000); // 浅色模式: 87%黑色

    return GestureDetector(
      onTap: onTap,
      onTapDown: (_) => setState(() {}),
      onTapUp: (_) => setState(() {}),
      onTapCancel: () => setState(() {}),
      child: Container(
        // 原版 margin: 3dp
        margin: const EdgeInsets.all(3),
        // 原版 padding: paddingTop=4dp, paddingBottom=4dp, paddingLeft=12dp, paddingRight=12dp
        padding: const EdgeInsets.only(
          top: 4,
          bottom: 4,
          left: 12,
          right: 12,
        ),
        decoration: BoxDecoration(
          // 原版圆角: 16dp
          borderRadius: BorderRadius.circular(16),
          // 原版背景: shape_fillet_btn (正常状态)
          color: normalBgColor,
        ),
        child: Text(
          label,
          // 原版 maxLines: 1, ellipsize: end, gravity: center
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            // 原版 textSize: 14sp
            fontSize: 14,
            // 原版 textColor: primaryText
            color: textColor,
          ),
        ),
      ),
    );
  }

  void _showHelpMenu(BuildContext context) {
    final actions = widget.callback.helpActions(context);
    if (actions.isEmpty) return;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                '帮助',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            ...actions.map((item) => ListTile(
              title: item.child,
              onTap: () {
                Navigator.pop(ctx);
                widget.callback.onHelpActionSelect(item.value ?? '');
              },
            )),
          ],
        ),
      ),
    );
  }
}

/// 默认辅助按键配置（与 Legado keyboardAssists.json 完全一致）
/// 参考: D:\pyc\dmwj\legados\app\src\main\assets\defaultData\keyboardAssists.json
class DefaultKeyboardAssists {
  /// 默认辅助按键列表（与原版一模一样）
  static const List<KeyboardAssistItem> defaultItems = [
    KeyboardAssistItem(key: '@css:', value: '@css:'),
    KeyboardAssistItem(key: '<js>', value: '<js></js>'),
    KeyboardAssistItem(key: '{{}}', value: '{{}}'),
    KeyboardAssistItem(key: '##', value: '##'),
    KeyboardAssistItem(key: '&&', value: '&&'),
    KeyboardAssistItem(key: '%%', value: '%%'),
    KeyboardAssistItem(key: '||', value: '||'),
    KeyboardAssistItem(key: '//', value: '//'),
    KeyboardAssistItem(key: '\\', value: '\\'),
    KeyboardAssistItem(key: '\$.', value: '\$.'),
    KeyboardAssistItem(key: '@', value: '@'),
    KeyboardAssistItem(key: ':', value: ':'),
    KeyboardAssistItem(key: 'class', value: 'class'),
    KeyboardAssistItem(key: 'text', value: 'text'),
    KeyboardAssistItem(key: 'href', value: 'href'),
    KeyboardAssistItem(key: 'textNodes', value: 'textNodes'),
    KeyboardAssistItem(key: 'ownText', value: 'ownText'),
    KeyboardAssistItem(key: 'all', value: 'all'),
    KeyboardAssistItem(key: 'html', value: 'html'),
    KeyboardAssistItem(key: '[', value: '['),
    KeyboardAssistItem(key: ']', value: ']'),
    KeyboardAssistItem(key: '<', value: '<'),
    KeyboardAssistItem(key: '>', value: '>'),
    KeyboardAssistItem(key: '#', value: '#'),
    KeyboardAssistItem(key: '!', value: '!'),
    KeyboardAssistItem(key: '.', value: '.'),
    KeyboardAssistItem(key: '+', value: '+'),
    KeyboardAssistItem(key: '-', value: '-'),
    KeyboardAssistItem(key: '*', value: '*'),
    KeyboardAssistItem(key: '/', value: '/'),
    KeyboardAssistItem(key: '=', value: '='),
    KeyboardAssistItem(key: 'useWebView', value: ',{"webView": true}'),
  ];
}