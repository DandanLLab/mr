/// EPUB OPF 包文档解析器
///
/// 移植自 JRead/Legado 的 EpubPackageParser.kt
///
/// 解析流程：
/// 1. 从 META-INF/container.xml 找到 OPF 路径
/// 2. 解析 OPF 的 metadata/manifest/spine
/// 3. 解析 rendition（EPUB3 property + EPUB2 meta name/content 双兼容）
/// 4. 提取 navHref/ncxHref/coverHref
///
/// 用 xml 包的 DOM API 替换 Kotlin 的 org.w3c.dom + XmlTools。
library;

import 'package:xml/xml.dart' as xml;

import 'epub_package.dart';
import 'epub_path.dart';

/// EPUB 归档读取接口（最小化抽象，与 ZipEpubArchive 对应）
abstract class EpubArchiveReader {
  bool exists(String path);
  List<String> list();
  List<int> readBytes(String path);
  String readText(String path);
}

/// OPF 包文档解析器
class EpubPackageParser {
  /// 解析 EPUB 包
  ///
  /// [archive] 提供 ZIP 内文件读取能力
  /// 返回解析后的 [EpubPackage]
  static EpubPackage parse(EpubArchiveReader archive) {
    final opfPath = _findOpfPath(archive);
    final opfXml = archive.readText(opfPath);
    final doc = xml.XmlDocument.parse(opfXml);

    final metadataElement = _findFirstElement(doc, 'metadata');
    final packageRendition = _parsePackageRendition(metadataElement);

    // 解析 manifest
    final manifest = <String, EpubManifestItem>{};
    final manifestElement = _findFirstElement(doc, 'manifest');
    if (manifestElement != null) {
      for (final item in manifestElement.findElements('item')) {
        final id = item.getAttribute('id');
        final href = item.getAttribute('href');
        if (id == null || href == null) continue;
        if (manifest.containsKey(id)) continue; // 去重

        final propertiesStr = item.getAttribute('properties') ?? '';
        final properties = propertiesStr
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotBlank)
            .toSet();

        manifest[id] = EpubManifestItem(
          id: id,
          href: EpubPath.resolve(opfPath, href),
          mediaType: item.getAttribute('media-type') ?? '',
          properties: properties,
        );
      }
    }

