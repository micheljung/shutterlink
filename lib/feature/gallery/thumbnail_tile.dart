import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../ptpip/camera_client.dart';
import '../spacing.dart';
import 'photo_group.dart';
import 'thumbnail_cache.dart';

class ThumbnailTile extends StatefulWidget {
  const ThumbnailTile({
    super.key,
    required this.group,
    required this.selected,
    required this.downloaded,
    required this.cache,
    required this.client,
    required this.onTap,
  });

  static const decodeWidth = 320;

  final PhotoGroup group;
  final bool selected;
  final bool downloaded;
  final ThumbnailCache cache;
  final CameraClient client;
  final VoidCallback onTap;

  @override
  State<ThumbnailTile> createState() => _ThumbnailTileState();
}

class _ThumbnailTileState extends State<ThumbnailTile> {
  final _cancelToken = CancelToken();
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final source = widget.group.thumbnailSource;
    _bytes = widget.cache.peek(source);
    if (_bytes == null) _load(source);
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    super.dispose();
  }

  Future<void> _load(CameraObject source) async {
    try {
      final bytes = await widget.cache.get(
        source,
        (handle) => widget.client.thumbnail(handle, cancelToken: _cancelToken),
      );
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _failed = bytes == null;
      });
    } on TransferCancelledException {
      // A disposed tile cancelled the shared request this tile joined.
      if (mounted && !_cancelToken.isCancelled) await _load(source);
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bytes = _bytes;
    return Semantics(
      selected: widget.selected,
      label: widget.group.baseName,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: colors.surfaceContainerHighest,
              child: bytes != null
                  ? Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      cacheWidth: ThumbnailTile.decodeWidth,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const _Placeholder(true),
                    )
                  : _Placeholder(_failed),
            ),
            if (widget.selected)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: _selectedTint),
                  border: Border.all(color: colors.primary, width: _border),
                ),
              ),
            Positioned(
              left: _inset,
              bottom: _inset,
              child: _FormatBadge(group: widget.group),
            ),
            if (widget.downloaded)
              const Positioned(
                right: _inset,
                bottom: _inset,
                child: _DownloadedBadge(),
              ),
            if (widget.selected)
              Positioned(
                right: _inset,
                top: _inset,
                child: Icon(Icons.check_circle, color: colors.primary),
              ),
          ],
        ),
      ),
    );
  }

  static const _selectedTint = 0.25;
  static const _border = 3.0;
  static const _inset = 4.0;
}

class _Placeholder extends StatelessWidget {
  const _Placeholder(this.failed);

  final bool failed;

  @override
  Widget build(BuildContext context) => Center(
    child: Icon(failed ? Icons.broken_image_outlined : Icons.photo_outlined),
  );
}

class _DownloadedBadge extends StatelessWidget {
  const _DownloadedBadge();

  static const _size = 16.0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.inverseSurface,
        shape: BoxShape.circle,
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.tiny),
        child: Icon(
          Icons.download_done,
          size: _size,
          color: colors.onInverseSurface,
          semanticLabel: 'Downloaded',
        ),
      ),
    );
  }
}

class _FormatBadge extends StatelessWidget {
  const _FormatBadge({required this.group});

  final PhotoGroup group;

  String get _label => switch ((group.jpeg != null, group.raw != null)) {
    (true, true) => 'RAW+JPEG',
    (false, true) => 'RAW',
    _ => 'JPEG',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.inverseSurface,
        borderRadius: BorderRadius.circular(_radius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _radius,
          vertical: Spacing.tiny,
        ),
        child: Text(
          _label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: colors.onInverseSurface),
        ),
      ),
    );
  }

  static const _radius = 4.0;
}
