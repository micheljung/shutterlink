import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import '../spacing.dart';

Uri sessionPageUrl(String serverUrl, String code) {
  final server = Uri.parse(serverUrl.trim());
  return server.replace(
    pathSegments: [
      ...server.pathSegments.where((segment) => segment.isNotEmpty),
      's',
      code,
    ],
  );
}

class SessionQrSheet extends StatelessWidget {
  const SessionQrSheet({
    super.key,
    required this.serverUrl,
    required this.code,
  });

  static const _qrSize = 240.0;

  final String serverUrl;
  final String code;

  static Future<void> show(
    BuildContext context, {
    required String serverUrl,
    required String code,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SessionQrSheet(serverUrl: serverUrl, code: code),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = sessionPageUrl(serverUrl, code).toString();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.large),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Scan to see your photos', style: theme.textTheme.titleMedium),
            const SizedBox(height: Spacing.large),
            ColoredBox(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(Spacing.medium),
                child: SizedBox.square(
                  dimension: _qrSize,
                  child: PrettyQrView.data(
                    data: url,
                    decoration: const PrettyQrDecoration(
                      shape: PrettyQrSquaresSymbol(color: Colors.black),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Spacing.large),
            SelectableText(
              code,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.small),
            SelectableText(
              url,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
