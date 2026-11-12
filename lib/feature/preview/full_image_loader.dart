import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/cr3_preview.dart';
import '../../ptpip/camera_client.dart';
import '../download/download_cubit.dart';
import '../gallery/photo_group.dart';
import '../spacing.dart';

class FullImageLoader extends StatefulWidget {
  const FullImageLoader({
    super.key,
    required this.group,
    required this.client,
    required this.thumbnail,
  });

  static const unavailableHint = 'Full resolution available after download';

  final PhotoGroup group;
  final CameraClient client;
  final Uint8List? thumbnail;

  @override
  State<FullImageLoader> createState() => _FullImageLoaderState();
}

class _FullImageLoaderState extends State<FullImageLoader> {
  final _cancelToken = CancelToken();
  late final bool _unavailable = context.read<DownloadCubit>().state.isActive;
  Uint8List? _full;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (!_unavailable) _load();
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _loading = true;
    try {
      final full = await _fetch();
      if (mounted) setState(() => _full = full);
    } on Exception {
      // The thumbnail stays on screen.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Uint8List?> _fetch() async {
    final jpeg = widget.group.jpeg;
    if (jpeg == null) {
      return readCr3Preview(
        widget.client,
        widget.group.raw!,
        cancelToken: _cancelToken,
      );
    }
    final bytes = BytesBuilder(copy: false);
    await widget.client.download(
      jpeg,
      (chunk) async => bytes.add(chunk),
      cancelToken: _cancelToken,
    );
    return bytes.takeBytes();
  }

  @override
  Widget build(BuildContext context) {
    final full = _full;
    final width =
        MediaQuery.sizeOf(context).width *
        MediaQuery.devicePixelRatioOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        PreviewImage(
          bytes: full ?? widget.thumbnail,
          fallback: widget.thumbnail,
          cacheWidth: full == null ? null : width.round(),
        ),
        if (_loading)
          const Align(
            alignment: Alignment.bottomCenter,
            child: LinearProgressIndicator(),
          ),
        if (_unavailable)
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(Spacing.large),
              child: Text(
                FullImageLoader.unavailableHint,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }
}

class PreviewImage extends StatelessWidget {
  const PreviewImage({
    super.key,
    required this.bytes,
    this.fallback,
    this.cacheWidth,
  });

  final Uint8List? bytes;
  final Uint8List? fallback;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    final bytes = this.bytes;
    if (bytes == null) return const _Placeholder(Icons.photo_outlined);
    return Image.memory(
      bytes,
      fit: BoxFit.contain,
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) {
        final fallback = this.fallback;
        if (fallback == null || identical(fallback, bytes)) {
          return const _Placeholder(Icons.broken_image_outlined);
        }
        return PreviewImage(bytes: fallback);
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) =>
      Center(child: Icon(icon, color: Colors.white));
}
