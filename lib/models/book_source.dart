import 'dart:convert';
import '../services/native/js_engine.dart' show JsEngineType;
import 'rules/search_rule.dart';
import 'rules/explore_rule.dart';
import 'rules/book_info_rule.dart';
import 'rules/toc_rule.dart';
import 'rules/content_rule.dart';
import 'rules/review_rule.dart';

enum BookSourceType { text, audio, image, file, video }

class BookSource {
  final String bookSourceUrl;
  final String bookSourceName;
  final String? bookSourceGroup;
  final BookSourceType bookSourceType;
  final String? bookUrlPattern;
  final int customOrder;
  final bool enabled;
  final bool enabledExplore;
  final String? jsLib;
  final String? engine; // 书源级引擎声明: "rhino" | "quickjs" | null(自动识别)
  final bool enabledCookieJar;
  final String? concurrentRate;
  final String? header;
  final String? loginUrl;
  final String? loginUi;
  final String? loginCheckJs;
  final String? coverDecodeJs;
  final String? bookSourceComment;
  final String? variableComment;
  final int lastUpdateTime;
  final int respondTime;
  final int weight;
  final String? searchUrl;
  final String? exploreUrl;
  final String? exploreScreen;
  final SearchRule? ruleSearch;
  final ExploreRule? ruleExplore;
  final BookInfoRule? ruleBookInfo;
  final TocRule? ruleToc;
  final ContentRule? ruleContent;
  final ReviewRule? ruleReview;
  final bool eventListener;
  final bool customButton;
  final bool nextPageLazyLoad;

  const BookSource({
    required this.bookSourceUrl,
    required this.bookSourceName,
    this.bookSourceGroup,
    this.bookSourceType = BookSourceType.text,
    this.bookUrlPattern,
    this.customOrder = 0,
    this.enabled = true,
    this.enabledExplore = true,
    this.jsLib,
    this.engine,
    this.enabledCookieJar = true,
    this.concurrentRate,
    this.header,
    this.loginUrl,
    this.loginUi,
    this.loginCheckJs,
    this.coverDecodeJs,
    this.bookSourceComment,
    this.variableComment,
    this.lastUpdateTime = 0,
    this.respondTime = 180000,
    this.weight = 0,
    this.searchUrl,
    this.exploreUrl,
    this.exploreScreen,
    this.ruleSearch,
    this.ruleExplore,
    this.ruleBookInfo,
    this.ruleToc,
    this.ruleContent,
    this.ruleReview,
    this.eventListener = false,
    this.customButton = false,
    this.nextPageLazyLoad = false,
  });

  BookSource copyWith({
    String? bookSourceUrl,
    String? bookSourceName,
    String? bookSourceGroup,
    BookSourceType? bookSourceType,
    String? bookUrlPattern,
    int? customOrder,
    bool? enabled,
    bool? enabledExplore,
    String? jsLib,
    String? engine,
    bool? enabledCookieJar,
    String? concurrentRate,
    String? header,
    String? loginUrl,
    String? loginUi,
    String? loginCheckJs,
    String? coverDecodeJs,
    String? bookSourceComment,
    String? variableComment,
    int? lastUpdateTime,
    int? respondTime,
    int? weight,
    String? searchUrl,
    String? exploreUrl,
    String? exploreScreen,
    SearchRule? ruleSearch,
    ExploreRule? ruleExplore,
    BookInfoRule? ruleBookInfo,
    TocRule? ruleToc,
    ContentRule? ruleContent,
    ReviewRule? ruleReview,
    bool? eventListener,
    bool? customButton,
    bool? nextPageLazyLoad,
  }) {
    return BookSource(
      bookSourceUrl: bookSourceUrl ?? this.bookSourceUrl,
      bookSourceName: bookSourceName ?? this.bookSourceName,
      bookSourceGroup: bookSourceGroup ?? this.bookSourceGroup,
      bookSourceType: bookSourceType ?? this.bookSourceType,
      bookUrlPattern: bookUrlPattern ?? this.bookUrlPattern,
      customOrder: customOrder ?? this.customOrder,
      enabled: enabled ?? this.enabled,
      enabledExplore: enabledExplore ?? this.enabledExplore,
      jsLib: jsLib ?? this.jsLib,
      engine: engine ?? this.engine,
      enabledCookieJar: enabledCookieJar ?? this.enabledCookieJar,
      concurrentRate: concurrentRate ?? this.concurrentRate,
      header: header ?? this.header,
      loginUrl: loginUrl ?? this.loginUrl,
      loginUi: loginUi ?? this.loginUi,
      loginCheckJs: loginCheckJs ?? this.loginCheckJs,
      coverDecodeJs: coverDecodeJs ?? this.coverDecodeJs,
      bookSourceComment: bookSourceComment ?? this.bookSourceComment,
      variableComment: variableComment ?? this.variableComment,
      lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
      respondTime: respondTime ?? this.respondTime,
      weight: weight ?? this.weight,
      searchUrl: searchUrl ?? this.searchUrl,
      exploreUrl: exploreUrl ?? this.exploreUrl,
      exploreScreen: exploreScreen ?? this.exploreScreen,
      ruleSearch: ruleSearch ?? this.ruleSearch,
      ruleExplore: ruleExplore ?? this.ruleExplore,
      ruleBookInfo: ruleBookInfo ?? this.ruleBookInfo,
      ruleToc: ruleToc ?? this.ruleToc,
      ruleContent: ruleContent ?? this.ruleContent,
      ruleReview: ruleReview ?? this.ruleReview,
      eventListener: eventListener ?? this.eventListener,
      customButton: customButton ?? this.customButton,
      nextPageLazyLoad: nextPageLazyLoad ?? this.nextPageLazyLoad,
    );
  }

