import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/download_history.dart';
import '../../data/settings_repository.dart';
import '../../ptpip/camera_client.dart';
import '../download/download_cubit.dart';
import '../history/download_history_cubit.dart';
import 'gallery_cubit.dart';
import 'photo_group.dart';

/// A running download holds the handles it is about to read.
bool canDeleteNow(BuildContext context, CameraClient client) {
  final downloading = context.select<DownloadCubit, bool>(
    (cubit) => cubit.state.isActive,
  );
  final deleting = context.select<GalleryCubit, bool>(
    (cubit) => cubit.state.deleting,
  );
  return client.canDelete && !downloading && !deleting;
}

Future<void> confirmDelete(
  BuildContext context,
  CameraClient client,
  List<PhotoGroup> groups,
) async {
  final history = context.read<DownloadHistoryCubit>();
  final cameraKey = cameraKeyOf(client.deviceInfo);
  final notDownloaded = groups
      .where(
        (group) => !history.isDownloaded(
          cameraKey,
          group.filesFor(DownloadFormat.both),
        ),
      )
      .length;
  final pairs = groups.any((group) => group.jpeg != null && group.raw != null);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete ${_photos(groups.length)} from the camera?'),
      content: Text(
        [
          if (pairs) 'RAW+JPEG shots lose both files.',
          if (notDownloaded > 0) 'Not downloaded: $notDownloaded.',
          "This can't be undone.",
        ].join('\n'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  final outcome = await context.read<GalleryCubit>().delete(groups);
  messenger.showSnackBar(
    SnackBar(content: Text(_report(groups.length, outcome))),
  );
}

String _report(int count, DeleteOutcome outcome) => switch (outcome) {
  (denied: 0, failed: 0, disconnected: _) => 'Deleted ${_photos(count)}.',
  (denied: final denied, failed: final failed, disconnected: true) =>
    'The camera disconnected. ${_photos(denied + failed)} not deleted.',
  (denied: final denied, failed: 0, disconnected: _) =>
    'Could not delete ${_photos(denied)}. '
        'They are protected or the card is locked.',
  (denied: final denied, failed: final failed, disconnected: _) =>
    'Could not delete ${_photos(denied + failed)}.',
};

String _photos(int count) => count == 1 ? '1 photo' : '$count photos';
