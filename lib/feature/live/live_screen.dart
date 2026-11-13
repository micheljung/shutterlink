import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../spacing.dart';
import '../upload/upload_status_cubit.dart';
import '../upload/upload_status_sheet.dart';
import 'live_transfer_cubit.dart';

/// Shown while Live transfer owns the camera.
class LiveScreen extends StatelessWidget {
  const LiveScreen({super.key});

  static const notificationsHint =
      'Notifications are off, so Live progress only shows here.';

  static String statusText(LiveTransferState state) => switch (state) {
    LiveIdle() || LiveConnecting() => LiveTransferCubit.connectingText,
    LiveTransferring() => 'Waiting for new photos',
    LiveReconnecting(unreachable: false) => LiveTransferCubit.reconnectingText,
    LiveReconnecting(unreachable: true) => LiveTransferCubit.unreachableText,
  };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LiveTransferCubit>().state;
    final uploads = context.watch<UploadStatusCubit>().state;
    return Scaffold(
      appBar: AppBar(title: const Text('Live transfer')),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.large),
        children: [
          if (state.notificationsDenied)
            Card(
              child: ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text(notificationsHint),
              ),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: state is LiveTransferring
                ? const Icon(Icons.sensors)
                : const SizedBox.square(
                    dimension: Spacing.extraLarge,
                    child: CircularProgressIndicator(),
                  ),
            title: Text(statusText(state)),
            subtitle: Text('${state.ingested} new photos'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cloud_upload_outlined),
            title: Text(
              '${uploads.pending} waiting · ${uploads.completed} uploaded',
            ),
            onTap: () => UploadStatusSheet.show(context),
          ),
          const SizedBox(height: Spacing.large),
          FilledButton.icon(
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
            onPressed: context.read<LiveTransferCubit>().stop,
          ),
        ],
      ),
    );
  }
}
