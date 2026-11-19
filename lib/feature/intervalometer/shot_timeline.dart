import 'dart:math';

import 'package:flutter/material.dart';

import '../spacing.dart';
import 'interval_plan.dart';
import 'intervalometer_text.dart';

/// The first few shots drawn to scale, so exposure, gap and interval read
/// as one rhythm instead of three numbers.
class ShotTimeline extends StatelessWidget {
  const ShotTimeline({super.key, required this.plan});

  static const _height = 36.0;
  static const _shownShots = 3;

  final IntervalPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final shown = min(_shownShots, plan.shots ?? _shownShots);
    final caption = theme.textTheme.labelMedium?.copyWith(
      color: colors.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    return Semantics(
      label: _description,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: _height,
            child: CustomPaint(
              painter: _TimelinePainter(
                plan: plan,
                shots: shown,
                exposure: colors.tertiary,
                track: colors.surfaceContainerHighest,
                tick: colors.primary,
                problem: plan.problem == null ? null : colors.error,
              ),
            ),
          ),
          const SizedBox(height: Spacing.small),
          Row(
            children: [
              if (plan.timed) ...[
                _Legend(color: colors.tertiary),
                const SizedBox(width: Spacing.extraSmall),
                Text(
                  plan.control == ExposureControl.video ? 'Clip' : 'Exposure',
                  style: caption,
                ),
                const SizedBox(width: Spacing.medium),
              ] else ...[
                _Legend(color: colors.primary),
                const SizedBox(width: Spacing.extraSmall),
                Text('Shot', style: caption),
                const SizedBox(width: Spacing.medium),
              ],
              Expanded(
                child: Text(
                  'every ${IntervalometerText.duration(plan.interval)}',
                  textAlign: TextAlign.end,
                  style: caption,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String get _description {
    final every =
        'One shot every ${IntervalometerText.duration(plan.interval)}';
    if (!plan.timed) return every;
    return '$every, ${IntervalometerText.duration(plan.exposure)} long, '
        'then ${IntervalometerText.duration(plan.gap)} to save it';
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color});

  static const _size = 10.0;
  static const _radius = 3.0;

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: _size,
    height: _size,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(_radius),
    ),
  );
}

class _TimelinePainter extends CustomPainter {
  const _TimelinePainter({
    required this.plan,
    required this.shots,
    required this.exposure,
    required this.track,
    required this.tick,
    required this.problem,
  });

  static const _radius = Radius.circular(8);
  static const _tickWidth = 4.0;
  static const _trackInset = 10.0;

  final IntervalPlan plan;
  final int shots;
  final Color exposure;
  final Color track;
  final Color tick;
  final Color? problem;

  @override
  void paint(Canvas canvas, Size size) {
    final span = plan.interval * shots;
    if (span <= Duration.zero) return;
    double x(Duration at) =>
        size.width * at.inMicroseconds / span.inMicroseconds;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(0, _trackInset, size.width, size.height - _trackInset),
        _radius,
      ),
      Paint()..color = track,
    );
    for (var shot = 0; shot < shots; shot++) {
      final start = plan.interval * shot;
      if (!plan.timed) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x(start), 0, _tickWidth, size.height),
            _radius,
          ),
          Paint()..color = tick,
        );
        continue;
      }
      final length = plan.exposureAt(shot);
      final end = start + length;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            x(start),
            0,
            max(x(start) + _tickWidth, min(x(end), size.width)),
            size.height,
          ),
          _radius,
        ),
        Paint()..color = problem ?? exposure,
      );
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter oldDelegate) =>
      oldDelegate.plan != plan ||
      oldDelegate.shots != shots ||
      oldDelegate.exposure != exposure ||
      oldDelegate.track != track ||
      oldDelegate.tick != tick ||
      oldDelegate.problem != problem;
}
