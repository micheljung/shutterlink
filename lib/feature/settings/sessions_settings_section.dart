import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/upload_worker.dart';
import '../sessions/sessions_upload_cubit.dart';
import '../spacing.dart';
import 'settings_cubit.dart';

class SessionsSettingsSection extends StatefulWidget {
  const SessionsSettingsSection({super.key});

  @override
  State<SessionsSettingsSection> createState() =>
      _SessionsSettingsSectionState();
}

class _SessionsSettingsSectionState extends State<SessionsSettingsSection> {
  late final TextEditingController _urlController;
  final _tokenController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(
      text: context.read<SettingsCubit>().state.sessionsServerUrl,
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SettingsCubit>();
    final theme = Theme.of(context);
    final state = context.watch<SettingsCubit>().state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Sessions', style: theme.textTheme.titleMedium),
          subtitle: const Text(
            'Upload the photos of each Session to a private web gallery.',
          ),
          value: state.sessionsEnabled,
          onChanged: (enabled) => cubit.setSessionsEnabled(enabled),
        ),
        if (state.sessionsEnabled) ...[
          const SizedBox(height: Spacing.small),
          ValueListenableBuilder(
            valueListenable: _urlController,
            builder: (context, value, _) => TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Server URL',
                hintText: 'https://photos.example.com',
                errorText:
                    value.text.trim().isEmpty ||
                        isValidSessionsServerUrl(value.text)
                    ? null
                    : 'Use https:// (http:// only for localhost)',
              ),
              onChanged: cubit.setSessionsServerUrl,
            ),
          ),
          const SizedBox(height: Spacing.medium),
          TextField(
            controller: _tokenController,
            obscureText: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Upload token',
              hintText: state.sessionsConfigured ? 'Saved' : null,
              suffixIcon: IconButton(
                tooltip: 'Save token',
                icon: const Icon(Icons.check),
                onPressed: _saveToken,
              ),
            ),
            onSubmitted: (_) => _saveToken(),
          ),
          const SizedBox(height: Spacing.small),
          const _UploadStatus(),
        ],
      ],
    );
  }

  Future<void> _saveToken() async {
    final token = _tokenController.text;
    if (token.trim().isEmpty) return;
    await context.read<SettingsCubit>().setSessionsToken(token);
    _tokenController.clear();
  }
}

class _UploadStatus extends StatelessWidget {
  const _UploadStatus();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
    return Text(
      [
        status,
        if (upload.pending > 0) '${upload.pending} waiting to upload.',
        if (upload.dropped > 0) '${upload.dropped} dropped.',
        if (upload.expired > 0) '${upload.expired} for expired Sessions.',
      ].join(' '),
      style: theme.textTheme.bodySmall,
    );
  }
}
