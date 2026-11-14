import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../upload/provider_preset.dart';
import '../../upload/storage_backend.dart';
import '../spacing.dart';
import 'settings_cards.dart';
import 'upload_draft_fields.dart';
import 'upload_settings_cubit.dart';
import 'upload_setup_cubit.dart';

/// Changes the saved upload destination on one page.
class UploadEditScreen extends StatefulWidget {
  const UploadEditScreen({super.key});

  static Route<void> route(UploadSettingsCubit settings) => uploadDraftRoute(
    settings,
    create: UploadSetupCubit.edit,
    screen: const UploadEditScreen(),
  );

  @override
  State<UploadEditScreen> createState() => _UploadEditScreenState();
}

class _UploadEditScreenState extends State<UploadEditScreen> {
  var _busy = false;
  String? _result;
  StorageException? _failure;

  UploadSetupCubit get _cubit => context.read<UploadSetupCubit>();

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _result = null;
      _failure = null;
    });
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() async {
    final failure = await testWithTrust(context, _cubit);
    if (!mounted) return;
    setState(() {
      _failure = failure;
      _result = failure == null ? 'Connection works.' : null;
    });
  }

  Future<void> _testAndSave() async {
    final failure = await testWithTrust(context, _cubit);
    if (!mounted) return;
    if (failure != null) {
      setState(() => _failure = failure);
      return;
    }
    await _save();
  }

  Future<void> _save() async {
    if (!await saveDraft(context, _cubit)) {
      _result = notSavedNote;
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<UploadSetupCubit>().state;
    final preset = state.preset ?? ProviderPreset.custom;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit upload')),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.large),
        children: [
          Row(
            children: [
              Icon(presetIcon(preset)),
              const SizedBox(width: Spacing.medium),
              Text(
                destinationTitle(state.destination, preset),
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
          const SettingsSectionHeader('Server'),
          const UploadServerFields(),
          const SettingsSectionHeader('Sign in'),
          const UploadSignInFields(),
          if (state.hasFolder) ...const [
            SettingsSectionHeader('Folder'),
            UploadFolderField(),
          ],
          const SizedBox(height: Spacing.large),
          SetupCheckStatus(
            busy: _busy,
            busyText: 'Checking the connection…',
            error: _failure?.message,
            note: _result,
            actions: [
              if (_failure case final failure? when !isTrustFailure(failure))
                OutlinedButton(
                  onPressed: () => _run(_save),
                  child: const Text('Save anyway'),
                ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.large),
          child: Row(
            children: [
              OutlinedButton(
                onPressed: _busy || !state.serverComplete
                    ? null
                    : () => _run(_test),
                child: const Text('Test connection'),
              ),
              const SizedBox(width: Spacing.medium),
              Expanded(
                child: FilledButton(
                  onPressed: _busy || !state.serverComplete
                      ? null
                      : () => _run(_testAndSave),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
