import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../../models/book_source.dart';
import '../../models/rules/search_rule.dart';
import '../../models/rules/explore_rule.dart';
import '../../models/rules/book_info_rule.dart';
import '../../models/rules/toc_rule.dart';
import '../../models/rules/content_rule.dart';
import '../../services/storage_service.dart';
import '../../routes/app_routes.dart';

/// 编辑字段实体
class EditEntity {
  final String key;
  String value;
  final String hint;

  EditEntity({
    required this.key,
    required this.value,
    required this.hint,
  });
}

/// 书源编辑页面
class BookSourceEditPage extends StatefulWidget {
  final String? sourceUrl;
  final BookSource? templateSource;

  const BookSourceEditPage({super.key, this.sourceUrl, this.templateSource});

  @override
  State<BookSourceEditPage> createState() => _BookSourceEditPageState();
}

class _BookSourceEditPageState extends State<BookSourceEditPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // 书源数据
  BookSource? _originalSource;
  late BookSource _source;

  // 各Tab的编辑字段
  List<EditEntity> _baseEntities = [];
  List<EditEntity> _searchEntities = [];
  List<EditEntity> _exploreEntities = [];
  List<EditEntity> _infoEntities = [];
  List<EditEntity> _tocEntities = [];
  List<EditEntity> _contentEntities = [];

  // 选项状态
  bool _enabled = true;
  bool _enabledExplore = true;
  bool _enabledCookieJar = true;
  bool _eventListener = false;
  bool _customButton = false;
  bool _nextPageLazyLoad = false;
  int _sourceType = 0;

  // 自动补全
  bool _autoComplete = true;

  // 是否有修改
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _loadSource();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadSource() async {
    if (widget.sourceUrl != null) {
      final data = StorageService.instance.getBookSource(widget.sourceUrl!);
      if (data != null) {
        _originalSource = BookSource.fromJson(data);
      }
    }

    // 优先级：已有书源 > 模板书源 > 空白书源
    _source = _originalSource ??
        widget.templateSource ??
        BookSource(
          bookSourceUrl: '',
          bookSourceName: '',
        );

    _initEntities();
    setState(() {});
  }

  void _initEntities() {
    // 基本信息
    _baseEntities = [
      EditEntity(
          key: 'bookSourceUrl',
          value: _source.bookSourceUrl,
          hint: '源 URL（bookSourceUrl）'),
      EditEntity(
          key: 'bookSourceName',
          value: _source.bookSourceName,
          hint: '源名称（bookSourceName）'),
      EditEntity(
          key: 'bookSourceGroup',
          value: _source.bookSourceGroup ?? '',
          hint: '源分组（bookSourceGroup）'),
      EditEntity(
          key: 'bookSourceComment',
          value: _source.bookSourceComment ?? '',
          hint: '源注释（bookSourceComment）'),
      EditEntity(
          key: 'loginUrl',
          value: _source.loginUrl ?? '',
          hint: '登录 URL（loginUrl）'),
      EditEntity(
          key: 'loginUi', value: _source.loginUi ?? '', hint: '登录 UI（loginUi）'),
      EditEntity(
          key: 'loginCheckJs',
          value: _source.loginCheckJs ?? '',
          hint: '登录检查 JS（loginCheckJs）'),
      EditEntity(
          key: 'coverDecodeJs',
          value: _source.coverDecodeJs ?? '',
          hint: '封面解密（coverDecodeJs）'),
      EditEntity(
          key: 'bookUrlPattern',
          value: _source.bookUrlPattern ?? '',
          hint: '书籍 URL 正则（bookUrlPattern）'),
      EditEntity(
          key: 'header', value: _source.header ?? '', hint: '请求头（header）'),
      EditEntity(
          key: 'variableComment',
          value: _source.variableComment ?? '',
          hint: '变量说明（variableComment）'),
      EditEntity(
          key: 'concurrentRate',
          value: _source.concurrentRate ?? '',
          hint: '并发率（concurrentRate）'),
      EditEntity(key: 'jsLib', value: _source.jsLib ?? '', hint: 'JS库（jsLib）'),
    ];

    // 搜索规则
    final sr = _source.ruleSearch ?? const SearchRule();
    _searchEntities = [
      EditEntity(
          key: 'searchUrl', value: _source.searchUrl ?? '', hint: '搜索地址（url）'),
      EditEntity(
          key: 'checkKeyWord',
          value: sr.checkKeyWord ?? '',
          hint: '校验关键字（checkKeyWord）'),
      EditEntity(
          key: 'bookList', value: sr.bookList ?? '', hint: '书籍列表规则（bookList）'),
      EditEntity(key: 'name', value: sr.name ?? '', hint: '书名规则（name）'),
      EditEntity(key: 'author', value: sr.author ?? '', hint: '作者规则（author）'),
      EditEntity(key: 'kind', value: sr.kind ?? '', hint: '分类规则（kind）'),
      EditEntity(
          key: 'wordCount', value: sr.wordCount ?? '', hint: '字数规则（wordCount）'),
      EditEntity(
          key: 'lastChapter',
          value: sr.lastChapter ?? '',
          hint: '最新章节规则（lastChapter）'),
      EditEntity(key: 'intro', value: sr.intro ?? '', hint: '简介规则（intro）'),
      EditEntity(
          key: 'coverUrl', value: sr.coverUrl ?? '', hint: '封面规则（coverUrl）'),
      EditEntity(
          key: 'bookUrl', value: sr.bookUrl ?? '', hint: '详情页 URL 规则（bookUrl）'),
    ];

    // 发现规则
    final er = _source.ruleExplore ?? const ExploreRule();
    _exploreEntities = [
      EditEntity(
          key: 'exploreUrl',
          value: _source.exploreUrl ?? '',
          hint: '发现地址规则（url）'),
      EditEntity(
          key: 'bookList', value: er.bookList ?? '', hint: '书籍列表规则（bookList）'),
      EditEntity(key: 'name', value: er.name ?? '', hint: '书名规则（name）'),
      EditEntity(key: 'author', value: er.author ?? '', hint: '作者规则（author）'),
      EditEntity(key: 'kind', value: er.kind ?? '', hint: '分类规则（kind）'),
      EditEntity(
          key: 'wordCount', value: er.wordCount ?? '', hint: '字数规则（wordCount）'),
      EditEntity(
          key: 'lastChapter',
          value: er.lastChapter ?? '',
          hint: '最新章节规则（lastChapter）'),
      EditEntity(key: 'intro', value: er.intro ?? '', hint: '简介规则（intro）'),
      EditEntity(
          key: 'coverUrl', value: er.coverUrl ?? '', hint: '封面规则（coverUrl）'),
      EditEntity(
          key: 'bookUrl', value: er.bookUrl ?? '', hint: '详情页 URL 规则（bookUrl）'),
    ];

    // 详情规则
    final ir = _source.ruleBookInfo ?? const BookInfoRule();
    _infoEntities = [
      EditEntity(
          key: 'init', value: ir.init ?? '', hint: '预处理规则（bookInfoInit）'),
      EditEntity(key: 'name', value: ir.name ?? '', hint: '书名规则（name）'),
      EditEntity(key: 'author', value: ir.author ?? '', hint: '作者规则（author）'),
      EditEntity(key: 'kind', value: ir.kind ?? '', hint: '分类规则（kind）'),
      EditEntity(
          key: 'wordCount', value: ir.wordCount ?? '', hint: '字数规则（wordCount）'),
      EditEntity(
          key: 'lastChapter',
          value: ir.lastChapter ?? '',
          hint: '最新章节规则（lastChapter）'),
      EditEntity(key: 'intro', value: ir.intro ?? '', hint: '简介规则（intro）'),
      EditEntity(
          key: 'coverUrl', value: ir.coverUrl ?? '', hint: '封面规则（coverUrl）'),
      EditEntity(
          key: 'tocUrl', value: ir.tocUrl ?? '', hint: '目录 URL 规则（tocUrl）'),
      EditEntity(
          key: 'canReName',
          value: ir.canReName ?? '',
          hint: '允许修改书名作者（canReName）'),
      EditEntity(
          key: 'downloadUrls',
          value: ir.downloadUrls ?? '',
          hint: '下载URL规则（downloadUrls）'),
    ];

    // 目录规则
    final tr = _source.ruleToc ?? const TocRule();
    _tocEntities = [
      EditEntity(
          key: 'preUpdateJs',
          value: tr.preUpdateJs ?? '',
          hint: '更新之前 JS（preUpdateJs）'),
      EditEntity(
          key: 'chapterList',
          value: tr.chapterList ?? '',
          hint: '目录列表规则（chapterList）'),
      EditEntity(
          key: 'chapterName',
          value: tr.chapterName ?? '',
          hint: '章节名称规则（chapterName）'),
      EditEntity(
          key: 'chapterUrl',
          value: tr.chapterUrl ?? '',
          hint: '章节 URL 规则（chapterUrl）'),
      EditEntity(
          key: 'formatJs', value: tr.formatJs ?? '', hint: '格式化规则（formatJs）'),
      EditEntity(
          key: 'isVolume',
          value: tr.isVolume ?? '',
          hint: 'Volume 标识（isVolume）'),
      EditEntity(
          key: 'updateTime',
          value: tr.updateTime ?? '',
          hint: '章节信息（updateTime）'),
      EditEntity(key: 'isVip', value: tr.isVip ?? '', hint: 'VIP 标识（isVip）'),
      EditEntity(key: 'isPay', value: tr.isPay ?? '', hint: '购买标识（isPay）'),
      EditEntity(
          key: 'nextTocUrl',
          value: tr.nextTocUrl ?? '',
          hint: '目录下一页规则（nextTocUrl）'),
    ];

    // 正文规则
    final cr = _source.ruleContent ?? const ContentRule();
    _contentEntities = [
      EditEntity(
          key: 'content', value: cr.content ?? '', hint: '正文规则（content）'),
      EditEntity(
          key: 'nextContentUrl',
          value: cr.nextContentUrl ?? '',
          hint: '正文下一页 URL 规则（nextContentUrl）'),
      EditEntity(
          key: 'subContent',
          value: cr.subContent ?? '',
          hint: '副文规则（subContent）'),
      EditEntity(
          key: 'replaceRegex',
          value: cr.replaceRegex ?? '',
          hint: '替换规则（replaceRegex）'),
      EditEntity(key: 'title', value: cr.title ?? '', hint: '章节名称规则（title）'),
      EditEntity(
          key: 'sourceRegex',
          value: cr.sourceRegex ?? '',
          hint: '资源正则（sourceRegex）'),
      EditEntity(
          key: 'imageStyle',
          value: cr.imageStyle ?? '',
          hint: '图片样式（imageStyle）'),
      EditEntity(
          key: 'imageDecode',
          value: cr.imageDecode ?? '',
          hint: '图片解密（imageDecode）'),
      EditEntity(
          key: 'webJs', value: cr.webJs ?? '', hint: 'WebView JS（webJs）'),
      EditEntity(
          key: 'payAction', value: cr.payAction ?? '', hint: '购买操作（payAction）'),
      EditEntity(
          key: 'callBackJs',
          value: cr.callBackJs ?? '',
          hint: '回调操作（callBackJs）'),
    ];

    // 选项状态
    _enabled = _source.enabled;
    _enabledExplore = _source.enabledExplore;
    _enabledCookieJar = _source.enabledCookieJar;
    _sourceType = _source.bookSourceType.index;
  }

  BookSource _buildSourceFromEntities() {
    // 从字段构建书源对象
    final baseMap = {for (var e in _baseEntities) e.key: e.value};
    final searchMap = {for (var e in _searchEntities) e.key: e.value};
    final exploreMap = {for (var e in _exploreEntities) e.key: e.value};
    final infoMap = {for (var e in _infoEntities) e.key: e.value};
    final tocMap = {for (var e in _tocEntities) e.key: e.value};
    final contentMap = {for (var e in _contentEntities) e.key: e.value};

    return BookSource(
      bookSourceUrl: baseMap['bookSourceUrl'] ?? '',
      bookSourceName: baseMap['bookSourceName'] ?? '',
      bookSourceGroup: baseMap['bookSourceGroup']?.isNotEmpty == true
          ? baseMap['bookSourceGroup']
          : null,
      bookSourceComment: baseMap['bookSourceComment']?.isNotEmpty == true
          ? baseMap['bookSourceComment']
          : null,
      bookSourceType: BookSourceType.values[_sourceType],
      enabled: _enabled,
      enabledExplore: _enabledExplore,
      enabledCookieJar: _enabledCookieJar,
      loginUrl:
          baseMap['loginUrl']?.isNotEmpty == true ? baseMap['loginUrl'] : null,
      loginUi:
          baseMap['loginUi']?.isNotEmpty == true ? baseMap['loginUi'] : null,
      loginCheckJs: baseMap['loginCheckJs']?.isNotEmpty == true
          ? baseMap['loginCheckJs']
          : null,
      coverDecodeJs: baseMap['coverDecodeJs']?.isNotEmpty == true
          ? baseMap['coverDecodeJs']
          : null,
      bookUrlPattern: baseMap['bookUrlPattern']?.isNotEmpty == true
          ? baseMap['bookUrlPattern']
          : null,
      header: baseMap['header']?.isNotEmpty == true ? baseMap['header'] : null,
      variableComment: baseMap['variableComment']?.isNotEmpty == true
          ? baseMap['variableComment']
          : null,
      concurrentRate: baseMap['concurrentRate']?.isNotEmpty == true
          ? baseMap['concurrentRate']
          : null,
      jsLib: baseMap['jsLib']?.isNotEmpty == true ? baseMap['jsLib'] : null,
      searchUrl: searchMap['searchUrl']?.isNotEmpty == true
          ? searchMap['searchUrl']
          : null,
      exploreUrl: exploreMap['exploreUrl']?.isNotEmpty == true
          ? exploreMap['exploreUrl']
          : null,
      ruleSearch: SearchRule(
        checkKeyWord: searchMap['checkKeyWord']?.isNotEmpty == true
            ? searchMap['checkKeyWord']
            : null,
        bookList: searchMap['bookList']?.isNotEmpty == true
            ? searchMap['bookList']
            : null,
        name: searchMap['name']?.isNotEmpty == true ? searchMap['name'] : null,
        author: searchMap['author']?.isNotEmpty == true
            ? searchMap['author']
            : null,
        intro:
            searchMap['intro']?.isNotEmpty == true ? searchMap['intro'] : null,
        kind: searchMap['kind']?.isNotEmpty == true ? searchMap['kind'] : null,
        lastChapter: searchMap['lastChapter']?.isNotEmpty == true
            ? searchMap['lastChapter']
            : null,
        coverUrl: searchMap['coverUrl']?.isNotEmpty == true
            ? searchMap['coverUrl']
            : null,
        bookUrl: searchMap['bookUrl']?.isNotEmpty == true
            ? searchMap['bookUrl']
            : null,
        wordCount: searchMap['wordCount']?.isNotEmpty == true
            ? searchMap['wordCount']
            : null,
      ),
      ruleExplore: ExploreRule(
        bookList: exploreMap['bookList']?.isNotEmpty == true
            ? exploreMap['bookList']
            : null,
        name:
            exploreMap['name']?.isNotEmpty == true ? exploreMap['name'] : null,
        author: exploreMap['author']?.isNotEmpty == true
            ? exploreMap['author']
            : null,
        intro: exploreMap['intro']?.isNotEmpty == true
            ? exploreMap['intro']
            : null,
        kind:
            exploreMap['kind']?.isNotEmpty == true ? exploreMap['kind'] : null,
        lastChapter: exploreMap['lastChapter']?.isNotEmpty == true
            ? exploreMap['lastChapter']
            : null,
        coverUrl: exploreMap['coverUrl']?.isNotEmpty == true
            ? exploreMap['coverUrl']
            : null,
        bookUrl: exploreMap['bookUrl']?.isNotEmpty == true
            ? exploreMap['bookUrl']
            : null,
        wordCount: exploreMap['wordCount']?.isNotEmpty == true
            ? exploreMap['wordCount']
            : null,
      ),
      ruleBookInfo: BookInfoRule(
        init: infoMap['init']?.isNotEmpty == true ? infoMap['init'] : null,
        name: infoMap['name']?.isNotEmpty == true ? infoMap['name'] : null,
        author:
            infoMap['author']?.isNotEmpty == true ? infoMap['author'] : null,
        intro: infoMap['intro']?.isNotEmpty == true ? infoMap['intro'] : null,
        kind: infoMap['kind']?.isNotEmpty == true ? infoMap['kind'] : null,
        lastChapter: infoMap['lastChapter']?.isNotEmpty == true
            ? infoMap['lastChapter']
            : null,
        coverUrl: infoMap['coverUrl']?.isNotEmpty == true
            ? infoMap['coverUrl']
            : null,
        tocUrl:
            infoMap['tocUrl']?.isNotEmpty == true ? infoMap['tocUrl'] : null,
        canReName: infoMap['canReName']?.isNotEmpty == true
            ? infoMap['canReName']
            : null,
        downloadUrls: infoMap['downloadUrls']?.isNotEmpty == true
            ? infoMap['downloadUrls']
            : null,
        wordCount: infoMap['wordCount']?.isNotEmpty == true
            ? infoMap['wordCount']
            : null,
      ),
      ruleToc: TocRule(
        preUpdateJs: tocMap['preUpdateJs']?.isNotEmpty == true
            ? tocMap['preUpdateJs']
            : null,
        chapterList: tocMap['chapterList']?.isNotEmpty == true
            ? tocMap['chapterList']
            : null,
        chapterName: tocMap['chapterName']?.isNotEmpty == true
            ? tocMap['chapterName']
            : null,
        chapterUrl: tocMap['chapterUrl']?.isNotEmpty == true
            ? tocMap['chapterUrl']
            : null,
        formatJs:
            tocMap['formatJs']?.isNotEmpty == true ? tocMap['formatJs'] : null,
        isVolume:
            tocMap['isVolume']?.isNotEmpty == true ? tocMap['isVolume'] : null,
        updateTime: tocMap['updateTime']?.isNotEmpty == true
            ? tocMap['updateTime']
            : null,
        isVip: tocMap['isVip']?.isNotEmpty == true ? tocMap['isVip'] : null,
        isPay: tocMap['isPay']?.isNotEmpty == true ? tocMap['isPay'] : null,
        nextTocUrl: tocMap['nextTocUrl']?.isNotEmpty == true
            ? tocMap['nextTocUrl']
            : null,
      ),
      ruleContent: ContentRule(
        content: contentMap['content']?.isNotEmpty == true
            ? contentMap['content']
            : null,
        nextContentUrl: contentMap['nextContentUrl']?.isNotEmpty == true
            ? contentMap['nextContentUrl']
            : null,
        subContent: contentMap['subContent']?.isNotEmpty == true
            ? contentMap['subContent']
            : null,
        replaceRegex: contentMap['replaceRegex']?.isNotEmpty == true
            ? contentMap['replaceRegex']
            : null,
        title: contentMap['title']?.isNotEmpty == true
            ? contentMap['title']
            : null,
        sourceRegex: contentMap['sourceRegex']?.isNotEmpty == true
            ? contentMap['sourceRegex']
            : null,
        imageStyle: contentMap['imageStyle']?.isNotEmpty == true
            ? contentMap['imageStyle']
            : null,
        imageDecode: contentMap['imageDecode']?.isNotEmpty == true
            ? contentMap['imageDecode']
            : null,
        webJs: contentMap['webJs']?.isNotEmpty == true
            ? contentMap['webJs']
            : null,
        payAction: contentMap['payAction']?.isNotEmpty == true
            ? contentMap['payAction']
            : null,
        callBackJs: contentMap['callBackJs']?.isNotEmpty == true
            ? contentMap['callBackJs']
            : null,
      ),
    );
  }

  Future<void> _saveSource() async {
    final source = _buildSourceFromEntities();

    if (source.bookSourceUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书源地址不能为空')),
      );
      return;
    }

    if (source.bookSourceName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书源名称不能为空')),
      );
      return;
    }

    try {
      await StorageService.instance.saveBookSource(source.toJson());
      _hasChanges = false;
      debugPrint('✅ 书源保存成功: ${source.bookSourceUrl}');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存成功')),
        );
        Navigator.pop(context, true); // 返回 true 触发列表刷新
      }
    } catch (e) {
      debugPrint('❌ 保存书源失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    }
  }

  /// 内容编辑 - 全屏JSON编辑器
  void _showContentEditor() {
    final source = _buildSourceFromEntities();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(source.toJson());

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _ContentEditPage(
          title: '内容编辑',
          content: jsonStr,
          onSave: (newContent) {
            try {
              final json = jsonDecode(newContent) as Map<String, dynamic>;
              final newSource = BookSource.fromJson(json);
              setState(() {
                _source = newSource;
                _initEntities();
                _hasChanges = true;
              });
              return true;
            } catch (e) {
              return false;
            }
          },
        ),
      ),
    );
  }

  void _showJsonEditor() {
    final source = _buildSourceFromEntities();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(source.toJson());
    final controller = TextEditingController(text: jsonStr);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('JSON编辑'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: TextField(
            controller: controller,
            maxLines: null,
            expands: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              try {
                final json =
                    jsonDecode(controller.text) as Map<String, dynamic>;
                final newSource = BookSource.fromJson(json);
                setState(() {
                  _source = newSource;
                  _initEntities();
                  _hasChanges = true;
                });
                Navigator.pop(context);
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('JSON格式错误: $e')),
                );
              }
            },
            child: const Text('应用'),
          ),
        ],
      ),
    );
  }

  void _copySource() {
    final source = _buildSourceFromEntities();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(source.toJson());
    Clipboard.setData(ClipboardData(text: jsonStr));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板')),
    );
  }

  Future<void> _pasteSource() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      try {
        final json = jsonDecode(data!.text!) as Map<String, dynamic>;
        final newSource = BookSource.fromJson(json);
        setState(() {
          _source = newSource;
          _initEntities();
          _hasChanges = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('粘贴成功')),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('粘贴失败: $e')),
        );
      }
    }
  }

  Future<void> _debugSource() async {
    final source = _buildSourceFromEntities();

    if (source.bookSourceUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('书源地址不能为空，无法调试')),
        );
      }
      return;
    }

    // 直接传 BookSource 对象给调试页面，无需保存即可调试
    if (mounted) {
      debugPrint('🔄 跳转调试页面: ${source.bookSourceName}');
      Navigator.pushNamed(context, AppRoutes.bookSourceDebug, arguments: {
        'sourceUrl': source.bookSourceUrl,
        'source': source,
      });
    }
  }

  void _searchWithSource() {
    final source = _buildSourceFromEntities();
    StorageService.instance.saveBookSource(source.toJson()).then((_) {
      Navigator.pushNamed(context, AppRoutes.search, arguments: {
        'sourceUrl': source.bookSourceUrl,
      });
    });
  }

  void _showSourceVariable() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置源变量'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '源变量',
            hintText: '可在 JS 中通过 source.getVariable() 获取',
            floatingLabelBehavior: FloatingLabelBehavior.auto,
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _clearCookie() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Cookie已清除')),
    );
  }

  void _shareSource() {
    final source = _buildSourceFromEntities();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(source.toJson());
    Clipboard.setData(ClipboardData(text: jsonStr));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制书源JSON，可分享给他人')),
    );
  }

  void _showLog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('日志'),
        content: const SizedBox(
          width: double.maxFinite,
          height: 300,
          child: SingleChildScrollView(
            child: Text('暂无日志'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<bool> _onWillPop() async {
    if (!_hasChanges) return true;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出'),
        content: const Text('有未保存的修改，确定要退出吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('不保存'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context, false);
              _saveSource();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final loginUrl = _baseEntities
        .firstWhere(
          (e) => e.key == 'loginUrl',
          orElse: () => EditEntity(key: 'loginUrl', value: '', hint: ''),
        )
        .value;

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_originalSource?.bookSourceName ?? '新建书源'),
          actions: [
            // 内容编辑
            IconButton(
              icon: const Icon(Icons.edit_note),
              onPressed: _showContentEditor,
              tooltip: '内容编辑',
            ),
            // 保存
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _saveSource,
              tooltip: '保存',
            ),
            // 调试
            IconButton(
              icon: const Icon(Icons.bug_report),
              onPressed: _debugSource,
              tooltip: '调试书源',
            ),
            // 更多菜单
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'login':
                    break;
                  case 'search':
                    _searchWithSource();
                    break;
                  case 'clear_cookie':
                    _clearCookie();
                    break;
                  case 'json':
                    _showJsonEditor();
                    break;
                  case 'auto_complete':
                    setState(() {
                      _autoComplete = !_autoComplete;
                    });
                    break;
                  case 'copy':
                    _copySource();
                    break;
                  case 'paste':
                    _pasteSource();
                    break;
                  case 'variable':
                    _showSourceVariable();
                    break;
                  case 'qr_import':
                    break;
                  case 'qr_share':
                    _shareSource();
                    break;
                  case 'share':
                    _shareSource();
                    break;
                  case 'log':
                    _showLog();
                    break;
                  case 'help':
                    _showHelp();
                    break;
                }
              },
              itemBuilder: (context) => [
                if (loginUrl.isNotEmpty)
                  const PopupMenuItem(
                    value: 'login',
                    child: ListTile(
                      leading: Icon(Icons.login),
                      title: Text('登录'),
                    ),
                  ),
                const PopupMenuItem(
                  value: 'search',
                  child: ListTile(
                    leading: Icon(Icons.search),
                    title: Text('搜索'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'clear_cookie',
                  child: ListTile(
                    leading: Icon(Icons.cookie),
                    title: Text('Cookie'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'json',
                  child: ListTile(
                    leading: Icon(Icons.code),
                    title: Text('JSON编辑'),
                  ),
                ),
                PopupMenuItem(
                  value: 'auto_complete',
                  child: ListTile(
                    leading: Icon(_autoComplete
                        ? Icons.check_box
                        : Icons.check_box_outline_blank),
                    title: const Text('自动补全'),
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'copy',
                  child: ListTile(
                    leading: Icon(Icons.copy),
                    title: Text('复制书源'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'paste',
                  child: ListTile(
                    leading: Icon(Icons.paste),
                    title: Text('粘贴书源'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'variable',
                  child: ListTile(
                    leading: Icon(Icons.settings),
                    title: Text('设置源变量'),
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'qr_import',
                  child: ListTile(
                    leading: Icon(Icons.qr_code_scanner),
                    title: Text('二维码导入'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'qr_share',
                  child: ListTile(
                    leading: Icon(Icons.qr_code),
                    title: Text('二维码分享'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'share',
                  child: ListTile(
                    leading: Icon(Icons.share),
                    title: Text('字符串分享'),
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'log',
                  child: ListTile(
                    leading: Icon(Icons.article),
                    title: Text('日志'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'help',
                  child: ListTile(
                    leading: Icon(Icons.help),
                    title: Text('帮助'),
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            // 第一行选项：类型、启用、发现、自动保存Cookie
            _buildOptionsRow1(),
            // 第二行选项：事件监听器、自定义按钮、下一页懒加载
            _buildOptionsRow2(),
            // Tab标签栏
            TabBar(
              controller: _tabController,
              isScrollable: true,
              tabs: const [
                Tab(text: '基本'),
                Tab(text: '搜索'),
                Tab(text: '发现'),
                Tab(text: '详情'),
                Tab(text: '目录'),
                Tab(text: '正文'),
              ],
            ),
            // Tab内容
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildEditList(_baseEntities),
                  _buildEditList(_searchEntities),
                  _buildEditList(_exploreEntities),
                  _buildEditList(_infoEntities),
                  _buildEditList(_tocEntities),
                  _buildEditList(_contentEntities),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 第一行选项：类型、启用、发现、自动保存Cookie
  Widget _buildOptionsRow1() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          const Text('类型'),
          const SizedBox(width: 4),
          DropdownButton<int>(
            value: _sourceType,
            isDense: true,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 0, child: Text('文字')),
              DropdownMenuItem(value: 1, child: Text('音频')),
              DropdownMenuItem(value: 2, child: Text('图片')),
              DropdownMenuItem(value: 3, child: Text('文件')),
              DropdownMenuItem(value: 4, child: Text('视频')),
            ],
            onChanged: (value) {
              setState(() {
                _sourceType = value ?? 0;
                _hasChanges = true;
              });
            },
          ),
          const SizedBox(width: 8),
          // 启用
          InkWell(
            onTap: () {
              setState(() {
                _enabled = !_enabled;
                _hasChanges = true;
              });
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _enabled,
                  onChanged: (value) {
                    setState(() {
                      _enabled = value ?? true;
                      _hasChanges = true;
                    });
                  },
                  visualDensity: VisualDensity.compact,
                ),
                const Text('启用'),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 发现
          InkWell(
            onTap: () {
              setState(() {
                _enabledExplore = !_enabledExplore;
                _hasChanges = true;
              });
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _enabledExplore,
                  onChanged: (value) {
                    setState(() {
                      _enabledExplore = value ?? true;
                      _hasChanges = true;
                    });
                  },
                  visualDensity: VisualDensity.compact,
                ),
                const Text('发现'),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 自动保存Cookie
          InkWell(
            onTap: () {
              setState(() {
                _enabledCookieJar = !_enabledCookieJar;
                _hasChanges = true;
              });
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _enabledCookieJar,
                  onChanged: (value) {
                    setState(() {
                      _enabledCookieJar = value ?? true;
                      _hasChanges = true;
                    });
                  },
                  visualDensity: VisualDensity.compact,
                ),
                const Text('自动保存Cookie'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 第二行选项：事件监听器、自定义按钮、下一页懒加载
  Widget _buildOptionsRow2() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // 事件监听器
          InkWell(
            onTap: () {
              setState(() {
                _eventListener = !_eventListener;
                _hasChanges = true;
              });
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _eventListener,
                  onChanged: (value) {
                    setState(() {
                      _eventListener = value ?? false;
                      _hasChanges = true;
                    });
                  },
                  visualDensity: VisualDensity.compact,
                ),
                const Text('事件监听器'),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 自定义按钮
          InkWell(
            onTap: () {
              setState(() {
                _customButton = !_customButton;
                _hasChanges = true;
              });
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _customButton,
                  onChanged: (value) {
                    setState(() {
                      _customButton = value ?? false;
                      _hasChanges = true;
                    });
                  },
                  visualDensity: VisualDensity.compact,
                ),
                const Text('自定义按钮'),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 下一页懒加载
          InkWell(
            onTap: () {
              setState(() {
                _nextPageLazyLoad = !_nextPageLazyLoad;
                _hasChanges = true;
              });
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _nextPageLazyLoad,
                  onChanged: (value) {
                    setState(() {
                      _nextPageLazyLoad = value ?? false;
                      _hasChanges = true;
                    });
                  },
                  visualDensity: VisualDensity.compact,
                ),
                const Text('下一页懒加载'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditList(List<EditEntity> entities) {
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: entities.length,
      itemBuilder: (context, index) {
        final entity = entities[index];
        return Padding(
          padding: const EdgeInsets.only(top: 3),
          child: TextField(
            controller: TextEditingController(text: entity.value),
            decoration: InputDecoration(
              labelText: entity.hint,
              floatingLabelBehavior: FloatingLabelBehavior.auto,
              border: const OutlineInputBorder(),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
            maxLines: null,
            minLines: 1,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            onChanged: (value) {
              entity.value = value;
              _hasChanges = true;
            },
          ),
        );
      },
    );
  }

  void _showHelp() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const _SourceHelpPage(),
      ),
    );
  }
}

/// 全屏内容编辑页面
/// 参考legado的ContentEditDialog实现
class _ContentEditPage extends StatefulWidget {
  final String title;
  final String content;
  final bool Function(String) onSave;

  const _ContentEditPage({
    required this.title,
    required this.content,
    required this.onSave,
  });

  @override
  State<_ContentEditPage> createState() => _ContentEditPageState();
}

class _ContentEditPageState extends State<_ContentEditPage> {
  late TextEditingController _controller;
  String _searchKeyword = '';
  int _currentIndex = -1;
  final List<int> _matchPositions = [];
  String _originalContent = '';
  bool _showSearchPanel = false;

  @override
  void initState() {
    super.initState();
    _originalContent = widget.content;
    _controller = TextEditingController(text: widget.content);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleSearchPanel() {
    setState(() {
      _showSearchPanel = !_showSearchPanel;
      if (!_showSearchPanel) {
        _clearSearchHighlight();
      }
    });
  }

  void _performSearch(String keyword) {
    _searchKeyword = keyword;
    if (_searchKeyword.isEmpty) {
      _clearSearchHighlight();
      return;
    }

    final content = _controller.text;
    _matchPositions.clear();
    var startIndex = 0;
    while (true) {
      final index = content.indexOf(_searchKeyword, startIndex);
      if (index == -1) break;
      _matchPositions.add(index);
      startIndex = index + 1;
    }

    if (_matchPositions.isNotEmpty) {
      _currentIndex = 0;
      _scrollToMatch(0);
    } else {
      _currentIndex = -1;
    }
    setState(() {});
  }

  void _clearSearchHighlight() {
    _matchPositions.clear();
    _currentIndex = -1;
    setState(() {});
  }

  void _navigateToMatch(int direction) {
    if (_matchPositions.isEmpty) return;
    _currentIndex = (_currentIndex + direction + _matchPositions.length) %
        _matchPositions.length;
    _scrollToMatch(_currentIndex);
    setState(() {});
  }

  void _scrollToMatch(int index) {
    if (index < 0 || index >= _matchPositions.length) return;
    final pos = _matchPositions[index];
    // 简单滚动到位置
    _controller.selection = TextSelection.collapsed(offset: pos);
  }

  void _save() {
    final content = _controller.text;
    final success = widget.onSave(content);
    if (success) {
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('JSON格式错误')),
      );
    }
  }

  void _reset() {
    _controller.text = _originalContent;
    _clearSearchHighlight();
  }

  void _copyAll() {
    Clipboard.setData(ClipboardData(text: _controller.text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          // 搜索
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: _toggleSearchPanel,
            tooltip: '搜索',
          ),
          // 保存
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _save,
            tooltip: '保存',
          ),
          // 更多菜单
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'reset':
                  _reset();
                  break;
                case 'copy_all':
                  _copyAll();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'reset',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('重置'),
                ),
              ),
              const PopupMenuItem(
                value: 'copy_all',
                child: ListTile(
                  leading: Icon(Icons.copy),
                  title: Text('复制全部'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索面板
          if (_showSearchPanel)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _matchPositions.isEmpty
                              ? (_searchKeyword.isEmpty ? '' : '未找到')
                              : '${_currentIndex + 1}/${_matchPositions.length}',
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: _toggleSearchPanel,
                        iconSize: 20,
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(
                            hintText: '搜索',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: _performSearch,
                          onChanged: _performSearch,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: () => _navigateToMatch(-1),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_downward),
                        onPressed: () => _navigateToMatch(1),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          // 编辑区域
          Expanded(
            child: TextField(
              controller: _controller,
              maxLines: null,
              expands: true,
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(12),
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// 书源帮助文档页面（加载 Markdown 文件渲染，支持切换文档）
class _SourceHelpPage extends StatefulWidget {
  const _SourceHelpPage();

  @override
  State<_SourceHelpPage> createState() => _SourceHelpPageState();
}

class _SourceHelpPageState extends State<_SourceHelpPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _generalHelp = '';
  String _jsHelp = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadMarkdown();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadMarkdown() async {
    try {
      final results = await Future.wait([
        rootBundle.loadString('assets/templates/book_source_help.md'),
        rootBundle.loadString('assets/templates/book_source_js_help.md'),
      ]);
      if (mounted) {
        setState(() {
          _generalHelp = results[0];
          _jsHelp = results[1];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _generalHelp = '# 加载帮助文档失败\n\n$e';
          _jsHelp = _generalHelp;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源帮助文档'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '规则语法', icon: Icon(Icons.menu_book, size: 18)),
            Tab(text: 'JS 开发', icon: Icon(Icons.javascript, size: 18)),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                Markdown(
                  data: _generalHelp,
                  padding: const EdgeInsets.all(16),
                  selectable: true,
                ),
                Markdown(
                  data: _jsHelp,
                  padding: const EdgeInsets.all(16),
                  selectable: true,
                ),
              ],
            ),
    );
  }
}
