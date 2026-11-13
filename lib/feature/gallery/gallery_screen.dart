import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/download_history.dart';
import '../../data/settings_repository.dart';
import '../../ptpip/camera_client.dart';
import '../connect/connect_cubit.dart';
import '../download/download_cubit.dart';
import '../download/download_sheet.dart';
import '../download/download_state.dart';
import '../history/download_history_cubit.dart';
import '../live/live_transfer_cubit.dart';
import '../settings/settings_cubit.dart';
import '../settings/settings_screen.dart';
import '../settings/upload_settings_cubit.dart';
import '../spacing.dart';
import '../upload/upload_status_sheet.dart';
import 'gallery_cubit.dart';
import 'gallery_grid.dart';
import 'gallery_state.dart';
import 'photo_group.dart';

class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key, required this.client});

  final CameraClient client;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => GalleryCubit(client)..load(),
    child: _GalleryView(
      client: client,
      cameraKey: cameraKeyOf(client.deviceInfo),
    ),
  );
}

class _GalleryView extends StatelessWidget {
  const _GalleryView({required this.client, required this.cameraKey});

  final CameraClient client;
  final String cameraKey;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GalleryCubit>().state;
    final cubit = context.read<GalleryCubit>();
    final history = context.watch<DownloadHistoryCubit>();
    final format = context.select<SettingsCubit, DownloadFormat>(
      (cubit) => cubit.state.format,
    );
    final uploads = context.select<UploadSettingsCubit, bool>(
      (cubit) => cubit.state.destination != null,
    );
    bool isDownloaded(PhotoGroup group) =>
        history.isDownloaded(cameraKey, group.filesFor(format));
    return Scaffold(
      appBar: AppBar(
        title: Text(
          state.selected.isEmpty
              ? 'Photos (${state.groups.length})'
              : '${state.selected.length} selected',
        ),
        actions: [
          if (uploads) ...[
            if (defaultTargetPlatform == TargetPlatform.android)
              IconButton(
                tooltip: 'Start Live transfer',
                icon: const Icon(Icons.sensors),
                onPressed: context.read<LiveTransferCubit>().start,
              ),
            IconButton(
              tooltip: 'Uploads',
              icon: const Icon(Icons.cloud_upload_outlined),
              onPressed: () => UploadStatusSheet.show(context),
            ),
          ],
          IconButton(
            tooltip: 'Select new',
            icon: const Icon(Icons.fiber_new_outlined),
            onPressed: () => cubit.selectWhere(
              (group) =>
                  group.filesFor(format).isNotEmpty && !isDownloaded(group),
            ),
          ),
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
        GalleryStatus.loaded => GalleryGrid(
          client: client,
          isDownloaded: isDownloaded,
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
