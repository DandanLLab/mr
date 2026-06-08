enum MediaType { novel, comic, video, audio }

enum BookOriginType { local, online }

class Book {
  final String bookUrl;
  final String name;
  final String author;
  final String coverUrl;
  final String intro;
  final MediaType mediaType;
  final BookOriginType originType;
  final String? sourceUrl;
  final String? sourceName;
  final String? kind;
  final String? lastChapter;
  final int? totalChapterNum;
  final String? status;
  final DateTime? lastCheckTime;
  final DateTime? durChapterTime;
  final int durChapterIndex;
  final String durChapterTitle;
  final int durChapterPos;
  final int durChapterTimeMillisecond;
  final bool isTop;
  final String? groupId;
  final List<String>? tags;
  final String? tocUrl;
  final String? wordCount;
  final bool canUpdate;
  final int? customOrder;
  final DateTime addedTime;
  final bool? splitLongChapter;
  final bool? deleteAlert;

  // 自定义元数据字段
  final String? customName;
  final String? customAuthor;
  final String? customCoverUrl;
  final String? customIntro;
  final String? publisher;
  final String? category;
  final bool showWordCount;

  // 显示属性：优先使用自定义值
  String get displayName => customName ?? name;
  String get displayAuthor => customAuthor ?? author;
  String get displayCoverUrl => customCoverUrl ?? coverUrl;
  String get displayIntro => customIntro ?? intro;
  String get latestChapterTitle => lastChapter ?? '';
  int get unreadCount {
    final total = totalChapterNum ?? 0;
    if (total <= 0) return 0;
    final readCount = durChapterIndex + 1;
    return total > readCount ? total - readCount : 0;
  }

  Book({
    required this.bookUrl,
    required this.name,
    required this.author,
    this.coverUrl = '',
    this.intro = '',
    required this.mediaType,
    required this.originType,
    this.sourceUrl,
    this.sourceName,
    this.kind,
    this.lastChapter,
    this.totalChapterNum,
    this.status,
    this.lastCheckTime,
    this.durChapterTime,
    this.durChapterIndex = 0,
    this.durChapterTitle = '',
    this.durChapterPos = 0,
    this.durChapterTimeMillisecond = 0,
    this.isTop = false,
    this.groupId,
    this.tags,
    this.tocUrl,
    this.wordCount,
    this.canUpdate = true,
    this.customOrder,
    required this.addedTime,
    this.splitLongChapter,
    this.deleteAlert,
    this.customName,
    this.customAuthor,
    this.customCoverUrl,
    this.customIntro,
    this.publisher,
    this.category,
    this.showWordCount = true,
  });

  double get progress {
    if (totalChapterNum == null || totalChapterNum == 0) return 0;
    return durChapterIndex / totalChapterNum!;
  }

  String get progressText {
    if (totalChapterNum == null || totalChapterNum == 0) return '';
    return '$durChapterIndex/$totalChapterNum';
  }

  Book copyWith({
    String? bookUrl,
    String? name,
    String? author,
    String? coverUrl,
    String? intro,
    MediaType? mediaType,
    BookOriginType? originType,
    String? sourceUrl,
    String? sourceName,
    String? kind,
    String? lastChapter,
    int? totalChapterNum,
    String? status,
    DateTime? lastCheckTime,
    DateTime? durChapterTime,
    int? durChapterIndex,
    String? durChapterTitle,
    int? durChapterPos,
    int? durChapterTimeMillisecond,
    bool? isTop,
    String? groupId,
    List<String>? tags,
    String? tocUrl,
    String? wordCount,
    bool? canUpdate,
    int? customOrder,
    DateTime? addedTime,
    bool? splitLongChapter,
    bool? deleteAlert,
    String? customName,
    String? customAuthor,
    String? customCoverUrl,
    String? customIntro,
    String? publisher,
    String? category,
    bool? showWordCount,
  }) {
    return Book(
      bookUrl: bookUrl ?? this.bookUrl,
      name: name ?? this.name,
      author: author ?? this.author,
      coverUrl: coverUrl ?? this.coverUrl,
      intro: intro ?? this.intro,
      mediaType: mediaType ?? this.mediaType,
      originType: originType ?? this.originType,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      sourceName: sourceName ?? this.sourceName,
      kind: kind ?? this.kind,
      lastChapter: lastChapter ?? this.lastChapter,
      totalChapterNum: totalChapterNum ?? this.totalChapterNum,
      status: status ?? this.status,
      lastCheckTime: lastCheckTime ?? this.lastCheckTime,
      durChapterTime: durChapterTime ?? this.durChapterTime,
      durChapterIndex: durChapterIndex ?? this.durChapterIndex,
      durChapterTitle: durChapterTitle ?? this.durChapterTitle,
      durChapterPos: durChapterPos ?? this.durChapterPos,
      durChapterTimeMillisecond:
          durChapterTimeMillisecond ?? this.durChapterTimeMillisecond,
      isTop: isTop ?? this.isTop,
      groupId: groupId ?? this.groupId,
      tags: tags ?? this.tags,
      tocUrl: tocUrl ?? this.tocUrl,
      wordCount: wordCount ?? this.wordCount,
      canUpdate: canUpdate ?? this.canUpdate,
      customOrder: customOrder ?? this.customOrder,
      addedTime: addedTime ?? this.addedTime,
      splitLongChapter: splitLongChapter ?? this.splitLongChapter,
      deleteAlert: deleteAlert ?? this.deleteAlert,
      customName: customName ?? this.customName,
      customAuthor: customAuthor ?? this.customAuthor,
      customCoverUrl: customCoverUrl ?? this.customCoverUrl,
      customIntro: customIntro ?? this.customIntro,
      publisher: publisher ?? this.publisher,
      category: category ?? this.category,
      showWordCount: showWordCount ?? this.showWordCount,
    );
  }

