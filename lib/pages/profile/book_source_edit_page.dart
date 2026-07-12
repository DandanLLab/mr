import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../models/book_source.dart';
import '../../models/rules/search_rule.dart';
import '../../models/rules/explore_rule.dart';
import '../../models/rules/book_info_rule.dart';
import '../../models/rules/toc_rule.dart';
import '../../models/rules/content_rule.dart';
import '../../services/storage_service.dart';
import '../../services/cookie_service.dart';
import '../../services/app_logger.dart';
import '../../routes/app_routes.dart';
import '../../widgets/keyboard_assist_toolbar.dart';

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
    with SingleTickerProviderStateMixin, KeyboardAssistCallback {
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

  // 缓存 TextEditingController
  final Map<String, TextEditingController> _controllers = {};

  // 当前焦点的输入框
  TextEditingController? _focusedController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _loadSource();
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
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
    _source = _originalSource ?? widget.templateSource ?? BookSource(
      bookSourceUrl: '',
      bookSourceName: '',
    );

    // 从已有书源加载开关状态
    _enabled = _source.enabled;
    _enabledExplore = _source.enabledExplore;
    _enabledCookieJar = _source.enabledCookieJar;
    _eventListener = _source.eventListener;
    _customButton = _source.customButton;
    _nextPageLazyLoad = _source.nextPageLazyLoad;
    _sourceType = _source.bookSourceType.index;

    _initEntities();
    setState(() {});
  }

  void _initEntities() {
    // 基本信息
    _baseEntities = [
      EditEntity(key: 'bookSourceUrl', value: _source.bookSourceUrl, hint: '源 URL（bookSourceUrl）'),
      EditEntity(key: 'bookSourceName', value: _source.bookSourceName, hint: '源名称（bookSourceName）'),
      EditEntity(key: 'bookSourceGroup', value: _source.bookSourceGroup ?? '', hint: '源分组（bookSourceGroup）'),
      EditEntity(key: 'bookSourceComment', value: _source.bookSourceComment ?? '', hint: '源注释（bookSourceComment）'),
      EditEntity(key: 'loginUrl', value: _source.loginUrl ?? '', hint: '登录 URL（loginUrl）'),
      EditEntity(key: 'loginUi', value: _source.loginUi ?? '', hint: '登录 UI（loginUi）'),
      EditEntity(key: 'loginCheckJs', value: _source.loginCheckJs ?? '', hint: '登录检查 JS（loginCheckJs）'),
      EditEntity(key: 'coverDecodeJs', value: _source.coverDecodeJs ?? '', hint: '封面解密（coverDecodeJs）'),
      EditEntity(key: 'bookUrlPattern', value: _source.bookUrlPattern ?? '', hint: '书籍 URL 正则（bookUrlPattern）'),
      EditEntity(key: 'header', value: _source.header ?? '', hint: '请求头（header）'),
      EditEntity(key: 'variableComment', value: _source.variableComment ?? '', hint: '变量说明（variableComment）'),
      EditEntity(key: 'concurrentRate', value: _source.concurrentRate ?? '', hint: '并发率（concurrentRate）'),
      EditEntity(key: 'jsLib', value: _source.jsLib ?? '', hint: 'JS库（jsLib）'),
    ];

    // 搜索规则
    final sr = _source.ruleSearch ?? const SearchRule();
    _searchEntities = [
      EditEntity(key: 'searchUrl', value: _source.searchUrl ?? '', hint: '搜索地址（url）'),
      EditEntity(key: 'checkKeyWord', value: sr.checkKeyWord ?? '', hint: '校验关键字（checkKeyWord）'),
      EditEntity(key: 'bookList', value: sr.bookList ?? '', hint: '书籍列表规则（bookList）'),
      EditEntity(key: 'name', value: sr.name ?? '', hint: '书名规则（name）'),
      EditEntity(key: 'author', value: sr.author ?? '', hint: '作者规则（author）'),
      EditEntity(key: 'kind', value: sr.kind ?? '', hint: '分类规则（kind）'),
      EditEntity(key: 'wordCount', value: sr.wordCount ?? '', hint: '字数规则（wordCount）'),
      EditEntity(key: 'lastChapter', value: sr.lastChapter ?? '', hint: '最新章节规则（lastChapter）'),
      EditEntity(key: 'intro', value: sr.intro ?? '', hint: '简介规则（intro）'),
      EditEntity(key: 'coverUrl', value: sr.coverUrl ?? '', hint: '封面规则（coverUrl）'),
      EditEntity(key: 'bookUrl', value: sr.bookUrl ?? '', hint: '详情页 URL 规则（bookUrl）'),
    ];

    // 发现规则
    final er = _source.ruleExplore ?? const ExploreRule();
    _exploreEntities = [
      EditEntity(key: 'exploreUrl', value: _source.exploreUrl ?? '', hint: '发现地址规则（url）'),
      EditEntity(key: 'bookList', value: er.bookList ?? '', hint: '书籍列表规则（bookList）'),
      EditEntity(key: 'name', value: er.name ?? '', hint: '书名规则（name）'),
      EditEntity(key: 'author', value: er.author ?? '', hint: '作者规则（author）'),
      EditEntity(key: 'kind', value: er.kind ?? '', hint: '分类规则（kind）'),
      EditEntity(key: 'wordCount', value: er.wordCount ?? '', hint: '字数规则（wordCount）'),
      EditEntity(key: 'lastChapter', value: er.lastChapter ?? '', hint: '最新章节规则（lastChapter）'),
      EditEntity(key: 'intro', value: er.intro ?? '', hint: '简介规则（intro）'),
      EditEntity(key: 'coverUrl', value: er.coverUrl ?? '', hint: '封面规则（coverUrl）'),
      EditEntity(key: 'bookUrl', value: er.bookUrl ?? '', hint: '详情页 URL 规则（bookUrl）'),
    ];

    // 详情规则
    final ir = _source.ruleBookInfo ?? const BookInfoRule();
    _infoEntities = [
      EditEntity(key: 'init', value: ir.init ?? '', hint: '预处理规则（bookInfoInit）'),
      EditEntity(key: 'name', value: ir.name ?? '', hint: '书名规则（name）'),
      EditEntity(key: 'author', value: ir.author ?? '', hint: '作者规则（author）'),
      EditEntity(key: 'kind', value: ir.kind ?? '', hint: '分类规则（kind）'),
      EditEntity(key: 'wordCount', value: ir.wordCount ?? '', hint: '字数规则（wordCount）'),
      EditEntity(key: 'lastChapter', value: ir.lastChapter ?? '', hint: '最新章节规则（lastChapter）'),
      EditEntity(key: 'intro', value: ir.intro ?? '', hint: '简介规则（intro）'),
      EditEntity(key: 'coverUrl', value: ir.coverUrl ?? '', hint: '封面规则（coverUrl）'),
      EditEntity(key: 'tocUrl', value: ir.tocUrl ?? '', hint: '目录 URL 规则（tocUrl）'),
      EditEntity(key: 'canReName', value: ir.canReName ?? '', hint: '允许修改书名作者（canReName）'),
      EditEntity(key: 'downloadUrls', value: ir.downloadUrls ?? '', hint: '下载URL规则（downloadUrls）'),
    ];

    // 目录规则
    final tr = _source.ruleToc ?? const TocRule();
    _tocEntities = [
      EditEntity(key: 'preUpdateJs', value: tr.preUpdateJs ?? '', hint: '更新之前 JS（preUpdateJs）'),
      EditEntity(key: 'chapterList', value: tr.chapterList ?? '', hint: '目录列表规则（chapterList）'),
      EditEntity(key: 'chapterName', value: tr.chapterName ?? '', hint: '章节名称规则（chapterName）'),
      EditEntity(key: 'chapterUrl', value: tr.chapterUrl ?? '', hint: '章节 URL 规则（chapterUrl）'),
      EditEntity(key: 'formatJs', value: tr.formatJs ?? '', hint: '格式化规则（formatJs）'),
      EditEntity(key: 'isVolume', value: tr.isVolume ?? '', hint: 'Volume 标识（isVolume）'),
      EditEntity(key: 'updateTime', value: tr.updateTime ?? '', hint: '章节信息（updateTime）'),
      EditEntity(key: 'isVip', value: tr.isVip ?? '', hint: 'VIP 标识（isVip）'),
      EditEntity(key: 'isPay', value: tr.isPay ?? '', hint: '购买标识（isPay）'),
      EditEntity(key: 'nextTocUrl', value: tr.nextTocUrl ?? '', hint: '目录下一页规则（nextTocUrl）'),
    ];

    // 正文规则
    final cr = _source.ruleContent ?? const ContentRule();
    _contentEntities = [
      EditEntity(key: 'content', value: cr.content ?? '', hint: '正文规则（content）'),
      EditEntity(key: 'nextContentUrl', value: cr.nextContentUrl ?? '', hint: '正文下一页 URL 规则（nextContentUrl）'),
      EditEntity(key: 'subContent', value: cr.subContent ?? '', hint: '副文规则（subContent）'),
      EditEntity(key: 'replaceRegex', value: cr.replaceRegex ?? '', hint: '替换规则（replaceRegex）'),
      EditEntity(key: 'title', value: cr.title ?? '', hint: '章节名称规则（title）'),
      EditEntity(key: 'sourceRegex', value: cr.sourceRegex ?? '', hint: '资源正则（sourceRegex）'),
      EditEntity(key: 'imageStyle', value: cr.imageStyle ?? '', hint: '图片样式（imageStyle）'),
      EditEntity(key: 'imageDecode', value: cr.imageDecode ?? '', hint: '图片解密（imageDecode）'),
      EditEntity(key: 'webJs', value: cr.webJs ?? '', hint: 'WebView JS（webJs）'),
      EditEntity(key: 'payAction', value: cr.payAction ?? '', hint: '购买操作（payAction）'),
      EditEntity(key: 'callBackJs', value: cr.callBackJs ?? '', hint: '回调操作（callBackJs）'),
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
      bookSourceGroup: baseMap['bookSourceGroup']?.isNotEmpty == true ? baseMap['bookSourceGroup'] : null,
      bookSourceComment: baseMap['bookSourceComment']?.isNotEmpty == true ? baseMap['bookSourceComment'] : null,
      bookSourceType: BookSourceType.values[_sourceType],
      enabled: _enabled,
      enabledExplore: _enabledExplore,
      enabledCookieJar: _enabledCookieJar,
      loginUrl: baseMap['loginUrl']?.isNotEmpty == true ? baseMap['loginUrl'] : null,
      loginUi: baseMap['loginUi']?.isNotEmpty == true ? baseMap['loginUi'] : null,
      loginCheckJs: baseMap['loginCheckJs']?.isNotEmpty == true ? baseMap['loginCheckJs'] : null,
      coverDecodeJs: baseMap['coverDecodeJs']?.isNotEmpty == true ? baseMap['coverDecodeJs'] : null,
      bookUrlPattern: baseMap['bookUrlPattern']?.isNotEmpty == true ? baseMap['bookUrlPattern'] : null,
      header: baseMap['header']?.isNotEmpty == true ? baseMap['header'] : null,
      variableComment: baseMap['variableComment']?.isNotEmpty == true ? baseMap['variableComment'] : null,
      concurrentRate: baseMap['concurrentRate']?.isNotEmpty == true ? baseMap['concurrentRate'] : null,
      jsLib: baseMap['jsLib']?.isNotEmpty == true ? baseMap['jsLib'] : null,
      searchUrl: searchMap['searchUrl']?.isNotEmpty == true ? searchMap['searchUrl'] : null,
      exploreUrl: exploreMap['exploreUrl']?.isNotEmpty == true ? exploreMap['exploreUrl'] : null,
      ruleSearch: SearchRule(
        checkKeyWord: searchMap['checkKeyWord']?.isNotEmpty == true ? searchMap['checkKeyWord'] : null,
        bookList: searchMap['bookList']?.isNotEmpty == true ? searchMap['bookList'] : null,
        name: searchMap['name']?.isNotEmpty == true ? searchMap['name'] : null,
        author: searchMap['author']?.isNotEmpty == true ? searchMap['author'] : null,
        intro: searchMap['intro']?.isNotEmpty == true ? searchMap['intro'] : null,
        kind: searchMap['kind']?.isNotEmpty == true ? searchMap['kind'] : null,
        lastChapter: searchMap['lastChapter']?.isNotEmpty == true ? searchMap['lastChapter'] : null,
        coverUrl: searchMap['coverUrl']?.isNotEmpty == true ? searchMap['coverUrl'] : null,
        bookUrl: searchMap['bookUrl']?.isNotEmpty == true ? searchMap['bookUrl'] : null,
        wordCount: searchMap['wordCount']?.isNotEmpty == true ? searchMap['wordCount'] : null,
      ),
      ruleExplore: ExploreRule(
        bookList: exploreMap['bookList']?.isNotEmpty == true ? exploreMap['bookList'] : null,
        name: exploreMap['name']?.isNotEmpty == true ? exploreMap['name'] : null,
        author: exploreMap['author']?.isNotEmpty == true ? exploreMap['author'] : null,
        intro: exploreMap['intro']?.isNotEmpty == true ? exploreMap['intro'] : null,
        kind: exploreMap['kind']?.isNotEmpty == true ? exploreMap['kind'] : null,
        lastChapter: exploreMap['lastChapter']?.isNotEmpty == true ? exploreMap['lastChapter'] : null,
        coverUrl: exploreMap['coverUrl']?.isNotEmpty == true ? exploreMap['coverUrl'] : null,
        bookUrl: exploreMap['bookUrl']?.isNotEmpty == true ? exploreMap['bookUrl'] : null,
        wordCount: exploreMap['wordCount']?.isNotEmpty == true ? exploreMap['wordCount'] : null,
      ),
      ruleBookInfo: BookInfoRule(
        init: infoMap['init']?.isNotEmpty == true ? infoMap['init'] : null,
        name: infoMap['name']?.isNotEmpty == true ? infoMap['name'] : null,
        author: infoMap['author']?.isNotEmpty == true ? infoMap['author'] : null,
        intro: infoMap['intro']?.isNotEmpty == true ? infoMap['intro'] : null,
        kind: infoMap['kind']?.isNotEmpty == true ? infoMap['kind'] : null,
        lastChapter: infoMap['lastChapter']?.isNotEmpty == true ? infoMap['lastChapter'] : null,
        coverUrl: infoMap['coverUrl']?.isNotEmpty == true ? infoMap['coverUrl'] : null,
        tocUrl: infoMap['tocUrl']?.isNotEmpty == true ? infoMap['tocUrl'] : null,
        canReName: infoMap['canReName']?.isNotEmpty == true ? infoMap['canReName'] : null,
        downloadUrls: infoMap['downloadUrls']?.isNotEmpty == true ? infoMap['downloadUrls'] : null,
        wordCount: infoMap['wordCount']?.isNotEmpty == true ? infoMap['wordCount'] : null,
      ),
      ruleToc: TocRule(
        preUpdateJs: tocMap['preUpdateJs']?.isNotEmpty == true ? tocMap['preUpdateJs'] : null,
        chapterList: tocMap['chapterList']?.isNotEmpty == true ? tocMap['chapterList'] : null,
        chapterName: tocMap['chapterName']?.isNotEmpty == true ? tocMap['chapterName'] : null,
        chapterUrl: tocMap['chapterUrl']?.isNotEmpty == true ? tocMap['chapterUrl'] : null,
        formatJs: tocMap['formatJs']?.isNotEmpty == true ? tocMap['formatJs'] : null,
        isVolume: tocMap['isVolume']?.isNotEmpty == true ? tocMap['isVolume'] : null,
        updateTime: tocMap['updateTime']?.isNotEmpty == true ? tocMap['updateTime'] : null,
        isVip: tocMap['isVip']?.isNotEmpty == true ? tocMap['isVip'] : null,
        isPay: tocMap['isPay']?.isNotEmpty == true ? tocMap['isPay'] : null,
        nextTocUrl: tocMap['nextTocUrl']?.isNotEmpty == true ? tocMap['nextTocUrl'] : null,
      ),
      ruleContent: ContentRule(
        content: contentMap['content']?.isNotEmpty == true ? contentMap['content'] : null,
        nextContentUrl: contentMap['nextContentUrl']?.isNotEmpty == true ? contentMap['nextContentUrl'] : null,
        subContent: contentMap['subContent']?.isNotEmpty == true ? contentMap['subContent'] : null,
        replaceRegex: contentMap['replaceRegex']?.isNotEmpty == true ? contentMap['replaceRegex'] : null,
        title: contentMap['title']?.isNotEmpty == true ? contentMap['title'] : null,
        sourceRegex: contentMap['sourceRegex']?.isNotEmpty == true ? contentMap['sourceRegex'] : null,
        imageStyle: contentMap['imageStyle']?.isNotEmpty == true ? contentMap['imageStyle'] : null,
        imageDecode: contentMap['imageDecode']?.isNotEmpty == true ? contentMap['imageDecode'] : null,
        webJs: contentMap['webJs']?.isNotEmpty == true ? contentMap['webJs'] : null,
        payAction: contentMap['payAction']?.isNotEmpty == true ? contentMap['payAction'] : null,
        callBackJs: contentMap['callBackJs']?.isNotEmpty == true ? contentMap['callBackJs'] : null,
      ),
      eventListener: _eventListener,
      customButton: _customButton,
      nextPageLazyLoad: _nextPageLazyLoad,
      // 保留原始书源的 variable/engine/sourceFormat 字段，避免保存时丢失
      variable: _source.variable,
      engine: _source.engine,
      sourceFormat: _source.sourceFormat,
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
        Navigator.pop(context, true);  // 返回 true 触发列表刷新
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
                _updateAllControllers();
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
                final json = jsonDecode(controller.text) as Map<String, dynamic>;
                final newSource = BookSource.fromJson(json);
                setState(() {
                  _source = newSource;
                  _initEntities();
                  _updateAllControllers();
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
          _updateAllControllers();
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
    final currentVariable = _source.variable ?? '';
    final controller = TextEditingController(text: currentVariable);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置源变量'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '源变量可在JS中通过source.getVariable()获取',
            border: OutlineInputBorder(),
          ),
          maxLines: 5,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final value = controller.text;
              Navigator.pop(context);
              setState(() {
                _source = _source.copyWith(variable: value);
                _hasChanges = true;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('源变量已设置')),
              );
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 二维码导入书源
  void _importFromQr() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _QrImportPage(
          onScanned: (String jsonStr) {
            try {
              final json = jsonDecode(jsonStr) as Map<String, dynamic>;
              final newSource = BookSource.fromJson(json);
              setState(() {
                _source = newSource;
                _initEntities();
                _updateAllControllers();
                _hasChanges = true;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('导入成功')),
              );
              return true;
            } catch (e) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('导入失败: $e')),
              );
              return false;
            }
          },
        ),
      ),
    );
  }

  /// 登录书源
  void _loginWithSource() {
    final source = _buildSourceFromEntities();
    final loginUrl = source.loginUrl;

    if (loginUrl == null || loginUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该书源未配置登录地址')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _SourceLoginPage(
          source: source,
          onLoginSuccess: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('登录成功')),
            );
          },
        ),
      ),
    );
  }

  Future<void> _clearCookie() async {
    final source = _buildSourceFromEntities();
    final url = source.bookSourceUrl;

    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书源地址为空，无法清除Cookie')),
      );
      return;
    }

    try {
      await CookieService.instance.removeCookie(url);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cookie已清除')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清除Cookie失败: $e')),
        );
      }
    }
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
    final allLogs = AppLogger.instance.logs;
    // 只显示最新 500 条，避免 3 万条日志炸 UI
    final logs = allLogs.length > 500 ? allLogs.sublist(allLogs.length - 500) : allLogs;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('日志'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: logs.isEmpty
              ? const Center(child: Text('暂无日志'))
              : ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (context, index) {
                    final log = logs[index];
                    return ListTile(
                      dense: true,
                      leading: Text(log.levelIcon),
                      title: Text(
                        log.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        '${log.category.label} ${log.time.hour}:${log.time.minute.toString().padLeft(2, '0')}:${log.time.second.toString().padLeft(2, '0')}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          if (logs.isNotEmpty)
            TextButton(
              onPressed: () {
                AppLogger.instance.clear();
                Navigator.pop(context);
              },
              child: const Text('清空'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmExit() async {
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
            onPressed: () async {
              Navigator.pop(context, false);
              await _saveSource();
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
    final loginUrl = _baseEntities.firstWhere(
      (e) => e.key == 'loginUrl',
      orElse: () => EditEntity(key: 'loginUrl', value: '', hint: ''),
    ).value;

    return PopScope(
      canPop: !_hasChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _confirmExit();
        if (shouldPop && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        // 设置为 false，让键盘覆盖内容
        // 辅助按键工具栏使用 Positioned 定位在键盘上方
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: const Text('编辑书源', overflow: TextOverflow.visible, style: TextStyle(fontWeight: FontWeight.w500)),
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
              tooltip: '更多选项',
              offset: const Offset(0, 48),
              onSelected: (value) {
                switch (value) {
                  case 'save':
                    _saveSource();
                    break;
                  case 'debug':
                    _debugSource();
                    break;
                  case 'login':
                    _loginWithSource();
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
                    _importFromQr();
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
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    height: 48,
                    child: Row(children: [Icon(Icons.login, size: 18), SizedBox(width: 12), Text('登录')]),
                  ),
                const PopupMenuItem(
                  value: 'search',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.search, size: 18), SizedBox(width: 12), Text('搜索')]),
                ),
                const PopupMenuItem(
                  value: 'clear_cookie',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.cookie, size: 18), SizedBox(width: 12), Text('清除Cookie')]),
                ),
                const PopupMenuItem(
                  value: 'json',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.code, size: 18), SizedBox(width: 12), Text('JSON编辑')]),
                ),
                PopupMenuItem(
                  value: 'auto_complete',
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(_autoComplete ? Icons.check_box : Icons.check_box_outline_blank, size: 18), const SizedBox(width: 12), const Text('自动补全')]),
                ),
                const PopupMenuItem(
                  value: 'copy',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.copy, size: 18), SizedBox(width: 12), Text('拷贝源')]),
                ),
                const PopupMenuItem(
                  value: 'paste',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.paste, size: 18), SizedBox(width: 12), Text('粘贴源')]),
                ),
                const PopupMenuItem(
                  value: 'variable',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.settings, size: 18), SizedBox(width: 12), Text('设置源变量')]),
                ),
                const PopupMenuItem(
                  value: 'qr_import',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.qr_code_scanner, size: 18), SizedBox(width: 12), Text('二维码导入')]),
                ),
                const PopupMenuItem(
                  value: 'qr_share',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.copy, size: 18), SizedBox(width: 12), Text('复制书源JSON')]),
                ),
                const PopupMenuItem(
                  value: 'share',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.share, size: 18), SizedBox(width: 12), Text('字符串分享')]),
                ),
                const PopupMenuItem(
                  value: 'save',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.save, size: 18), SizedBox(width: 12), Text('保存')]),
                ),
                const PopupMenuItem(
                  value: 'debug',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.bug_report, size: 18), SizedBox(width: 12), Text('调试')]),
                ),
                const PopupMenuItem(
                  value: 'log',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.article, size: 18), SizedBox(width: 12), Text('日志')]),
                ),
                const PopupMenuItem(
                  value: 'help',
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  height: 48,
                  child: Row(children: [Icon(Icons.help, size: 18), SizedBox(width: 12), Text('帮助')]),
                ),
              ],
            ),
          ],
        ),
        body: Stack(
          children: [
            // 主内容
            Column(
              children: [
                // 第一行选项：类型、启用、发现、自动保存Cookie
                _buildOptionsRow1(),
                // 第二行选项：事件监听器、自定义按钮、下一页懒加载
                _buildOptionsRow2(),
                // Tab标签栏
                TabBar(
                  controller: _tabController,
                  isScrollable: false,
                  labelPadding: EdgeInsets.zero,
                  labelStyle: const TextStyle(fontSize: 13),
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
                      _buildEditList(_baseEntities, 'base'),
                      _buildEditList(_searchEntities, 'search'),
                      _buildEditList(_exploreEntities, 'explore'),
                      _buildEditList(_infoEntities, 'info'),
                      _buildEditList(_tocEntities, 'toc'),
                      _buildEditList(_contentEntities, 'content'),
                    ],
                  ),
                ),
              ],
            ),
            // 辅助按键工具栏 - 显示在键盘上方
            // 与原版 legados 逻辑一致：键盘高度超过屏幕五分之一时显示
            // 使用 Positioned 定位，bottom = 键盘高度
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).viewInsets.bottom,
              child: Material(
                color: Colors.transparent,
                child: KeyboardAssistToolbar(
                  callback: this,
                  assistItems: DefaultKeyboardAssists.defaultItems,
                  showUndoRedo: false,
                  keyboardHeight: MediaQuery.of(context).viewInsets.bottom,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 第一行选项：类型、启用、发现、自动保存Cookie
  Widget _buildOptionsRow1() {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Row(
        children: [
          const Text('类型：'),
          const SizedBox(width: 12),
          PopupMenuButton<int>(
            initialValue: _sourceType,
            tooltip: '选择类型',
            offset: const Offset(0, 24),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 60, maxWidth: 80),
            onSelected: (value) {
              setState(() {
                _sourceType = value;
                _hasChanges = true;
              });
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 0, child: Text('文字')),
              PopupMenuItem(value: 1, child: Text('音频')),
              PopupMenuItem(value: 2, child: Text('图片')),
              PopupMenuItem(value: 3, child: Text('文件')),
              PopupMenuItem(value: 4, child: Text('视频')),
            ],
            child: UnderlineWidget(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(['文字', '音频', '图片', '文件', '视频'][_sourceType]),
                  const Icon(Icons.arrow_drop_down, size: 20),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
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
                  visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const Text('启用'),
              ],
            ),
          ),
          const SizedBox(width: 12),
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
                  visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const Text('发现'),
              ],
            ),
          ),
          const SizedBox(width: 12),
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
                  visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const Text('Cookie'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 第二行选项：事件监听器、自定义按钮、下一页懒加载
  Widget _buildOptionsRow2() {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
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
                  visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const Text('事件监听'),
              ],
            ),
          ),
          const SizedBox(width: 12),
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
                  visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const Text('自定义按钮'),
              ],
            ),
          ),
          const SizedBox(width: 12),
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
                  visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                const Text('下一页懒加载'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditList(List<EditEntity> entities, String tabPrefix) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: entities.length,
      itemBuilder: (context, index) {
        final entity = entities[index];
        final controllerKey = '${tabPrefix}_${entity.key}';
        final controller = _getControllerByKey(controllerKey, entity.value);

        return TextFormField(
          controller: controller,
          decoration: InputDecoration(
            labelText: entity.hint,
            floatingLabelBehavior: FloatingLabelBehavior.auto,
            isDense: true,
            contentPadding: const EdgeInsets.only(top: 8, bottom: 4),
          ),
          maxLines: null,
          minLines: 1,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          onChanged: (value) {
            entity.value = value;
            _hasChanges = true;
          },
          onTap: () {
            // 记录当前焦点的输入框
            _focusedController = controller;
          },
        );
      },
    );
  }

  TextEditingController _getControllerByKey(String key, String initialValue) {
    if (!_controllers.containsKey(key)) {
      _controllers[key] = TextEditingController(text: initialValue);
    }
    return _controllers[key]!;
  }

  /// 更新所有 controller 的值（用于粘贴源等场景）
  void _updateAllControllers() {
    // 基本信息
    for (final entity in _baseEntities) {
      final key = 'base_${entity.key}';
      if (_controllers.containsKey(key)) {
        _controllers[key]!.text = entity.value;
      }
    }
    // 搜索规则
    for (final entity in _searchEntities) {
      final key = 'search_${entity.key}';
      if (_controllers.containsKey(key)) {
        _controllers[key]!.text = entity.value;
      }
    }
    // 发现规则
    for (final entity in _exploreEntities) {
      final key = 'explore_${entity.key}';
      if (_controllers.containsKey(key)) {
        _controllers[key]!.text = entity.value;
      }
    }
    // 详情规则
    for (final entity in _infoEntities) {
      final key = 'info_${entity.key}';
      if (_controllers.containsKey(key)) {
        _controllers[key]!.text = entity.value;
      }
    }
    // 目录规则
    for (final entity in _tocEntities) {
      final key = 'toc_${entity.key}';
      if (_controllers.containsKey(key)) {
        _controllers[key]!.text = entity.value;
      }
    }
    // 正文规则
    for (final entity in _contentEntities) {
      final key = 'content_${entity.key}';
      if (_controllers.containsKey(key)) {
        _controllers[key]!.text = entity.value;
      }
    }
  }

  /// KeyboardAssistCallback 实现 - 获取帮助操作列表
  @override
  List<PopupMenuItem<String>> helpActions(BuildContext context) {
    return [
      const PopupMenuItem(
        value: 'urlOption',
        height: 48,
        child: Row(children: [Icon(Icons.link, size: 18), SizedBox(width: 12), Text('插入URL参数')]),
      ),
      const PopupMenuItem(
        value: 'ruleHelp',
        height: 48,
        child: Row(children: [Icon(Icons.menu_book, size: 18), SizedBox(width: 12), Text('书源教程')]),
      ),
      const PopupMenuItem(
        value: 'jsHelp',
        height: 48,
        child: Row(children: [Icon(Icons.javascript, size: 18), SizedBox(width: 12), Text('JS教程')]),
      ),
      const PopupMenuItem(
        value: 'regexHelp',
        height: 48,
        child: Row(children: [Icon(Icons.code, size: 18), SizedBox(width: 12), Text('正则教程')]),
      ),
    ];
  }

  /// KeyboardAssistCallback 实现 - 处理帮助操作选择
  @override
  void onHelpActionSelect(String action) {
    switch (action) {
      case 'urlOption':
        _showUrlOptionDialog();
        break;
      case 'ruleHelp':
        _showHelp();
        break;
      case 'jsHelp':
        _showJsHelp();
        break;
      case 'regexHelp':
        _showRegexHelp();
        break;
    }
  }

  /// KeyboardAssistCallback 实现 - 发送文本到当前焦点输入框
  @override
  void sendText(String text) {
    final controller = _focusedController;
    if (controller == null) return;

    final currentText = controller.text;
    final selection = controller.selection;
    final start = selection.start;
    final end = selection.end;

    // 确保 start <= end
    final actualStart = start < end ? start : end;
    final actualEnd = start < end ? end : start;

    // 在光标位置插入文本
    if (actualStart < 0 || actualStart >= currentText.length) {
      controller.text = currentText + text;
      controller.selection = TextSelection.collapsed(offset: currentText.length + text.length);
    } else {
      final newText = currentText.replaceRange(actualStart, actualEnd, text);
      controller.text = newText;
      controller.selection = TextSelection.collapsed(offset: actualStart + text.length);
    }

    // 更新对应的 EditEntity
    _updateEntityFromController(controller, controller.text);
    _hasChanges = true;
  }

  /// KeyboardAssistCallback 实现 - 撤销操作
  @override
  void onUndoClicked() {
    // Flutter 的 TextField 不直接支持撤销，需要通过 TextEditingController 实现
    // 这里暂时不做实现，因为 Flutter 的 TextField 已经内置了撤销功能
  }

  /// KeyboardAssistCallback 实现 - 重做操作
  @override
  void onRedoClicked() {
    // Flutter 的 TextField 不直接支持重做，需要通过 TextEditingController 实现
    // 这里暂时不做实现，因为 Flutter 的 TextField 已经内置了重做功能
  }

  /// 更新对应的 EditEntity 值
  void _updateEntityFromController(TextEditingController controller, String value) {
    // 根据 controller 找到对应的 EditEntity 并更新
    final tabPosition = _tabController.index;
    List<EditEntity> entities;
    switch (tabPosition) {
      case 1:
        entities = _searchEntities;
        break;
      case 2:
        entities = _exploreEntities;
        break;
      case 3:
        entities = _infoEntities;
        break;
      case 4:
        entities = _tocEntities;
        break;
      case 5:
        entities = _contentEntities;
        break;
      default:
        entities = _baseEntities;
    }

    // 找到对应的 entity 并更新
    for (final entity in entities) {
      final key = '${_getTabKey(tabPosition)}_${entity.key}';
      if (_controllers[key] == controller) {
        entity.value = value;
        break;
      }
    }
  }

  /// 获取 Tab 的 key
  String _getTabKey(int position) {
    switch (position) {
      case 1:
        return 'search';
      case 2:
        return 'explore';
      case 3:
        return 'info';
      case 4:
        return 'toc';
      case 5:
        return 'content';
      default:
        return 'base';
    }
  }

  /// 显示 URL 参数对话框
  void _showUrlOptionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('插入URL参数'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('{{key}}'),
              subtitle: const Text('搜索关键字'),
              onTap: () {
                Navigator.pop(context);
                sendText('{{key}}');
              },
            ),
            ListTile(
              title: const Text('{{page}}'),
              subtitle: const Text('页码'),
              onTap: () {
                Navigator.pop(context);
                sendText('{{page}}');
              },
            ),
            ListTile(
              title: const Text('{{size}}'),
              subtitle: const Text('每页数量'),
              onTap: () {
                Navigator.pop(context);
                sendText('{{size}}');
              },
            ),
            ListTile(
              title: const Text('{{total}}'),
              subtitle: const Text('总页数'),
              onTap: () {
                Navigator.pop(context);
                sendText('{{total}}');
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// 显示 JS 帮助
  void _showJsHelp() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const _SourceHelpPage(initialTab: 1),
      ),
    );
  }

  /// 显示正则帮助
  void _showRegexHelp() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('正则表达式帮助'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('常用正则符号：'),
              SizedBox(height: 8),
              Text('• . 匹配任意字符'),
              Text('• * 匹配前一个字符0次或多次'),
              Text('• + 匹配前一个字符1次或多次'),
              Text('• ? 匹配前一个字符0次或1次'),
              Text('• \\d 匹配数字'),
              Text('• \\w 匹配字母、数字、下划线'),
              Text('• \\s 匹配空白字符'),
              Text('• [] 匹配括号内的任意字符'),
              Text('• () 分组捕获'),
              Text('• | 或运算'),
              SizedBox(height: 16),
              Text('示例：'),
              Text('• ##\\n.* 匹配换行后的内容'),
              Text('• ##<p>(.*?)</p> 匹配p标签内容'),
            ],
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
  final ScrollController _scrollController = ScrollController();
  final ScrollController _lineNumberController = ScrollController();
  String _searchKeyword = '';
  String _replaceKeyword = '';
  int _currentIndex = -1;
  final List<int> _matchPositions = [];
  String _originalContent = '';
  bool _showSearchPanel = false;
  bool _showReplace = false;
  int _lineCount = 1;
  int _cursorLine = 1;
  int _cursorCol = 1;

  @override
  void initState() {
    super.initState();
    _originalContent = widget.content;
    _controller = TextEditingController(text: widget.content);
    _controller.addListener(_updateCursorInfo);
    _updateLineCount();
  }

  @override
  void dispose() {
    _controller.removeListener(_updateCursorInfo);
    _controller.dispose();
    _scrollController.dispose();
    _lineNumberController.dispose();
    super.dispose();
  }

  void _updateCursorInfo() {
    final text = _controller.text;
    final offset = _controller.selection.baseOffset;
    if (offset < 0) return;
    final beforeCursor = text.substring(0, offset);
    final line = '\n'.allMatches(beforeCursor).length + 1;
    final lastNewline = beforeCursor.lastIndexOf('\n');
    final col = offset - lastNewline;
    if (_cursorLine != line || _cursorCol != col) {
      setState(() {
        _cursorLine = line;
        _cursorCol = col;
      });
    }
    _updateLineCount();
  }

  void _updateLineCount() {
    final count = '\n'.allMatches(_controller.text).length + 1;
    if (_lineCount != count) {
      setState(() {
        _lineCount = count;
      });
    }
  }

  void _toggleSearchPanel() {
    setState(() {
      _showSearchPanel = !_showSearchPanel;
      _showReplace = false;
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
    _currentIndex = (_currentIndex + direction + _matchPositions.length) % _matchPositions.length;
    _scrollToMatch(_currentIndex);
    setState(() {});
  }

  void _scrollToMatch(int index) {
    if (index < 0 || index >= _matchPositions.length) return;
    final pos = _matchPositions[index];
    _controller.selection = TextSelection.collapsed(offset: pos);
  }

  void _replaceCurrent() {
    if (_matchPositions.isEmpty || _currentIndex < 0 || _replaceKeyword.isEmpty) return;
    final pos = _matchPositions[_currentIndex];
    final text = _controller.text;
    _controller.text = text.substring(0, pos) + _replaceKeyword + text.substring(pos + _searchKeyword.length);
    _performSearch(_searchKeyword);
  }

  void _replaceAll() {
    if (_searchKeyword.isEmpty || _replaceKeyword.isEmpty) return;
    final text = _controller.text;
    _controller.text = text.replaceAll(_searchKeyword, _replaceKeyword);
    _performSearch(_searchKeyword);
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

  void _formatJson() {
    try {
      final decoded = jsonDecode(_controller.text);
      final formatted = const JsonEncoder.withIndent('  ').convert(decoded);
      _controller.text = formatted;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('格式化成功')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('格式化失败: $e')),
      );
    }
  }

  /// 构建行号
  Widget _buildLineNumbers() {
    final lineHeight = 18.0;
    return Container(
      width: 48,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: ListView.builder(
        controller: _lineNumberController,
        itemCount: _lineCount,
        itemBuilder: (context, index) {
          final lineNum = index + 1;
          final isCurrentLine = lineNum == _cursorLine;
          return Container(
            height: lineHeight,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              '$lineNum',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: isCurrentLine
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                fontWeight: isCurrentLine ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final editorBg = isDark ? const Color(0xFF1E1E1E) : const Color(0xFFFAFAFA);
    final gutterBorder = isDark ? const Color(0xFF333333) : const Color(0xFFE0E0E0);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          // 搜索
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: _toggleSearchPanel,
            tooltip: '搜索/替换',
          ),
          // 格式化
          IconButton(
            icon: const Icon(Icons.format_align_left),
            onPressed: _formatJson,
            tooltip: '格式化JSON',
          ),
          // 保存
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _save,
            tooltip: '保存',
          ),
          // 更多菜单
          PopupMenuButton<String>(
            tooltip: '更多选项',
            offset: const Offset(0, 48),
            onSelected: (value) {
              switch (value) {
                case 'reset':
                  _reset();
                case 'copy_all':
                  _copyAll();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'reset',
                height: 36,
                child: Row(children: [Icon(Icons.refresh, size: 18), SizedBox(width: 12), Text('重置')]),
              ),
              const PopupMenuItem(
                value: 'copy_all',
                height: 36,
                child: Row(children: [Icon(Icons.copy, size: 18), SizedBox(width: 12), Text('复制全部')]),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 搜索/替换面板
          if (_showSearchPanel)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                border: Border(bottom: BorderSide(color: gutterBorder)),
              ),
              child: Column(
                children: [
                  // 搜索行
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(
                            hintText: '搜索',
                            isDense: true,
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.search, size: 18),
                          ),
                          onSubmitted: _performSearch,
                          onChanged: _performSearch,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _matchPositions.isEmpty
                            ? (_searchKeyword.isEmpty ? '' : '无匹配')
                            : '${_currentIndex + 1}/${_matchPositions.length}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.keyboard_arrow_up),
                        onPressed: () => _navigateToMatch(-1),
                        iconSize: 20,
                        tooltip: '上一个',
                      ),
                      IconButton(
                        icon: const Icon(Icons.keyboard_arrow_down),
                        onPressed: () => _navigateToMatch(1),
                        iconSize: 20,
                        tooltip: '下一个',
                      ),
                      IconButton(
                        icon: Icon(_showReplace ? Icons.expand_less : Icons.expand_more),
                        onPressed: () => setState(() => _showReplace = !_showReplace),
                        iconSize: 20,
                        tooltip: '替换',
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: _toggleSearchPanel,
                        iconSize: 20,
                      ),
                    ],
                  ),
                  // 替换行
                  if (_showReplace) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              hintText: '替换为',
                              isDense: true,
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.find_replace, size: 18),
                            ),
                            onChanged: (v) => _replaceKeyword = v,
                          ),
                        ),
                        const SizedBox(width: 4),
                        TextButton(
                          onPressed: _replaceCurrent,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(40, 32),
                          ),
                          child: const Text('替换'),
                        ),
                        TextButton(
                          onPressed: _replaceAll,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(40, 32),
                          ),
                          child: const Text('全部'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          // 编辑区域（行号 + 编辑器）
          Expanded(
            child: Container(
              color: editorBg,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 行号
                  Container(
                    decoration: BoxDecoration(
                      border: Border(right: BorderSide(color: gutterBorder)),
                    ),
                    child: _buildLineNumbers(),
                  ),
                  // 编辑器
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      scrollController: _scrollController,
                      maxLines: null,
                      expands: true,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.only(left: 8, right: 12, top: 2, bottom: 24),
                      ),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        height: 18 / 13,
                        color: isDark ? const Color(0xFFD4D4D4) : const Color(0xFF1E1E1E),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 状态栏
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              border: Border(top: BorderSide(color: gutterBorder)),
            ),
            child: Row(
              children: [
                Icon(Icons.code, size: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
                const SizedBox(width: 4),
                Text(
                  '行 $_cursorLine, 列 $_cursorCol',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  '$_lineCount 行',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  '${_controller.text.length} 字符',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const Spacer(),
                if (_matchPositions.isNotEmpty)
                  Text(
                    '${_matchPositions.length} 个匹配',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                const SizedBox(width: 8),
                Text(
                  'UTF-8',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 带下划线的组件
class UnderlineWidget extends StatelessWidget {
  final Widget child;

  const UnderlineWidget({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: child,
        ),
        Container(
          height: 1.5,
          width: 48,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ],
    );
  }
}

/// 书源帮助文档页面（加载 Markdown 文件渲染，支持切换文档）
class _SourceHelpPage extends StatefulWidget {
  final int initialTab;

  const _SourceHelpPage({this.initialTab = 0});

  @override
  State<_SourceHelpPage> createState() => _SourceHelpPageState();
}

class _SourceHelpPageState extends State<_SourceHelpPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _generalHelp = '';
  String _jsHelp = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this, initialIndex: widget.initialTab);
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

/// 二维码导入页面
class _QrImportPage extends StatefulWidget {
  final bool Function(String) onScanned;

  const _QrImportPage({required this.onScanned});

  @override
  State<_QrImportPage> createState() => _QrImportPageState();
}

class _QrImportPageState extends State<_QrImportPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _processed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_processed) return;

    final barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        _processed = true;
        _controller.stop();

        final success = widget.onScanned(value);
        if (success && mounted) {
          Navigator.pop(context);
        } else {
          // 如果失败，允许重新扫描
          _processed = false;
          _controller.start();
        }
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描二维码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
            tooltip: '切换闪光灯',
          ),
        ],
      ),
      body: MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
      ),
    );
  }
}

