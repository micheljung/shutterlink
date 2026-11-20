import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../brand/brand_theme.dart';
import '../../remote/remote_bluetooth.dart';
import '../../remote/shutter_remote.dart';
import '../spacing.dart';
import 'camera_pairing_sheet.dart';
import 'interval_plan.dart';
import 'interval_presets.dart';
import 'intervalometer_cubit.dart';
import 'intervalometer_run_view.dart';
import 'intervalometer_text.dart';
import 'plan_editor.dart';

/// Time-lapses and long exposures, fired over the camera's Bluetooth
/// remote. No Wi-Fi connection is needed.
class IntervalometerScreen extends StatefulWidget {
  const IntervalometerScreen({super.key});

  static const routeName = 'intervalometer';
  static const startLabel = 'Start';
  static const pairLabel = 'Pair a camera';
  static const backgroundLabel = 'Keep shooting in background';

  static Route<void> route() => MaterialPageRoute(
    settings: const RouteSettings(name: routeName),
    builder: (_) => const IntervalometerScreen(),
  );

  @override
  State<IntervalometerScreen> createState() => _IntervalometerScreenState();
}

class _IntervalometerScreenState extends State<IntervalometerScreen> {
  late final IntervalometerCubit _cubit = context.read<IntervalometerCubit>();

  @override
  void initState() {
    super.initState();
    unawaited(_cubit.opened());
  }

  @override
  void dispose() {
    unawaited(_cubit.closed());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showsRun = context.select<IntervalometerCubit, bool>(
      (cubit) => cubit.state.run != null,
    );
    final running = context.select<IntervalometerCubit, bool>(
      (cubit) => cubit.state.running,
    );
    return PopScope(
      canPop: !running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leaveRun());
      },
      child: _scaffold(showsRun),
    );
  }

  /// Back during a run asks whether to stop it or leave it shooting, so
  /// neither happens by accident.
  Future<void> _leaveRun() async {
    final choice = await showDialog<_LeaveChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(IntervalometerRunView.stopTitle),
        content: const Text(
          'Stop now, or keep shooting in the background. The run shows on '
          'the start screen until it ends.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_LeaveChoice.background),
            child: const Text(IntervalometerScreen.backgroundLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_LeaveChoice.stop),
            child: const Text(IntervalometerRunView.stopLabel),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == _LeaveChoice.stop) await _cubit.stop();
    if (mounted) Navigator.of(context).pop();
  }

  Widget _scaffold(bool showsRun) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(IntervalometerText.title),
        actions: const [
          _CameraChip(),
          SizedBox(width: Spacing.small),
        ],
      ),
      body: AnimatedSwitcher(
        duration: kThemeAnimationDuration,
        child: showsRun
            ? const IntervalometerRunView(key: ValueKey('run'))
            : const _SetupView(key: ValueKey('setup')),
      ),
    );
  }
}

enum _LeaveChoice { stop, background }

class _SetupView extends StatelessWidget {
  const _SetupView({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<IntervalometerCubit>().state;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              Spacing.large,
              Spacing.small,
              Spacing.large,
              Spacing.large,
            ),
            children: [
              const _CameraCard(),
              const SizedBox(height: Spacing.extraLarge),
              const _SectionTitle('Start from'),
              const SizedBox(height: Spacing.small),
              const _PresetStrip(),
              const SizedBox(height: Spacing.extraLarge),
              const _SectionTitle('Each shot'),
              const SizedBox(height: Spacing.small),
              const PlanEditor(),
              const SizedBox(height: Spacing.extraLarge),
              _PlanSummary(state: state),
              const SizedBox(height: Spacing.large),
              const _CameraChecklist(),
            ],
          ),
        ),
        _StartBar(state: state),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.extraSmall),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The app bar's link status, readable at a glance during a run.
class _CameraChip extends StatelessWidget {
  const _CameraChip();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<IntervalometerCubit>().state;
    if (state.camera == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.small),
      child: LinkDot(link: state.link),
    );
  }
}

/// Green while the camera listens, amber while reconnecting.
class LinkDot extends StatelessWidget {
  const LinkDot({super.key, required this.link});

  static const _size = 10.0;
  static const _glowAlpha = 0.6;
  static const _glowBlur = 6.0;

  final RemoteLink link;

  static String label(RemoteLink link) => switch (link) {
    RemoteLink.connected => 'Camera connected',
    RemoteLink.connecting => 'Connecting to the camera',
    RemoteLink.pairing => 'Waiting for the pairing to be confirmed',
    RemoteLink.refused => 'The camera refuses this phone',
    RemoteLink.disconnected => 'Camera not connected',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (link) {
      RemoteLink.connected => BrandColors.online(theme.brightness),
      RemoteLink.connecting || RemoteLink.pairing => BrandColors.accent,
      RemoteLink.refused => theme.colorScheme.error,
      RemoteLink.disconnected => theme.colorScheme.outline,
    };
    return Tooltip(
      message: label(link),
      child: Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: link == RemoteLink.disconnected
              ? null
              : [
                  BoxShadow(
                    color: color.withValues(alpha: _glowAlpha),
                    blurRadius: _glowBlur,
                  ),
                ],
        ),
      ),
    );
  }
}

