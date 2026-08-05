// HTML封面模板配置 - 移植自 legado_max CoverHtmlTemplateConfig
// 管理HTML封面模板的增删改查和持久化

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

/// HTML封面模板
class CoverHtmlTemplate {
  String id;
  String name;
  String htmlCode;
  bool isSelected;

  CoverHtmlTemplate({
    required this.id,
    required this.name,
    required this.htmlCode,
    this.isSelected = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'htmlCode': htmlCode,
    'isSelected': isSelected,
  };

  factory CoverHtmlTemplate.fromJson(Map<String, dynamic> json) {
    return CoverHtmlTemplate(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      htmlCode: json['htmlCode'] as String? ?? '',
      isSelected: json['isSelected'] as bool? ?? false,
    );
  }

  CoverHtmlTemplate copy() => CoverHtmlTemplate(
    id: id,
    name: name,
    htmlCode: htmlCode,
    isSelected: isSelected,
  );
}

/// HTML封面模板配置管理
class CoverHtmlTemplateConfig {
  static const _configFileName = 'coverHtmlTemplate.json';

  static CoverHtmlTemplateConfig? _instance;
  static CoverHtmlTemplateConfig get instance => _instance ??= CoverHtmlTemplateConfig._();

  CoverHtmlTemplateConfig._();

  List<CoverHtmlTemplate> _templateList = [];
  bool _loaded = false;

  File? _configFile;

  Future<File> _getFile() async {
    if (_configFile != null) return _configFile!;
    final appDir = await getApplicationDocumentsDirectory();
    _configFile = File('${appDir.path}/$_configFileName');
    return _configFile!;
  }

  /// 默认模板
  List<CoverHtmlTemplate> _getDefaultTemplates() {
    return [
      CoverHtmlTemplate(
        id: 'default',
        name: '默认模板',
        htmlCode: _defaultHtmlCode,
        isSelected: true,
      ),
    ];
  }

  static const _defaultHtmlCode =
      '<!DOCTYPE html>\n<html>\n<head>\n<meta charset="utf-8">\n<style>\n'
      'body{margin:0;padding:0;width:120px;height:160px;display:flex;align-items:center;justify-content:center;background:#f5f5f5;}\n'
      '.cover{width:100%;height:100%;display:flex;flex-direction:column;justify-content:center;align-items:center;}\n'
      '.name{font-size:14px;color:#333;text-align:center;padding:8px;word-break:break-all;}\n'
      '.author{font-size:10px;color:#999;margin-top:4px;}\n</style>\n</head>\n<body>\n'
      '<div class="cover">\n  <div class="name">{{bookName}}</div>\n  <div class="author">{{author}}</div>\n</div>\n'
      '</body>\n</html>';

  /// 加载模板列表
  Future<void> load() async {
    if (_loaded) return;
    final file = await _getFile();
    if (file.existsSync()) {
      try {
        final json = jsonDecode(file.readAsStringSync()) as List;
        _templateList = json.map((e) => CoverHtmlTemplate.fromJson(e as Map<String, dynamic>)).toList();
      } catch (e) {
        debugPrint('加载HTML封面模板失败: $e');
        _templateList = _getDefaultTemplates();
      }
    } else {
      _templateList = _getDefaultTemplates();
      await save();
    }
    _loaded = true;
  }

  List<CoverHtmlTemplate> get templateList {
    if (!_loaded) return _getDefaultTemplates();
    return _templateList;
  }

  /// 保存模板列表
  Future<void> save() async {
    final file = await _getFile();
    await file.writeAsString(jsonEncode(_templateList.map((t) => t.toJson()).toList()));
  }

  /// 添加模板
  Future<void> addTemplate(CoverHtmlTemplate template) async {
    await load();
    if (_templateList.isEmpty) template.isSelected = true;
    _templateList.add(template);
    await save();
  }

  /// 更新模板
  Future<void> updateTemplate(CoverHtmlTemplate template) async {
    await load();
    final index = _templateList.indexWhere((t) => t.id == template.id);
    if (index != -1) {
      _templateList[index] = template;
      await save();
    }
  }

  /// 删除模板
  Future<void> deleteTemplate(int index) async {
    await load();
    if (index < 0 || index >= _templateList.length) return;
    final wasSelected = _templateList[index].isSelected;
    _templateList.removeAt(index);
    if (wasSelected && _templateList.isNotEmpty) {
      _templateList[0].isSelected = true;
    }
    await save();
  }

  /// 设置当前使用的模板
  Future<void> setSelectedTemplate(String id) async {
    await load();
    for (final t in _templateList) {
      t.isSelected = t.id == id;
    }
    await save();
  }

  /// 获取当前选中的模板
  Future<CoverHtmlTemplate?> getSelectedTemplate() async {
    await load();
    return _templateList.where((t) => t.isSelected).firstOrNull ?? _templateList.firstOrNull;
  }

  /// 生成新模板ID
  String generateId() => DateTime.now().millisecondsSinceEpoch.toString();
}
