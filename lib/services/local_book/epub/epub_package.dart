/// EPUB 包数据模型
///
/// 移植自 JRead/Legado 的 EpubPackage.kt
///
/// 定义 EPUB OPF 文档的不可变数据结构：
/// - metadata（标题/作者/语言/标识符）
/// - manifest（资源清单：id → href/mediaType/properties）
/// - spine（阅读顺序：itemref 列表）
/// - rendition（布局意向：reflowable/pre-paginated）
library;

/// EPUB 包（OPF 文档解析结果）
class EpubPackage {
  final String opfPath;
  final EpubMetadata metadata;
  final Map<String, EpubManifestItem> manifest;
  final List<EpubSpineItem> spine;
  final String? navHref;
  final String? ncxHref;
  final String? coverHref;
  final EpubRendition rendition;

  const EpubPackage({
    required this.opfPath,
    required this.metadata,
    required this.manifest,
    required this.spine,
    this.navHref,
    this.ncxHref,
    this.coverHref,
    this.rendition = const EpubRendition(),
  });
}

/// EPUB 元数据
class EpubMetadata {
  final String? title;
  final String? creator;
  final String? language;
  final String? identifier;
  final String? description;

  const EpubMetadata({
    this.title,
    this.creator,
    this.language,
    this.identifier,
    this.description,
  });
}

/// Manifest 条目
class EpubManifestItem {
  final String id;
  final String href;
  final String mediaType;
  final Set<String> properties;

  const EpubManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    this.properties = const {},
  });

  /// 是否为 CSS 资源
  bool get isCssItem =>
      mediaType == 'text/css' || href.toLowerCase().endsWith('.css');
}

/// Spine 条目（阅读顺序）
class EpubSpineItem {
  final int index;
  final String idRef;
  final String href;
  final bool linear;
  final Set<String> properties;
  final EpubRendition rendition;
  final EpubPageSpread pageSpread;

  const EpubSpineItem({
    required this.index,
    required this.idRef,
    required this.href,
    required this.linear,
    this.properties = const {},
    this.rendition = const EpubRendition(),
    this.pageSpread = EpubPageSpread.auto,
  });
}

/// EPUB rendition 布局意向
class EpubRendition {
  final EpubRenditionLayout layout;
  final EpubRenditionOrientation orientation;
  final EpubRenditionSpread spread;
  final double? viewportWidth;
  final double? viewportHeight;

  const EpubRendition({
    this.layout = EpubRenditionLayout.reflowable,
    this.orientation = EpubRenditionOrientation.auto,
    this.spread = EpubRenditionSpread.auto,
    this.viewportWidth,
    this.viewportHeight,
  });

  EpubRendition copyWith({
    EpubRenditionLayout? layout,
    EpubRenditionOrientation? orientation,
    EpubRenditionSpread? spread,
    double? viewportWidth,
    double? viewportHeight,
  }) =>
      EpubRendition(
        layout: layout ?? this.layout,
        orientation: orientation ?? this.orientation,
        spread: spread ?? this.spread,
        viewportWidth: viewportWidth ?? this.viewportWidth,
        viewportHeight: viewportHeight ?? this.viewportHeight,
      );
}

/// 布局模式
enum EpubRenditionLayout { reflowable, prePaginated }

/// 方向锁定
enum EpubRenditionOrientation { auto, portrait, landscape }

/// 双页展开
enum EpubRenditionSpread { auto, none, both, portrait, landscape }

/// 页面展开方向
enum EpubPageSpread { auto, left, right, center }

/// 章节内容模式（对齐 JRead EpubWebContentMode）
///
/// 决定阅读器如何渲染章节：
/// - [reflowable]：流式布局，用 column-width 分栏翻页（多数文字小说）
/// - [fixedLayout]：固定布局，单页不切分（画册、漫画、SVG 矢量图）
/// - [mediaPage]：纯媒体页，单页不切分（纯图片章节）
enum EpubContentMode {
  reflowable,
  fixedLayout,
  mediaPage;

  /// 是否为单页模式（不切分）
  bool get isSinglePage => this != reflowable;
}
