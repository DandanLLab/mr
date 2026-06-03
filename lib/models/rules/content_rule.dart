class ContentRule {
  final String? content;
  final String? subContent;
  final String? title;
  final String? nextContentUrl;
  final String? webJs;
  final String? sourceRegex;
  final String? replaceRegex;
  final String? imageStyle;
  final String? imageDecode;
  final String? payAction;
  final String? callBackJs;
  final String? js;

  const ContentRule({
    this.content,
    this.subContent,
    this.title,
    this.nextContentUrl,
    this.webJs,
    this.sourceRegex,
    this.replaceRegex,
    this.imageStyle,
    this.imageDecode,
    this.payAction,
    this.callBackJs,
    this.js,
  });

  factory ContentRule.fromJson(Map<String, dynamic> json) {
    return ContentRule(
      content: json['content'] as String?,
      subContent: json['subContent'] as String?,
      title: json['title'] as String?,
      nextContentUrl: json['nextContentUrl'] as String?,
      webJs: json['webJs'] as String?,
      sourceRegex: json['sourceRegex'] as String?,
      replaceRegex: json['replaceRegex'] as String?,
      imageStyle: json['imageStyle'] as String?,
      imageDecode: json['imageDecode'] as String?,
      payAction: json['payAction'] as String?,
      callBackJs: json['callBackJs'] as String?,
      js: json['js'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (content != null) 'content': content,
      if (subContent != null) 'subContent': subContent,
      if (title != null) 'title': title,
      if (nextContentUrl != null) 'nextContentUrl': nextContentUrl,
      if (webJs != null) 'webJs': webJs,
      if (sourceRegex != null) 'sourceRegex': sourceRegex,
      if (replaceRegex != null) 'replaceRegex': replaceRegex,
      if (imageStyle != null) 'imageStyle': imageStyle,
      if (imageDecode != null) 'imageDecode': imageDecode,
      if (payAction != null) 'payAction': payAction,
      if (callBackJs != null) 'callBackJs': callBackJs,
      if (js != null) 'js': js,
    };
  }
}
