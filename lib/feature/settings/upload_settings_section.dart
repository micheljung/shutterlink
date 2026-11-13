import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../upload/backend_factory.dart';
import '../../upload/destination.dart';
import '../../upload/network_policy.dart';
import '../../upload/storage_backend.dart';
import '../spacing.dart';
import 'upload_settings_cubit.dart';

class UploadSettingsSection extends StatelessWidget {
  const UploadSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final UploadSettingsCubit cubit;
    try {
      cubit = context.read<UploadSettingsCubit>();
    } on ProviderNotFoundException {
      // Screens built without upload support, e.g. in isolated tests.
      return const SizedBox.shrink();
    }
    return _UploadSettingsForm(cubit: cubit);
  }
}

class _UploadSettingsForm extends StatefulWidget {
  const _UploadSettingsForm({required this.cubit});

  final UploadSettingsCubit cubit;

  @override
  State<_UploadSettingsForm> createState() => _UploadSettingsFormState();
}

class _UploadSettingsFormState extends State<_UploadSettingsForm> {
  final _endpoint = TextEditingController();
  final _region = TextEditingController();
  final _bucket = TextEditingController();
  final _basePath = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();
  var _type = DestinationType.webdav;
  var _pathStyle = false;
  var _policy = MobileDataPolicy.off;
  var _keepLocalCopy = true;
  String? _certificatePin;
  String? _hostKeyPin;
  var _busy = false;
  String? _result;

  UploadSettingsCubit get _cubit => widget.cubit;

  @override
  void initState() {
    super.initState();
    _fill(_cubit.state);
    _cubit.load();
  }

