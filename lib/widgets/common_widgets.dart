import 'package:flutter/material.dart';
import '../utils/design_tokens.dart';

class CommonWidgets {
  static Widget buildLoadingWidget({String? message}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: DesignTokens.spacingMd),
            Text(
              message,
              style: const TextStyle(fontSize: DesignTokens.fontBody),
            ),
          ],
        ],
      ),
    );
  }

  static Widget buildEmptyWidget({
    required BuildContext context,
    required IconData icon,
    required String message,
    String? actionText,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: DesignTokens.emptyIconSize,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: DesignTokens.spacingMd),
          Text(
            message,
            style: TextStyle(
              fontSize: DesignTokens.fontTitle,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          if (actionText != null && onAction != null) ...[
            const SizedBox(height: DesignTokens.spacingMd),
            TextButton(
              onPressed: onAction,
              child: Text(actionText),
            ),
          ],
        ],
      ),
    );
  }

  static Widget buildErrorWidget({
    required BuildContext context,
    required String message,
    String? actionText,
    VoidCallback? onRetry,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline,
            size: DesignTokens.emptyIconSize,
            color: Colors.red,
          ),
          const SizedBox(height: DesignTokens.spacingMd),
          Text(
            message,
            style: TextStyle(
              fontSize: DesignTokens.fontTitle,
              color: Theme.of(context).colorScheme.outline,
            ),
            textAlign: TextAlign.center,
          ),
          if (actionText != null && onRetry != null) ...[
            const SizedBox(height: DesignTokens.spacingMd),
            ElevatedButton(
              onPressed: onRetry,
              child: Text(actionText),
            ),
          ],
        ],
      ),
    );
  }

  /// 通用选择弹窗
  /// 统一使用设计令牌：圆角 panelRadius，字号 fontTitle/fontBody
  static Future<int?> showSelectorDialog(
    BuildContext context, {
    required String title,
    required List<String> items,
    int selectedIndex = -1,
  }) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final titleColor = isDark ? Colors.white : colorScheme.onSurface;
    final itemColor = isDark ? Colors.white : colorScheme.onSurface;
    final bgColor = isDark ? colorScheme.surfaceContainer : Colors.white;

    return await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          title,
          style: TextStyle(fontSize: DesignTokens.fontTitle, color: titleColor),
        ),
        titlePadding: DesignTokens.dialogTitlePadding,
        contentPadding: EdgeInsets.zero,
        insetPadding: DesignTokens.dialogInsetPadding,
        backgroundColor: bgColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.panelRadius),
        ),
        content: SizedBox(
          width: 280,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: items.length,
            itemBuilder: (context, index) => InkWell(
              onTap: () => Navigator.pop(ctx, index),
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(
                    horizontal: DesignTokens.spacingXxl),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        items[index],
                        style: TextStyle(
                            fontSize: DesignTokens.fontSubtitle,
                            color: itemColor),
                      ),
                    ),
                    if (index == selectedIndex)
                      Icon(Icons.check,
                          color: colorScheme.primary, size: 20),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 通用确认弹窗
  /// 统一使用设计令牌：圆角 panelRadius，字号 fontTitle/fontBody
  static Future<bool> showConfirmDialog(
    BuildContext context, {
    required String title,
    required String content,
    String confirmText = '确定',
    String cancelText = '取消',
  }) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final titleColor = isDark ? Colors.white : colorScheme.onSurface;
    final contentColor =
        isDark ? Colors.white70 : colorScheme.onSurfaceVariant;
    final bgColor = isDark ? colorScheme.surfaceContainer : Colors.white;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          title,
          style: TextStyle(fontSize: DesignTokens.fontTitle, color: titleColor),
        ),
        titlePadding: DesignTokens.dialogTitlePadding,
        contentPadding: DesignTokens.dialogContentPadding,
        insetPadding: DesignTokens.dialogInsetPadding,
        backgroundColor: bgColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.panelRadius),
        ),
        content: Text(
          content,
          style: TextStyle(
              fontSize: DesignTokens.fontSubtitle, color: contentColor),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancelText, style: TextStyle(color: contentColor)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmText,
                style: TextStyle(color: colorScheme.primary)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  static void showSnackBar(
    BuildContext context, {
    required String message,
    Duration duration = const Duration(seconds: 2),
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        action: action,
      ),
    );
  }
}
