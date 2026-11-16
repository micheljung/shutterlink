import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../ptpip/camera_client.dart';
import '../connect/connect_cubit.dart';
import '../connect/connect_state.dart';
import '../gallery/thumbnail_cache.dart';
import '../mode/attached_client.dart';
import '../mode/modes_button.dart';
import '../mode/operating_mode.dart';
import '../settings/upload_draft_fields.dart';
import '../settings/upload_settings_cubit.dart';
import '../spacing.dart';
import '../upload/upload_status_indicator.dart';
import '../upload/upload_status_sheet.dart';
import 'auto_upload_cubit.dart';

/// Auto Upload's dashboard: what was found and sent, where it goes and how
/// the camera is connected. The card itself is not browsed here.
class AutoUploadScreen extends StatelessWidget {
  const AutoUploadScreen({super.key});

  static const keepOpenText = 'Keep Shutterlink open to sync';
  static const keepOpenHint =
      'On iPhone, new photos are only uploaded while the app is open.';
  static const notificationsHint =
      'Notifications are off, so progress only shows here.';
  static const readingText = 'Reading the card…';
  static const waitingText = 'Waiting for new photos';
  static const reconnectingText = 'Reconnecting…';
  static const uploadBacklogLabel = 'Upload them';
  static const skipBacklogLabel = 'Only new shots';
  static const recentTitle = 'Recent shots';
  static const noShotsText = 'New shots appear here.';
  static const detectedLabel = 'Detected';
  static const uploadedLabel = 'Uploaded';
  static const pendingLabel = 'Waiting';
  static const failedLabel = 'Failed';

  static String backlogText(int count) => count == 1
      ? 'Also upload the 1 existing photo?'
      : 'Also upload the $count existing photos?';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AutoUploadCubit>().state;
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    final backlog = state.backlog;
    return Scaffold(
      appBar: AppBar(
        title: Text(OperatingMode.autoUpload.label),
        actions: const [UploadStatusIndicator(), ModesButton()],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.large),
        children: [
          if (ios)
            const _Notice(
              icon: Icons.phone_iphone,
              title: keepOpenText,
              subtitle: keepOpenHint,
            ),
          if (state.notificationsDenied)
            const _Notice(
              icon: Icons.notifications_off_outlined,
              title: notificationsHint,
            ),
          if (backlog != null) _BacklogPrompt(count: backlog),
          const _Connection(),
          const _DestinationTile(),
          const SizedBox(height: Spacing.medium),
          _Counters(state: state),
          const SizedBox(height: Spacing.large),
          Text(recentTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Spacing.small),
          if (state.recent.isEmpty)
            const Text(noShotsText)
          else
            Wrap(
              spacing: Spacing.small,
              runSpacing: Spacing.small,
              children: [
                for (final shot in state.recent)
                  _RecentThumbnail(key: ValueKey(shot), shot: shot),
              ],
            ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.title, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
      ),
    );
  }
}

