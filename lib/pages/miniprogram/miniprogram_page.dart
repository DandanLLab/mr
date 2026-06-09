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
      body: Column(
        children: [
          // 页眉（标题栏）
          Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  Text(
                    '小程序',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: _showInstallDialog,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _miniprograms.isEmpty
                ? _buildEmptyState()
                : _buildList(),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.apps_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            '暂无小程序',
            style: TextStyle(
              fontSize: 16,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '点击右上角按钮安装小程序',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity(0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _miniprograms.length,
      itemBuilder: (context, index) {
        final mp = _miniprograms[index];
        return _buildMiniprogramItem(mp);
      },
    );
  }

  Widget _buildMiniprogramItem(Miniprogram mp) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: mp.icon != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    mp.icon!,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Icon(
                        Icons.apps,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      );
                    },
                  ),
                )
              : Icon(
                  Icons.apps,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
        ),
        title: Text(
          mp.name,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          'v${mp.version} · ${mp.description ?? "暂无描述"}',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (mp.size != null)
              Text(
                '${(mp.size! / 1024).toStringAsFixed(1)} KB',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
        onTap: () => _launchMiniprogram(mp),
        onLongPress: () => _showMiniprogramOptions(mp),
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
                leading: const Icon(Icons.info_outline),
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
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  '卸载',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
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
              _buildDetailRow('版本', 'v${mp.version}'),
              const SizedBox(height: 8),
              _buildDetailRow('描述', mp.description ?? '无'),
              const SizedBox(height: 8),
              _buildDetailRow(
                '占用空间',
                mp.size != null ? '${(mp.size! / 1024).toStringAsFixed(2)} KB' : '未知',
              ),
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

  Widget _buildDetailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Expanded(
          child: Text(value),
        ),
      ],
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
              child: Text(
                '卸载',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
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
              border: OutlineInputBorder(),
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
