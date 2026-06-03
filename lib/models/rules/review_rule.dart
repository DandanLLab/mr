/// 段评规则
/// 参考 legados ReviewRule.kt
class ReviewRule {
  final String? reviewList;
  final String? reviewContent;
  final String? reviewUser;
  final String? reviewTime;
  final String? reviewVote;
  final String? reviewUrl;

  const ReviewRule({
    this.reviewList,
    this.reviewContent,
    this.reviewUser,
    this.reviewTime,
    this.reviewVote,
    this.reviewUrl,
  });

  factory ReviewRule.fromJson(Map<String, dynamic> json) {
    return ReviewRule(
      reviewList: json['reviewList'] as String?,
      reviewContent: json['reviewContent'] as String?,
      reviewUser: json['reviewUser'] as String?,
      reviewTime: json['reviewTime'] as String?,
      reviewVote: json['reviewVote'] as String?,
      reviewUrl: json['reviewUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (reviewList != null) 'reviewList': reviewList,
      if (reviewContent != null) 'reviewContent': reviewContent,
      if (reviewUser != null) 'reviewUser': reviewUser,
      if (reviewTime != null) 'reviewTime': reviewTime,
      if (reviewVote != null) 'reviewVote': reviewVote,
      if (reviewUrl != null) 'reviewUrl': reviewUrl,
    };
  }
}
