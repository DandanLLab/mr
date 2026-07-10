import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/book_source.dart';
import 'native/js_advanced_service.dart';
import 'native/platform_bridge.dart';

/// 支持图片解密的自定义 ImageProvider
///
/// 借鉴 Legado 的 OkHttpStreamFetcher + BookHelp.saveImage：
/// 当书源配置了 coverDecodeJs（封面）或 ruleContent.imageDecode（正文）时，
/// 需要先下载原始字节，用 JS 规则解密，再交给 Flutter 解码显示。
///
/// 使用方式：
/// ```dart
/// if (DecodedImageProvider.needsDecode(source, isCover)) {
///   Image(image: DecodedImageProvider(url: url, headers: h, source: source, isCover: isCover, book: book))
/// } else {
///   CachedNetworkImage(imageUrl: url, httpHeaders: h)  // 原有链路
/// }
/// ```
class DecodedImageProvider extends ImageProvider<DecodedImageProvider> {
  DecodedImageProvider({
    required this.url,
    required this.headers,
    required this.source,
    this.isCover = false,
    this.book,
  });

  /// 图片 URL
  final String url;

  /// 请求头（含防盗链 Referer / User-Agent 等）
  final Map<String, String> headers;

  /// 书源（用于读取 coverDecodeJs / imageDecode 规则）
  final BookSource source;

  /// true=封面(用 coverDecodeJs), false=正文图片(用 imageDecode)
  final bool isCover;

  /// 书籍信息（可选，传给 JS 上下文）
  final Book? book;

  /// 判断是否需要走解密链路
  ///
  /// 没有配置解密规则时，应使用原 CachedNetworkImage 链路以享受磁盘缓存
  static bool needsDecode(BookSource? source, bool isCover) {
    if (source == null) return false;
    final js = isCover ? source.coverDecodeJs : source.ruleContent?.imageDecode;
    return js != null && js.trim().isNotEmpty;
  }

  @override
  Future<DecodedImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<DecodedImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    DecodedImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode, chunkEvents),
      chunkEvents: chunkEvents.stream,
      scale: 1.0,
      informationCollector: () sync* {
        yield DiagnosticsProperty<String>('URL', key.url);
        yield DiagnosticsProperty<bool>('isCover', key.isCover);
        yield DiagnosticsProperty<String>(
          'source',
          key.source.bookSourceName,
        );
      },
    );
  }

  /// 下载 → 解密 → 解码
  Future<ui.Codec> _loadAsync(
    DecodedImageProvider key,
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunkEvents,
  ) async {
    // 发送初始事件，触发 loadingBuilder 显示加载中状态
    chunkEvents.add(const ImageChunkEvent(
      cumulativeBytesLoaded: 0,
      expectedTotalBytes: null,
    ));

    Uint8List bytes;
    try {
      final response = await PlatformBridge.instance.dio.get<List<int>>(
        key.url,
        options: Options(
          headers: key.headers,
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 30),
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            chunkEvents.add(ImageChunkEvent(
              cumulativeBytesLoaded: received,
              expectedTotalBytes: total,
            ));
          }
        },
      );
      bytes = Uint8List.fromList(response.data ?? const <int>[]);
    } catch (e) {
      debugPrint('⚠️ [DecodedImageProvider] 下载失败: ${key.url} → $e');
      rethrow;
    } finally {
      await chunkEvents.close();
    }

    if (bytes.isEmpty) {
      throw StateError('图片下载响应为空: ${key.url}');
    }

    // 调用 JS 解密（借鉴 Legado ImageUtils.decode）
    final decoded = await JsAdvancedService.instance.decodeImage(
      bytes,
      key.url,
      source: key.source,
      isCover: key.isCover,
      book: key.book?.toJson(),
    );

    final finalBytes = decoded ?? bytes;
    if (finalBytes.isEmpty) {
      throw StateError('图片解密后字节为空: ${key.url}');
    }

    final buffer = await ui.ImmutableBuffer.fromUint8List(finalBytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DecodedImageProvider &&
        other.url == url &&
        other.isCover == isCover;
  }

  @override
  int get hashCode => Object.hash(url, isCover);

  @override
  String toString() =>
      'DecodedImageProvider(url: $url, isCover: $isCover)';
}
