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

    // 下载诊断：打印请求 URL 和 headers 的 keys，确认请求头是否传入
    final headerKeys = key.headers.keys.map((k) => '$k=${_maskValue(key.headers[k])}').join(', ');
    debugPrint('📥 [DecodedImageProvider] 开始下载: ${key.url}\n'
        '  请求头: {$headerKeys}');

    Uint8List bytes;
    int? statusCode;
    Map<String, String> respHeaders = {};
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
      statusCode = response.statusCode;
      respHeaders = response.headers.map.map(
        (k, v) => MapEntry(k, v.first),
      );
      // 下载诊断：打印状态码、字节数、前16字节、Content-Type
      final hex = bytes
          .take(16)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      final contentType = respHeaders['content-type'] ?? respHeaders['Content-Type'] ?? '(无)';
      debugPrint('📥 [DecodedImageProvider] 下载完成: ${key.url}\n'
          '  状态码: $statusCode, 字节数: ${bytes.length}\n'
          '  Content-Type: $contentType, 前16字节: $hex');
    } catch (e) {
      debugPrint('⚠️ [DecodedImageProvider] 下载失败: ${key.url} → $e');
      rethrow;
    } finally {
      await chunkEvents.close();
    }

    if (bytes.isEmpty) {
      // 空响应诊断：打印状态码和响应头，帮助判断是 403/404 还是服务器返回空
      debugPrint('❌ [DecodedImageProvider] 响应为空: ${key.url}\n'
          '  状态码: $statusCode, 响应头: $respHeaders');
      final statusInfo = statusCode != null ? '(状态码: $statusCode)' : '(无状态码)';
      throw StateError('图片下载响应为空: ${key.url} $statusInfo');
    }

    // 检测 HTML 错误页（服务器返回 200 但内容是 HTML 而非图片）
    if (_isHtmlResponse(bytes)) {
      final preview = String.fromCharCodes(bytes.take(200));
      throw StateError('服务器返回 HTML 而非图片数据: ${key.url} (前200字符: $preview)');
    }

    // 调用 JS 解密（借鉴 Legado ImageUtils.decode）
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
      final lastError = JsEngine.instance.lastEvalError;
      final ruleJs = key.isCover
          ? key.source.coverDecodeJs
          : key.source.ruleContent?.imageDecode;
      final rulePreview = (ruleJs != null && ruleJs.length > 200)
          ? '${ruleJs.substring(0, 200)}...'
          : (ruleJs ?? '(空)');
      throw StateError('图片解密失败（JS返回null）: ${key.url}\n'
          '  lastEvalError: $lastError\n'
          '  ruleJs: $rulePreview');
    }

    if (decoded.isEmpty) {
      throw StateError('图片解密后字节为空: ${key.url}');
    }

    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(decoded);
      return decode(buffer);
    } catch (e) {
      // 解码失败时输出详细诊断：原始大小、解密后大小、前几字节
      final origHex = bytes
          .take(16)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      final decodedHex = decoded
          .take(16)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      debugPrint('⚠️ [DecodedImageProvider] 图片解码失败: ${key.url}\n'
          '  原始大小: ${bytes.length} bytes, 前16字节: $origHex\n'
          '  解密后大小: ${decoded.length} bytes, 前16字节: $decodedHex\n'
          '  错误: $e');
      rethrow;
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

  /// 脱敏请求头值：过长值（如 Cookie）截断显示，便于诊断
  static String _maskValue(String? value) {
    if (value == null || value.isEmpty) return '(空)';
    // 书源 header 通常是 UA/Referer，需要完整显示便于诊断
    // 过长的值（如 Cookie）截断显示
    if (value.length > 120) {
      return '${value.substring(0, 120)}...(${value.length}字符)';
    }
    return value;
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
