import 'package:flutter/material.dart';

import '../feature/spacing.dart';
import 'lens_rings.dart';
import 'shutterlink_logo.dart';
import 'shutterlink_wordmark.dart';

class BrandIntro extends StatelessWidget {
  const BrandIntro({
    super.key,
    this.compact = false,
    this.padding = const EdgeInsets.symmetric(horizontal: Spacing.extraLarge),
    this.children = const [],
  });

  static const tagline =
      'Download photos from your Canon EOS R over Wi-Fi or USB.';

  static const _heroHeight = 240.0;
  static const _compactHeroHeight = 160.0;
  static const _logoSize = 136.0;
  static const _compactLogoSize = 96.0;

  /// Shrinks the hero so a notice below it fits without scrolling.
  final bool compact;
  final EdgeInsets padding;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomScrollView(
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: compact ? _compactHeroHeight : _heroHeight,
                  ),
                  child: LensHero(
                    logo: ShutterlinkLogo(
                      size: compact ? _compactLogoSize : _logoSize,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ShutterlinkWordmark(),
                    const SizedBox(height: Spacing.small),
                    Text(
                      tagline,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (children.isNotEmpty) ...[
                      const SizedBox(height: Spacing.large),
                      ...children,
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
