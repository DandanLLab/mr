class Chapter {
  final String id;
  final String bookId;
  final String title;
  final int index;
  final String? url;
  final bool isVip;
  final bool isCached;
  final DateTime? updateTime;
  final int? wordCount;

  Chapter({
    required this.id,
    required this.bookId,
    required this.title,
    required this.index,
    this.url,
    this.isVip = false,
    this.isCached = false,
    this.updateTime,
    this.wordCount,
  });

  Chapter copyWith({
    String? id,
    String? bookId,
    String? title,
    int? index,
    String? url,
    bool? isVip,
    bool? isCached,
    DateTime? updateTime,
    int? wordCount,
  }) {
    return Chapter(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      title: title ?? this.title,
      index: index ?? this.index,
      url: url ?? this.url,
      isVip: isVip ?? this.isVip,
      isCached: isCached ?? this.isCached,
      updateTime: updateTime ?? this.updateTime,
      wordCount: wordCount ?? this.wordCount,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'bookId': bookId,
      'title': title,
      'index': index,
      'url': url,
      'isVip': isVip,
      'isCached': isCached,
      'updateTime': updateTime?.toIso8601String(),
      'wordCount': wordCount,
    };
  }

  factory Chapter.fromJson(Map<String, dynamic> json) {
    return Chapter(
      id: json['id'] as String,
      bookId: json['bookId'] as String,
      title: json['title'] as String,
      index: json['index'] as int,
      url: json['url'] as String?,
      isVip: json['isVip'] as bool? ?? false,
      isCached: json['isCached'] as bool? ?? false,
      updateTime: json['updateTime'] != null
          ? DateTime.parse(json['updateTime'] as String)
          : null,
      wordCount: json['wordCount'] as int?,
    );
  }
}
