import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../upload/backend_factory.dart';
import '../../upload/destination.dart';
import '../../upload/provider_preset.dart';
import '../../upload/remote_path.dart';
import '../../upload/storage_backend.dart';
import '../spacing.dart';
import 'settings_cards.dart';
import 'upload_settings_cubit.dart';
import 'upload_setup_cubit.dart';

const _folderHint = 'Photos';
const _immichHint = 'https://photos.example.com';

IconData presetIcon(ProviderPreset? preset) => switch (preset) {
  ProviderPreset.nextcloud => Icons.cloud_outlined,
  ProviderPreset.backblazeB2 => Icons.local_fire_department_outlined,
  ProviderPreset.awsS3 => Icons.inventory_2_outlined,
  ProviderPreset.cloudflareR2 => Icons.bolt_outlined,
  ProviderPreset.hetznerStorageBox => Icons.dns_outlined,
  ProviderPreset.immich => Icons.photo_library_outlined,
  ProviderPreset.custom || null => Icons.tune,
};

String destinationTitle(Destination destination, ProviderPreset? preset) =>
    switch (preset) {
      null || ProviderPreset.custom => switch (destination.type) {
        DestinationType.webdav => 'WebDAV server',
        DestinationType.s3 => 'S3 bucket',
        DestinationType.sftp => 'SFTP server',
        DestinationType.immich => 'Immich server',
      },
      _ => preset.label,
    };

/// The bucket for S3, otherwise the server's host name.
String destinationLocation(Destination destination) {
  if (destination.type == DestinationType.s3) return destination.bucket;
  final endpoint = destination.endpoint;
  final uri = Uri.tryParse(
    destination.type == DestinationType.sftp ? 'sftp://$endpoint' : endpoint,
  );
  return uri == null || uri.host.isEmpty ? endpoint : uri.host;
}

String destinationFolder(Destination destination) =>
    destination.type == DestinationType.immich
    ? 'Timeline'
    : '/${pathSegments(destination.basePath).join('/')}';

/// A route to [screen] with a draft made by [create] from [settings].
Route<void> uploadDraftRoute(
  UploadSettingsCubit settings, {
  required UploadSetupCubit Function(UploadSettingsCubit settings) create,
  required Widget screen,
  bool fullscreenDialog = false,
}) => MaterialPageRoute(
  fullscreenDialog: fullscreenDialog,
  builder: (_) => BlocProvider.value(
    value: settings,
    child: BlocProvider(create: (_) => create(settings), child: screen),
  ),
);

const notSavedNote = 'Not saved. The current destination is unchanged.';

/// Runs the connection test and offers to trust an unknown certificate or
/// host key. Returns null when the connection works.
Future<StorageException?> testWithTrust(
  BuildContext context,
  UploadSetupCubit cubit,
) async {
  while (true) {
    final error = await cubit.test();
    if (!context.mounted) return error;
    switch (error) {
      case null:
        return null;
      case UntrustedCertificateException(:final fingerprint):
        if (!await _confirmTrust(
          context,
          'Trust this certificate?',
          'SHA-256',
          fingerprint,
        )) {
          return error;
        }
        cubit.trustCertificate(fingerprint);
      case UnknownHostKeyException(:final keyType, :final fingerprint):
        if (!await _confirmTrust(
          context,
          'Trust this host key?',
          keyType,
          fingerprint,
        )) {
          return error;
        }
        cubit.trustHostKey(fingerprint);
      case StorageException():
        return error;
    }
  }
}

/// Saves the draft after confirming a replaced destination. Returns whether
/// it was saved.
Future<bool> saveDraft(BuildContext context, UploadSetupCubit cubit) async {
  if (cubit.replaces &&
      !await confirmDialog(
        context,
        title: 'Replace destination?',
        content: 'Photos not uploaded yet will go to the new destination.',
        action: 'Replace',
      )) {
    return false;
  }
  await cubit.save();
  return true;
}

bool isTrustFailure(StorageException error) =>
    error is UntrustedCertificateException || error is UnknownHostKeyException;

Future<bool> _confirmTrust(
  BuildContext context,
  String title,
  String label,
  String fingerprint,
) => confirmDialog(
  context,
  title: title,
  contentWidget: Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Only trust it if this matches your server.'),
      const SizedBox(height: Spacing.medium),
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      SelectableText(
        fingerprint,
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    ],
  ),
  action: 'Trust',
);

class _DraftField extends StatelessWidget {
  const _DraftField({
    required this.controller,
    required this.label,
    this.hint,
    this.obscure = false,
    this.maxLines = 1,
    this.keyboardType,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final int? maxLines;
  final TextInputType? keyboardType;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Spacing.large),
    child: TextField(
      controller: controller,
      obscureText: obscure,
      maxLines: maxLines,
      keyboardType: keyboardType,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: label,
        hintText: hint,
      ),
      onChanged: onChanged,
    ),
  );
}

