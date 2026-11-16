import 'dart:math';

import 'package:flutter/material.dart';

class LensRingsPainter extends CustomPainter {
  const LensRingsPainter(this.color);

  final Color color;

  static const _radii = [96.0, 136.0, 184.0, 240.0, 304.0];
  static const _ringAlpha = 0.28;
  static const _ringAlphaStep = 0.05;
  static const _strokeWidth = 1.2;
  static const _tickRadius = 184.0;
  static const _tickCount = 72;
  static const _majorTickEvery = 6;
  static const _majorTickLength = 12.0;
  static const _minorTickLength = 5.0;
  static const _tickAlpha = 0.3;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (final (index, radius) in _radii.indexed) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _strokeWidth
          ..color = color.withValues(
            alpha: _ringAlpha - index * _ringAlphaStep,
          ),
      );
    }
    final tick = Paint()
      ..color = color.withValues(alpha: _tickAlpha)
      ..strokeWidth = _strokeWidth;
    for (var index = 0; index < _tickCount; index++) {
      final angle = index * 2 * pi / _tickCount;
      final length = index % _majorTickEvery == 0
          ? _majorTickLength
          : _minorTickLength;
      final direction = Offset(cos(angle), sin(angle));
      canvas.drawLine(
        center + direction * _tickRadius,
        center + direction * (_tickRadius - length),
        tick,
      );
    }
  }

  @override
  bool shouldRepaint(LensRingsPainter oldDelegate) =>
      oldDelegate.color != color;
}

class LensHero extends StatelessWidget {
  const LensHero({super.key, required this.logo});

  final Widget logo;

  static const _lightFade = 0.7;
  static const _darkFade = 0.55;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fade = theme.brightness == Brightness.dark ? _darkFade : _lightFade;
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                colors.primaryContainer.withValues(alpha: fade),
                colors.surface,
              ],
            ),
          ),
        ),
        ClipRect(child: CustomPaint(painter: LensRingsPainter(colors.primary))),
        Center(child: logo),
      ],
    );
  }
}
