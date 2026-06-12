import 'package:flutter/material.dart';

class CommonWidgets {
  static Widget buildLoadingWidget({String? message}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(message),
          ],
        ],
      ),
    );
  }

  static Widget buildEmptyWidget({
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
            size: 80,
            color: Colors.grey,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: const TextStyle(
              fontSize: 18,
              color: Colors.grey,
            ),
          ),
          if (actionText != null && onAction != null) ...[
            const SizedBox(height: 16),
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
            size: 80,
            color: Colors.red,
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: const TextStyle(
              fontSize: 18,
              color: Colors.grey,
            ),
            textAlign: TextAlign.center,
          ),
          if (actionText != null && onRetry != null) ...[
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: onRetry,
              child: Text(actionText),
            ),
          ],
        ],
      ),
    );
  }

  /// 通用选择弹窗 - 与原版 AlertDialog selector 一致
  /// 标题 18sp，内容 16sp，列表项高度 48dp，宽度 280dp
  static Future<int?> showSelectorDialog(
    BuildContext context, {
    required String title,
    required List<String> items,
    int selectedIndex = -1,
  }) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: TextStyle(fontSize: 18, color: isDark ? Colors.white : const Color(0xFF212121))),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        contentPadding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        backgroundColor: isDark ? const Color(0xFF424242) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        content: SizedBox(
          width: 280,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: items.length,
            itemBuilder: (context, index) => InkWell(
              onTap: () => Navigator.pop(ctx, index),
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        items[index],
                        style: TextStyle(fontSize: 16, color: isDark ? Colors.white : const Color(0xFF212121)),
                      ),
                    ),
                    if (index == selectedIndex)
                      Icon(Icons.check, color: Theme.of(context).colorScheme.primary, size: 20),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 通用确认弹窗 - 与原版 AlertDialog 一致
  static Future<bool> showConfirmDialog(
    BuildContext context, {
    required String title,
    required String content,
    String confirmText = '确定',
    String cancelText = '取消',
  }) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: TextStyle(fontSize: 18, color: isDark ? Colors.white : const Color(0xFF212121))),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        backgroundColor: isDark ? const Color(0xFF424242) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        content: Text(content, style: TextStyle(fontSize: 16, color: isDark ? Colors.white70 : const Color(0xFF757575))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancelText, style: TextStyle(color: isDark ? Colors.white70 : const Color(0xFF757575))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmText, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
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