  factory BookSource.fromJson(Map<String, dynamic> json) {
    final typeValue = json['bookSourceType'];
    final typeIndex =
        typeValue is int ? typeValue : int.tryParse('$typeValue') ?? 0;
    final ruleSearch = _asMap(json['ruleSearch']);
    final ruleExplore = _asMap(json['ruleExplore']);
    final ruleBookInfo = _asMap(json['ruleBookInfo']);
    final ruleToc = _asMap(json['ruleToc']);
    final ruleContent = _asMap(json['ruleContent']);
    final ruleReview = _asMap(json['ruleReview']);
    return BookSource(
      bookSourceUrl: json['bookSourceUrl'] as String? ?? '',
      bookSourceName: json['bookSourceName'] as String? ?? '',
      bookSourceGroup: json['bookSourceGroup'] as String?,
      bookSourceType: typeIndex >= 0 && typeIndex < BookSourceType.values.length
          ? BookSourceType.values[typeIndex]
          : BookSourceType.text,
      bookUrlPattern: json['bookUrlPattern'] as String?,
      customOrder: _asInt(json['customOrder']),
      enabled: _asBool(json['enabled'], defaultValue: true),
      enabledExplore: _asBool(json['enabledExplore'], defaultValue: true),
      jsLib: json['jsLib'] as String?,
      engine: json['engine'] as String?,
      enabledCookieJar: _asBool(json['enabledCookieJar'], defaultValue: true),
      concurrentRate: json['concurrentRate'] as String?,
      header: json['header'] as String?,
      loginUrl: json['loginUrl'] as String?,
      loginUi: json['loginUi'] as String?,
      loginCheckJs: json['loginCheckJs'] as String?,
      coverDecodeJs: json['coverDecodeJs'] as String?,
      bookSourceComment: json['bookSourceComment'] as String?,
      variableComment: json['variableComment'] as String?,
      lastUpdateTime: _asInt(json['lastUpdateTime']),
      respondTime: _asInt(json['respondTime'], defaultValue: 180000),
      weight: _asInt(json['weight']),
      searchUrl: json['searchUrl'] as String?,
      exploreUrl: json['exploreUrl'] as String?,
      exploreScreen: json['exploreScreen'] as String?,
      ruleSearch: ruleSearch == null ? null : SearchRule.fromJson(ruleSearch),
      ruleExplore:
          ruleExplore == null ? null : ExploreRule.fromJson(ruleExplore),
      ruleBookInfo:
          ruleBookInfo == null ? null : BookInfoRule.fromJson(ruleBookInfo),
      ruleToc: ruleToc == null ? null : TocRule.fromJson(ruleToc),
      ruleContent:
          ruleContent == null ? null : ContentRule.fromJson(ruleContent),
      ruleReview: ruleReview == null ? null : ReviewRule.fromJson(ruleReview),
      eventListener: _asBool(json['eventListener']),
      customButton: _asBool(json['customButton']),
      nextPageLazyLoad: _asBool(json['nextPageLazyLoad']),
    );
  }

  static int _asInt(dynamic value, {int defaultValue = 0}) {
    return value is int ? value : int.tryParse('$value') ?? defaultValue;
  }