  factory Book.fromJson(Map<String, dynamic> json) {
    return Book(
      bookUrl: json['bookUrl'] as String? ?? json['id'] as String? ?? '',
      name: json['name'] as String? ?? json['title'] as String? ?? '',
      author: json['author'] as String? ?? '',
      coverUrl: json['coverUrl'] as String? ?? json['cover'] as String? ?? '',
      intro: json['intro'] as String? ?? json['description'] as String? ?? '',
      mediaType: MediaType.values[json['mediaType'] as int? ?? 0],
      originType: BookOriginType
          .values[json['originType'] as int? ?? json['source'] as int? ?? 0],
      sourceUrl: json['sourceUrl'] as String? ?? json['sourceId'] as String?,
      sourceName: json['sourceName'] as String?,
      kind: json['kind'] as String?,
      lastChapter: json['lastChapter'] as String?,
      totalChapterNum:
          json['totalChapterNum'] as int? ?? json['chapterCount'] as int?,
      status: json['status'] as String?,
      lastCheckTime: json['lastCheckTime'] != null
          ? DateTime.tryParse(json['lastCheckTime'] as String)
          : null,
      durChapterTime: json['durChapterTime'] != null
          ? DateTime.tryParse(json['durChapterTime'] as String)
          : null,
      durChapterIndex: json['durChapterIndex'] as int? ?? 0,
      durChapterTitle: json['durChapterTitle'] as String? ?? '',
      durChapterPos: json['durChapterPos'] as int? ?? 0,
      durChapterTimeMillisecond: json['durChapterTimeMillisecond'] as int? ?? 0,
      isTop: json['isTop'] as bool? ?? false,
      groupId: json['groupId'] as String?,
      tags: (json['tags'] as List<dynamic>?)?.cast<String>(),
      tocUrl: json['tocUrl'] as String?,
      wordCount: json['wordCount'] as String?,
      canUpdate: json['canUpdate'] as bool? ?? true,
      customOrder: json['customOrder'] as int?,
      addedTime: json['addedTime'] != null
          ? DateTime.parse(json['addedTime'] as String)
          : DateTime.now(),
      splitLongChapter: json['splitLongChapter'] as bool?,
      deleteAlert: json['deleteAlert'] as bool?,
      customName: json['customName'] as String?,
      customAuthor: json['customAuthor'] as String?,
      customCoverUrl: json['customCoverUrl'] as String?,
      customIntro: json['customIntro'] as String?,
      publisher: json['publisher'] as String?,
      category: json['category'] as String?,
      showWordCount: json['showWordCount'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'bookUrl': bookUrl,
      'name': name,
      'author': author,
      'coverUrl': coverUrl,
      'intro': intro,
      'mediaType': mediaType.index,
      'originType': originType.index,
      if (sourceUrl != null) 'sourceUrl': sourceUrl,
      if (sourceName != null) 'sourceName': sourceName,
      if (kind != null) 'kind': kind,
      if (lastChapter != null) 'lastChapter': lastChapter,
      if (totalChapterNum != null) 'totalChapterNum': totalChapterNum,
      if (status != null) 'status': status,
      if (lastCheckTime != null)
        'lastCheckTime': lastCheckTime!.toIso8601String(),
      if (durChapterTime != null)
        'durChapterTime': durChapterTime!.toIso8601String(),
      'durChapterIndex': durChapterIndex,
      'durChapterTitle': durChapterTitle,
      'durChapterPos': durChapterPos,
      'durChapterTimeMillisecond': durChapterTimeMillisecond,
      'isTop': isTop,
      if (groupId != null) 'groupId': groupId,
      if (tags != null) 'tags': tags,
      if (tocUrl != null) 'tocUrl': tocUrl,
      if (wordCount != null) 'wordCount': wordCount,
      'canUpdate': canUpdate,
      if (customOrder != null) 'customOrder': customOrder,
      'addedTime': addedTime.toIso8601String(),
      if (splitLongChapter != null) 'splitLongChapter': splitLongChapter,
      if (deleteAlert != null) 'deleteAlert': deleteAlert,
      if (customName != null) 'customName': customName,
      if (customAuthor != null) 'customAuthor': customAuthor,
      if (customCoverUrl != null) 'customCoverUrl': customCoverUrl,
      if (customIntro != null) 'customIntro': customIntro,
      if (publisher != null) 'publisher': publisher,
      if (category != null) 'category': category,
      'showWordCount': showWordCount,
    };
  }
}
