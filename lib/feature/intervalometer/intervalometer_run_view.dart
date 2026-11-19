import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../remote/shutter_remote.dart';
import '../spacing.dart';
import 'interval_plan.dart';
import 'interval_run.dart';
import 'intervalometer_cubit.dart';
import 'intervalometer_text.dart';
import 'progress_dial.dart';

/// A run in progress: a dial to read from a distance, what happens next, and
/// pause and stop within thumb's reach.
class IntervalometerRunView extends StatefulWidget {
  const IntervalometerRunView({super.key});

  static const pauseLabel = 'Pause';
  static const resumeLabel = 'Resume';
  static const stopLabel = 'Stop';
  static const newRunLabel = 'Set up a new run';
  static const stopTitle = 'Stop the run?';

  @override
  State<IntervalometerRunView> createState() => _IntervalometerRunViewState();
}

class _IntervalometerRunViewState extends State<IntervalometerRunView>
    with SingleTickerProviderStateMixin {
  /// Redraws the countdowns and the dial's arc.
  late final Timer _ticker;
  late final _flash = AnimationController(
    vsync: this,
    duration: _flashDuration,
  );

  static const _redrawEvery = Duration(milliseconds: 200);
  static const _flashDuration = Duration(milliseconds: 450);
  static const _flashAlpha = 0.35;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(_redrawEvery, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    _flash.dispose();
    super.dispose();
  }

  Future<void> _confirmStop(IntervalometerCubit cubit) async {
    final stop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(IntervalometerRunView.stopTitle),
        content: const Text(
          'The shots taken so far stay on the card. A running exposure is '
          'closed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep shooting'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(IntervalometerRunView.stopLabel),
          ),
        ],
      ),
    );
    if (stop ?? false) unawaited(cubit.stop());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final cubit = context.read<IntervalometerCubit>();
    final state = context.watch<IntervalometerCubit>().state;
    final run = state.run;
    if (run == null) return const SizedBox.shrink();
    final now = clock.now();
    final connected = state.link == RemoteLink.connected;
    return BlocListener<IntervalometerCubit, IntervalometerState>(
      listenWhen: (previous, current) =>
          current.run?.lastShotAt != null &&
          previous.run?.lastShotAt != current.run?.lastShotAt,
      listener: (_, _) => _flash.forward(from: 0),
      child: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.large,
                    Spacing.large,
                    Spacing.large,
                    Spacing.large,
                  ),
                  children: [
                    if (!connected && run.active)
                      _Banner(
                        icon: Icons.bluetooth_searching,
                        text:
                            'Camera out of reach. Reconnecting; shots due meanwhile '
                            'are missed, and the run keeps its pace.',
                      ),
                    if (run.closeFailed)
                      const _Banner(
                        icon: Icons.warning_amber_rounded,
                        text:
                            'An exposure could not be ended. It ends as soon as '
                            'the camera is back; check the camera.',
                      ),
                    if (state.notificationsDenied && run.active)
                      const _Banner(
                        icon: Icons.notifications_off_outlined,
                        text: 'Notifications are off, so progress only shows here.',
                        quiet: true,
                      ),
                    const SizedBox(height: Spacing.medium),
                    Center(
                      child: ProgressDial(
                        progress: run.active ? run.progress : 1,
                        cycle: _cycle(run, now),
                        exposing: run.phase == RunPhase.exposing,
                        child: _DialCenter(run: run, now: now),
                      ),
                    ),
                    const SizedBox(height: Spacing.extraLarge),
                    _Stats(run: run, now: now),
                    const SizedBox(height: Spacing.large),
                    _PlanLine(plan: run.plan),
                  ],
                ),
              ),
              Material(
                color: colors.surfaceContainer,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(Spacing.large),
                    child: run.active
                        ? Row(
                            children: [
                              Expanded(
                                child: run.phase == RunPhase.paused
                                    ? FilledButton.tonalIcon(
                                        icon: const Icon(Icons.play_arrow),
                                        label: const Text(
                                          IntervalometerRunView.resumeLabel,
                                        ),
                                        onPressed: cubit.resume,
                                      )
                                    : OutlinedButton.icon(
                                        icon: const Icon(Icons.pause),
                                        label: const Text(
                                          IntervalometerRunView.pauseLabel,
                                        ),
                                        onPressed: cubit.pause,
                                      ),
                              ),
                              const SizedBox(width: Spacing.medium),
                              Expanded(
                                child: FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: colors.error,
                                    foregroundColor: colors.onError,
                                  ),
                                  icon: const Icon(Icons.stop),
                                  label: const Text(
                                    IntervalometerRunView.stopLabel,
                                  ),
                                  onPressed: () => _confirmStop(cubit),
                                ),
                              ),
                            ],
                          )
                        : FilledButton.icon(
                            icon: const Icon(Icons.tune),
                            label: const Text(
                              IntervalometerRunView.newRunLabel,
                            ),
                            onPressed: cubit.dismissRun,
                          ),
                  ),
                ),
              ),
            ],
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _flash,
                builder: (context, _) => ColoredBox(
                  color: colors.primary.withValues(
                    alpha: _flash.isAnimating
                        ? (1 - _flash.value) * _flashAlpha
                        : 0,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// How far through the current wait or exposure the run is.
  static double _cycle(RunSnapshot run, DateTime now) {
    if (run.phase == RunPhase.exposing) {
      final start = run.exposureStartedAt;
      final end = run.exposureEndsAt;
      if (start == null || end == null) return 0;
      return _share(now.difference(start), end.difference(start));
    }
    final next = run.nextShotAt;
    if (next == null) return run.active ? 0 : 1;
    final from = switch (run.phase) {
      RunPhase.starting => run.startsAt.subtract(run.plan.startDelay),
      _ => next.subtract(run.plan.interval),
    };
    final at = run.phase == RunPhase.paused ? run.pausedAt ?? now : now;
    return _share(at.difference(from), next.difference(from));
  }

  static double _share(Duration part, Duration whole) => whole <= Duration.zero
      ? 1
      : (part.inMicroseconds / whole.inMicroseconds).clamp(0, 1).toDouble();
}

class _DialCenter extends StatelessWidget {
  const _DialCenter({required this.run, required this.now});

  static const _countTracking = -2.0;

  final RunSnapshot run;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final shots = run.plan.shots;
    final (caption, countdown) = switch (run.phase) {
      RunPhase.starting => (
        'Starts in',
        IntervalometerText.countdown(run.startsAt.difference(now)),
      ),
      RunPhase.exposing => (
        run.plan.control == ExposureControl.video ? 'Recording' : 'Exposing',
        IntervalometerText.countdown(
          (run.exposureEndsAt ?? now).difference(now),
        ),
      ),
      RunPhase.waiting => (
        'Next shot in',
        IntervalometerText.countdown((run.nextShotAt ?? now).difference(now)),
      ),
      RunPhase.paused => ('Paused', ''),
      RunPhase.finished => ('Done', ''),
      RunPhase.stopped => ('Stopped', ''),
    };
    return Semantics(
      liveRegion: true,
      label: '${IntervalometerText.progress(run)} shots. $caption $countdown',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${run.done}',
            style: theme.textTheme.displayLarge?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: _countTracking,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            shots == null ? 'shots' : 'of $shots',
            style: theme.textTheme.titleMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.medium),
          Text(
            caption,
            style: theme.textTheme.labelLarge?.copyWith(
              color: run.phase == RunPhase.exposing
                  ? colors.tertiary
                  : colors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (countdown.isNotEmpty)
            Text(
              countdown,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.run, required this.now});

  final RunSnapshot run;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final started = run.startsAt;
    final elapsed = now.isAfter(started) && run.active
        ? now.difference(started)
        : null;
    final ends = run.endsAt(now);
    return Row(
      children: [
        _Stat(label: 'Taken', value: '${run.taken}'),
        _Stat(label: 'Missed', value: '${run.missed}', warn: run.missed > 0),
        _Stat(
          label: 'Running',
          value: elapsed == null ? '—' : IntervalometerText.countdown(elapsed),
        ),
        _Stat(
          label: 'Ends',
          value: ends == null || run.phase == RunPhase.paused
              ? '—'
              : IntervalometerText.timeOfDay(ends),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = warn ? theme.colorScheme.error : null;
    return Expanded(
      child: Card.filled(
        margin: const EdgeInsets.symmetric(horizontal: Spacing.extraSmall),
        child: Semantics(
          label: '$label: $value',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.medium),
            child: Column(
              children: [
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlanLine extends StatelessWidget {
  const _PlanLine({required this.plan});

  final IntervalPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rampTo = plan.rampTo;
    final length = switch (plan.control) {
      ExposureControl.camera => 'Camera exposure',
      ExposureControl.bulb when plan.ramps && rampTo != null =>
        'BULB ${IntervalometerText.duration(plan.exposure)} → '
            '${IntervalometerText.duration(rampTo)}',
      ExposureControl.bulb =>
        'BULB ${IntervalometerText.duration(plan.exposure)}',
      ExposureControl.video =>
        '${IntervalometerText.duration(plan.exposure)} clips',
    };
    return Text(
      '$length · every ${IntervalometerText.duration(plan.interval)} · '
      '${IntervalometerText.shots(plan.shots)}',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.quiet = false});

  final IconData icon;
  final String text;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = quiet
        ? colors.surfaceContainerHigh
        : colors.tertiaryContainer;
    final foreground = quiet ? colors.onSurface : colors.onTertiaryContainer;
    return Card.filled(
      color: background,
      margin: const EdgeInsets.only(bottom: Spacing.small),
      child: ListTile(
        leading: Icon(icon, color: foreground),
        title: Text(text, style: TextStyle(color: foreground)),
      ),
    );
  }
}
