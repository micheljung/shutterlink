import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../ptpip/camera_client.dart';
import '../connect/connect_cubit.dart';
import '../download/download_cubit.dart';
import '../download/download_sheet.dart';
import '../download/download_state.dart';
import '../settings/settings_cubit.dart';
import '../settings/settings_screen.dart';
import '../spacing.dart';
import 'gallery_cubit.dart';
import 'gallery_state.dart';
import 'thumbnail_cache.dart';
import 'thumbnail_tile.dart';

class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key, required this.client});

  final CameraClient client;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => GalleryCubit(client)..load(),
    child: _GalleryView(client: client),
  );
}

class _GalleryView extends StatelessWidget {
  const _GalleryView({required this.client});

  static const _maxTileExtent = 160.0;
  static const _tileSpacing = 2.0;

  final CameraClient client;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GalleryCubit>().state;
    final cubit = context.read<GalleryCubit>();
    final cache = context.read<ThumbnailCache>();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          state.selected.isEmpty
              ? 'Photos (${state.groups.length})'
              : '${state.selected.length} selected',
        ),
        actions: [
          IconButton(
            tooltip: state.allSelected ? 'Select none' : 'Select all',
            icon: Icon(state.allSelected ? Icons.deselect : Icons.select_all),
            onPressed: state.allSelected
                ? cubit.clearSelection
                : cubit.selectAll,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(SettingsScreen.route()),
          ),
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off),
            onPressed: context.read<ConnectCubit>().disconnect,
          ),
        ],
      ),
      body: switch (state.status) {
        GalleryStatus.loading => const Center(
          child: CircularProgressIndicator(),
        ),
        GalleryStatus.failed => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not list photos: ${state.error}'),
              TextButton(onPressed: cubit.load, child: const Text('Retry')),
            ],
          ),
        ),
        GalleryStatus.loaded when state.groups.isEmpty => const Center(
          child: Text('No photos on the card.'),
        ),
        GalleryStatus.loaded => GridView.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: _maxTileExtent,
            mainAxisSpacing: _tileSpacing,
            crossAxisSpacing: _tileSpacing,
          ),
          itemCount: state.groups.length,
          itemBuilder: (context, index) {
            final group = state.groups[index];
            return ThumbnailTile(
              key: ValueKey(group.key),
              group: group,
              selected: state.selected.contains(group.key),
              cache: cache,
              client: client,
              onTap: () => cubit.toggle(group),
            );
          },
        ),
      },
      bottomNavigationBar: _DownloadBar(client: client),
    );
  }
}

class _DownloadBar extends StatelessWidget {
  const _DownloadBar({required this.client});

  final CameraClient client;

  @override
  Widget build(BuildContext context) {
    final selected = context.select<GalleryCubit, int>(
      (cubit) => cubit.state.selected.length,
    );
    final download = context.watch<DownloadCubit>().state;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.medium),
        child: switch (download.status) {
          DownloadStatus.running ||
          DownloadStatus.paused => OutlinedButton.icon(
            icon: Icon(
              download.status == DownloadStatus.paused
                  ? Icons.pause_circle_outline
                  : Icons.downloading,
            ),
            label: Text(
              download.status == DownloadStatus.paused
                  ? 'Download paused – tap to resume'
                  : 'Downloading ${(download.overallProgress * _percent).round()}%',
            ),
            onPressed: () => DownloadSheet.show(context),
          ),
          _ => FilledButton.icon(
            icon: const Icon(Icons.download),
            label: Text('Download ($selected)'),
            onPressed: selected == 0 ? null : () => _download(context),
          ),
        },
      ),
    );
  }

  static const _percent = 100;

  void _download(BuildContext context) {
    final groups = context.read<GalleryCubit>().state.selectedGroups;
    final format = context.read<SettingsCubit>().state.format;
    context.read<DownloadCubit>().start(client, groups, format);
    context.read<GalleryCubit>().clearSelection();
    DownloadSheet.show(context);
  }
}
