import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/exif.dart';
import '../../ptpip/camera_client.dart';
import '../download/download_cubit.dart';
import '../download/download_state.dart';
import '../spacing.dart';
import 'full_image_load.dart';

/// Shows the full-size image of [load] once it arrives, the [thumbnail]
/// until then, each turned upright.
///
/// The load starts once [thumbnailSettled], so it doesn't hold up the
/// thumbnail on the camera. While a download runs it reads only the
/// orientation.
class FullImageLoader extends StatefulWidget {
  const FullImageLoader({
    super.key,
    required this.load,
    required this.client,
    required this.thumbnail,
    required this.thumbnailSettled,
  });

  static const unavailableHint = 'Full resolution available after download';

  final FullImageLoad load;
  final CameraClient client;
  final Uint8List? thumbnail;
  final bool thumbnailSettled;

  @override
  State<FullImageLoader> createState() => _FullImageLoaderState();
}

class _FullImageLoaderState extends State<FullImageLoader> {
  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(FullImageLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  /// While a download runs, only the small head of the file is read, for
  /// the orientation.
  void _sync() {
    if (!widget.thumbnailSettled) return;
    final load = widget.load;
    if (context.read<DownloadCubit>().state.isActive) {
      // A head read for the orientation may go on; a full load may not.
      if (load.loading) load.pause();
      load.start(orientationOnly: true);
    } else {
      load.start();
    }
  }

  void _onDownloadChanged(BuildContext context, DownloadState download) {
    if (!download.isActive) widget.load.release();
    _sync();
  }

  @override
  Widget build(BuildContext context) =>
      BlocListener<DownloadCubit, DownloadState>(
        listenWhen: (previous, current) =>
            previous.isActive != current.isActive,
        listener: _onDownloadChanged,
        child: ListenableBuilder(listenable: widget.load, builder: _build),
      );

  /// A camera thumbnail is as the sensor saw it, unless it carries its own
  /// EXIF orientation, which the decoder applies.
  int _thumbnailTurns(int photoTurns) {
    final thumbnail = widget.thumbnail;
    if (widget.client.thumbnailsUpright || thumbnail == null) return 0;
    return extraQuarterTurns(photoTurns, thumbnail);
  }

  Widget _build(BuildContext context, Widget? _) {
    final load = widget.load;
    final full = load.full;
    final thumbnailTurns = _thumbnailTurns(load.quarterTurns);
    final downloading = context.select<DownloadCubit, bool>(
      (cubit) => cubit.state.isActive,
    );
    final width =
        MediaQuery.sizeOf(context).width *
        MediaQuery.devicePixelRatioOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        PreviewImage(
          bytes: full ?? widget.thumbnail,
          quarterTurns: full == null ? thumbnailTurns : load.fullQuarterTurns,
          fallback: widget.thumbnail,
          fallbackQuarterTurns: thumbnailTurns,
          cacheSize: full == null ? null : width.round(),
        ),
        if (load.loading)
          const Align(
            alignment: Alignment.bottomCenter,
            child: LinearProgressIndicator(),
          ),
        if (downloading && full == null)
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
    this.quarterTurns = 0,
    this.fallback,
    this.fallbackQuarterTurns = 0,
    this.cacheSize,
  });

  final Uint8List? bytes;

  /// Clockwise quarter turns that show [bytes] upright.
  final int quarterTurns;
  final Uint8List? fallback;
  final int fallbackQuarterTurns;

  /// Decode to this many pixels across the screen, whichever way the image
  /// is turned.
  final int? cacheSize;

  @override
  Widget build(BuildContext context) {
    final bytes = this.bytes;
    if (bytes == null) return const _Placeholder(Icons.photo_outlined);
    final sideways = quarterTurns.isOdd;
    // Always a RotatedBox, so the Image keeps its place in the tree and
    // swaps without a gap when the turn changes.
    return RotatedBox(
      quarterTurns: quarterTurns,
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        cacheWidth: sideways ? null : cacheSize,
        cacheHeight: sideways ? cacheSize : null,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) {
          final fallback = this.fallback;
          if (fallback == null || identical(fallback, bytes)) {
            return const _Placeholder(Icons.broken_image_outlined);
          }
          return RotatedBox(
            quarterTurns: (fallbackQuarterTurns - quarterTurns) % 4,
            child: PreviewImage(bytes: fallback),
          );
        },
      ),
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
