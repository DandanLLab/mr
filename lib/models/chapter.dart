class Chapter {
  final String id;
  final String bookId;
  final String title;
  final int index;
  final String? url;
  final bool isVolume;
  final bool isVip;
  final bool isPay;
  final bool isCached;
  final DateTime? updateTime;
  final int? wordCount;
  final String? tag;

  // ===== EPUB 树状目录支持字段 =====
  // 仅 EPUB 本地书解析时填充，在线书源保持默认值
  // 用于树状目录缩进展示和 spine 精确进度计算

  /// 对应 OPF spine 的顺序索引（-1 表示无对应，例如纯分组节点）
  /// 用于 EPUB 精确进度计算（按 spine 项数百分比）
  final int spineIndex;

  /// 嵌套层级（0=顶层，1=第一层子节点...）
  /// 用于树状目录缩进展示
  final int depth;

  /// 父节点 index（-1=顶层，否则为父节点在扁平列表中的 index）
  /// 用于树状目录折叠/展开
  final int parentId;

  // ===== EPUB 画廊章节支持字段 =====
  // 仅 EPUB 本地书解析时填充，标识该章节是否为多看画廊页
  // （含 .duokan-image-gallery 的章节），由 Flutter PageView 接管渲染

  /// 是否为画廊章节（多看画廊 duokan-image-gallery）
  /// true 时阅读器走 PageView 横向滑动渲染，不走 WebView
  final bool isGallery;

  Chapter({
    required this.id,
    required this.bookId,
    required this.title,
    required this.index,
    this.url,
    this.isVolume = false,
    this.isVip = false,
    this.isPay = false,
    this.isCached = false,
    this.updateTime,
    this.wordCount,
    this.tag,
    this.spineIndex = -1,
    this.depth = 0,
    this.parentId = -1,
    this.isGallery = false,
  });

  Chapter copyWith({
    String? id,
    String? bookId,
    String? title,
    int? index,
    String? url,
    bool? isVolume,
    bool? isVip,
    bool? isPay,
    bool? isCached,
    DateTime? updateTime,
    int? wordCount,
    String? tag,
    int? spineIndex,
    int? depth,
    int? parentId,
    bool? isGallery,
  }) {
    return Chapter(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      title: title ?? this.title,
      index: index ?? this.index,
      url: url ?? this.url,
      isVolume: isVolume ?? this.isVolume,
      isVip: isVip ?? this.isVip,
      isPay: isPay ?? this.isPay,
      isCached: isCached ?? this.isCached,
      updateTime: updateTime ?? this.updateTime,
      wordCount: wordCount ?? this.wordCount,
      tag: tag ?? this.tag,
      spineIndex: spineIndex ?? this.spineIndex,
      depth: depth ?? this.depth,
      parentId: parentId ?? this.parentId,
      isGallery: isGallery ?? this.isGallery,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'bookId': bookId,
      'title': title,
      'index': index,
      'url': url,
      'isVolume': isVolume,
      'isVip': isVip,
      'isPay': isPay,
      'isCached': isCached,
      'updateTime': updateTime?.toIso8601String(),
      'wordCount': wordCount,
      'tag': tag,
      'spineIndex': spineIndex,
      'depth': depth,
      'parentId': parentId,
      'isGallery': isGallery,
    };
  }

  factory Chapter.fromJson(Map<String, dynamic> json) {
    return Chapter(
      id: json['id'] as String,
      bookId: json['bookId'] as String,
      title: json['title'] as String,
      index: json['index'] as int,
      url: json['url'] as String?,
      isVolume: json['isVolume'] as bool? ?? false,
      isVip: json['isVip'] as bool? ?? false,
      isPay: json['isPay'] as bool? ?? false,
      isCached: json['isCached'] as bool? ?? false,
      updateTime: json['updateTime'] != null
          ? DateTime.parse(json['updateTime'] as String)
          : null,
      wordCount: json['wordCount'] as int?,
      tag: json['tag'] as String?,
      spineIndex: json['spineIndex'] as int? ?? -1,
      depth: json['depth'] as int? ?? 0,
      parentId: json['parentId'] as int? ?? -1,
      isGallery: json['isGallery'] as bool? ?? false,
    );
  }
}
