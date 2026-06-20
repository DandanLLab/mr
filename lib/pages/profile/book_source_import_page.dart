import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../models/book_source.dart';
import '../../services/book_source_import_service.dart';
import '../../utils/design_tokens.dart';

/// 书源导入页面
/// 支持网络导入、本地文件导入、二维码导入、剪贴板导入
class BookSourceImportPage extends StatefulWidget {
  /// 外部传入的初始文本（如其他 App 分享来的 URL 或 JSON）
  final String? initialText;

  const BookSourceImportPage({super.key, this.initialText});

  @override
  State<BookSourceImportPage> createState() => _BookSourceImportPageState();
}

class _BookSourceImportPageState extends State<BookSourceImportPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _urlController = TextEditingController();
  final _textController = TextEditingController();
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    if (widget.initialText != null && widget.initialText!.isNotEmpty) {
      _textController.text = widget.initialText!;
      // 如果是 URL，填入 URL 标签
      if (_looksLikeUrl(widget.initialText!)) {
        _urlController.text = widget.initialText!;
        _tabController.index = 0;
      } else {
        _tabController.index = 1;
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _urlController.dispose();
    _textController.dispose();
    super.dispose();
  }

  bool _looksLikeUrl(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith('http://') || trimmed.startsWith('https://');
  }

  Future<void> _importFromUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _showError('请输入书源地址');
      return;
    }
    await _doImport(url);
  }

  Future<void> _importFromText() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      _showError('请输入书源 JSON 内容');
      return;
    }
    await _doImport(text);
  }

  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt', 'js'],
      );
      if (result == null || result.files.isEmpty) return;

      setState(() => _isImporting = true);

      final file = result.files.first;
      final bytes = file.bytes ??
          await _readFileBytes(file.path!);
      final ext = file.extension?.toLowerCase() ?? 'json';

      final importResult =
          await BookSourceImportService().importBytes(bytes, fileExtension: ext);
      _showResult(importResult);
    } catch (e) {
      _showError('文件导入失败: $e');
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<Uint8List> _readFileBytes(String path) async {
    // file_picker 在移动端已返回 bytes，Web 端也返回 bytes
    // 此方法作为后备：从文件路径读取字节（仅原生平台）
    if (kIsWeb) return Uint8List(0);
    try {
      final file = File(path);
      return await file.readAsBytes();
    } catch (e) {
      debugPrint('读取文件失败: $e');
      return Uint8List(0);
    }
  }

  Future<void> _importFromQr() async {
    final scanned = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => const _QrScannerPage(),
      ),
    );
    if (scanned == null || scanned.isEmpty) return;
    await _doImport(scanned);
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      _showError('剪贴板为空');
      return;
    }
    _textController.text = text;
    await _doImport(text);
  }

  Future<void> _doImport(String text) async {
    setState(() => _isImporting = true);
    try {
      final result = await BookSourceImportService().importText(text);
      _showResult(result);
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      _showError('导入失败: $e');
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  void _showResult(BookSourceImportResult result) {
    final msg = '导入完成：新增 ${result.added}，更新 ${result.updated}，未变 ${result.unchanged}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('导入书源'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '网络导入'),
            Tab(text: '文本导入'),
            Tab(icon: Icon(Icons.qr_code_scanner), text: '二维码'),
          ],
        ),
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tabController,
            children: [
              _buildUrlTab(),
              _buildTextTab(),
              _buildQrTab(),
            ],
          ),
          if (_isImporting)
            Container(
              color: Colors.black54,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _buildUrlTab() {
    return Padding(
      padding: const EdgeInsets.all(DesignTokens.spacingLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '输入书源订阅地址（网络链接），将自动下载并导入',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: DesignTokens.spacingMd),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: '书源地址',
              hintText: 'https://example.com/sources.json',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _importFromUrl(),
          ),
          const SizedBox(height: DesignTokens.spacingMd),
          FilledButton.icon(
            onPressed: _isImporting ? null : _importFromUrl,
            icon: const Icon(Icons.download),
            label: const Text('导入'),
          ),
          const SizedBox(height: DesignTokens.spacingLg),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(DesignTokens.spacingMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('使用说明',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: DesignTokens.spacingSm),
                  const Text(
                    '• 支持 Legado 格式的书源 JSON\n'
                    '• 地址应返回 JSON 数组或单个书源对象\n'
                    '• 也支持包含 {"sourceUrls": ["url1", ...]} 的订阅格式\n'
                    '• .js 格式的 JS 书源请使用文本导入',
                    style: TextStyle(fontSize: 13, height: 1.6),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextTab() {
    return Padding(
      padding: const EdgeInsets.all(DesignTokens.spacingLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '粘贴书源 JSON 文本或 JS 书源代码',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: DesignTokens.spacingMd),
          Expanded(
            child: TextField(
              controller: _textController,
              maxLines: null,
              expands: true,
              decoration: const InputDecoration(
                hintText: '粘贴书源 JSON 或 JS 代码...',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.text_snippet),
              ),
              textAlignVertical: TextAlignVertical.top,
            ),
          ),
          const SizedBox(height: DesignTokens.spacingMd),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _isImporting ? null : _importFromClipboard,
                icon: const Icon(Icons.content_paste),
                label: const Text('从剪贴板'),
              ),
              const SizedBox(width: DesignTokens.spacingMd),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isImporting ? null : _importFromText,
                  icon: const Icon(Icons.download),
                  label: const Text('导入'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQrTab() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.qr_code_scanner,
              size: 80, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: DesignTokens.spacingLg),
          const Text('扫描书源二维码导入',
              style: TextStyle(fontSize: DesignTokens.fontTitle)),
          const SizedBox(height: DesignTokens.spacingSm),
          const Text('支持包含书源 JSON 或订阅 URL 的二维码',
              style: TextStyle(color: Colors.grey)),
          const SizedBox(height: DesignTokens.spacingXl),
          FilledButton.icon(
            onPressed: _isImporting ? null : _importFromQr,
            icon: const Icon(Icons.camera_alt),
            label: const Text('开始扫码'),
          ),
          const SizedBox(height: DesignTokens.spacingLg),
          OutlinedButton.icon(
            onPressed: _isImporting ? null : _importFromFile,
            icon: const Icon(Icons.folder_open),
            label: const Text('从文件导入'),
          ),
        ],
      ),
    );
  }
}

/// 二维码扫描页面
class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  late MobileScannerController _controller;
  bool _hasScanned = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          if (_hasScanned) return;
          final barcodes = capture.barcodes;
          if (barcodes.isEmpty) return;
          final value = barcodes.first.rawValue;
          if (value == null || value.isEmpty) return;
          _hasScanned = true;
          _controller.stop();
          Navigator.pop(context, value);
        },
      ),
    );
  }
}
