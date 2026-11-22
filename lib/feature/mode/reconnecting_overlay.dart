import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../connect/connect_cubit.dart';
import '../connect/connect_state.dart';
import '../spacing.dart';
import 'mode_cubit.dart';

/// Covers the mode while the camera reconnects, so the mode continues once
/// it is back.
class ReconnectingOverlay extends StatelessWidget {
  const ReconnectingOverlay({super.key, required this.state});

  static const reconnectingText = 'Reconnecting…';
  static const unreachableText = 'Camera not reachable';
  static const userActionText = 'Open Shutterlink to allow USB access';
  static const notRespondingText = ConnectCubit.notRespondingMessage;
  static const allowUsbLabel = 'Allow USB access';
  static const abortLabel = 'Abort';

  final ConnectReconnecting state;

  /// Leaves the mode and gives up the camera. A camera that came back in
  /// the meantime stays, and the picker shows.
  static void abort(BuildContext context) {
    context.read<ModeCubit>().leave();
    unawaited(context.read<ConnectCubit>().abortReconnect());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, text) = switch (state) {
      ConnectReconnecting(userActionNeeded: true) => (
        Icons.usb,
        userActionText,
      ),
      ConnectReconnecting(notResponding: true) => (
        Icons.power_settings_new,
        notRespondingText,
      ),
      ConnectReconnecting(unreachable: true) => (
        Icons.portable_wifi_off,
        unreachableText,
      ),
      ConnectReconnecting(usb: true) => (Icons.usb, reconnectingText),
      _ => (Icons.sync, reconnectingText),
    };
    return ColoredBox(
      color: theme.colorScheme.scrim.withValues(alpha: _scrimAlpha),
      child: Center(
        child: Card(
          margin: const EdgeInsets.all(Spacing.large),
          child: Padding(
            padding: const EdgeInsets.all(Spacing.large),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: Spacing.extraLarge),
                const SizedBox(height: Spacing.medium),
                Text(
                  text,
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Spacing.large),
                if (state.userActionNeeded) ...[
                  FilledButton.icon(
                    icon: const Icon(Icons.usb),
                    label: const Text(allowUsbLabel),
                    onPressed: context.read<ConnectCubit>().allowUsbAccess,
                  ),
                  const SizedBox(height: Spacing.small),
                ],
                TextButton(
                  onPressed: () => abort(context),
                  child: const Text(abortLabel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const _scrimAlpha = 0.5;
}