class _BacklogPrompt extends StatelessWidget {
  const _BacklogPrompt({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<AutoUploadCubit>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.medium),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AutoUploadScreen.backlogText(count),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Spacing.small),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: Spacing.small,
              children: [
                TextButton(
                  onPressed: () => cubit.uploadBacklog(upload: false),
                  child: const Text(AutoUploadScreen.skipBacklogLabel),
                ),
                FilledButton(
                  onPressed: () => cubit.uploadBacklog(upload: true),
                  child: const Text(AutoUploadScreen.uploadBacklogLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Connection extends StatelessWidget {
  const _Connection();

  @override
  Widget build(BuildContext context) {
    final connection = context.watch<ConnectCubit>().state;
    final phase = context.select<AutoUploadCubit, AutoUploadPhase>(
      (cubit) => cubit.state.phase,
    );
    final (icon, text) = switch (connection) {
      ConnectReconnecting(usb: true) => (
        Icons.usb_off,
        AutoUploadScreen.reconnectingText,
      ),
      ConnectReconnecting() => (
        Icons.sync_problem,
        AutoUploadScreen.reconnectingText,
      ),
      _ when phase != AutoUploadPhase.running => (
        Icons.sd_card_outlined,
        AutoUploadScreen.readingText,
      ),
      ConnectConnected(:final target) => (
        switch (target) {
          UsbTarget() => Icons.usb,
          DemoTarget() => Icons.photo_library_outlined,
          WifiTarget() || null => Icons.wifi,
        },
        AutoUploadScreen.waitingText,
      ),
      _ => (Icons.link_off, AutoUploadScreen.reconnectingText),
    };
    final camera = switch (connection) {
      ConnectConnected(:final client) => client.deviceInfo.model,
      _ => null,
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(text),
      subtitle: camera == null || camera.isEmpty ? null : Text(camera),
    );
  }
}

class _DestinationTile extends StatelessWidget {
  const _DestinationTile();

  @override
  Widget build(BuildContext context) {
    final uploads = context.watch<UploadSettingsCubit>().state;
    final destination = uploads.destination;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(presetIcon(uploads.preset)),
      title: Text(
        destination == null
            ? 'No destination'
            : destinationTitle(destination, uploads.preset),
      ),
      subtitle: destination == null
          ? null
          : Text(destinationLocation(destination)),
    );
  }
}

class _Counters extends StatelessWidget {
  const _Counters({required this.state});

  final AutoUploadState state;

  @override
  Widget build(BuildContext context) {
    void showUploads() => UploadStatusSheet.show(context);
    return Row(
      children: [
        _Counter(label: AutoUploadScreen.detectedLabel, value: state.detected),
        _Counter(
          label: AutoUploadScreen.uploadedLabel,
          value: state.uploaded,
          onTap: showUploads,
        ),
        _Counter(
          label: AutoUploadScreen.pendingLabel,
          value: state.pending,
          onTap: showUploads,
        ),
        _Counter(
          label: AutoUploadScreen.failedLabel,
          value: state.failed,
          onTap: showUploads,
          highlight: state.failed > 0,
        ),
      ],
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({
    required this.label,
    required this.value,
    this.onTap,
    this.highlight = false,
  });

  final String label;
  final int value;
  final VoidCallback? onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = highlight ? theme.colorScheme.error : null;
    return Expanded(
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            label: '$label: $value',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.medium),
              child: Column(
                children: [
                  Text(
                    '$value',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: color,
                    ),
                  ),
                  Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(color: color),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A shot's thumbnail, asked only of the client it came from while that
/// client is still the attached one; otherwise only the cache is used.
class _RecentThumbnail extends StatefulWidget {
  const _RecentThumbnail({super.key, required this.shot});

  static const size = 96.0;
  static const decodeWidth = 192;

  final RecentShot shot;

  @override
  State<_RecentThumbnail> createState() => _RecentThumbnailState();
}

class _RecentThumbnailState extends State<_RecentThumbnail> {
  final _cancelToken = CancelToken();
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    final cache = context.read<ThumbnailCache>();
    final RecentShot(:object, :client) = widget.shot;
    _bytes = cache.peek(object);
    if (_bytes == null && AttachedClient.allows(context, client)) {
      _load(cache, object, client);
    }
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    super.dispose();
  }

  Future<void> _load(
    ThumbnailCache cache,
    CameraObject object,
    CameraClient client,
  ) async {
    try {
      final bytes = await cache.get(
        object,
        (handle) => client.thumbnail(handle, cancelToken: _cancelToken),
      );
      if (mounted && bytes != null) setState(() => _bytes = bytes);
    } on Exception {
      // The placeholder stays; the photo is uploaded either way.
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Semantics(
      label: widget.shot.object.filename,
      image: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Spacing.small),
        child: SizedBox.square(
          dimension: _RecentThumbnail.size,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: bytes == null
                ? const Icon(Icons.photo_outlined)
                : Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    cacheWidth: _RecentThumbnail.decodeWidth,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image_outlined),
                  ),
          ),
        ),
      ),
    );
  }
}
