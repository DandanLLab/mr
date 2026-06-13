import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 封面规则配置 - 参考原版 BookCover.CoverRule
class CoverRule {
  final bool enable;
  final String searchUrl;
  final String coverRule;

  const CoverRule({
    required this.enable,
    required this.searchUrl,
    required this.coverRule,
  });

  factory CoverRule.fromJson(Map<String, dynamic> json) => CoverRule(
    enable: json['enable'] as bool? ?? true,
    searchUrl: json['searchUrl'] as String? ?? '',
    coverRule: json['coverRule'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'enable': enable,
    'searchUrl': searchUrl,
    'coverRule': coverRule,
  };

  /// 默认封面规则 - 来自原版 coverRule.json
  static const CoverRule defaultRule = CoverRule(
    enable: true,
    searchUrl: 'data:;base64,{{java.base64Encode(key)}},{\"type\":\"lyc\"}',
    coverRule: r'''@js:
var key = java.hexDecodeToString(result);
var url1 = `https://pre-api.tuishujun.com/api/searchBook?search_value=${key}&page=1&pageSize=20`;
var url2 = `http://m.ypshuo.com/api/novel/search?keyword=${key}&searchType=1&page=1`;
var [rr1, rr2] = java.ajaxAll([url1, url2]).map(r => r.body());
function jjson(str, rule) {
    try {
        return com.jayway.jsonpath.JsonPath.read(str, rule);
    } catch (e) {
        return [];
    }
}
rr1 = jjson(rr1, '$.data.data[*]');
rr2 = jjson(rr2, '$.data.data[*]');
var na = String(book.name),
    au = String(book.author);
function search() {
    for (let char of rr1) {
        if (na.includes(char.title + '')) {
            let au2 = char.author_nickname + '';
            if (au.includes(au2) || au2.includes(au)) {
                return char.cover;
            }
        }
    }
    for (let char of rr2) {
        if (na.includes(char.novel_name + '')) {
            let au2 = char.author_name + '';
            if (au.includes(au2) || au2.includes(au)) {
                return char.novel_img;
            }
        }
    }
    return '';
}
search()''',
  );
}

/// 封面配置服务 - 参考原版 legado BookCover + CoverCollectionManager
class CoverConfigService {
  CoverConfigService._();
  static final CoverConfigService instance = CoverConfigService._();

  static const String _coverRuleKey = 'legadoCoverRuleConfig';

  // 缓存
  bool _loadCoverOnlyWifi = false;
  bool _loadCoverHighQuality = false;
  bool _useDefaultCover = false;
  bool _coverShowName = true;
  bool _coverShowAuthor = true;
  bool _coverShowNameN = true;
  bool _coverShowAuthorN = true;
  String _defaultCover = '';
  String _defaultCoverDark = '';
  String _coverCollectionModeDay = 'random';
  String _coverCollectionModeNight = 'random';
  CoverRule? _coverRule;
  bool _initialized = false;

  /// 初始化，从 SharedPreferences 加载配置
  Future<void> init() async {
    if (_initialized) return;
    await reload();
  }

  /// 重新加载配置
  Future<void> reload() async {
    final prefs = await SharedPreferences.getInstance();
    _loadCoverOnlyWifi = prefs.getBool('loadCoverOnlyWifi') ?? false;
    _loadCoverHighQuality = prefs.getBool('loadCoverHighQuality') ?? false;
    _useDefaultCover = prefs.getBool('useDefaultCover') ?? false;
    _coverShowName = prefs.getBool('coverShowName') ?? true;
    _coverShowAuthor = prefs.getBool('coverShowAuthor') ?? true;
    _coverShowNameN = prefs.getBool('coverShowNameN') ?? true;
    _coverShowAuthorN = prefs.getBool('coverShowAuthorN') ?? true;
    _defaultCover = prefs.getString('defaultCover') ?? '';
    _defaultCoverDark = prefs.getString('defaultCoverDark') ?? '';
    _coverCollectionModeDay = prefs.getString('coverCollectionModeDay') ?? 'random';
    _coverCollectionModeNight = prefs.getString('coverCollectionModeNight') ?? 'random';
    // 加载封面规则
    final ruleJson = prefs.getString(_coverRuleKey);
    if (ruleJson != null && ruleJson.isNotEmpty) {
      try {
        _coverRule = CoverRule.fromJson(json.decode(ruleJson) as Map<String, dynamic>);
      } catch (_) {
        _coverRule = null;
      }
    }
    _initialized = true;
  }

  /// 是否仅WiFi加载封面
  bool get loadCoverOnlyWifi => _loadCoverOnlyWifi;

