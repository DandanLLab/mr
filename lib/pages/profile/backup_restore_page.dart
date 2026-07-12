import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../utils/share_helper.dart';
import '../../services/storage_service.dart';
import '../../utils/design_tokens.dart';

class BackupRestorePage extends StatefulWidget {
  const BackupRestorePage({super.key});

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends State<BackupRestorePage> {
  bool _isBackingUp = false;
  List<String> _backupFiles = [];
  String? _lastBackupTime;

  @override
  void initState() {
    super.initState();
    _loadBackupInfo();
  }

  Future<void> _loadBackupInfo() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final backupDir = Directory('${directory.path}/backup');
      if (await backupDir.exists()) {
        final files = await backupDir.list().toList();
        final backupFiles = files
            .where((f) => f.path.endsWith('.json'))
            .map((f) => f.path.split('/').last)
            .toList();
        backupFiles.sort((a, b) => b.compareTo(a)); // 按时间倒序
        setState(() {
          _backupFiles = backupFiles;
          if (backupFiles.isNotEmpty) {
            _lastBackupTime = backupFiles.first.replaceAll('backup_', '').replaceAll('.json', '');
          }
        });
      }
    } catch (e) {
      debugPrint('Load backup info failed: $e');
    }
  }

  Future<void> _backup() async {
    setState(() => _isBackingUp = true);

    try {
      // 收集所有数据
      final data = {
        'version': '1.0',
        'timestamp': DateTime.now().toIso8601String(),
        'books': StorageService.instance.getAllBooks(),
        'bookSources': StorageService.instance.getCachedData('book_sources') ?? '[]',
      };

      // 保存到本地
      final directory = await getApplicationDocumentsDirectory();
      final backupDir = Directory('${directory.path}/backup');
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File('${backupDir.path}/backup_$timestamp.json');
      await file.writeAsString(jsonEncode(data));

      setState(() => _isBackingUp = false);
      _loadBackupInfo();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('备份成功')),
        );
      }
    } catch (e) {
      setState(() => _isBackingUp = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('备份失败: $e')),
        );
      }
    }
  }

  Future<void> _restoreFromFile(String fileName) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/backup/$fileName');
      final content = await file.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;

      // 恢复书籍
      if (data['books'] != null) {
        final books = data['books'] as List;
        for (final book in books) {
          await StorageService.instance.addToBookshelf(book as Map<String, dynamic>);
        }
      }

      // 恢复书源
      if (data['bookSources'] != null) {
        await StorageService.instance.cacheData('book_sources', data['bookSources']);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('恢复成功')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('恢复失败: $e')),
        );
      }
    }
  }

  Future<void> _exportBackup(String fileName) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/backup/$fileName');
      if (!mounted) return;
      await ShareHelper.shareFiles(context, [XFile(file.path)], text: '备份文件');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    }
  }

  Future<void> _importBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final content = await file.readAsString();
        
        // 验证是否为有效的备份文件
        final data = jsonDecode(content);
        if (data is Map && data['version'] != null) {
          // 保存到本地备份目录
          final directory = await getApplicationDocumentsDirectory();
          final backupDir = Directory('${directory.path}/backup');
          if (!await backupDir.exists()) {
            await backupDir.create(recursive: true);
          }

          final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
          final newFile = File('${backupDir.path}/backup_$timestamp.json');
          await newFile.writeAsString(content);

          _loadBackupInfo();

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('导入成功')),
            );
          }
        } else {
          throw Exception('无效的备份文件');
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  Future<void> _deleteBackup(String fileName) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/backup/$fileName');
      await file.delete();
      _loadBackupInfo();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  String _formatBackupTime(String timestamp) {
    try {
      final time = DateTime.parse(timestamp.replaceAll('-', ':'));
      return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return timestamp;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('备份恢复'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(DesignTokens.spacingLg),
        children: [
          // 备份操作
          Card(
            child: Padding(
              padding: const EdgeInsets.all(DesignTokens.spacingLg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '备份',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: DesignTokens.spacingSm),
                  Text(
                    '将书籍和书源数据备份到本地',
                    style: TextStyle(
                      fontSize: DesignTokens.fontCaption,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (_lastBackupTime != null) ...[
                    const SizedBox(height: DesignTokens.spacingSm),
                    Text(
                      '上次备份: ${_formatBackupTime(_lastBackupTime!)}',
                      style: TextStyle(
                        fontSize: DesignTokens.fontCaption,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                  const SizedBox(height: DesignTokens.spacingLg),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _isBackingUp ? null : _backup,
                          icon: _isBackingUp
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.backup),
                          label: const Text('立即备份'),
                        ),
                      ),
                      const SizedBox(width: DesignTokens.spacingSm),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _importBackup,
                          icon: const Icon(Icons.file_download),
                          label: const Text('导入备份'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: DesignTokens.spacingLg),
          // 备份文件列表
          Text(
            '本地备份',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: DesignTokens.spacingSm),
          if (_backupFiles.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(DesignTokens.spacingLg),
                child: Text(
                  '暂无备份文件',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            ..._backupFiles.map((fileName) => Card(
                  child: ListTile(
                    title: Text(_formatBackupTime(
                      fileName.replaceAll('backup_', '').replaceAll('.json', ''),
                    )),
                    subtitle: Text(fileName),
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'restore') {
                          _showRestoreConfirm(fileName);
                        } else if (value == 'export') {
                          _exportBackup(fileName);
                        } else if (value == 'delete') {
                          _showDeleteConfirm(fileName);
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'restore',
                          child: Text('恢复'),
                        ),
                        const PopupMenuItem(
                          value: 'export',
                          child: Text('导出'),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('删除'),
                        ),
                      ],
                    ),
                  ),
                )),
        ],
      ),
    );
  }

  void _showRestoreConfirm(String fileName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复备份'),
        content: const Text('恢复将覆盖当前数据，确定要继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _restoreFromFile(fileName);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirm(String fileName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除备份'),
        content: const Text('确定要删除此备份文件吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteBackup(fileName);
            },
            child: Text('确定', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
  }
}
