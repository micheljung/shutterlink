import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../brand/brand_theme.dart';

/// A USB plug with waves rippling out on both sides: the camera is connected
/// over the cable. Holds still when the system asks for reduced motion.
class UsbWavesIndicator extends StatefulWidget {
  const UsbWavesIndicator({super.key});

  /// One wave travels from the plug to the edge in this time.
  static const period = Duration(seconds: 2);

  @override
  State<UsbWavesIndicator> createState() => UsbWavesIndicatorState();
}

@visibleForTesting
class UsbWavesIndicatorState extends State<UsbWavesIndicator>
    with SingleTickerProviderStateMixin {
  /// Where the waves rest when motion is reduced.
  static const _stillProgress = 0.5;
  static const _iconSize = 18.0;
  static const _size = Size(56, 28);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: UsbWavesIndicator.period,
  );

  @visibleForTesting
  AnimationController get controller => _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller
        ..stop()
        ..value = _stillProgress;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = BrandColors.online(Theme.of(context).brightness);
    return RepaintBoundary(
      child: SizedBox.fromSize(
        size: _size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => CustomPaint(
            painter: UsbWavesPainter(color: color, progress: _controller.value),
            child: child,
          ),
          child: Center(
            child: Icon(Icons.usb, size: _iconSize, color: color),
          ),
        ),
      ),
    );
  }
}

/// Paints three arcs on each side of the plug. Each grows from the plug and
/// fades as it goes, a third of a period after the one before.
@visibleForTesting
class UsbWavesPainter extends CustomPainter {
  const UsbWavesPainter({required this.color, required this.progress});

  final Color color;

  /// Where the cycle is, from 0 to 1.
  final double progress;

  static const _waves = 3;
  static const _sweep = math.pi / 3;
  static const _strokeWidth = 1.6;
  static const _fadeIn = 5.0;

  /// The gap kept clear around the plug icon.
  static const _innerRadius = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final outerRadius = size.width / 2 - _strokeWidth;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;
    for (var wave = 0; wave < _waves; wave++) {
      final phase = (progress + wave / _waves) % 1;
      final radius = _innerRadius + (outerRadius - _innerRadius) * phase;
      // Fades in leaving the plug and out reaching the edge.
      final alpha = math.min(1, phase * _fadeIn) * (1 - phase);
      paint.color = color.withValues(alpha: alpha);
      final bounds = Rect.fromCircle(center: centre, radius: radius);
      canvas
        ..drawArc(bounds, -_sweep / 2, _sweep, false, paint)
        ..drawArc(bounds, math.pi - _sweep / 2, _sweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(UsbWavesPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