class _Help extends StatelessWidget {
  const _Help(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Spacing.large),
    child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
  );
}

/// Where the server is: the preset's own inputs, or the raw fields for
/// Custom.
class UploadServerFields extends StatefulWidget {
  const UploadServerFields({super.key});

  @override
  State<UploadServerFields> createState() => _UploadServerFieldsState();
}

class _UploadServerFieldsState extends State<UploadServerFields> {
  late final UploadSetupCubit _cubit = context.read<UploadSetupCubit>();
  late final _server = TextEditingController(text: _cubit.state.input.server);
  late final _region = TextEditingController(text: _cubit.state.input.region);
  late final _bucket = TextEditingController(text: _cubit.state.input.bucket);
  late final _username = TextEditingController(
    text: _cubit.state.input.username,
  );

  @override
  void dispose() {
    for (final controller in [_server, _region, _bucket, _username]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _update(PresetInput Function(PresetInput input) change) =>
      _cubit.updateInput(change(_cubit.state.input));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UploadSetupCubit>().state;
    final preset = state.preset ?? ProviderPreset.custom;
    final server = _DraftField(
      controller: _server,
      label: switch (preset) {
        ProviderPreset.nextcloud => 'Server address',
        ProviderPreset.cloudflareR2 => 'Account ID',
        _ => switch (state.input.type) {
          DestinationType.webdav || DestinationType.immich => 'Server URL',
          DestinationType.s3 => 'Endpoint URL',
          DestinationType.sftp => 'Host',
        },
      },
      hint: switch (preset) {
        ProviderPreset.nextcloud => 'cloud.example.com',
        ProviderPreset.cloudflareR2 => null,
        ProviderPreset.immich => _immichHint,
        _ => switch (state.input.type) {
          DestinationType.webdav =>
            'https://cloud.example.com/remote.php/dav/files/me',
          DestinationType.s3 => 'https://s3.eu-central-1.amazonaws.com',
          DestinationType.sftp => 'example.com:22',
          DestinationType.immich => _immichHint,
        },
      },
      keyboardType: TextInputType.url,
      onChanged: (value) => _update((input) => input.copyWith(server: value)),
    );
    final region = _DraftField(
      controller: _region,
      label: 'Region',
      hint: switch (preset) {
        ProviderPreset.backblazeB2 => 'eu-central-003',
        ProviderPreset.awsS3 => 'eu-central-1',
        _ => defaultS3Region,
      },
      onChanged: (value) => _update((input) => input.copyWith(region: value)),
    );
    final bucket = _DraftField(
      controller: _bucket,
      label: preset == ProviderPreset.custom ? 'Bucket' : 'Bucket name',
      onChanged: (value) => _update((input) => input.copyWith(bucket: value)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...switch (preset) {
          ProviderPreset.nextcloud => [
            const _Help('The address you open Nextcloud or ownCloud with.'),
            server,
          ],
          ProviderPreset.backblazeB2 => [
            const _Help(
              'Find both in the B2 console under Buckets. The region is '
              'part of the endpoint, e.g. s3.eu-central-003.backblazeb2.com.',
            ),
            region,
            bucket,
          ],
          ProviderPreset.awsS3 => [
            const _Help('Find both in the S3 console under Buckets.'),
            region,
            bucket,
          ],
          ProviderPreset.cloudflareR2 => [
            const _Help(
              'Find the account ID in the Cloudflare dashboard under R2.',
            ),
            server,
            bucket,
          ],
          ProviderPreset.hetznerStorageBox => [
            const _Help('Find it in Hetzner Console under Storage Boxes.'),
            _DraftField(
              controller: _username,
              label: 'Username',
              hint: 'u123456 or u123456-sub1',
              onChanged: (value) =>
                  _update((input) => input.copyWith(username: value)),
            ),
          ],
          ProviderPreset.immich => [
            const _Help('The address you open Immich with.'),
            server,
          ],
          ProviderPreset.custom => [
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.large),
              child: SegmentedButton<DestinationType>(
                segments: const [
                  ButtonSegment(
                    value: DestinationType.webdav,
                    label: Text('WebDAV'),
                  ),
                  ButtonSegment(value: DestinationType.s3, label: Text('S3')),
                  ButtonSegment(
                    value: DestinationType.sftp,
                    label: Text('SFTP'),
                  ),
                ],
                selected: {state.input.type},
                onSelectionChanged: (selection) =>
                    _update((input) => input.copyWith(type: selection.single)),
              ),
            ),
            server,
            if (state.input.type == DestinationType.s3) ...[
              bucket,
              ExpansionTile(
                title: const Text('Advanced'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                shape: const Border(),
                children: [
                  region,
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Path-style URLs'),
                    value: state.input.pathStyle,
                    onChanged: (value) =>
                        _update((input) => input.copyWith(pathStyle: value)),
                  ),
                ],
              ),
            ],
          ],
        },
        if (preset != ProviderPreset.custom && state.serverComplete)
          InfoBox('Endpoint: ${state.destination.endpoint}'),
      ],
    );
  }
}

