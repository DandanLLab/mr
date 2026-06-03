import 'package:flutter/material.dart';
import '../../models/miniprogram.dart';

class MiniprogramPage extends StatefulWidget {
  const MiniprogramPage({super.key});

  @override
  State<MiniprogramPage> createState() => _MiniprogramPageState();
}

class _MiniprogramPageState extends State<MiniprogramPage> {
  final List<Miniprogram> _miniprograms = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('小程序'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showInstallDialog,
          ),
        ],
      ),
      body: _miniprograms.isEmpty
          ? _buildEmptyState()
          : _buildGrid(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.apps_outlined,
            size: 80,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            '暂无小程序',
            style: TextStyle(
              fontSize: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击右上角按钮安装小程序',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.8,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: _miniprograms.length,
      itemBuilder: (context, index) {
        final mp = _miniprograms[index];
        return _buildMiniprogramCard(mp);
      },
    );
  }

  Widget _buildMiniprogramCard(Miniprogram mp) {
    return GestureDetector(
      onTap: () => _launchMiniprogram(mp),
      onLongPress: () => _showMiniprogramOptions(mp),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: mp.icon != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.network(
                      mp.icon!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return Icon(
                          Icons.apps,
                          size: 32,
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                        );
                      },
                    ),
                  )
                : Icon(
                    Icons.apps,
                    size: 32,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
          ),
          const SizedBox(height: 8),
          Text(
            mp.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
          Text(
            'v${mp.version}',
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  void _launchMiniprogram(Miniprogram mp) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(mp.name),
          content: const Text('小程序功能开发中...'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _showMiniprogramOptions(Miniprogram mp) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.info),
                title: const Text('查看详情'),
                onTap: () {
                  Navigator.pop(context);
                  _showMiniprogramDetail(mp);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('导出'),
                onTap: () {
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('卸载'),
                onTap: () {
                  Navigator.pop(context);
                  _uninstallMiniprogram(mp);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showMiniprogramDetail(Miniprogram mp) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(mp.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('版本: ${mp.version}'),
              const SizedBox(height: 8),
              Text('描述: ${mp.description ?? "无"}'),
              const SizedBox(height: 8),
              Text('占用空间: ${mp.size != null ? "${(mp.size! / 1024).toStringAsFixed(2)} KB" : "未知"}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _uninstallMiniprogram(Miniprogram mp) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('确认卸载'),
          content: Text('确定要卸载 ${mp.name} 吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _miniprograms.remove(mp);
                });
                Navigator.pop(context);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _showInstallDialog() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.folder),
                title: const Text('本地导入'),
                subtitle: const Text('选择 .dan 文件'),
                onTap: () {
                  Navigator.pop(context);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cloud_download),
                title: const Text('网络下载'),
                subtitle: const Text('输入 URL'),
                onTap: () {
                  Navigator.pop(context);
                  _showUrlInputDialog();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showUrlInputDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('输入下载地址'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'https://example.com/miniprogram.dan',
            ),
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
              child: const Text('下载'),
            ),
          ],
        );
      },
    );
  }
}
