import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../connect/connect_cubit.dart';
import '../settings/settings_screen.dart';
import '../spacing.dart';
import 'mode_cubit.dart';
import 'operating_mode.dart';

/// Shown after a connect: the user picks what happens to photos.
class ModePickerScreen extends StatelessWidget {
  const ModePickerScreen({super.key});

  static const title = 'Choose a mode';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(title),
      actions: [
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context).push(SettingsScreen.route()),
        ),
        IconButton(
          tooltip: 'Disconnect',
          icon: const Icon(Icons.link_off),
          onPressed: context.read<ConnectCubit>().disconnect,
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(Spacing.large),
      children: [
        for (final mode in OperatingMode.values)
          Card(
            child: ListTile(
              leading: Icon(mode.icon),
              title: Text(mode.label),
              subtitle: Text(mode.description),
              onTap: () => context.read<ModeCubit>().select(mode),
            ),
          ),
      ],
    ),
  );
}