    // 解析 spine
    final spineElement = _findFirstElement(doc, 'spine');
    final spine = <EpubSpineItem>[];
    if (spineElement != null) {
      var index = 0;
      for (final itemref in spineElement.findElements('itemref')) {
        final idRef = itemref.getAttribute('idref');
        if (idRef == null) continue;
        final item = manifest[idRef];
        if (item == null) continue;

        final propertiesStr = itemref.getAttribute('properties') ?? '';
        final properties = propertiesStr
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotBlank)
            .toSet();

        spine.add(EpubSpineItem(
          index: index,
          idRef: idRef,
          href: item.href,
          linear: itemref.getAttribute('linear') != 'no',
          properties: properties,
          rendition: _resolveRendition(packageRendition, properties),
          pageSpread: _resolvePageSpread(properties),
        ));
        index++;
      }
    }

    // 提取 navHref / ncxHref / coverHref
    final navHref = manifest.values
        .where((item) => item.properties.contains('nav'))
        .firstOrNull?.href;
    final ncxAttr = spineElement?.getAttribute('toc');
    final ncxHref = ncxAttr != null ? manifest[ncxAttr]?.href : null;
    final coverHref = _findCoverHref(doc, manifest);

    return EpubPackage(
      opfPath: opfPath,
      metadata: EpubMetadata(
        title: _firstText(metadataElement, 'title'),
        creator: _firstText(metadataElement, 'creator'),
        language: _firstText(metadataElement, 'language'),
        identifier: _firstText(metadataElement, 'identifier'),
        description: _firstText(metadataElement, 'description'),
      ),
      manifest: manifest,
      spine: spine,
      navHref: navHref,
      ncxHref: ncxHref,
      coverHref: coverHref,
      rendition: packageRendition,
    );
  }

  /// 从 META-INF/container.xml 找到 OPF 路径
  static String _findOpfPath(EpubArchiveReader archive) {
    if (archive.exists('META-INF/container.xml')) {
      final containerXml = archive.readText('META-INF/container.xml');
      final doc = xml.XmlDocument.parse(containerXml);
      final rootfiles = _findFirstElement(doc, 'rootfiles') ??
          _findFirstElement(doc, 'rootfile');
      if (rootfiles != null) {
        // rootfile 元素
        for (final rf in rootfiles.findElements('rootfile')) {
          final fullPath = rf.getAttribute('full-path');
          if (fullPath != null && fullPath.isNotBlank && archive.exists(fullPath)) {
            return EpubPath.normalize(fullPath);
          }
        }
        // 有些 container.xml 直接在 rootfiles 上有 full-path
        final fullPath = rootfiles.getAttribute('full-path');
        if (fullPath != null && fullPath.isNotBlank && archive.exists(fullPath)) {
          return EpubPath.normalize(fullPath);
        }
      }
      // 降级：直接搜索所有 rootfile 元素（不管命名空间）
      final allRootfiles = doc.findAllElements('rootfile');
      for (final rf in allRootfiles) {
        final fullPath = rf.getAttribute('full-path');
        if (fullPath != null && fullPath.isNotBlank && archive.exists(fullPath)) {
          return EpubPath.normalize(fullPath);
        }
      }
    }
    // 回退：找第一个 .opf 文件
    final opfFile = archive.list().where((p) => p.toLowerCase().endsWith('.opf')).firstOrNull;
    if (opfFile == null) {
      throw StateError('EPUB package document not found');
    }
    return EpubPath.normalize(opfFile);
  }

  /// 解析包级 rendition（EPUB3 property + EPUB2 meta name/content）
  static EpubRendition _parsePackageRendition(xml.XmlElement? metadata) {
    if (metadata == null) return const EpubRendition();

    String? propertyValue(String name) {
      for (final meta in metadata.findElements('meta')) {
        final prop = meta.getAttribute('property');
        if (prop != null && prop.toLowerCase() == name.toLowerCase()) {
          final text = meta.innerText.trim();
          return text.isNotEmpty ? text : null;
        }
      }
      return null;
    }

    String? namedValue(String name) {
      for (final meta in metadata.findElements('meta')) {
        final attrName = meta.getAttribute('name');
        if (attrName != null && attrName.toLowerCase() == name.toLowerCase()) {
          final content = meta.getAttribute('content');
          if (content != null && content.trim().isNotEmpty) return content.trim();
        }
      }
      return null;
    }

    // layout
    final epub2FixedLayout = namedValue('fixed-layout')?.toLowerCase();
    final isEpub2Fixed = epub2FixedLayout == 'true' || epub2FixedLayout == 'yes';
    final layoutValue = propertyValue('rendition:layout')?.toLowerCase();
    final layout = switch (layoutValue) {
      'pre-paginated' => EpubRenditionLayout.prePaginated,
      'reflowable' => EpubRenditionLayout.reflowable,
      _ when isEpub2Fixed => EpubRenditionLayout.prePaginated,
      _ => EpubRenditionLayout.reflowable,
    };

    // orientation
    final orientationValue =
        (propertyValue('rendition:orientation') ?? namedValue('orientation-lock'))
            ?.toLowerCase();
    final orientation = switch (orientationValue) {
      'portrait' => EpubRenditionOrientation.portrait,
      'landscape' => EpubRenditionOrientation.landscape,
      _ => EpubRenditionOrientation.auto,
    };

    // spread
    final spreadValue =
        (propertyValue('rendition:spread') ?? namedValue('open-to-spread'))
            ?.toLowerCase();
    final spread = switch (spreadValue) {
      'none' || 'false' => EpubRenditionSpread.none,
      'both' || 'true' => EpubRenditionSpread.both,
      'portrait' => EpubRenditionSpread.portrait,
      'landscape' => EpubRenditionSpread.landscape,
      _ => EpubRenditionSpread.auto,
    };

    // viewport（EPUB2 original-resolution）
    final originalResolution = namedValue('original-resolution');
    final (vpW, vpH) = originalResolution != null
        ? _parseResolution(originalResolution)
        : (null, null);

    return EpubRendition(
      layout: layout,
      orientation: orientation,
      spread: spread,
      viewportWidth: vpW,
      viewportHeight: vpH,
    );
  }

  /// itemref 级 properties 覆盖包级 rendition
  static EpubRendition _resolveRendition(
    EpubRendition base,
    Set<String> properties,
  ) {
    final normalized = properties.map((p) => p.toLowerCase()).toSet();
    final layout = normalized.any((p) => p == 'duokan-page-fullscreen')
        ? EpubRenditionLayout.prePaginated
        : normalized.any((p) =>
                p == 'rendition:layout-pre-paginated' || p == 'layout-pre-paginated')
            ? EpubRenditionLayout.prePaginated
            : normalized.any((p) =>
                    p == 'rendition:layout-reflowable' || p == 'layout-reflowable')
                ? EpubRenditionLayout.reflowable
                : base.layout;
    final orientation = normalized.any((p) => p.endsWith('orientation-portrait'))
        ? EpubRenditionOrientation.portrait
        : normalized.any((p) => p.endsWith('orientation-landscape'))
            ? EpubRenditionOrientation.landscape
            : normalized.any((p) => p.endsWith('orientation-auto'))
                ? EpubRenditionOrientation.auto
                : base.orientation;
    final spread = normalized.any((p) => p.endsWith('spread-none'))
        ? EpubRenditionSpread.none
        : normalized.any((p) => p.endsWith('spread-both'))
            ? EpubRenditionSpread.both
            : normalized.any((p) => p.endsWith('spread-portrait'))
                ? EpubRenditionSpread.portrait
                : normalized.any((p) => p.endsWith('spread-landscape'))
                    ? EpubRenditionSpread.landscape
                    : normalized.any((p) => p.endsWith('spread-auto'))
                        ? EpubRenditionSpread.auto
                        : base.spread;
    return base.copyWith(
      layout: layout,
      orientation: orientation,
      spread: spread,
    );
  }

  /// 解析 page-spread-* 属性
  static EpubPageSpread _resolvePageSpread(Set<String> properties) {
    final normalized = properties.map((p) => p.toLowerCase()).toSet();
    if (normalized.contains('page-spread-left')) return EpubPageSpread.left;
    if (normalized.contains('page-spread-right')) return EpubPageSpread.right;
    if (normalized.any((p) =>
        p == 'rendition:page-spread-center' || p == 'page-spread-center')) {
      return EpubPageSpread.center;
    }
    return EpubPageSpread.auto;
  }

  /// 解析 "WxH" 格式的分辨率字符串
  static (double?, double?) _parseResolution(String value) {
    final match = RegExp(
      r'^\s*(\d+(?:\.\d+)?)\s*[x×,]\s*(\d+(?:\.\d+)?)\s*$',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return (null, null);
    final w = double.tryParse(match.group(1)!);
    final h = double.tryParse(match.group(2)!);
    if (w == null || w <= 0 || h == null || h <= 0) return (null, null);
    return (w, h);
  }

  /// 查找封面 href
  static String? _findCoverHref(
    xml.XmlDocument doc,
    Map<String, EpubManifestItem> manifest,
  ) {
    // EPUB3: properties="cover-image"
    final coverByProps = manifest.values
        .where((item) => item.properties.contains('cover-image'))
        .firstOrNull?.href;
    if (coverByProps != null) return coverByProps;

    // EPUB2: <meta name="cover" content="coverId"/>
    final metaElements = doc.findAllElements('meta');
    for (final meta in metaElements) {
      if (meta.getAttribute('name') == 'cover') {
        final coverId = meta.getAttribute('content');
        if (coverId != null) {
          return manifest[coverId]?.href;
        }
      }
    }
    return null;
  }

  // ---- XML 工具方法 ----

  /// 查找第一个指定名称的元素（忽略命名空间）
  static xml.XmlElement? _findFirstElement(xml.XmlNode parent, String name) {
    for (final child in parent.descendants) {
      if (child is xml.XmlElement && child.localName == name) {
        return child;
      }
    }
    return null;
  }

  /// 获取元素下第一个指定名称子元素的文本内容
  static String? _firstText(xml.XmlElement? parent, String name) {
    if (parent == null) return null;
    for (final child in parent.children) {
      if (child is xml.XmlElement && child.localName == name) {
        final text = child.innerText.trim();
        return text.isNotEmpty ? text : null;
      }
    }
    return null;
  }
}

/// String 扩展：isNotBlank（Dart 没有 Kotlin 的 isNotBlank）
extension StringNotBlank on String {
  bool get isNotBlank => trim().isNotEmpty;
}

/// Iterable 扩展：firstOrNull（Dart 3.0+ 已有 firstOrNull，但为兼容性保留）
extension IterableFirstOrNull<T> on Iterable<T> {
  T? get firstOrNullOrNull => isEmpty ? null : first;
}