  @override
  void dispose() {
    for (final controller in [
      _endpoint,
      _region,
      _bucket,
      _basePath,
      _username,
      _password,
      _privateKey,
      _passphrase,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _fill(UploadSettingsState state) {
    final destination = state.destination;
    final secrets = state.secrets;
    _type = destination?.type ?? DestinationType.webdav;
    _endpoint.text = destination?.endpoint ?? '';
    _region.text = destination?.region ?? '';
    _bucket.text = destination?.bucket ?? '';
    _basePath.text = destination?.basePath ?? '';
    _username.text = destination?.username ?? '';
    _pathStyle = destination?.pathStyle ?? false;
    _policy = destination?.policy ?? MobileDataPolicy.off;
    _keepLocalCopy = destination?.keepLocalCopy ?? true;
    _password.text = secrets.password;
    _privateKey.text = secrets.privateKey;
    _passphrase.text = secrets.passphrase;
    _certificatePin = secrets.certificatePin;
    _hostKeyPin = secrets.hostKeyPin;
  }

  void _forgetPins() {
    _certificatePin = null;
    _hostKeyPin = null;
  }

  Destination get _draft => Destination(
    type: _type,
    endpoint: _endpoint.text.trim(),
    region: _type == DestinationType.s3 ? _region.text.trim() : '',
    bucket: _type == DestinationType.s3 ? _bucket.text.trim() : '',
    basePath: _basePath.text.trim(),
    username: _username.text.trim(),
    pathStyle: _type == DestinationType.s3 && _pathStyle,
    policy: _policy,
    keepLocalCopy: _keepLocalCopy,
  );

  DestinationSecrets get _draftSecrets => DestinationSecrets(
    password: _password.text,
    privateKey: _type == DestinationType.sftp ? _privateKey.text.trim() : '',
    passphrase: _type == DestinationType.sftp ? _passphrase.text : '',
    certificatePin: _type == DestinationType.sftp ? null : _certificatePin,
    hostKeyPin: _type == DestinationType.sftp ? _hostKeyPin : null,
  );

  String? get _missingField {
    if (_endpoint.text.trim().isEmpty) return 'Enter the server address.';
    if (_type == DestinationType.s3 && _bucket.text.trim().isEmpty) {
      return 'Enter the bucket.';
    }
    return null;
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final result = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
    });
  }

  Future<String?> _testConnection() async {
    final missing = _missingField;
    if (missing != null) return missing;
    while (true) {
      final error = await _cubit.test(_draft, _draftSecrets);
      if (!mounted) return null;
      switch (error) {
        case null:
          return 'Connection works.';
        case UntrustedCertificateException(:final fingerprint):
          if (!await _confirmTrust(
            'Trust this certificate?',
            'SHA-256',
            fingerprint,
          )) {
            return error.message;
          }
          _certificatePin = fingerprint;
        case UnknownHostKeyException(:final keyType, :final fingerprint):
          if (!await _confirmTrust(
            'Trust this host key?',
            keyType,
            fingerprint,
          )) {
            return error.message;
          }
          _hostKeyPin = fingerprint;
        case StorageException(:final message):
          return message;
      }
    }
  }

  Future<String?> _save() async {
    final missing = _missingField;
    if (missing != null) return missing;
    final draft = _draft;
    if (_cubit.replaces(draft) &&
        !await _confirm(
          title: 'Replace destination?',
          content: 'Photos not uploaded yet will go to the new destination.',
          action: 'Replace',
        )) {
      return null;
    }
    await _cubit.save(draft, _draftSecrets);
    return 'Saved.';
  }

  Future<String?> _remove() async {
    if (!await _confirm(
      title: 'Remove destination?',
      content: 'Photos not uploaded yet wait until you add a destination.',
      action: 'Remove',
    )) {
      return null;
    }
    await _cubit.remove();
    return null;
  }

  Future<bool> _confirmTrust(String title, String label, String fingerprint) =>
      _confirm(
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

  Future<bool> _confirm({
    required String title,
    String? content,
    Widget? contentWidget,
    required String action,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: contentWidget ?? Text(content!),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool obscure = false,
    int? maxLines = 1,
    TextInputType? keyboardType,
    ValueChanged<String>? onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(top: Spacing.medium),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s3 = _type == DestinationType.s3;
    final sftp = _type == DestinationType.sftp;
    return BlocListener<UploadSettingsCubit, UploadSettingsState>(
      bloc: _cubit,
      listener: (context, state) => setState(() => _fill(state)),
      child: BlocBuilder<UploadSettingsCubit, UploadSettingsState>(
        bloc: _cubit,
        builder: (context, state) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: Spacing.extraLarge),
            Text('Upload', style: theme.textTheme.titleMedium),
            const SizedBox(height: Spacing.small),
            Text(
              'Copies downloaded photos to your own server.',
              style: theme.textTheme.bodySmall,
            ),
            if (state.credentialsMissing) ...[
              const SizedBox(height: Spacing.small),
              Text(
                'Credentials missing. Enter them again and save.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: Spacing.small),
            SegmentedButton<DestinationType>(
              segments: const [
                ButtonSegment(
                  value: DestinationType.webdav,
                  label: Text('WebDAV'),
                ),
                ButtonSegment(value: DestinationType.s3, label: Text('S3')),
                ButtonSegment(value: DestinationType.sftp, label: Text('SFTP')),
              ],
              selected: {_type},
              onSelectionChanged: (selection) => setState(() {
                _type = selection.single;
                _forgetPins();
                _result = null;
              }),
            ),
            _field(
              _endpoint,
              switch (_type) {
                DestinationType.webdav => 'Server URL',
                DestinationType.s3 => 'Endpoint URL',
                DestinationType.sftp => 'Host',
              },
              hint: switch (_type) {
                DestinationType.webdav =>
                  'https://cloud.example.com/remote.php/dav/files/me',
                DestinationType.s3 => 'https://s3.eu-central-1.amazonaws.com',
                DestinationType.sftp => 'example.com:22',
              },
              keyboardType: TextInputType.url,
              onChanged: (_) => _forgetPins(),
            ),
            if (s3) ...[
              _field(_region, 'Region', hint: defaultS3Region),
              _field(_bucket, 'Bucket'),
            ],
            _field(_basePath, 'Folder', hint: 'Photos'),
            _field(_username, s3 ? 'Access key ID' : 'Username'),
            _field(
              _password,
              s3 ? 'Secret access key' : 'Password',
              obscure: true,
            ),
            if (sftp) ...[
              _field(_privateKey, 'Private key (optional)', maxLines: null),
              _field(_passphrase, 'Key passphrase', obscure: true),
            ],
            if (s3)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Path-style URLs'),
                value: _pathStyle,
                onChanged: (value) => setState(() => _pathStyle = value),
              ),
            const SizedBox(height: Spacing.medium),
            Text('Mobile data', style: theme.textTheme.titleSmall),
            const SizedBox(height: Spacing.small),
            SegmentedButton<MobileDataPolicy>(
              segments: const [
                ButtonSegment(value: MobileDataPolicy.off, label: Text('Off')),
                ButtonSegment(
                  value: MobileDataPolicy.jpeg,
                  label: Text('JPEG only'),
                ),
                ButtonSegment(value: MobileDataPolicy.all, label: Text('All')),
              ],
              selected: {_policy},
              onSelectionChanged: (selection) =>
                  setState(() => _policy = selection.single),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep photos in gallery after upload'),
              value: _keepLocalCopy,
              onChanged: (value) => setState(() => _keepLocalCopy = value),
            ),
            Wrap(
              spacing: Spacing.small,
              runSpacing: Spacing.small,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : () => _run(_testConnection),
                  child: const Text('Test connection'),
                ),
                FilledButton(
                  onPressed: _busy ? null : () => _run(_save),
                  child: const Text('Save'),
                ),
                if (state.destination != null)
                  TextButton(
                    onPressed: _busy ? null : () => _run(_remove),
                    child: const Text('Remove destination'),
                  ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: Spacing.small),
              const LinearProgressIndicator(),
            ],
            if (_result case final result?) ...[
              const SizedBox(height: Spacing.small),
              Text(result, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
