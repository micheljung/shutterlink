import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/settings_repository.dart';
import '../../ptpip/camera_client.dart';
import '../gallery/gallery_cubit.dart';
import '../gallery/photo_group.dart';
import '../gallery/thumbnail_cache.dart';
import '../settings/settings_cubit.dart';
import 'full_image_loader.dart';

class PreviewScreen extends StatefulWidget {
  const PreviewScreen({
    super.key,
    required this.client,
    required this.initialIndex,
  });

  static Route<void> route(
    BuildContext context, {
    required CameraClient client,
    required int index,
  }) {
    final gallery = context.read<GalleryCubit>();
    return MaterialPageRoute(
      builder: (_) => BlocProvider.value(
        value: gallery,
        child: PreviewScreen(client: client, initialIndex: index),
      ),
    );
  }

  final CameraClient client;
  final int initialIndex;

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  late final _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GalleryCubit>().state;
    final quality = context.select<SettingsCubit, PreviewQuality>(
      (cubit) => cubit.state.previewQuality,
    );
    final groups = state.groups;
    final group = groups[_index];
    final selected = state.selected.contains(group.key);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(group.baseName),
        actions: [
          IconButton(
            tooltip: selected ? 'Deselect' : 'Select',
            icon: Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
            ),
            onPressed: () => context.read<GalleryCubit>().toggle(group),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: groups.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) {
          final group = groups[index];
          return _PreviewPage(
            key: ValueKey(group.key),
            group: group,
            client: widget.client,
            quality: quality,
          );
        },
      ),
    );
  }
}

class _PreviewPage extends StatefulWidget {
  const _PreviewPage({
    super.key,
    required this.group,
    required this.client,
    required this.quality,
  });

  final PhotoGroup group;
  final CameraClient client;
  final PreviewQuality quality;

  @override
  State<_PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<_PreviewPage> {
  final _cancelToken = CancelToken();
  late final _cache = context.read<ThumbnailCache>();
  Uint8List? _thumbnail;

  @override
  void initState() {
    super.initState();
    final source = widget.group.thumbnailSource;
    _thumbnail = _cache.peek(source);
    if (_thumbnail == null) _load(source);
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    super.dispose();
  }

  Future<void> _load(CameraObject source) async {
    try {
      final bytes = await _cache.get(
        source,
        (handle) => widget.client.thumbnail(handle, cancelToken: _cancelToken),
      );
      if (mounted) setState(() => _thumbnail = bytes);
    } on TransferCancelledException {
      if (mounted && !_cancelToken.isCancelled) await _load(source);
    } on Exception {
      // The placeholder stays on screen.
    }
  }

  @override
  Widget build(BuildContext context) => switch (widget.quality) {
    PreviewQuality.thumbnail => PreviewImage(bytes: _thumbnail),
    PreviewQuality.full => FullImageLoader(
      group: widget.group,
      client: widget.client,
      thumbnail: _thumbnail,
    ),
  };
}
