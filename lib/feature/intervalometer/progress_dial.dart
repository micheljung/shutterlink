import 'dart:math';

import 'package:flutter/material.dart';

/// A lens-ring dial: the outer ticks fill with the run's progress, the inner
/// arc with the time to the next shot or through the open exposure.
class ProgressDial extends StatelessWidget {
  const ProgressDial({
    super.key,
    required this.progress,
    required this.cycle,
    required this.exposing,
    required this.child,
  });

  static const size = 280.0;

  /// The share of shots done; null when shooting until stopped.
  final double? progress;

  /// How far the current wait or exposure is, from 0 to 1.
  final double cycle;
  final bool exposing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _DialPainter(
          progress: progress,
          cycle: cycle,
          ticks: colors.outlineVariant,
          done: colors.primary,
          arc: exposing ? colors.tertiary : colors.secondary,
          arcTrack: colors.surfaceContainerHighest,
        ),
        child: Center(child: child),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  const _DialPainter({
    required this.progress,
    required this.cycle,
    required this.ticks,
    required this.done,
    required this.arc,
    required this.arcTrack,
  });

  static const _tickCount = 72;
  static const _majorTickEvery = 6;
  static const _majorTickLength = 16.0;
  static const _minorTickLength = 9.0;
  static const _tickWidth = 3.0;
  static const _arcInset = 28.0;
  static const _arcWidth = 10.0;
  static const _top = -pi / 2;

  final double? progress;
  final double cycle;
  final Color ticks;
  final Color done;
  final Color arc;
  final Color arcTrack;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final filled = ((progress ?? 0) * _tickCount).floor();
    for (var index = 0; index < _tickCount; index++) {
      final angle = _top + index * 2 * pi / _tickCount;
      final length = index % _majorTickEvery == 0
          ? _majorTickLength
          : _minorTickLength;
      final direction = Offset(cos(angle), sin(angle));
      canvas.drawLine(
        center + direction * radius,
        center + direction * (radius - length),
        Paint()
          ..color = index < filled ? done : ticks
          ..strokeWidth = _tickWidth
          ..strokeCap = StrokeCap.round,
      );
    }
    final arcRect = Rect.fromCircle(center: center, radius: radius - _arcInset);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _arcWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(arcRect, 0, 2 * pi, false, stroke..color = arcTrack);
    final sweep = cycle.clamp(0, 1) * 2 * pi;
    if (sweep > 0) {
      canvas.drawArc(arcRect, _top, sweep, false, stroke..color = arc);
    }
  }

  @override
  bool shouldRepaint(_DialPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.cycle != cycle ||
      oldDelegate.ticks != ticks ||
      oldDelegate.done != done ||
      oldDelegate.arc != arc ||
      oldDelegate.arcTrack != arcTrack;
}