/// The credentials, worded for the provider.
class UploadSignInFields extends StatefulWidget {
  const UploadSignInFields({super.key});

  @override
  State<UploadSignInFields> createState() => _UploadSignInFieldsState();
}

class _UploadSignInFieldsState extends State<UploadSignInFields> {
  late final UploadSetupCubit _cubit = context.read<UploadSetupCubit>();
  late final _username = TextEditingController(
    text: _cubit.state.input.username,
  );
  late final _password = TextEditingController(text: _cubit.state.password);
  late final _privateKey = TextEditingController(text: _cubit.state.privateKey);
  late final _passphrase = TextEditingController(text: _cubit.state.passphrase);

  @override
  void dispose() {
    for (final controller in [_username, _password, _privateKey, _passphrase]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UploadSetupCubit>().state;
    final preset = state.preset ?? ProviderPreset.custom;
    final s3 = state.type == DestinationType.s3;
    final sftp = state.type == DestinationType.sftp;
    final (username, password) = switch (preset) {
      ProviderPreset.nextcloud => ('Username', 'App password'),
      ProviderPreset.backblazeB2 => ('Key ID', 'Application key'),
      ProviderPreset.immich => ('', 'API key'),
      _ when s3 => ('Access key ID', 'Secret access key'),
      _ => ('Username', 'Password'),
    };
    final help = switch (preset) {
      ProviderPreset.nextcloud =>
        'Use an app password. Create one in Nextcloud under Personal '
            'settings, Security.',
      ProviderPreset.backblazeB2 =>
        'Create an application key for this bucket in the B2 console under '
            'Application Keys.',
      ProviderPreset.awsS3 =>
        'Use an IAM access key that may list and write this bucket.',
      ProviderPreset.cloudflareR2 =>
        'Create an R2 API token with Object Read & Write for this bucket.',
      ProviderPreset.hetznerStorageBox =>
        'Turn on SSH support for the Storage Box in Hetzner Console.',
      ProviderPreset.immich =>
        'Create an API key in Immich under Account Settings, API Keys. It '
            'needs the asset.upload permission.',
      ProviderPreset.custom => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (help != null) _Help(help),
        if (preset != ProviderPreset.hetznerStorageBox &&
            state.type != DestinationType.immich)
          _DraftField(
            controller: _username,
            label: username,
            onChanged: (value) => _cubit.updateInput(
              _cubit.state.input.copyWith(username: value),
            ),
          ),
        if (!(sftp && state.useKey))
          _DraftField(
            controller: _password,
            label: password,
            obscure: true,
            onChanged: _cubit.setPassword,
          ),
        if (sftp) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use a private key instead'),
            value: state.useKey,
            onChanged: _cubit.setUseKey,
          ),
          if (state.useKey) ...[
            const SizedBox(height: Spacing.small),
            _DraftField(
              controller: _privateKey,
              label: 'Private key',
              maxLines: null,
              onChanged: _cubit.setPrivateKey,
            ),
            _DraftField(
              controller: _passphrase,
              label: 'Key passphrase',
              obscure: true,
              onChanged: _cubit.setPassphrase,
            ),
          ],
        ],
      ],
    );
  }
}

/// The base folder, with a preview of where photos land.
class UploadFolderField extends StatefulWidget {
  const UploadFolderField({super.key});

  @override
  State<UploadFolderField> createState() => _UploadFolderFieldState();
}

class _UploadFolderFieldState extends State<UploadFolderField> {
  late final UploadSetupCubit _cubit = context.read<UploadSetupCubit>();
  late final _folder = TextEditingController(text: _cubit.state.input.basePath);

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final destination = context.watch<UploadSetupCubit>().state.destination;
    final day = captureDayOf(clock.now());
    final folder = [...pathSegments(destination.basePath), day].join('/');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DraftField(
          controller: _folder,
          label: 'Folder',
          hint: _folderHint,
          onChanged: (value) =>
              _cubit.updateInput(_cubit.state.input.copyWith(basePath: value)),
        ),
        InfoBox(
          'Each day gets its own folder, e.g. /$folder on '
          '${destinationLocation(destination)}.',
        ),
      ],
    );
  }
}
