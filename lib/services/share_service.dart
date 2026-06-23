import 'package:flutter/services.dart';

/// 接收其他App分享的文本/URL
/// 通过 Android Intent.ACTION_SEND / ACTION_VIEW 接收
class ShareService {
  ShareService._();
  static final ShareService instance = ShareService._();

  static const MethodChannel _channel = MethodChannel('com.mr.app/share');

  /// 获取其他App分享来的文本（一次性读取，读后清空）
  /// 返回 null 表示没有分享内容
  Future<String?> getSharedText() async {
    try {
      final result = await _channel.invokeMethod<String>('getSharedText');
      return result;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // 非Android平台或原生端未注册
      return null;
    }
  }
}
