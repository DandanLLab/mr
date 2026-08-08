/// EPUB Container 抽象 —— 统一资源访问接口
///
/// 移植自 Readium Kotlin-toolkit 的 Container 概念：
/// 提供统一的资源读取接口，屏蔽底层存储差异（ZIP 内存 / 解压目录 / 网络包）。
///
/// 现有实现：
/// - [_MapArchiveReader]（epub_parser.dart）：从 ZIP 解压后的 Map 读取
/// - [DirectoryEpubArchiveReader]：从解压目录读取（extractedBasePath 方案）
///
/// 所有实现都遵循相同的路径匹配策略：
/// 1. 精确匹配
/// 2. 大小写不敏感匹配（EPUB 生产工具大小写敏感性不一致）
library;

import 'dart:convert';
import 'dart:io';

import 'epub_package_parser.dart';

/// 从文件系统解压目录读取 EPUB 资源的 Container 实现
///
/// 配合 `extractedBasePath` 方案使用：EPUB 导入时解压到应用文档目录，
/// 此 Container 包装该目录，提供统一的 [EpubArchiveReader] 接口访问资源。
///
/// 路径匹配策略与 _MapArchiveReader 一致：先精确匹配，再大小写不敏感匹配。
class DirectoryEpubArchiveReader implements EpubArchiveReader {
  final String _basePath;

  DirectoryEpubArchiveReader(this._basePath);

  String _resolve(String path) {
    final clean = path.replaceAll('\\', '/');
    return '$_basePath/$clean';
  }

  @override
  bool exists(String path) {
    final file = File(_resolve(path));
    if (file.existsSync()) return true;
    // 大小写不敏感匹配
    final dir = Directory(_basePath);
    final lower = path.toLowerCase();
    try {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          final relative = entity.path
              .replaceAll('\\', '/')
              .replaceFirst(_basePath.replaceAll('\\', '/'), '')
              .replaceFirst(RegExp(r'^/'), '');
          if (relative.toLowerCase() == lower) return true;
        }
      }
    } catch (_) {}
    return false;
  }

  @override
  List<String> list() {
    final result = <String>[];
    final dir = Directory(_basePath);
    final base = _basePath.replaceAll('\\', '/');
    try {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          var relative = entity.path.replaceAll('\\', '/');
          relative = relative.replaceFirst(base, '');
          relative = relative.replaceFirst(RegExp(r'^/'), '');
          result.add(relative);
        }
      }
    } catch (_) {}
    return result;
  }

  @override
  List<int> readBytes(String path) {
    final file = File(_resolve(path));
    if (file.existsSync()) return file.readAsBytesSync();
    // 大小写不敏感匹配
    final lower = path.toLowerCase();
    final dir = Directory(_basePath);
    try {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) {
          final relative = entity.path
              .replaceAll('\\', '/')
              .replaceFirst(_basePath.replaceAll('\\', '/'), '')
              .replaceFirst(RegExp(r'^/'), '');
          if (relative.toLowerCase() == lower) {
            return File(entity.path).readAsBytesSync();
          }
        }
      }
    } catch (_) {}
    return [];
  }

  @override
  String readText(String path) {
    final bytes = readBytes(path);
    if (bytes.isEmpty) return '';
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }
}