class _CameraCard extends StatelessWidget {
  const _CameraCard();

  static const _radius = 28.0;
  static const _iconRadius = 24.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final cubit = context.read<IntervalometerCubit>();
    final state = context.watch<IntervalometerCubit>().state;
    final camera = state.camera;
    final (title, subtitle) = switch ((camera, state.link)) {
      (null, _) => (
        'No camera paired',
        'Pair your Canon once over Bluetooth. No Wi-Fi needed, and the '
            'camera battery lasts far longer.',
      ),
      (final camera?, RemoteLink.connected) => (camera.name, 'Ready to shoot'),
      (final camera?, RemoteLink.connecting) => (camera.name, 'Connecting…'),
      (final camera?, RemoteLink.pairing) => (
        camera.name,
        IntervalometerText.pairingText,
      ),
      (final camera?, RemoteLink.refused) => (
        camera.name,
        IntervalometerText.refusedTitle,
      ),
      (final camera?, RemoteLink.disconnected) => (
        camera.name,
        state.bluetooth == BluetoothState.off
            ? 'Bluetooth is off'
            : state.bluetooth == BluetoothState.locationOff
            ? 'Location is off, which this Android version needs'
            : 'Not connected. Switch the camera on and keep it close.',
      ),
    };
    return Card.filled(
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.large),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: _iconRadius,
                  backgroundColor: colors.primaryContainer,
                  foregroundColor: colors.onPrimaryContainer,
                  child: Icon(
                    camera == null
                        ? Icons.bluetooth_searching
                        : Icons.photo_camera_outlined,
                  ),
                ),
                const SizedBox(width: Spacing.large),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (camera != null) ...[
                            const SizedBox(width: Spacing.small),
                            LinkDot(link: state.link),
                          ],
                        ],
                      ),
                      const SizedBox(height: Spacing.tiny),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (camera != null)
                  PopupMenuButton<VoidCallback>(
                    tooltip: 'Camera options',
                    onSelected: (action) => action(),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: () => CameraPairingSheet.show(context),
                        child: const Text('Pair another camera'),
                      ),
                      if (!state.demo)
                        PopupMenuItem(
                          value: cubit.forgetCamera,
                          child: const Text('Forget this camera'),
                        ),
                    ],
                  ),
              ],
            ),
            if (camera == null) ...[
              const SizedBox(height: Spacing.large),
              FilledButton.icon(
                icon: const Icon(Icons.bluetooth),
                label: const Text(IntervalometerScreen.pairLabel),
                onPressed: () => CameraPairingSheet.show(context),
              ),
            ] else if (state.link == RemoteLink.refused && !state.demo) ...[
              const SizedBox(height: Spacing.medium),
              const _RefusedSteps(),
              const SizedBox(height: Spacing.medium),
              FilledButton.icon(
                icon: const Icon(Icons.bluetooth),
                label: const Text(IntervalometerText.pairAgainLabel),
                onPressed: () => CameraPairingSheet.show(context),
              ),
            ] else if (state.link == RemoteLink.disconnected) ...[
              const SizedBox(height: Spacing.medium),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Reconnect'),
                onPressed: cubit.reconnect,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What to do on the camera so it accepts this phone again.
class _RefusedSteps extends StatelessWidget {
  const _RefusedSteps();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(IntervalometerText.refusedText, style: theme.textTheme.bodySmall),
        const SizedBox(height: Spacing.small),
        for (final (index, step) in IntervalometerText.refusedSteps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.tiny),
            child: Text(
              '${index + 1}. $step',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _PresetStrip extends StatelessWidget {
  const _PresetStrip();

  static const _height = 112.0;
  static const _width = 128.0;
  static const _radius = 20.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final cubit = context.read<IntervalometerCubit>();
    final selected = context.select<IntervalometerCubit, IntervalPreset?>(
      (cubit) => cubit.state.preset,
    );
    return SizedBox(
      height: _height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: IntervalPreset.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: Spacing.small),
        itemBuilder: (context, index) {
          final preset = IntervalPreset.values[index];
          final active = preset == selected;
          final foreground = active
              ? colors.onTertiaryContainer
              : colors.onSurface;
          return SizedBox(
            width: _width,
            child: Card.filled(
              margin: EdgeInsets.zero,
              color: active
                  ? colors.tertiaryContainer
                  : colors.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(_radius),
                side: active
                    ? BorderSide(color: colors.tertiary)
                    : BorderSide.none,
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => cubit.applyPreset(preset),
                child: Tooltip(
                  message: preset.description,
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.medium),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(preset.icon, color: foreground),
                        const Spacer(),
                        Text(
                          preset.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: foreground,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          _short(preset.plan),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: active
                                ? colors.onTertiaryContainer
                                : colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  static String _short(IntervalPlan plan) {
    final every = 'every ${IntervalometerText.duration(plan.interval)}';
    if (plan.shots == 1) {
      return '${IntervalometerText.duration(plan.exposure)} BULB';
    }
    return plan.bulb
        ? '${IntervalometerText.duration(plan.exposure)}, $every'
        : every;
  }
}

/// What the plan adds up to: how long it takes, when it ends and how long
/// the clip will be.
class _PlanSummary extends StatelessWidget {
  const _PlanSummary({required this.state});

  final IntervalometerState state;

  static const _radius = 24.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final plan = state.plan;
    final runTime = plan.runTime;
    final clip = plan.clipLength(state.frameRate);
    final cubit = context.read<IntervalometerCubit>();
    final problem = plan.problem;
    return Card.filled(
      margin: EdgeInsets.zero,
      color: colors.secondaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_radius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.large),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _Figure(
                  label: 'Shooting time',
                  value: runTime == null
                      ? 'Open-ended'
                      : IntervalometerText.duration(runTime + plan.startDelay),
                ),
                _Figure(
                  label: 'Ends about',
                  value: runTime == null
                      ? '—'
                      : IntervalometerText.timeOfDay(
                          clock.now().add(runTime + plan.startDelay),
                        ),
                ),
                if (plan.control != ExposureControl.video)
                  _Figure(
                    label: 'Clip at ${state.frameRate} fps',
                    value: clip == null
                        ? '—'
                        : IntervalometerText.duration(clip),
                    onTap: () {
                      const rates = IntervalPlan.clipFrameRates;
                      final next =
                          rates[(rates.indexOf(state.frameRate) + 1) %
                              rates.length];
                      cubit.setFrameRate(next);
                    },
                  ),
              ],
            ),
            if (problem != null) ...[
              const SizedBox(height: Spacing.medium),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, color: colors.error),
                  const SizedBox(width: Spacing.small),
                  Expanded(
                    child: Text(
                      IntervalometerText.problem(problem, plan),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(Spacing.medium),
        onTap: onTap,
        child: Semantics(
          label: '$label: $value',
          button: onTap != null,
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.extraSmall),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: colors.onSecondaryContainer,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.onSecondaryContainer,
                        ),
                      ),
                    ),
                    if (onTap != null)
                      Icon(
                        Icons.unfold_more,
                        size: theme.textTheme.labelMedium?.fontSize,
                        color: colors.onSecondaryContainer,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What to set on the camera, which an app cannot set over the remote.
class _CameraChecklist extends StatelessWidget {
  const _CameraChecklist();

  static const _radius = 20.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final control = context.select<IntervalometerCubit, ExposureControl>(
      (cubit) => cubit.state.plan.control,
    );
    final items = [
      (
        Icons.timer_outlined,
        'Drive mode: Self-timer/Remote',
        'The camera ignores the remote in any other drive mode. It still '
            'fires at once.',
      ),
      if (control == ExposureControl.bulb)
        (
          Icons.shutter_speed_outlined,
          'Shutter speed: BULB',
          'Use mode M or B. Shutterlink opens and closes each exposure.',
        )
      else if (control == ExposureControl.camera)
        (
          Icons.shutter_speed_outlined,
          'Shutter speed shorter than the interval',
          'The camera takes as long as its shutter speed, plus a moment to '
              'save.',
        )
      else
        (
          Icons.videocam_outlined,
          'Movie mode, Remote control: Enable',
          'Set in the shooting menu, so the remote can start recordings.',
        ),
      (
        Icons.center_focus_strong_outlined,
        'Focus: manual',
        'So no shot is lost hunting for focus in the dark.',
      ),
      (
        Icons.power_settings_new,
        'Auto power off: Disable',
        'For long intervals, so the camera stays awake between shots.',
      ),
    ];
    return Card.outlined(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(_radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(Icons.checklist, color: colors.primary),
        title: Text(
          'On the camera',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: const Text('Set these once before you start'),
        children: [
          for (final (icon, title, detail) in items)
            ListTile(
              dense: true,
              leading: Icon(icon),
              title: Text(title),
              subtitle: Text(detail),
            ),
          const SizedBox(height: Spacing.small),
        ],
      ),
    );
  }
}

class _StartBar extends StatelessWidget {
  const _StartBar({required this.state});

  final IntervalometerState state;

  String? get _blocker {
    if (state.camera == null) return 'Pair a camera to start.';
    if (state.link != RemoteLink.connected) {
      return 'Waiting for the camera…';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocker = _blocker;
    final cubit = context.read<IntervalometerCubit>();
    final plan = state.plan;
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.large,
            Spacing.medium,
            Spacing.large,
            Spacing.medium,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (blocker != null) ...[
                Text(
                  blocker,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: Spacing.small),
              ],
              FilledButton.icon(
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(
                  plan.startDelay > Duration.zero
                      ? 'Start in ${IntervalometerText.duration(plan.startDelay)}'
                      : IntervalometerScreen.startLabel,
                ),
                onPressed: state.canStart ? cubit.start : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
