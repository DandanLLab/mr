// 段评气泡包管理器 - 移植自 legado_max BubblePackageManager
// 管理多套气泡包配置，支持创建/编辑/删除/导入导出

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

/// 气泡包配置
class BubblePackageConfig {
  String name;
  String dirName;
  String svgTemplate;
  double sizeScale;
  String? dayNormalColor;
  String? dayEmphasisColor;
  String? nightNormalColor;
  String? nightEmphasisColor;
  int updatedAt;

  BubblePackageConfig({
    required this.name,
    this.dirName = '',
    this.svgTemplate = '',
    this.sizeScale = 1.0,
    this.dayNormalColor,
    this.dayEmphasisColor,
    this.nightNormalColor,
    this.nightEmphasisColor,
    int? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
    'name': name,
    'dirName': dirName,
    'svgTemplate': svgTemplate,
    'sizeScale': sizeScale,
    'dayNormalColor': dayNormalColor,
    'dayEmphasisColor': dayEmphasisColor,
    'nightNormalColor': nightNormalColor,
    'nightEmphasisColor': nightEmphasisColor,
    'updatedAt': updatedAt,
  };

  factory BubblePackageConfig.fromJson(Map<String, dynamic> json) {
    return BubblePackageConfig(
      name: json['name'] as String? ?? '段评气泡',
      dirName: json['dirName'] as String? ?? '',
      svgTemplate: json['svgTemplate'] as String? ?? '',
      sizeScale: (json['sizeScale'] as num?)?.toDouble() ?? 1.0,
      dayNormalColor: json['dayNormalColor'] as String?,
      dayEmphasisColor: json['dayEmphasisColor'] as String?,
      nightNormalColor: json['nightNormalColor'] as String?,
      nightEmphasisColor: json['nightEmphasisColor'] as String?,
      updatedAt: json['updatedAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  BubblePackageConfig copy() => BubblePackageConfig(
    name: name,
    dirName: dirName,
    svgTemplate: svgTemplate,
    sizeScale: sizeScale,
    dayNormalColor: dayNormalColor,
    dayEmphasisColor: dayEmphasisColor,
    nightNormalColor: nightNormalColor,
    nightEmphasisColor: nightEmphasisColor,
    updatedAt: updatedAt,
  );
}

/// 气泡包条目
class BubblePackageEntry {
  final BubblePackageConfig config;
  final bool isBuiltin;
  final String dirName;
  final Directory? localDir;

  BubblePackageEntry({
    required this.config,
    required this.isBuiltin,
    required this.dirName,
    this.localDir,
  });
}

/// 气泡包管理器
class BubblePackageManager {
  static const _backupDirName = 'bubblePackages';
  static const builtinDirName = 'builtin_default';
  static const _packageFileName = 'bubble.json';
  static const _prefKey = 'paragraphBubblePackage';

  static const defaultEmphasisColor = '#FF0000';
  static const defaultNormalColor = '#808080';
  static const minSizeScale = 0.5;
  static const maxSizeScale = 1.5;

  static const _defaultBubblePath =
      'M44 48 Q48 48 48 44 L48 20 Q48 16 44 16 L20 16 Q16 16 16 20 L16 24 S16 28 10 30 Q6 32 10 34 Q16 36 16 38 L16 44 Q16 48 20 48 Z';

  static BubblePackageManager? _instance;
  static BubblePackageManager get instance => _instance ??= BubblePackageManager._();
  BubblePackageManager._();

  static Directory? _rootDirCache;
  Directory get _rootDir {
    if (_rootDirCache != null) return _rootDirCache!;
    throw StateError('BubblePackageManager not initialized, call init() first');
  }

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    _rootDirCache = Directory('${appDir.path}/$_backupDirName');
  }

  Directory get _tempDir {
    final d = Directory('${_rootDir.path}/temp');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 默认 SVG 模板
  String defaultSvgTemplate() {
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">\n'
        '  <path d="' + _defaultBubblePath + '" fill="none" stroke="\${color}" stroke-width="3.2" stroke-linejoin="round" stroke-linecap="round"/>\n'
        '  <text x="32" y="32" dy=".35em" text-anchor="middle" font-family="sans-serif" font-size="15" font-weight="600" fill="\${color}">\${num}</text>\n'
        '</svg>';
  }

  /// 内置配置
  BubblePackageConfig builtinConfig() {
    return BubblePackageConfig(
      name: '内置段评气泡',
      dirName: builtinDirName,
      svgTemplate: defaultSvgTemplate(),
      sizeScale: 1.0,
      dayNormalColor: defaultNormalColor,
      dayEmphasisColor: defaultEmphasisColor,
      nightNormalColor: defaultNormalColor,
      nightEmphasisColor: defaultEmphasisColor,
      updatedAt: 0,
    );
  }

  /// 内置条目
  BubblePackageEntry builtinEntry() {
    return BubblePackageEntry(
      config: builtinConfig(),
      isBuiltin: true,
      dirName: builtinDirName,
    );
  }

  /// 加载所有条目（内置 + 本地）
  List<BubblePackageEntry> loadEntries() {
    final entries = <BubblePackageEntry>[builtinEntry()];
    if (!_rootDir.existsSync()) return entries;
    final localDirs = _rootDir.listSync().whereType<Directory>()
        .where((d) => d.path.split('/').last != builtinDirName && d.path.split('\\').last != builtinDirName);
    final localEntries = <BubblePackageEntry>[];
    for (final dir in localDirs) {
      final entry = _readEntry(dir);
      if (entry != null) localEntries.add(entry);
    }
    localEntries.sort((a, b) {
      final cmp = b.config.updatedAt.compareTo(a.config.updatedAt);
      return cmp != 0 ? cmp : a.config.name.compareTo(b.config.name);
    });
    entries.addAll(localEntries);
    return entries;
  }

  /// 当前激活的 dirName
  String activeDirName() {
    // 通过 SharedPreferences 读取，这里返回默认值，实际调用方使用 prefs
    return builtinDirName;
  }

  /// 添加或更新配置
  Future<BubblePackageEntry> addOrUpdate(BubblePackageConfig config, {BubblePackageEntry? oldEntry}) async {
    final normalized = _normalizeConfig(config);
    final isEditingLocal = oldEntry != null && !oldEntry.isBuiltin && oldEntry.dirName != builtinDirName;
    final name = normalized.name.trim().isEmpty ? '段评气泡' : normalized.name.trim();
    final dirName = isEditingLocal
        ? oldEntry.dirName
        : await _uniqueDirName(normalized.dirName.isEmpty ? name : normalized.dirName);
    final dir = _localDir(dirName);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final next = normalized
      ..name = name
      ..dirName = dirName
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    final file = File('${dir.path}/$_packageFileName');
    await file.writeAsString(jsonEncode(next.toJson()));
    return BubblePackageEntry(config: next, isBuiltin: false, dirName: dirName, localDir: dir);
  }

  /// 删除本地条目
  Future<void> deleteLocal(BubblePackageEntry entry) async {
    if (entry.isBuiltin || entry.dirName == builtinDirName) return;
    final dir = entry.localDir ?? _localDir(entry.dirName);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// 导出为 ZIP
  Future<File> exportZip(List<BubblePackageEntry> entries) async {
    final localEntries = entries.where((e) => !e.isBuiltin && e.dirName != builtinDirName).toList();
    if (localEntries.isEmpty) throw Exception('没有可导出的气泡');
    final exportDir = Directory('${_tempDir.path}/export_${DateTime.now().millisecondsSinceEpoch}');
    if (exportDir.existsSync()) await exportDir.delete(recursive: true);
    exportDir.createSync(recursive: true);
    final archive = Archive();
    for (final entry in localEntries) {
      final sourceDir = entry.localDir ?? _localDir(entry.dirName);
      if (!sourceDir.existsSync()) throw Exception('气泡配置不存在：${entry.config.name}');
      await for (final entity in sourceDir.list(recursive: true)) {
        if (entity is File) {
          final relativePath = entity.path.substring(sourceDir.path.length + 1);
          final bytes = await entity.readAsBytes();
          archive.addFile(ArchiveFile('${entry.dirName}/$relativePath', bytes.length, bytes));
        }
      }
    }
    final zipName = localEntries.length == 1
        ? '${localEntries.first.dirName}.zip'
        : 'bubble_packages_${DateTime.now().millisecondsSinceEpoch}.zip';
    final zipFile = File('${_tempDir.path}/$zipName');
    if (zipFile.existsSync()) await zipFile.delete();
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null || zipBytes.isEmpty) throw Exception('气泡导出失败');
    await zipFile.writeAsBytes(zipBytes);
    await exportDir.delete(recursive: true);
    return zipFile;
  }

  /// 从 ZIP 导入
  Future<List<BubblePackageEntry>> importZip(File zipFile) async {
    final bytes = await zipFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final unzipDir = Directory('${_tempDir.path}/import_${DateTime.now().millisecondsSinceEpoch}');
    if (unzipDir.existsSync()) await unzipDir.delete(recursive: true);
    unzipDir.createSync(recursive: true);
    for (final file in archive) {
      final outPath = '${unzipDir.path}/${file.name}';
      if (file.isFile) {
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
    final packageFiles = <File>[];
    await for (final entity in unzipDir.list(recursive: true)) {
      if (entity is File && entity.path.split('/').last == _packageFileName) {
        packageFiles.add(entity);
      }
    }
    if (packageFiles.isEmpty) throw Exception('气泡配置不存在');
    final entries = <BubblePackageEntry>[];
    for (final packageFile in packageFiles) {
      final entry = await _importPackageFile(packageFile);
      entries.add(entry);
    }
    await unzipDir.delete(recursive: true);
    return entries;
  }

  Future<BubblePackageEntry> _importPackageFile(File packageFile) async {
    final json = jsonDecode(await packageFile.readAsString()) as Map<String, dynamic>;
    final config = _normalizeConfig(BubblePackageConfig.fromJson(json));
    final dirName = await _uniqueDirName(
      config.dirName.isEmpty ? config.name : config.dirName,
    );
    final targetDir = _localDir(dirName);
    if (targetDir.existsSync()) await targetDir.delete(recursive: true);
    targetDir.createSync(recursive: true);
    final parentDir = packageFile.parent;
    await for (final entity in parentDir.list(recursive: true)) {
      if (entity is File) {
        final relativePath = entity.path.substring(parentDir.path.length + 1);
        await File('${targetDir.path}/$relativePath').parent.create(recursive: true);
        await entity.copy('${targetDir.path}/$relativePath');
      }
    }
    config.dirName = dirName;
    config.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await File('${targetDir.path}/$_packageFileName').writeAsString(jsonEncode(config.toJson()));
    return BubblePackageEntry(config: config, isBuiltin: false, dirName: dirName, localDir: targetDir);
  }

  BubblePackageEntry? _readEntry(Directory dir) {
    final file = File('${dir.path}/$_packageFileName');
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final config = _normalizeConfig(BubblePackageConfig.fromJson(json));
      config.dirName = dir.path.split(RegExp(r'[/\\]')).last;
      return BubblePackageEntry(config: config, isBuiltin: false, dirName: config.dirName, localDir: dir);
    } catch (e) {
      debugPrint('读取气泡包失败: $e');
      return null;
    }
  }

  BubblePackageConfig _normalizeConfig(BubblePackageConfig config) {
    final size = config.sizeScale.isFinite ? config.sizeScale : 1.0;
    return BubblePackageConfig(
      name: config.name.trim().isEmpty ? '段评气泡' : config.name.trim(),
      dirName: config.dirName,
      svgTemplate: config.svgTemplate.isEmpty ? defaultSvgTemplate() : config.svgTemplate,
      sizeScale: size.clamp(minSizeScale, maxSizeScale),
      dayNormalColor: _normalizeColor(config.dayNormalColor, defaultNormalColor),
      dayEmphasisColor: _normalizeColor(config.dayEmphasisColor, defaultEmphasisColor),
      nightNormalColor: _normalizeColor(config.nightNormalColor, defaultNormalColor),
      nightEmphasisColor: _normalizeColor(config.nightEmphasisColor, defaultEmphasisColor),
      updatedAt: config.updatedAt,
    );
  }

  String _normalizeColor(String? value, String fallback) {
    var normalized = (value ?? '').trim().isEmpty ? fallback : value!.trim();
    if (!normalized.startsWith('#')) normalized = '#$normalized';
    return normalized;
  }

  Directory _localDir(String dirName) => Directory('${_rootDir.path}/$dirName');

  Future<String> _uniqueDirName(String preferred) async {
    var clean = preferred.replaceAll(RegExp(r'[^a-zA-Z0-9_\u4e00-\u9fa5]'), '_');
    if (clean.isEmpty) clean = 'bubble_${DateTime.now().millisecondsSinceEpoch}';
    var candidate = clean;
    var index = 1;
    while (_localDir(candidate).existsSync()) {
      candidate = '${clean}_$index';
      index++;
    }
    return candidate;
  }
}
