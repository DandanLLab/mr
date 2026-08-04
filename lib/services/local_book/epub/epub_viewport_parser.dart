/// EPUB fixed-layout 视口解析器
///
/// 移植自 JRead/Legado 的 EpubViewportParser.kt
///
/// 解析 fixed-layout EPUB 的出版商视口尺寸：
/// 1. XHTML <meta name="viewport"> content
/// 2. SVG viewBox
/// 3. SVG width/height 属性
/// 4. EPUB2 original-resolution 兜底
///
/// 并提供 looksLikeFixedLayout 启发式判断
library;

import 'package:html/parser.dart' as html_parser;

/// 出版商视口尺寸
class EpubPublisherViewport {
  final double width;
  final double height;
  final String source;

  const EpubPublisherViewport(this.width, this.height, this.source)
      : assert(width > 0),
        assert(height > 0);
}

/// 视口解析器
class EpubViewportParser {
  EpubViewportParser._();

  static final RegExp _absolutePositionRegex =
      RegExp(r'position\s*:\s*(?:absolute|fixed)\b');

  /// 解析视口尺寸
  ///
  /// [html] 章节 HTML
  /// [fallbackWidth] / [fallbackHeight] 来自包级 rendition 的兜底值
  static EpubPublisherViewport? parse(
    String html, {
    double? fallbackWidth,
    double? fallbackHeight,
  }) {
    if (html.trim().isNotEmpty) {
      final doc = html_parser.parse(html);

      // 1. <meta name="viewport">
      for (final meta in doc.querySelectorAll('meta[name=viewport]')) {
        final content = meta.attributes['content'] ?? '';
        final result = _parseViewportContent(content);
        if (result != null) {
          return EpubPublisherViewport(result.$1, result.$2, 'xhtml-viewport');
        }
      }

      // 2. <svg viewBox="...">
      final svgWithViewBox = doc.querySelectorAll('svg[viewBox], svg[viewbox]').firstOrNull;
      if (svgWithViewBox != null) {
        final viewBox = svgWithViewBox.attributes['viewBox'] ??
            svgWithViewBox.attributes['viewbox'] ??
            '';
        final result = _parseViewBox(viewBox);
        if (result != null) {
          return EpubPublisherViewport(result.$1, result.$2, 'svg-viewBox');
        }
      }

      // 3. <svg width="..." height="...">
      final svgWithSize = doc.querySelectorAll('svg[width][height]').firstOrNull;
      if (svgWithSize != null) {
        final width = _cssNumber(svgWithSize.attributes['width'] ?? '');
        final height = _cssNumber(svgWithSize.attributes['height'] ?? '');
        if (width != null && height != null) {
          return EpubPublisherViewport(width, height, 'svg-size');
        }
      }
    }

    // 4. fallback
    final w = fallbackWidth != null && fallbackWidth > 0 ? fallbackWidth : null;
    final h = fallbackHeight != null && fallbackHeight > 0 ? fallbackHeight : null;
    if (w != null && h != null) {
      return EpubPublisherViewport(w, h, 'package-original-resolution');
    }
    return null;
  }

  /// 启发式判断是否为 fixed-layout
  static bool looksLikeFixedLayout(String html, EpubPublisherViewport? viewport) {
    if (viewport == null || html.trim().isEmpty) return false;
    final source = html.toLowerCase();
    if (source.contains('<svg') && source.contains('viewbox')) return true;

    // position:absolute/fixed 出现 ≥2 次
    final absoluteMatches = _absolutePositionRegex.allMatches(source).take(4).toList();
    if (absoluteMatches.length >= 2) return true;

    final doc = html_parser.parse(html);
    final body = doc.body;
    if (body == null) return false;

    final elementCount = body.querySelectorAll('*').length;
    final imageCount = doc.querySelectorAll('img,svg,image').length;
    final compactText = body.text.replaceAll(RegExp(r'\s+'), '');

    return imageCount > 0 &&
        compactText.length < 80 &&
        elementCount <= 20 &&
        (viewport.width / viewport.height - 1).abs() > 0.08;
  }

  static (double, double)? _parseViewportContent(String content) {
    if (content.trim().isEmpty) return null;
    final values = <String, String>{};
    for (final token in content.split(RegExp(r'[,;]'))) {
      final parts = token.trim().split('=');
      if (parts.length == 2) {
        values[parts[0].trim().toLowerCase()] = parts[1].trim();
      }
    }
    final width = _cssNumber(values['width'] ?? '');
    final height = _cssNumber(values['height'] ?? '');
    if (width != null && height != null) return (width, height);
    return null;
  }

  static (double, double)? _parseViewBox(String value) {
    final numbers = value
        .trim()
        .split(RegExp(r'[\s,]+'))
        .map((s) => double.tryParse(s))
        .whereType<double>()
        .toList();
    if (numbers.length < 4) return null;
    final w = numbers[2];
    final h = numbers[3];
    if (w <= 0 || h <= 0) return null;
    return (w, h);
  }

  static double? _cssNumber(String value) {
    final match = RegExp(r'^\s*(\d+(?:\.\d+)?)').firstMatch(value);
    final num = match?.group(1) != null ? double.tryParse(match!.group(1)!) : null;
    return num != null && num > 0 ? num : null;
  }
}
