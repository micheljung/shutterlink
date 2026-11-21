import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../brand/brand_theme.dart';
import '../../brand/shutterlink_logo.dart';
import '../../brand/shutterlink_wordmark.dart';
import '../connect/connect_cubit.dart';
import '../connect/connect_state.dart';
import '../live_view_probe/live_view_probe_screen.dart';
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

  /// Hides the debug tools; profile builds keep them, since they measure.
  /// The README screenshots turn it on to show the app as released.
  @visibleForTesting
  static bool hidesDebugTools = kReleaseMode;

  static const title = 'Choose a mode';

  /// Enters [mode] once what it needs is set up: a destination for Auto
  /// Upload, the Sessions server for Live Share.
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
      case OperatingMode.liveShare:
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

  static String statusText(ConnectTarget? target) => switch (target) {
    WifiTarget() || null => 'Connected over Wi-Fi',
    UsbTarget() => 'Connected over USB',
    DemoTarget() => 'Connected to the demo camera',
  };

  static const _logoSize = 30.0;
  static const _wordmarkSize = 22.0;
  static const _headlineTracking = -1.0;
  static const _statusGap = 6.0;

  /// From here on the cards sit side by side, as in Material's medium
  /// window class.
  static const _wideLayoutWidth = 600.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: Spacing.extraLarge,
        title: const Row(
          children: [
            ShutterlinkLogo(size: _logoSize),
            SizedBox(width: Spacing.small),
            Flexible(child: ShutterlinkWordmark(size: _wordmarkSize)),
          ],
        ),
        actions: [
          const UploadStatusIndicator(),
          if (!hidesDebugTools)
            IconButton(
              tooltip: LiveViewProbe.title,
              icon: const Icon(Icons.speed),
              onPressed: () =>
                  Navigator.of(context).push(LiveViewProbeScreen.route()),
            ),
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
          const SizedBox(width: Spacing.small),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _wideLayoutWidth;
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                Spacing.extraLarge,
                Spacing.medium,
                Spacing.extraLarge,
                Spacing.extraLarge,
              ),
              children: [
                const _ConnectionStatus(),
                const SizedBox(height: _statusGap),
                Text(
                  title,
                  style: theme.textTheme.headlineLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: _headlineTracking,
                  ),
                ),
                const SizedBox(height: Spacing.large),
                if (wide)
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (index, mode)
                            in OperatingMode.values.indexed) ...[
                          if (index > 0) const SizedBox(width: Spacing.medium),
                          Expanded(child: _ModeCard(mode)),
                        ],
                      ],
                    ),
                  )
                else
                  for (final (index, mode) in OperatingMode.values.indexed) ...[
                    if (index > 0) const SizedBox(height: Spacing.medium),
                    _ModeCard(mode),
                  ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus();

  static const _dotSize = 8.0;
  static const _glowAlpha = 0.6;
  static const _glowBlur = 6.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connection = context.watch<ConnectCubit>().state;
    if (connection is! ConnectConnected) return const SizedBox.shrink();
    final online = BrandColors.online(theme.brightness);
    return Row(
      children: [
        Container(
          width: _dotSize,
          height: _dotSize,
          decoration: BoxDecoration(
            color: online,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: online.withValues(alpha: _glowAlpha),
                blurRadius: _glowBlur,
              ),
            ],
          ),
        ),
        const SizedBox(width: Spacing.medium),
        Expanded(
          child: Text(
            ModePickerScreen.statusText(connection.target),
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard(this.mode);

  final OperatingMode mode;

  static const _radius = 28.0;
  static const _heroHeight = 92.0;
  static const _heroInset = 20.0;
  static const _heroShade = 0.18;
  static const _iconSize = 40.0;
  static const _watermarkSize = 168.0;
  static const _watermarkRight = -28.0;
  static const _watermarkTop = -36.0;
  static const _watermarkAlpha = 0.1;
  static const _arrowRadius = 18.0;
  static const _arrowSize = 20.0;
  static const _labelTracking = -0.3;
  static const _descriptionLineHeight = 1.35;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (container, onContainer) = switch (mode) {
      OperatingMode.browse => (
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      OperatingMode.autoUpload => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      OperatingMode.liveShare => (
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
    };
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => ModePickerScreen.enter(context, mode),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: _heroHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          container,
                          Color.lerp(container, onContainer, _heroShade)!,
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    right: _watermarkRight,
                    top: _watermarkTop,
                    child: Icon(
                      mode.icon,
                      size: _watermarkSize,
                      color: onContainer.withValues(alpha: _watermarkAlpha),
                    ),
                  ),
                  Positioned(
                    left: _heroInset,
                    bottom: _heroInset,
                    child: Icon(mode.icon, size: _iconSize, color: onContainer),
                  ),
                  Positioned(
                    right: _heroInset,
                    bottom: _heroInset,
                    child: CircleAvatar(
                      radius: _arrowRadius,
                      backgroundColor: onContainer,
                      child: Icon(
                        Icons.arrow_forward,
                        size: _arrowSize,
                        color: container,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                _heroInset,
                Spacing.medium,
                _heroInset,
                _heroInset,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mode.label,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: _labelTracking,
                    ),
                  ),
                  const SizedBox(height: Spacing.extraSmall),
                  Text(
                    mode.description,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: _descriptionLineHeight,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