  static bool _asBool(dynamic value, {bool defaultValue = false}) {
    if (value == null) return defaultValue;
    if (value is bool) return value;
    return '$value'.toLowerCase() == 'true' || '$value' == '1';
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is! Map) return null;
    return value.map((key, item) => MapEntry('$key', item));
  }

  Map<String, dynamic> toJson() {
    return {
      'bookSourceUrl': bookSourceUrl,
      'bookSourceName': bookSourceName,
      if (bookSourceGroup != null) 'bookSourceGroup': bookSourceGroup,
      'bookSourceType': bookSourceType.index,
      if (bookUrlPattern != null) 'bookUrlPattern': bookUrlPattern,
      'customOrder': customOrder,
      'enabled': enabled,
      'enabledExplore': enabledExplore,
      if (jsLib != null) 'jsLib': jsLib,
      if (engine != null) 'engine': engine,
      'enabledCookieJar': enabledCookieJar,
      if (concurrentRate != null) 'concurrentRate': concurrentRate,
      if (header != null) 'header': header,
      if (loginUrl != null) 'loginUrl': loginUrl,
      if (loginUi != null) 'loginUi': loginUi,
      if (loginCheckJs != null) 'loginCheckJs': loginCheckJs,
      if (coverDecodeJs != null) 'coverDecodeJs': coverDecodeJs,
      if (bookSourceComment != null) 'bookSourceComment': bookSourceComment,
      if (variableComment != null) 'variableComment': variableComment,
      'lastUpdateTime': lastUpdateTime,
      'respondTime': respondTime,
      'weight': weight,
      if (searchUrl != null) 'searchUrl': searchUrl,
      if (exploreUrl != null) 'exploreUrl': exploreUrl,
      if (exploreScreen != null) 'exploreScreen': exploreScreen,
      if (ruleSearch != null) 'ruleSearch': ruleSearch!.toJson(),
      if (ruleExplore != null) 'ruleExplore': ruleExplore!.toJson(),
      if (ruleBookInfo != null) 'ruleBookInfo': ruleBookInfo!.toJson(),
      if (ruleToc != null) 'ruleToc': ruleToc!.toJson(),
      if (ruleContent != null) 'ruleContent': ruleContent!.toJson(),
      if (ruleReview != null) 'ruleReview': ruleReview!.toJson(),
      if (eventListener) 'eventListener': eventListener,
      if (customButton) 'customButton': customButton,
      if (nextPageLazyLoad) 'nextPageLazyLoad': nextPageLazyLoad,
    };
  }

  /// 获取搜索规则（确保非空）
  SearchRule getSearchRule() {
    return ruleSearch ?? const SearchRule();
  }

  /// 获取发现规则（确保非空）
  ExploreRule getExploreRule() {
    return ruleExplore ?? const ExploreRule();
  }

  /// 获取书籍信息规则（确保非空）
  BookInfoRule getBookInfoRule() {
    return ruleBookInfo ?? const BookInfoRule();
  }

  /// 获取目录规则（确保非空）
  TocRule getTocRule() {
    return ruleToc ?? const TocRule();
  }

  /// 获取正文规则（确保非空）
  ContentRule getContentRule() {
    return ruleContent ?? const ContentRule();
  }

  /// 获取段评规则（确保非空）
  ReviewRule getReviewRule() {
    return ruleReview ?? const ReviewRule();
  }

  /// 解析书源级引擎声明
  JsEngineType? get engineType {
    if (engine == null) return null;
    switch (engine!.toLowerCase()) {
      case 'rhino':
        return JsEngineType.rhino;
      case 'quickjs':
        return JsEngineType.quickjs;
      default:
        return null;
    }
  }

  String get typeName {
    switch (bookSourceType) {
      case BookSourceType.text:
        return '小说';
      case BookSourceType.audio:
        return '音频';
      case BookSourceType.image:
        return '漫画';
      case BookSourceType.file:
        return '文件';
      case BookSourceType.video:
        return '视频';
    }
  }

  /// 获取显示名称（包含分组）
  String get displayName {
    if (bookSourceGroup == null || bookSourceGroup!.isEmpty) {
      return bookSourceName;
    }
    return '$bookSourceName ($bookSourceGroup)';
  }

  /// 解析请求头
  Map<String, String> getHeaderMap() {
    if (header == null || header!.isEmpty) {
      return {};
    }

    try {
      final decoded = jsonDecode(header!);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {
      // 尝试按行解析
      final headers = <String, String>{};
      for (final line in header!.split('\n')) {
        final parts = line.split(':');
        if (parts.length >= 2) {
          headers[parts[0].trim()] = parts.sublist(1).join(':').trim();
        }
      }
      return headers;
    }

    return {};
  }
}
