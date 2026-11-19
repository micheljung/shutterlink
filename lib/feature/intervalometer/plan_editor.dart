import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../spacing.dart';
import 'duration_picker_sheet.dart';
import 'interval_plan.dart';
import 'intervalometer_cubit.dart';
import 'intervalometer_text.dart';
import 'shot_timeline.dart';

/// Edits the plan: who times the exposure, how long and how often, how many
/// shots and when to begin.
class PlanEditor extends StatelessWidget {
  const PlanEditor({super.key});

  static const exposureLabel = 'Exposure';
  static const clipLabel = 'Clip length';
  static const intervalLabel = 'Interval';
  static const gapLabel = 'Gap';
  static const shotsLabel = 'Shots';
  static const clipsLabel = 'Clips';
  static const delayLabel = 'Start delay';
  static const rampLabel = 'Ramp exposure';

  static const _exposurePicks = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];
  static const _intervalPicks = [
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
  ];
  static const _gapPicks = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];
  static const _delayPicks = [
    Duration.zero,
    Duration(seconds: 2),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 30),
  ];
  static const _radius = 24.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final cubit = context.read<IntervalometerCubit>();
    final plan = context.select<IntervalometerCubit, IntervalPlan>(
      (cubit) => cubit.state.plan,
    );
    final video = plan.control == ExposureControl.video;
    final rampTo = plan.rampTo;

    Future<void> pick({
      required String title,
      required Duration initial,
      required List<Duration> picks,
      required IntervalPlan Function(Duration) apply,
      Duration min = Duration.zero,
      String? hint,
    }) async {
      final picked = await DurationPickerSheet.show(
        context,
        title: title,
        initial: initial,
        quickPicks: picks,
        min: min,
        max: IntervalPlan.maxDuration,
        hint: hint,
      );
      if (picked != null) cubit.setPlan(apply(picked));
    }

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
            SegmentedButton<ExposureControl>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: ExposureControl.camera,
                  icon: Icon(Icons.photo_camera_outlined),
                  label: Text('Photo'),
                  tooltip: 'The camera\'s own shutter speed',
                ),
                ButtonSegment(
                  value: ExposureControl.bulb,
                  icon: Icon(Icons.shutter_speed_outlined),
                  label: Text('Bulb'),
                  tooltip: 'Exposures of any length, timed by Shutterlink',
                ),
                ButtonSegment(
                  value: ExposureControl.video,
                  icon: Icon(Icons.videocam_outlined),
                  label: Text('Video'),
                  tooltip: 'A clip each interval',
                ),
              ],
              selected: {plan.control},
              onSelectionChanged: (selection) {
                HapticFeedback.selectionClick();
                cubit.setPlan(plan.withControl(selection.single));
              },
            ),
            const SizedBox(height: Spacing.small),
            Text(
              switch (plan.control) {
                ExposureControl.camera =>
                  'Uses the shutter speed set on the camera.',
                ExposureControl.bulb =>
                  'Set the camera to BULB. Exposures can be as long as you '
                      'like.',
                ExposureControl.video =>
                  'Starts and stops a recording each interval.',
              },
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Spacing.large),
            _TileGrid(
              tiles: [
                if (plan.timed)
                  _ValueTile(
                    label: video
                        ? clipLabel
                        : plan.ramps
                        ? 'First exposure'
                        : exposureLabel,
                    value: IntervalometerText.duration(plan.exposure),
                    icon: video ? Icons.videocam_outlined : Icons.shutter_speed,
                    onTap: () => pick(
                      title: video ? clipLabel : exposureLabel,
                      initial: plan.exposure,
                      picks: _exposurePicks,
                      min: IntervalPlan.minExposure,
                      apply: plan.withExposure,
                    ),
                  ),
                if (plan.timed)
                  _ValueTile(
                    label: gapLabel,
                    value: IntervalometerText.duration(plan.gap),
                    icon: Icons.more_horiz,
                    error: plan.problem == PlanProblem.intervalTooShort,
                    onTap: () => pick(
                      title: gapLabel,
                      hint:
                          'The pause after each ${video ? 'clip' : 'exposure'}'
                          ', while the camera saves it.',
                      initial: plan.gap.isNegative
                          ? IntervalPlan.minGap
                          : plan.gap,
                      picks: _gapPicks,
                      min: IntervalPlan.minGap,
                      apply: plan.withGap,
                    ),
                  ),
                _ValueTile(
                  label: intervalLabel,
                  value: IntervalometerText.duration(plan.interval),
                  icon: Icons.av_timer,
                  error: plan.problem == PlanProblem.intervalTooShort,
                  onTap: () => pick(
                    title: intervalLabel,
                    hint:
                        'From the start of one shot to the start of the '
                        'next.',
                    initial: plan.interval,
                    picks: _intervalPicks,
                    min: IntervalPlan.minInterval,
                    apply: (interval) => plan.copyWith(interval: interval),
                  ),
                ),
                _ValueTile(
                  label: video ? clipsLabel : shotsLabel,
                  value: plan.shots == null ? '∞' : '${plan.shots}',
                  icon: Icons.burst_mode_outlined,
                  error: plan.problem == PlanProblem.rampNeedsShotCount,
                  onTap: () async {
                    final shots = await ShotsSheet.show(context, plan);
                    if (shots == null) return;
                    cubit.setPlan(
                      shots.count == null
                          ? plan.copyWith(clearShots: true)
                          : plan.copyWith(shots: shots.count),
                    );
                  },
                ),
                _ValueTile(
                  label: delayLabel,
                  value: plan.startDelay == Duration.zero
                      ? 'None'
                      : IntervalometerText.duration(plan.startDelay),
                  icon: Icons.hourglass_top,
                  onTap: () => pick(
                    title: delayLabel,
                    hint:
                        'Time to step away, so you don\'t shake the '
                        'tripod.',
                    initial: plan.startDelay,
                    picks: _delayPicks,
                    apply: (delay) => plan.copyWith(startDelay: delay),
                  ),
                ),
              ],
            ),
            if (plan.bulb) ...[
              const SizedBox(height: Spacing.small),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(rampLabel),
                subtitle: Text(
                  rampTo == null
                      ? 'For sunsets: lengthen the exposure smoothly over '
                            'the run.'
                      : 'From ${IntervalometerText.duration(plan.exposure)} '
                            'to ${IntervalometerText.duration(rampTo)}, even '
                            'in stops',
                ),
                value: rampTo != null,
                onChanged: (on) => cubit.setPlan(
                  plan.withRampTo(on ? plan.exposure * 2 : null),
                ),
              ),
              if (rampTo != null)
                _TileGrid(
                  tiles: [
                    _ValueTile(
                      label: 'Last exposure',
                      value: IntervalometerText.duration(rampTo),
                      icon: Icons.trending_up,
                      onTap: () => pick(
                        title: 'Last exposure',
                        initial: rampTo,
                        picks: _exposurePicks,
                        min: IntervalPlan.minExposure,
                        apply: plan.withRampTo,
                      ),
                    ),
                  ],
                ),
            ],
            const SizedBox(height: Spacing.large),
            ShotTimeline(plan: plan),
          ],
        ),
      ),
    );
  }
}

