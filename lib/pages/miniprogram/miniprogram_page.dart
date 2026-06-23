import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../models/miniprogram.dart';
import '../../utils/design_tokens.dart';

class MiniprogramPage extends StatefulWidget {
  const MiniprogramPage({super.key});

  @override
  State<MiniprogramPage> createState() => _MiniprogramPageState();
}

class _MiniprogramPageState extends State<MiniprogramPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final List<Miniprogram> _miniprograms = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 参考 legado-main: 根据实际 primary 颜色明暗决定标题文字颜色
    final primaryColor = Theme.of(context).colorScheme.primary;
    final appBarForeground = ThemeData.estimateBrightnessForColor(primaryColor) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Scaffold(
      body: Column(
        children: [
          // 参考原版：TitleBar (AppBarLayout) - 搜索框和标题栏在同一行
          Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top,
            ),
            color: Theme.of(context).colorScheme.primary,
            child: Column(
              children: [
                // Toolbar + 搜索框在同一行（不显示标题文字）
                SizedBox(
                  height: DesignTokens.topBarHeight,
                  child: Row(
                    children: [
                      const SizedBox(width: DesignTokens.spacingSm),
                      // 搜索框（参考原版：高度30dp）
                      Expanded(
                        child: SizedBox(
                          height: 32,
                          child: TextField(
                            controller: _searchController,
                            decoration: InputDecoration(
                              hintText: '搜索订阅',
                              hintStyle: TextStyle(fontSize: DesignTokens.fontSummary, color: appBarForeground.withValues(alpha: 0.7)),
                              prefixIcon: Icon(Icons.search, size: 16, color: appBarForeground.withValues(alpha: 0.7)),
                              suffixIcon: _searchQuery.isNotEmpty
                                  ? IconButton(
                                      icon: Icon(Icons.clear, size: 16, color: appBarForeground.withValues(alpha: 0.7)),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () {
                                        _searchController.clear();
                                        setState(() {
                                          _searchQuery = '';
                                        });
                                      },
                                    )
                                  : null,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(DesignTokens.searchRadius),
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: DesignTokens.spacingSm, vertical: 0),
                              isDense: true,
                            ),
                            style: TextStyle(fontSize: DesignTokens.fontSummary, color: appBarForeground),
                            onChanged: (value) {
                              setState(() {
                                _searchQuery = value;
                              });
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: DesignTokens.spacingXs),
                      // 历史记录
                      IconButton(
                        icon: Icon(Icons.history, size: 20, color: appBarForeground),
                        tooltip: '历史记录',
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('历史记录功能开发中'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                      // 收藏分组
                      IconButton(
                        icon: Icon(Icons.folder_outlined, size: 20, color: appBarForeground),
                        tooltip: '收藏分组',
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('收藏分组功能开发中'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                      // 设置
                      IconButton(
                        icon: Icon(Icons.settings, size: 20, color: appBarForeground),
                        tooltip: '设置',
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('设置功能开发中'),
                              duration: Duration(seconds: 1),
                            ),
                          );
                        },
                      ),
                      // 更多菜单
                      PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert, size: 20, color: appBarForeground),
                        tooltip: '更多',
                        offset: const Offset(0, DesignTokens.topBarHeight),
                        onSelected: (value) {
                          if (value == 'add') {
                            _showInstallDialog();
                          }
                        },
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'add',
                            child: Text('添加小程序', style: TextStyle(color: appBarForeground)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 小程序列表
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
            size: DesignTokens.emptyIconSize,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: DesignTokens.spacingLg),
          Text(
            '暂无小程序',
            style: TextStyle(
              fontSize: DesignTokens.fontSubtitle,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: DesignTokens.spacingSm),
          Text(
            '点击右上角按钮安装小程序',
            style: TextStyle(
              fontSize: DesignTokens.fontBody,
              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      cacheExtent: 500,
      padding: const EdgeInsets.all(DesignTokens.spacingMd),
      itemCount: _miniprograms.length,
      itemBuilder: (context, index) {
        final mp = _miniprograms[index];
        return RepaintBoundary(child: _buildMiniprogramItem(mp));
      },
    );
  }

  Widget _buildMiniprogramItem(Miniprogram mp) {
    return Container(
      margin: const EdgeInsets.only(bottom: DesignTokens.spacingSm),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(DesignTokens.panelRadius),
      ),
      child: ListTile(
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(DesignTokens.panelRadius),
          ),
          child: mp.icon != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(DesignTokens.panelRadius),
                  clipBehavior: Clip.hardEdge,
                  child: CachedNetworkImage(
                    imageUrl: mp.icon!,
                    fit: BoxFit.cover,
                    memCacheWidth: 96,
                    errorWidget: (context, url, error) {
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
            fontSize: DesignTokens.fontCaption,
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
                  fontSize: DesignTokens.fontCaption,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: DesignTokens.spacingSm),
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
              const SizedBox(height: DesignTokens.spacingSm),
              _buildDetailRow('描述', mp.description ?? '无'),
              const SizedBox(height: DesignTokens.spacingSm),
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
