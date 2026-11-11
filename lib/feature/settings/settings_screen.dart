import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/camera_host_resolver.dart';
import '../../data/settings_repository.dart';
import '../spacing.dart';
import 'settings_cubit.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute(builder: (_) => const SettingsScreen());

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _hostController = TextEditingController(
    text: context.read<SettingsCubit>().state.hostOverride,
  );

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SettingsCubit>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.large),
        children: [
          Text('Download format', style: theme.textTheme.titleMedium),
          const SizedBox(height: Spacing.small),
          BlocBuilder<SettingsCubit, SettingsState>(
            buildWhen: (previous, current) => previous.format != current.format,
            builder: (context, state) => SegmentedButton<DownloadFormat>(
              segments: const [
                ButtonSegment(value: DownloadFormat.jpeg, label: Text('JPEG')),
                ButtonSegment(value: DownloadFormat.raw, label: Text('RAW')),
                ButtonSegment(value: DownloadFormat.both, label: Text('Both')),
              ],
              selected: {state.format},
              onSelectionChanged: (selection) =>
                  cubit.setFormat(selection.single),
            ),
          ),
          const SizedBox(height: Spacing.small),
          Text(
            'Photos without the chosen format are skipped.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.extraLarge),
          Text('Camera address', style: theme.textTheme.titleMedium),
          const SizedBox(height: Spacing.small),
          TextField(
            controller: _hostController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'IP address',
              hintText:
                  'Automatic (Wi-Fi gateway, '
                  'else ${CameraHostResolver.fallbackHost})',
            ),
            onChanged: cubit.setHostOverride,
          ),
        ],
      ),
    );
  }
}
