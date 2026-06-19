import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../utils/design_tokens.dart';

class BookCard extends StatelessWidget {
  final String title;
  final String author;
  final String? cover;
  final double progress;
  final String? badge;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const BookCard({
    super.key,
    required this.title,
    required this.author,
    this.cover,
    this.progress = 0,
    this.badge,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DesignTokens.panelRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Container(
                    color: colorScheme.surfaceContainerHighest,
                    child: Center(
                      child: cover != null
                          ? CachedNetworkImage(
                              imageUrl: cover!,
                              fit: BoxFit.cover,
                              memCacheWidth: 240,
                              errorWidget: (context, url, error) {
                                return const Icon(Icons.book, size: 48);
                              },
                            )
                          : const Icon(Icons.book, size: 48),
                    ),
                  ),
                  if (badge != null)
                    Positioned(
                      top: DesignTokens.spacingSm,
                      left: DesignTokens.spacingSm,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          borderRadius: BorderRadius.circular(
                              DesignTokens.actionRadius),
                        ),
                        child: Text(
                          badge!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: DesignTokens.fontCaption,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(DesignTokens.spacingSm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: DesignTokens.fontCaption,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (progress > 0) ...[
                    const SizedBox(height: DesignTokens.spacingXs),
                    LinearProgressIndicator(
                      value: progress,
                      backgroundColor: colorScheme.surfaceContainerHighest,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