/// 书源登录页面
class _SourceLoginPage extends StatefulWidget {
  final BookSource source;
  final VoidCallback onLoginSuccess;

  const _SourceLoginPage({
    required this.source,
    required this.onLoginSuccess,
  });

  @override
  State<_SourceLoginPage> createState() => _SourceLoginPageState();
}

class _SourceLoginPageState extends State<_SourceLoginPage> {
  bool _isLoading = true;
  bool _checking = false;

  String get _loginUrl {
    final loginUrl = widget.source.loginUrl ?? '';
    final baseUrl = widget.source.bookSourceUrl;

    // 如果 loginUrl 已经是完整 URL，直接使用
    if (loginUrl.startsWith('http://') || loginUrl.startsWith('https://')) {
      return loginUrl;
    }

    // 否则拼接 baseUrl
    if (baseUrl.isNotEmpty) {
      final baseUri = Uri.tryParse(baseUrl);
      if (baseUri != null) {
        return baseUri.resolve(loginUrl).toString();
      }
    }

    return loginUrl;
  }

  Future<void> _saveCookies(String url) async {
    try {
      final cookieManager = CookieManager.instance();
      final cookies = await cookieManager.getCookies(url: WebUri(url));

      final cookieStr = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      if (cookieStr.isNotEmpty) {
        await CookieService.instance.setCookie(url, cookieStr);
      }
    } catch (e) {
      debugPrint('保存 Cookie 失败: $e');
    }
  }

  void _onCheckLogin() {
    setState(() {
      _checking = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在检查登录状态...')),
    );

    // 模拟检查完成后重置状态
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _checking = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('登录状态检查完成')),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('登录 - ${widget.source.bookSourceName}'),
        actions: [
          TextButton(
            onPressed: _checking ? null : _onCheckLogin,
            child: const Text('完成'),
          ),
        ],
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(_loginUrl)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              databaseEnabled: true,
              useHybridComposition: true,
            ),
            onLoadStart: (controller, url) async {
              if (url != null) {
                await _saveCookies(url.toString());
              }
            },
            onLoadStop: (controller, url) async {
              setState(() {
                _isLoading = false;
              });

              if (url != null) {
                await _saveCookies(url.toString());
              }

              // 如果正在检查登录状态，完成登录
              if (_checking) {
                widget.onLoginSuccess();
                if (mounted) {
                  Navigator.pop(context);
                }
              }
            },
            onReceivedError: (controller, request, error) {
              setState(() {
                _isLoading = false;
              });
            },
          ),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
