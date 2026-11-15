import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../connect/connect_cubit.dart';
import '../connect/connect_state.dart';
import '../settings/sessions_setup_screen.dart';
import '../settings/settings_cubit.dart';
import '../settings/settings_screen.dart';
import '../settings/upload_settings_cubit.dart';
import '../settings/upload_setup_screen.dart';
import '../spacing.dart';
import '../upload/upload_status_indicator.dart';
import 'mode_cubit.dart';
import 'operating_mode.dart';

/// Shown after a connect: the user picks what happens to photos.
class ModePickerScreen extends StatelessWidget {
  const ModePickerScreen({super.key});

  static const title = 'Choose a mode';

  /// Enters [mode] once what it needs is set up: a destination for Auto
  /// Upload, the Sessions server for QR Session.
  static Future<void> enter(BuildContext context, OperatingMode mode) async {
    final modes = context.read<ModeCubit>();
    final connect = context.read<ConnectCubit>();
    final navigator = Navigator.of(context);
    switch (mode) {
      case OperatingMode.browse:
        break;
      case OperatingMode.autoUpload:
        final uploads = context.read<UploadSettingsCubit>();
        if (uploads.state.destination == null) {
          await navigator.push(UploadSetupScreen.route(uploads));
          if (uploads.state.destination == null) return;
        }
      case OperatingMode.qrSession:
        final settings = context.read<SettingsCubit>();
        if (!settings.state.sessionsConfigured) {
          await navigator.push(SessionsSetupScreen.route());
          if (!settings.state.sessionsConfigured) return;
        }
    }
    // The camera may have gone during the setup.
    final connected = switch (connect.state) {
      ConnectConnected() || ConnectReconnecting() => true,
      _ => false,
    };
    if (connected && !modes.isClosed) modes.select(mode);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(title),
      actions: [
        const UploadStatusIndicator(),
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
              onTap: () => enter(context, mode),
            ),
          ),
      ],
    ),
  );
}
