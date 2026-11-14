import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../upload/network_policy.dart';
import '../spacing.dart';
import 'settings_cards.dart';
import 'upload_draft_fields.dart';
import 'upload_edit_screen.dart';
import 'upload_settings_cubit.dart';
import 'upload_setup_screen.dart';

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
    return _UploadSettings(cubit: cubit);
  }
}

class _UploadSettings extends StatefulWidget {
  const _UploadSettings({required this.cubit});

  final UploadSettingsCubit cubit;

  @override
  State<_UploadSettings> createState() => _UploadSettingsState();
}

class _UploadSettingsState extends State<_UploadSettings> {
  UploadSettingsCubit get _cubit => widget.cubit;

  @override
  void initState() {
    super.initState();
    _cubit.load();
  }

  Future<void> _remove() async {
    if (await confirmDialog(
      context,
      title: 'Remove destination?',
      content: 'Photos not uploaded yet wait until you add a destination.',
      action: 'Remove',
    )) {
      await _cubit.remove();
    }
  }

  Future<void> _edit() async {
    await Navigator.of(context).push(UploadEditScreen.route(_cubit));
    await _cubit.load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocBuilder<UploadSettingsCubit, UploadSettingsState>(
      bloc: _cubit,
      builder: (context, state) {
        final destination = state.destination;
        final policy = destination?.policy ?? MobileDataPolicy.off;
        final keepLocalCopy = destination?.keepLocalCopy ?? true;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsSectionHeader('Upload'),
            if (destination == null)
              SettingsEmptyCard(
                icon: Icons.cloud_off_outlined,
                title: 'No upload destination',
                text:
                    'Copy downloaded photos to your own server or cloud '
                    'storage.',
                action: 'Set up upload',
                onPressed: () =>
                    Navigator.of(context).push(UploadSetupScreen.route(_cubit)),
              )
            else
              SettingsSummaryCard(
                icon: presetIcon(state.preset),
                title: destinationTitle(destination, state.preset),
                subtitle:
                    '${destinationLocation(destination)} · '
                    '${destinationFolder(destination)}',
                error: state.credentialsMissing
                    ? 'Credentials missing. Enter them again.'
                    : null,
                actions: [
                  TextButton(onPressed: _remove, child: const Text('Remove')),
                  FilledButton.tonalIcon(
                    onPressed: state.loaded ? _edit : null,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(state.credentialsMissing ? 'Fix' : 'Edit'),
                  ),
                ],
              ),
            const SizedBox(height: Spacing.medium),
            SettingsCard(
              children: [
                Text('Mobile data', style: theme.textTheme.titleMedium),
                const SizedBox(height: Spacing.small),
                SegmentedButton<MobileDataPolicy>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: MobileDataPolicy.off,
                      label: Text('Off'),
                    ),
                    ButtonSegment(
                      value: MobileDataPolicy.jpeg,
                      label: Text('JPEG only'),
                    ),
                    ButtonSegment(
                      value: MobileDataPolicy.all,
                      label: Text('All'),
                    ),
                  ],
                  selected: {policy},
                  onSelectionChanged: destination == null
                      ? null
                      : (selection) => _cubit.setPolicy(
                          selection.single,
                          keepLocalCopy: keepLocalCopy,
                        ),
                ),
                const SizedBox(height: Spacing.extraSmall),
                Text(
                  destination == null
                      ? 'Available after upload is set up.'
                      : switch (policy) {
                          MobileDataPolicy.off => 'Uploads wait for Wi-Fi.',
                          MobileDataPolicy.jpeg =>
                            'JPEGs upload on mobile data, RAW files wait '
                                'for Wi-Fi.',
                          MobileDataPolicy.all =>
                            'Everything uploads on mobile data too.',
                        },
                  style: theme.textTheme.bodySmall,
                ),
                const Divider(height: Spacing.extraLarge),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keep photos in gallery after upload'),
                  value: keepLocalCopy,
                  onChanged: destination == null
                      ? null
                      : (value) =>
                            _cubit.setPolicy(policy, keepLocalCopy: value),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
