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
    );
  }
}
