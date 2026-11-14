import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../upload/provider_preset.dart';
import '../../upload/storage_backend.dart';
import '../spacing.dart';
import 'settings_cards.dart';
import 'upload_draft_fields.dart';
import 'upload_settings_cubit.dart';
import 'upload_setup_cubit.dart';

/// Creates the upload destination step by step, starting from a provider.
class UploadSetupScreen extends StatefulWidget {
  const UploadSetupScreen({super.key});

  static Route<void> route(UploadSettingsCubit settings) => uploadDraftRoute(
    settings,
    create: UploadSetupCubit.new,
    screen: const UploadSetupScreen(),
    fullscreenDialog: true,
  );

  @override
  State<UploadSetupScreen> createState() => _UploadSetupScreenState();
}

enum _Step {
  provider('Provider'),
  server('Server'),
  signIn('Sign in'),
  folder('Folder'),
  check('Check & save');

  const _Step(this.label);

  final String label;
}

class _UploadSetupScreenState extends State<UploadSetupScreen> {
  var _step = _Step.provider;
  var _checking = false;
  StorageException? _failure;
  String? _note;

  UploadSetupCubit get _cubit => context.read<UploadSetupCubit>();

  void _goTo(_Step step) {
    setState(() {
      _step = step;
      _failure = null;
      _note = null;
    });
    if (step == _Step.check) _check();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _failure = null;
      _note = null;
    });
    try {
      final failure = await testWithTrust(context, _cubit);
      if (!mounted) return;
      _failure = failure;
      if (failure == null) await _save();
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _save() async {
    setState(() => _checking = true);
    try {
      if (await saveDraft(context, _cubit)) {
        if (mounted) Navigator.of(context).pop();
      } else {
        _note = notSavedNote;
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  String _headline(ProviderPreset? preset) => switch (_step) {
    _Step.provider => 'Where should photos go?',
    _Step.server => switch (preset) {
      ProviderPreset.nextcloud => 'Your Nextcloud server',
      ProviderPreset.backblazeB2 => 'Your Backblaze B2 bucket',
      ProviderPreset.awsS3 => 'Your AWS S3 bucket',
      ProviderPreset.cloudflareR2 => 'Your Cloudflare R2 bucket',
      ProviderPreset.hetznerStorageBox => 'Your Storage Box',
      ProviderPreset.custom || null => 'Your server',
    },
    _Step.signIn => 'Sign in',
    _Step.folder => 'Choose a folder',
    _Step.check => 'Check and save',
  };

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UploadSetupCubit>().state;
    final previous = _step.index == 0 ? null : _Step.values[_step.index - 1];
    final canContinue = switch (_step) {
      _Step.provider => state.preset != null,
      _Step.server => state.serverComplete,
      _ => true,
    };
    return SetupScaffold(
      title: 'Set up upload',
      steps: [for (final step in _Step.values) step.label],
      step: _step.index,
      headline: _headline(state.preset),
      bottomBar: _step == _Step.check
          ? SetupButtonBar(
              onBack: _checking ? null : () => _goTo(_Step.folder),
              primary: 'Check again',
              onPrimary: _checking ? null : _check,
            )
          : SetupButtonBar(
              onBack: previous == null ? null : () => _goTo(previous),
              primary: 'Next',
              onPrimary: canContinue
                  ? () => _goTo(_Step.values[_step.index + 1])
                  : null,
            ),
      children: switch (_step) {
        _Step.provider => [
          for (final preset in ProviderPreset.values)
            _ProviderCard(
              preset: preset,
              selected: state.preset == preset,
              onTap: () => _cubit.choosePreset(preset),
            ),
        ],
        _Step.server => const [UploadServerFields()],
        _Step.signIn => const [UploadSignInFields()],
        _Step.folder => const [UploadFolderField()],
        _Step.check => [
          SetupCheckStatus(
            busy: _checking,
            busyText: 'Checking the connection…',
            error: _failure?.message,
            note: _note,
            actions: [
              if (_failure is AuthenticationException)
                TextButton(
                  onPressed: () => _goTo(_Step.signIn),
                  child: const Text('Back to Sign in'),
                )
              else
                TextButton(
                  onPressed: () => _goTo(_Step.server),
                  child: const Text('Back to Server'),
                ),
              if (_failure case final failure? when !isTrustFailure(failure))
                OutlinedButton(
                  onPressed: _save,
                  child: const Text('Save anyway'),
                ),
            ],
          ),
        ],
      },
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  static const _radius = 12.0;
  static const _selectedBorder = 2.0;

  final ProviderPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_radius),
      side: selected
          ? BorderSide(color: colors.primary, width: _selectedBorder)
          : BorderSide(color: colors.outlineVariant),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.small),
      child: Card.outlined(
        margin: EdgeInsets.zero,
        shape: shape,
        child: ListTile(
          shape: shape,
          leading: Icon(presetIcon(preset)),
          title: Text(preset.label),
          subtitle: Text(preset.description),
          selected: selected,
          trailing: selected
              ? Icon(Icons.check_circle, color: colors.primary)
              : null,
          onTap: onTap,
        ),
      ),
    );
  }
}
