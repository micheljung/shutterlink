import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:url_launcher/url_launcher.dart';

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
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(Spacing.large),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Scan to see your photos',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: Spacing.large),
          SessionQrCode(serverUrl: serverUrl, code: code),
        ],
      ),
    ),
  );
}

/// A Session's QR code, its code and its page address.
class SessionQrCode extends StatelessWidget {
  const SessionQrCode({
    super.key,
    required this.serverUrl,
    required this.code,
    this.size = defaultSize,
  });

  static const defaultSize = 240.0;
  static const openLabel = 'Open in browser';
  static const openFailedText = 'No browser could open the link.';

  final String serverUrl;
  final String code;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = sessionPageUrl(serverUrl, code);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ColoredBox(
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.medium),
            child: SessionQrImage(serverUrl: serverUrl, code: code, size: size),
          ),
        ),
        const SizedBox(height: Spacing.large),
        SelectableText(
          code,
          style: theme.textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Spacing.medium),
        SizedBox(
          width: size + 2 * Spacing.medium,
          child: SessionUrlField(url: url.toString()),
        ),
        const SizedBox(height: Spacing.medium),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.open_in_browser),
          label: const Text(openLabel),
          onPressed: () => _open(context, url),
        ),
      ],
    );
  }
}

/// Just the QR code of a Session's page, black on transparent.
class SessionQrImage extends StatelessWidget {
  const SessionQrImage({
    super.key,
    required this.serverUrl,
    required this.code,
    required this.size,
  });

  final String serverUrl;
  final String code;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: PrettyQrView.data(
      data: sessionPageUrl(serverUrl, code).toString(),
      decoration: const PrettyQrDecoration(
        shape: PrettyQrSquaresSymbol(color: Colors.black),
      ),
    ),
  );
}

Future<void> _open(BuildContext context, Uri url) async {
  final messenger = ScaffoldMessenger.of(context);
  bool opened;
  try {
    opened = await launchUrl(url, mode: LaunchMode.externalApplication);
  } on PlatformException {
    opened = false;
  }
  if (!opened) {
    messenger.showSnackBar(
      const SnackBar(content: Text(SessionQrCode.openFailedText)),
    );
  }
}

/// A one-line, sideways-scrolling address that is copied when tapped.
class SessionUrlField extends StatefulWidget {
  const SessionUrlField({super.key, required this.url});

  static const copyLabel = 'Copy link';
  static const copiedLabel = 'Copied';
  static const copiedFor = Duration(seconds: 2);

  final String url;

  @override
  State<SessionUrlField> createState() => _SessionUrlFieldState();
}

class _SessionUrlFieldState extends State<SessionUrlField> {
  late final _controller = TextEditingController(text: widget.url);
  Timer? _copiedTimer;

  @override
  void didUpdateWidget(SessionUrlField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _controller.text = widget.url;
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.url));
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() {
      _copiedTimer = Timer(SessionUrlField.copiedFor, () {
        if (mounted) setState(() => _copiedTimer = null);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final copied = _copiedTimer != null;
    return TextField(
      controller: _controller,
      readOnly: true,
      showCursor: false,
      enableInteractiveSelection: false,
      maxLines: 1,
      onTap: _copy,
      style: const TextStyle(fontFamily: 'monospace'),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        border: const OutlineInputBorder(),
        suffixIcon: Icon(
          copied ? Icons.check : Icons.copy,
          semanticLabel: copied
              ? SessionUrlField.copiedLabel
              : SessionUrlField.copyLabel,
        ),
      ),
    );
  }
}
