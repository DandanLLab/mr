import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/explore_show_provider.dart';
import '../../routes/app_routes.dart';
import '../../utils/design_tokens.dart';

class ExploreShowPage extends StatefulWidget {
  final String sourceUrl;
  final String sourceName;
  final String exploreName;
  final String exploreUrl;

  const ExploreShowPage({
    super.key,
    required this.sourceUrl,
    required this.sourceName,
    required this.exploreName,
    required this.exploreUrl,
  });

  @override
  State<ExploreShowPage> createState() => _ExploreShowPageState();
}

class _ExploreShowPageState extends State<ExploreShowPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ExploreShowProvider>().loadExploreBooks(
        widget.sourceUrl,
        widget.exploreUrl,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.exploreName),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              context.read<ExploreShowProvider>().loadExploreBooks(
                widget.sourceUrl,
                widget.exploreUrl,
              );
            },
          ),
        ],
      ),
      body: Consumer<ExploreShowProvider>(
        builder: (context, provider, child) {
          if (provider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (provider.books.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.book_outlined,
                    size: DesignTokens.emptyIconSize,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: DesignTokens.spacingLg),
                  Text(
                    '暂无内容',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () => provider.loadExploreBooks(
              widget.sourceUrl,
              widget.exploreUrl,
            ),
            child: GridView.builder(
              cacheExtent: 500,
              padding: const EdgeInsets.all(DesignTokens.spacingMd),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 0.65,
                crossAxisSpacing: DesignTokens.spacingMd,
                mainAxisSpacing: DesignTokens.spacingMd,
              ),
              itemCount: provider.books.length,
              itemBuilder: (context, index) {
                final book = provider.books[index];
                return _buildBookCard(book);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildBookCard(Map<String, dynamic> book) {
    return GestureDetector(
      onTap: () {
        Navigator.pushNamed(
          context,
          AppRoutes.detail,
          arguments: {
            'bookUrl': book['bookUrl'],
            'bookData': book,
          },
        );
      },
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Center(
                  child: Icon(
                    Icons.book,
                    size: 48,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(DesignTokens.spacingSm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book['name'] ?? '未知书名',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: DesignTokens.fontCaption,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    book['author'] ?? '未知作者',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
