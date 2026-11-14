import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/upload_worker.dart';
import '../sessions/sessions_upload_cubit.dart';
import 'sessions_setup_screen.dart';
import 'settings_cards.dart';
import 'settings_cubit.dart';

class SessionsSettingsSection extends StatelessWidget {
  const SessionsSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SettingsCubit>().state;
    final host = Uri.tryParse(state.sessionsServerUrl ?? '')?.host;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader('Sessions'),
        if (state.sessionsEnabled)
          SettingsSummaryCard(
            icon: Icons.photo_library_outlined,
            title: host == null || host.isEmpty ? 'Sessions' : host,
            subtitle: _uploadStatus(context),
            actions: [
              TextButton(
                onPressed: () => _disconnect(context),
                child: const Text('Disconnect'),
              ),
              FilledButton.tonalIcon(
                onPressed: () =>
                    Navigator.of(context).push(SessionsSetupScreen.route()),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              ),
            ],
          )
        else
          SettingsEmptyCard(
            icon: Icons.link_off,
            title: 'Sessions not connected',
            text: 'Upload the photos of each Session to a private web gallery.',
            action: 'Connect Sessions',
            onPressed: () =>
                Navigator.of(context).push(SessionsSetupScreen.route()),
          ),
      ],
    );
  }

  String _uploadStatus(BuildContext context) {
    final upload = context.watch<SessionsUploadCubit>().state;
    final configured = context.select<SettingsCubit, bool>(
      (cubit) => cubit.state.sessionsConfigured,
    );
    final status = switch (upload.status) {
      _ when !configured => 'Enter a server URL and an upload token.',
      UploadWorkerStatus.unauthorized =>
        'Upload token rejected (unauthorized). Check the token.',
      UploadWorkerStatus.serverConfiguration =>
        'Unexpected server response (server configuration). Retrying later.',
      UploadWorkerStatus.waitingForNetwork => 'Waiting for internet.',
      UploadWorkerStatus.retrying =>
        'Could not read the upload token or queue. '
            'Retrying.',
      UploadWorkerStatus.notConfigured => 'Not configured.',
      UploadWorkerStatus.uploading => 'Uploading…',
      UploadWorkerStatus.idle => 'Ready.',
    };
    return [
      status,
      if (upload.pending > 0) '${upload.pending} waiting to upload.',
      if (upload.dropped > 0) '${upload.dropped} dropped.',
      if (upload.expired > 0) '${upload.expired} for expired Sessions.',
    ].join(' ');
  }

  Future<void> _disconnect(BuildContext context) async {
    final settings = context.read<SettingsCubit>();
    if (await confirmDialog(
      context,
      title: 'Disconnect Sessions?',
      content:
          'Photos stop uploading to Sessions. The server address stays '
          'filled in for when you connect again.',
      action: 'Disconnect',
    )) {
      await settings.setSessionsEnabled(false);
    }
  }
}