  /// 是否加载高清封面
  bool get loadCoverHighQuality => _loadCoverHighQuality;

  /// 是否总是使用默认封面
  bool get useDefaultCover => _useDefaultCover;

  /// 日间是否显示书名
  bool get coverShowName => _coverShowName;

  /// 日间是否显示作者
  bool get coverShowAuthor => _coverShowAuthor;

  /// 夜间是否显示书名
  bool get coverShowNameN => _coverShowNameN;

  /// 夜间是否显示作者
  bool get coverShowAuthorN => _coverShowAuthorN;

  /// 日间默认封面路径
  String get defaultCoverPath => _defaultCover;

  /// 夜间默认封面路径
  String get defaultCoverDarkPath => _defaultCoverDark;

  /// 日间封面模式
  String get coverCollectionModeDay => _coverCollectionModeDay;

  /// 夜间封面模式
  String get coverCollectionModeNight => _coverCollectionModeNight;

  /// 获取封面规则
  CoverRule get coverRule => _coverRule ?? CoverRule.defaultRule;

  /// 保存封面规则
  Future<void> saveCoverRule(CoverRule rule) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_coverRuleKey, json.encode(rule.toJson()));
    _coverRule = rule;
  }

  /// 删除封面规则（恢复默认）
  Future<void> deleteCoverRule() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_coverRuleKey);
    _coverRule = null;
  }

  /// 根据当前主题判断是否显示书名
  bool shouldShowName(bool isDark) =>
      isDark ? _coverShowNameN : _coverShowName;

  /// 根据当前主题判断是否显示作者
  bool shouldShowAuthor(bool isDark) =>
      isDark ? _coverShowAuthorN : _coverShowAuthor;

  /// 获取当前主题的默认封面路径
  String currentDefaultCoverPath(bool isDark) =>
      isDark ? _defaultCoverDark : _defaultCover;

  /// 获取当前主题的封面模式
  String currentCoverMode(bool isDark) =>
      isDark ? _coverCollectionModeNight : _coverCollectionModeDay;

  /// 判断当前是否在WiFi网络下
  Future<bool> isWifiConnected() async {
    final dynamic result = await Connectivity().checkConnectivity();
    // connectivity_plus 不同版本返回类型不同
    // 5.x 返回 List<ConnectivityResult>, 旧版返回单个 ConnectivityResult
    if (result is List) {
      return (result as List).contains(ConnectivityResult.wifi);
    } else if (result == ConnectivityResult.wifi) {
      return true;
    }
    return false;
  }

  /// 判断是否应该加载网络封面（考虑WiFi设置）
  Future<bool> shouldLoadNetworkCover() async {
    if (!_loadCoverOnlyWifi) return true;
    return await isWifiConnected();
  }

  /// 获取封面显示URL - 核心方法
  /// 综合考虑：总是使用默认封面、WiFi限制、默认封面路径
  /// 返回 null 表示不显示网络封面（显示默认封面占位）
  Future<String?> getDisplayCoverUrl({
    required String coverUrl,
    required bool isDark,
  }) async {
    // 总是使用默认封面
    if (_useDefaultCover) {
      return null;
    }

    // WiFi限制检查
    if (_loadCoverOnlyWifi) {
      final isWifi = await isWifiConnected();
      if (!isWifi) {
        return null;
      }
    }

    return coverUrl.isNotEmpty ? coverUrl : null;
  }

  /// 获取默认封面的 ImageProvider
  ImageProvider? getDefaultCoverProvider(bool isDark) {
    final path = currentDefaultCoverPath(isDark);
    if (path.isEmpty) return null;
    final file = File(path);
    if (file.existsSync()) {
      return FileImage(file);
    }
    return null;
  }

  /// 构建封面占位符 - 参考原版 CoverImageView 的默认封面绘制
  /// 在没有网络封面时，在默认封面上绘制书名和作者
  Widget buildDefaultCoverPlaceholder({
    required String bookName,
    String? bookAuthor,
    required bool isDark,
    double width = double.infinity,
    double height = double.infinity,
    BorderRadius? borderRadius,
  }) {
    final showName = shouldShowName(isDark);
    final showAuthor = shouldShowAuthor(isDark) && showName;

    // 如果有自定义默认封面图片
    final coverProvider = getDefaultCoverProvider(isDark);
    if (coverProvider != null) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          image: DecorationImage(
            image: coverProvider,
            fit: BoxFit.cover,
          ),
        ),
      );
    }

    // 没有自定义默认封面，使用纯色背景 + 书名/作者文字
    // 参考原版 CoverImageView.generateCoverBitmap 的样式
    final colorScheme = isDark
        ? const ColorScheme.dark(
            primary: Color(0xFFBB86FC),
            surface: Color(0xFF303030),
            onSurface: Color(0xFFE0E0E0),
          )
        : const ColorScheme.light(
            primary: Color(0xFF0288D1),
            surface: Color(0xFFFAFAFA),
            onSurface: Color(0xFF212121),
          );

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: borderRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (showName)
              Text(
                bookName,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colorScheme.primary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  height: 1.3,
                ),
              ),
            if (showAuthor && bookAuthor != null && bookAuthor.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                bookAuthor,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colorScheme.onSurface.withOpacity(0.6),
                  fontSize: 12,
                  height: 1.3,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 封面图集数据 - 参考原版 CoverCollectionManager.Collection
class CoverCollection {
  final String id;
  final String name;
  final String dirName;
  final bool isNight;
  final List<String> images;
  final int updatedAt;

  const CoverCollection({
    required this.id,
    required this.name,
    required this.dirName,
    required this.isNight,
    this.images = const [],
    this.updatedAt = 0,
  });

  factory CoverCollection.fromJson(Map<String, dynamic> json) => CoverCollection(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    dirName: json['dirName'] as String? ?? '',
    isNight: json['isNight'] as bool? ?? false,
    images: (json['images'] as List<dynamic>?)
        ?.map((e) => e as String)
        .toList() ?? [],
    updatedAt: json['updatedAt'] as int? ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'dirName': dirName,
    'isNight': isNight,
    'images': images,
    'updatedAt': updatedAt,
  };

  CoverCollection copyWith({
    String? name,
    List<String>? images,
    int? updatedAt,
  }) => CoverCollection(
    id: id,
    name: name ?? this.name,
    dirName: dirName,
    isNight: isNight,
    images: images ?? this.images,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// 封面图集管理器 - 参考原版 CoverCollectionManager
class CoverCollectionManager {
  CoverCollectionManager._();
  static final CoverCollectionManager instance = CoverCollectionManager._();

  static const String _dayIndexKey = 'coverCollectionsDay';
  static const String _nightIndexKey = 'coverCollectionsNight';
  static const String _selectedDayKey = 'coverCollectionDay';
  static const String _selectedNightKey = 'coverCollectionNight';

  List<CoverCollection>? _dayCache;
  List<CoverCollection>? _nightCache;

  /// 获取图集根目录
  Future<Directory> _getRootDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/coverCollections');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 获取日间/夜间图集目录
  Future<Directory> _getTypeDir(bool isNight) async {
    final root = await _getRootDir();
    final dir = Directory('${root.path}/${isNight ? 'night' : 'day'}');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 获取图集图片目录
  Future<Directory> _getImagesDir(CoverCollection collection) async {
    final typeDir = await _getTypeDir(collection.isNight);
    final dir = Directory('${typeDir.path}/${collection.dirName}/images');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 加载图集索引
  Future<List<CoverCollection>> loadCollections(bool isNight) async {
    final prefs = await SharedPreferences.getInstance();
    final key = isNight ? _dayIndexKey : _nightIndexKey;
    final jsonStr = prefs.getString(key);
    if (jsonStr == null || jsonStr.isEmpty) {
      if (isNight) _nightCache = [];
      else _dayCache = [];
      return [];
    }
    try {
      final list = (json.decode(jsonStr) as List<dynamic>)
          .map((e) => CoverCollection.fromJson(e as Map<String, dynamic>))
          .toList();
      if (isNight) _nightCache = list;
      else _dayCache = list;
      return list;
    } catch (_) {
      if (isNight) _nightCache = [];
      else _dayCache = [];
      return [];
    }
  }

  /// 获取缓存的图集列表
  Future<List<CoverCollection>> getCollections(bool isNight) async {
    if (isNight && _nightCache != null) return _nightCache!;
    if (!isNight && _dayCache != null) return _dayCache!;
    return loadCollections(isNight);
  }

  /// 保存图集索引
  Future<void> _saveCollections(List<CoverCollection> collections, bool isNight) async {
    final prefs = await SharedPreferences.getInstance();
    final key = isNight ? _dayIndexKey : _nightIndexKey;
    await prefs.setString(key, json.encode(collections.map((e) => e.toJson()).toList()));
    if (isNight) _nightCache = collections;
    else _dayCache = collections;
  }

  /// 创建图集
  Future<CoverCollection> createCollection({
    required String name,
    required bool isNight,
  }) async {
    final uuid = const Uuid();
    final id = uuid.v4();
    final dirName = id.substring(0, 8);
    final collection = CoverCollection(
      id: id,
      name: name,
      dirName: dirName,
      isNight: isNight,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    // 创建图片目录
    await _getImagesDir(collection);
    // 保存到索引
    final collections = await getCollections(isNight);
    collections.add(collection);
    await _saveCollections(collections, isNight);
    return collection;
  }

  /// 删除图集
  Future<void> deleteCollection(String collectionId, bool isNight) async {
    final collections = await getCollections(isNight);
    final target = collections.where((c) => c.id == collectionId).firstOrNull;
    if (target != null) {
      // 删除图片目录
      final typeDir = await _getTypeDir(isNight);
      final collDir = Directory('${typeDir.path}/${target.dirName}');
      if (collDir.existsSync()) {
        collDir.deleteSync(recursive: true);
      }
    }
    collections.removeWhere((c) => c.id == collectionId);
    await _saveCollections(collections, isNight);
    // 如果删除的是当前选中的，清除选中
    final prefs = await SharedPreferences.getInstance();
    final selectedKey = isNight ? _selectedDayKey : _selectedNightKey;
    final selectedId = prefs.getString(selectedKey) ?? '';
    if (selectedId == collectionId) {
      await prefs.remove(selectedKey);
    }
  }

  /// 重命名图集
  Future<void> renameCollection(String collectionId, String newName, bool isNight) async {
    final collections = await getCollections(isNight);
    final index = collections.indexWhere((c) => c.id == collectionId);
    if (index >= 0) {
      collections[index] = collections[index].copyWith(
        name: newName,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _saveCollections(collections, isNight);
    }
  }

  /// 导入图片到图集
  Future<void> importImages(String collectionId, List<String> filePaths, bool isNight) async {
    final collections = await getCollections(isNight);
    final index = collections.indexWhere((c) => c.id == collectionId);
    if (index < 0) return;

    final collection = collections[index];
    final imagesDir = await _getImagesDir(collection);
    final newImages = <String>[...collection.images];

    for (final srcPath in filePaths) {
      final srcFile = File(srcPath);
      if (!srcFile.existsSync()) continue;
      final fileName = srcPath.split(Platform.pathSeparator).last;
      final destPath = '${imagesDir.path}${Platform.pathSeparator}$fileName';
      await srcFile.copy(destPath);
      newImages.add(destPath);
    }

    collections[index] = collection.copyWith(
      images: newImages,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _saveCollections(collections, isNight);
  }

  /// 删除图集中的图片
  Future<void> removeImage(String collectionId, String imagePath, bool isNight) async {
    final collections = await getCollections(isNight);
    final index = collections.indexWhere((c) => c.id == collectionId);
    if (index < 0) return;

    final collection = collections[index];
    final newImages = collection.images.where((img) => img != imagePath).toList();

    // 删除文件
    final file = File(imagePath);
    if (file.existsSync()) file.deleteSync();

    collections[index] = collection.copyWith(
      images: newImages,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _saveCollections(collections, isNight);
  }

  /// 获取选中的图集ID
  Future<String> getSelectedCollectionId(bool isNight) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(isNight ? _selectedNightKey : _selectedDayKey) ?? '';
  }

  /// 设置选中的图集
  Future<void> setSelectedCollection(String? collectionId, bool isNight) async {
    final prefs = await SharedPreferences.getInstance();
    final key = isNight ? _selectedNightKey : _selectedDayKey;
    if (collectionId == null || collectionId.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, collectionId);
    }
  }

  /// 获取选中的图集
  Future<CoverCollection?> getSelectedCollection(bool isNight) async {
    final id = await getSelectedCollectionId(isNight);
    if (id.isEmpty) return null;
    final collections = await getCollections(isNight);
    return collections.where((c) => c.id == id).firstOrNull;
  }

  /// 根据书籍key获取图集封面路径 - 核心方法
  /// 参考原版 CoverCollectionManager.selectedCollectionCover
  Future<String?> getCollectionCoverPath({
    required String bookKey,
    required bool isDark,
    bool hasOriginalCover = true,
  }) async {
    final collection = await getSelectedCollection(isDark);
    if (collection == null || collection.images.isEmpty) return null;

    final mode = CoverConfigService.instance.currentCoverMode(isDark);

    // 混合模式：有原始封面时使用原始封面
    if (mode == 'mixed' && hasOriginalCover) return null;

    int imageIndex;
    if (mode == 'sequence') {
      // 顺序模式：根据bookKey的hashCode稳定取模
      imageIndex = bookKey.hashCode.abs() % collection.images.length;
    } else {
      // 随机模式：根据bookKey的hashCode稳定取模
      imageIndex = bookKey.hashCode.abs() % collection.images.length;
    }

    final imagePath = collection.images[imageIndex];
    final file = File(imagePath);
    if (!file.existsSync()) return null;
    return imagePath;
  }
}
