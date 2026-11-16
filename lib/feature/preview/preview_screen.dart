import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/settings_repository.dart';
import '../../ptpip/camera_client.dart';
import '../download/download_cubit.dart';
import '../download/download_sheet.dart';
import '../gallery/delete_photos.dart';
import '../gallery/gallery_cubit.dart';
import '../gallery/photo_group.dart';
import '../gallery/thumbnail_cache.dart';
import '../settings/settings_cubit.dart';
import 'full_image_load.dart';
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

  /// How many loads of pages left behind are kept, paused, so swiping back
  /// shows them at once or resumes them.
  static const keptLoads = 3;

  /// The full-size loads of the pages built now, by group key.
  final _loads = <String, FullImageLoad>{};

  /// Loads of pages left behind, least recently left first.
  final _kept = <String, FullImageLoad>{};

  @override
  void dispose() {
    // Pages are gone by now and have handed their loads back.
    for (final load in [..._loads.values, ..._kept.values]) {
      load.dispose();
    }
    _controller.dispose();
    super.dispose();
  }

  FullImageLoad _acquire(PhotoGroup group) {
    final kept = _kept.remove(group.key);
    final FullImageLoad load;
    if (kept != null && kept.group == group) {
      load = kept;
    } else {
      kept?.dispose();
      load = FullImageLoad(widget.client, group);
    }
    _loads[group.key] = load;
    return load;
  }

  void _leave(String key, FullImageLoad load) {
    if (identical(_loads[key], load)) _loads.remove(key);
    load.pause();
    final replaced = _kept.remove(key);
    if (replaced != null && !identical(replaced, load)) replaced.dispose();
    _kept[key] = load;
    while (_kept.length > keptLoads) {
      _kept.remove(_kept.keys.first)!.dispose();
    }
  }

  /// Downloads [group] at once, resuming from what the preview already has
  /// of it.
  void _download(PhotoGroup group) {
    final format = context.read<SettingsCubit>().state.format;
    final load = _loads[group.key];
    final started = context.read<DownloadCubit>().start(
      widget.client,
      [group],
      format,
      prefetched: load?.handOver() ?? const {},
      onFetched: load?.adopt,
    );
    // A download that never got going leaves the preview to load on.
    unawaited(
      started.catchError((Object _) {
        load
          ?..release()
          ..start();
      }),
    );
    final gallery = context.read<GalleryCubit>();
    if (gallery.state.selected.contains(group.key)) {
      gallery.setSelected([group], false);
    }
    DownloadSheet.show(context);
  }

  Future<void> _delete(PhotoGroup group) async {
    await confirmDelete(context, widget.client, [group]);
    if (!mounted) return;
    if (context.read<GalleryCubit>().state.groups.isEmpty) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GalleryCubit>().state;
    final downloading = context.select<DownloadCubit, bool>(
      (cubit) => cubit.state.isActive,
    );
    final groups = state.groups;
    if (groups.isEmpty) {
      return const Scaffold(backgroundColor: Colors.black);
    }
    final group = groups[min(_index, groups.length - 1)];
    final selected = state.selected.contains(group.key);
    final format = context.select<SettingsCubit, DownloadFormat>(
      (cubit) => cubit.state.format,
    );
    final deletable = canDeleteNow(context, widget.client);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(group.baseName),
        actions: [
          IconButton(
            tooltip: 'Download',
            icon: const Icon(Icons.download),
            onPressed:
                downloading || state.deleting || group.filesFor(format).isEmpty
                ? null
                : () => _download(group),
          ),
          if (widget.client.canDelete)
            IconButton(
              tooltip: 'Delete from camera',
              icon: const Icon(Icons.delete_outline),
              onPressed: deletable ? () => _delete(group) : null,
            ),
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
            acquire: _acquire,
            leave: _leave,
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
    required this.acquire,
    required this.leave,
  });

  final PhotoGroup group;
  final CameraClient client;

  /// Hands out the page's load, one kept from an earlier visit if any.
  final FullImageLoad Function(PhotoGroup group) acquire;

  /// Takes the load back when the page goes.
  final void Function(String key, FullImageLoad load) leave;

  @override
  State<_PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<_PreviewPage> {
  final _cancelToken = CancelToken();
  late final _cache = context.read<ThumbnailCache>();
  late final FullImageLoad _load;
  Uint8List? _thumbnail;
  bool _thumbnailSettled = false;

  @override
  void initState() {
    super.initState();
    _load = widget.acquire(widget.group);
    _load.addListener(_rememberTurns);
    _seedTurns();
    final source = widget.group.thumbnailSource;
    _thumbnail = _cache.peek(source);
    _thumbnailSettled = _thumbnail != null;
    if (_thumbnail == null) _loadThumbnail(source);
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    _load.removeListener(_rememberTurns);
    widget.leave(widget.group.key, _load);
    super.dispose();
  }

  /// An orientation stored by an earlier preview turns the thumbnail before
  /// the head of the file arrives.
  Future<void> _seedTurns() async {
    final turns = await _cache.loadTurns(widget.group.thumbnailSource);
    if (turns != null && mounted) _load.assumeTurns(turns);
  }

  /// Shares what the load learned with the grid and later runs.
  void _rememberTurns() {
    if (_load.orientationRead) {
      _cache.rememberTurns(widget.group.thumbnailSource, _load.quarterTurns);
    }
  }

  Future<void> _loadThumbnail(CameraObject source) async {
    try {
      final bytes = await _cache.get(
        source,
        (handle) => widget.client.thumbnail(handle, cancelToken: _cancelToken),
      );
      if (mounted) setState(() => _thumbnail = bytes);
    } on TransferCancelledException {
      if (mounted && !_cancelToken.isCancelled) {
        await _loadThumbnail(source);
        return;
      }
    } on Exception {
      // The placeholder stays on screen.
    }
    if (mounted) setState(() => _thumbnailSettled = true);
  }

  @override
  Widget build(BuildContext context) => FullImageLoader(
    load: _load,
    client: widget.client,
    thumbnail: _thumbnail,
    thumbnailSettled: _thumbnailSettled,
  );
}
