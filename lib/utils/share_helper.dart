import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

/// 分享工具：统一处理 iOS/iPad 的 sharePositionOrigin。
///
/// iPad 上 UIKit 要求分享弹窗（UIActivityViewController）必须提供一个
/// 非零的锚点矩形（sharePositionOrigin），否则抛
/// PlatformException(sharePositionOrigin: argument must be set ...)。
/// 这里从触发分享的 context 计算其在屏幕上的矩形作为锚点。
class ShareHelper {
  ShareHelper._();

  /// 根据 context 计算分享弹窗锚点矩形。
  /// 取 context 对应 RenderBox 的全局矩形；拿不到时回退到屏幕中心一个小矩形。
  static Rect _originRect(BuildContext context) {
    try {
      final box = context.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final offset = box.localToGlobal(Offset.zero);
        final rect = offset & box.size;
        if (rect.width > 0 && rect.height > 0) return rect;
      }
    } catch (_) {
      // 忽略，走回退
    }
    final size = MediaQuery.maybeOf(context)?.size ?? const Size(400, 800);
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: 1,
      height: 1,
    );
  }

  /// 分享文本，自动附带 sharePositionOrigin。
  static Future<void> shareText(
    BuildContext context,
    String text, {
    String? subject,
  }) {
    return Share.share(
      text,
      subject: subject,
      sharePositionOrigin: _originRect(context),
    );
  }

  /// 分享文件，自动附带 sharePositionOrigin。
  static Future<ShareResult> shareFiles(
    BuildContext context,
    List<XFile> files, {
    String? subject,
    String? text,
  }) {
    return Share.shareXFiles(
      files,
      subject: subject,
      text: text,
      sharePositionOrigin: _originRect(context),
    );
  }
}
