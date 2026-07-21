import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/book_source.dart';
import 'native/js_advanced_service.dart';
import 'native/js_engine.dart';
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
    this.partsUrls,
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

  /// 配对切片 URL 列表（书源 data-parts 属性指定的 JSON 数组）
  /// 下载主图后，额外下载所有切片，通过 JS 全局变量传给 decryptImage 合并解密
  final List<String>? partsUrls;

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
      // 包装原始异常（可能是 Dio 内部的 null 断言），防止直接到达
      // FlutterError.reportError 被误判为崩溃（图片加载有 errorBuilder 处理 UI）
      throw StateError('图片下载失败: ${key.url} - $e');
    } finally {
      await chunkEvents.close();
    }

    if (bytes.isEmpty) {
      throw StateError('图片下载响应为空: ${key.url}');
    }

    // 检测 HTML 错误页（服务器返回 200 但内容是 HTML 而非图片）
    if (_isHtmlResponse(bytes)) {
      throw StateError('服务器返回 HTML 而非图片数据: ${key.url}');
    }

    // 调用 JS 解密（借鉴 Legado ImageUtils.decode）
    // 如果有配对切片 URL 列表，先下载所有切片并存入 JS 全局变量
    if (key.partsUrls != null && key.partsUrls!.isNotEmpty) {
      final partsBytes = <Uint8List>[];
      for (var i = 0; i < key.partsUrls!.length; i++) {
        final partUrl = key.partsUrls![i];
        try {
          final response = await PlatformBridge.instance.dio.get<List<int>>(
            partUrl,
            options: Options(
              headers: key.headers,
              responseType: ResponseType.bytes,
              receiveTimeout: const Duration(seconds: 30),
            ),
          );
          final partBytes = Uint8List.fromList(response.data ?? const <int>[]);
          if (partBytes.isNotEmpty) {
            partsBytes.add(partBytes);
          }
        } catch (e) {
          // 切片下载失败不中断，decryptImage 会按解密失败处理
          debugPrint('⚠️ 切片[$i]下载失败: $partUrl - $e');
        }
      }
      // 把所有切片字节存入 JS 全局变量数组，decryptImage 从中读取
      for (var i = 0; i < partsBytes.length; i++) {
        await JsEngine.instance.setGlobalBytes('_partBytes_$i', partsBytes[i]);
      }
      // 存入切片数量，decryptImage 据此读取
      await JsEngine.instance.executeAsync('globalThis._partCount = ${partsBytes.length}');
    }

    final decoded = await JsAdvancedService.instance.decodeImage(
      bytes,
      key.url,
      source: key.source,
      isCover: key.isCover,
      book: key.book?.toJson(),
    );

    // 解密失败（JS 执行错误/返回 null）：有 imageDecode 规则说明图片是加密的，
    // 用原始加密字节也无法解码，直接报错避免模糊的 "Invalid image data"
    if (decoded == null) {
      throw StateError('图片解密失败: ${key.url}');
    }

    if (decoded.isEmpty) {
      throw StateError('图片解密后字节为空: ${key.url}');
    }

    final buffer = await ui.ImmutableBuffer.fromUint8List(decoded);
    try {
      return await decode(buffer);
    } catch (e) {
      throw StateError('图片解码失败: ${key.url} - $e');
    }
  }

  /// 检测字节数据是否为 HTML 而非图片
  ///
  /// 服务器可能返回 200 状态码但内容是 HTML 错误页（如 Cloudflare 拦截页），
  /// 此时字节流以 `<!DOCTYPE` 或 `<html` 开头（不区分大小写）。
  static bool _isHtmlResponse(Uint8List bytes) {
    if (bytes.length < 6) return false;
    final prefix = String.fromCharCodes(bytes.take(9)).toLowerCase();
    return prefix.startsWith('<!doctype') || prefix.startsWith('<html');
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