class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.tiles});

  static const _columns = 2;

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width =
          (constraints.maxWidth - Spacing.small * (_columns - 1)) / _columns;
      return Wrap(
        spacing: Spacing.small,
        runSpacing: Spacing.small,
        children: [
          for (final tile in tiles) SizedBox(width: width, child: tile),
        ],
      );
    },
  );
}

class _ValueTile extends StatelessWidget {
  const _ValueTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    this.error = false,
  });

  static const _radius = 16.0;
  static const _iconSize = 18.0;

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onTap;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = error ? colors.error : colors.primary;
    return Material(
      color: error ? colors.errorContainer : colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(_radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          button: true,
          label: '$label: $value',
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.medium),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: _iconSize, color: accent),
                    const SizedBox(width: Spacing.extraSmall),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: error
                              ? colors.onErrorContainer
                              : colors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Spacing.extraSmall),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: error ? colors.onErrorContainer : colors.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// How many shots: a number, enough for a stretch of time, or until stopped.
class ShotsSheet extends StatefulWidget {
  const ShotsSheet({super.key, required this.plan});

  static const untilLabel = 'Until I stop';
  static const doneLabel = 'Done';
  static const _countPicks = [10, 50, 100, 300, 600, 1000];
  static const _durationPicks = [
    Duration(minutes: 10),
    Duration(minutes: 30),
    Duration(hours: 1),
    Duration(hours: 2),
    Duration(hours: 4),
  ];

  final IntervalPlan plan;

  /// The picked count, null inside meaning until stopped; null when
  /// dismissed.
  static Future<({int? count})?> show(
    BuildContext context,
    IntervalPlan plan,
  ) => showModalBottomSheet<({int? count})>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ShotsSheet(plan: plan),
  );

  @override
  State<ShotsSheet> createState() => _ShotsSheetState();
}

class _ShotsSheetState extends State<ShotsSheet> {
  late final _controller = TextEditingController(
    text: '${widget.plan.shots ?? ''}',
  );
  late bool _until = widget.plan.shots == null;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? get _count {
    final count = int.tryParse(_controller.text);
    if (count == null || count < 1 || count > IntervalPlan.maxShots) {
      return null;
    }
    return count;
  }

  void _set(int count) => setState(() {
    _until = false;
    _controller.text = '$count';
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final interval = widget.plan.interval;
    final count = _count;
    final valid = _until || count != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Spacing.extraLarge,
        0,
        Spacing.extraLarge,
        Spacing.extraLarge + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              PlanEditor.shotsLabel,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: Spacing.large),
            TextField(
              controller: _controller,
              enabled: !_until,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Number of shots',
                border: const OutlineInputBorder(),
                helperText: count == null || _until
                    ? null
                    : 'Takes ${IntervalometerText.duration(interval * (count - 1))}',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Spacing.medium),
            Wrap(
              spacing: Spacing.small,
              runSpacing: Spacing.small,
              children: [
                for (final pick in ShotsSheet._countPicks)
                  ChoiceChip(
                    label: Text('$pick'),
                    selected: !_until && count == pick,
                    onSelected: (_) => _set(pick),
                  ),
              ],
            ),
            const SizedBox(height: Spacing.large),
            Text('Or enough for', style: theme.textTheme.titleSmall),
            const SizedBox(height: Spacing.small),
            Wrap(
              spacing: Spacing.small,
              runSpacing: Spacing.small,
              children: [
                for (final duration in ShotsSheet._durationPicks)
                  ActionChip(
                    avatar: const Icon(Icons.schedule),
                    label: Text(IntervalometerText.duration(duration)),
                    onPressed: () =>
                        _set(IntervalPlan.shotsFor(duration, interval)),
                  ),
              ],
            ),
            const SizedBox(height: Spacing.small),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(ShotsSheet.untilLabel),
              value: _until,
              onChanged: (until) => setState(() => _until = until),
            ),
            const SizedBox(height: Spacing.medium),
            FilledButton(
              onPressed: valid
                  ? () =>
                        Navigator.of(context)
                            .pop((count: _until ? null : count))
                  : null,
              child: const Text(ShotsSheet.doneLabel),
            ),
          ],
        ),
      ),
    );
  }
}
