import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_parsing/path_parsing.dart';

/// Vector geometry as SVG path data, so the in-app [Path] and the exported
/// SVG come from the same numbers.
class LogoGeometry {
  const LogoGeometry({required this.viewBox, required this.paths});

  final Rect viewBox;
  final List<String> paths;

  /// The geometry in [viewBox] units.
  Path toPath() {
    final builder = _PathBuilder();
    for (final data in paths) {
      writeSvgPathDataToPath(data, builder);
    }
    return builder.path;
  }

  /// Where [viewBox] lands when scaled uniformly into the centre of [size].
  Rect fit(Size size) {
    final scale = size.shortestSide / viewBox.longestSide;
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: viewBox.width * scale,
      height: viewBox.height * scale,
    );
  }

  Path toSizedPath(Size size) {
    final target = fit(size);
    final scale = target.width / viewBox.width;
    final matrix = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(
        target.left - viewBox.left * scale,
        target.top - viewBox.top * scale,
        0,
      );
    return toPath().transform(matrix.storage);
  }

  String toSvg(List<Color> colors) {
    final box = [
      viewBox.left,
      viewBox.top,
      viewBox.width,
      viewBox.height,
    ].map(_number).join(' ');
    final gradient = colors.length > 1;
    final fill = gradient ? 'url(#$_gradientId)' : _hex(colors.single);
    return [
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="$box">',
      if (gradient) ...[
        '  <defs>',
        '    <linearGradient id="$_gradientId" gradientUnits="userSpaceOnUse" '
            'x1="${_number(viewBox.left)}" y1="${_number(viewBox.top)}" '
            'x2="${_number(viewBox.right)}" y2="${_number(viewBox.bottom)}">',
        for (final (index, color) in colors.indexed)
          '      <stop offset="${_number(index / (colors.length - 1))}" '
              'stop-color="${_hex(color)}"/>',
        '    </linearGradient>',
        '  </defs>',
      ],
      for (final data in paths) '  <path fill="$fill" d="$data"/>',
      '</svg>',
      '',
    ].join('\n');
  }

  static const _gradientId = 'shutterlink-gradient';

  static String _number(double value) =>
      value == value.roundToDouble() ? '${value.round()}' : '$value';

  static String _hex(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
}

/// A lens ring interlocked with a chain link: the ring passes over the link
/// at the top crossing and under it at the bottom one. Arcs stay clear of
/// exactly 180 degrees, which path_parsing may bend to either side.
const shutterlinkLogo = LogoGeometry(
  viewBox: Rect.fromLTWH(0, 0, 37.942, 33.241),
  paths: [
    'M28.989 18.164A14.5 14.5 0 1 1 26.49 10.586L23.461 12.786'
        'A0.45 0.45 0 0 1 22.833 12.686L22.671 12.804'
        'A10.1 10.1 0 1 0 24.468 20.371A8.05 8.05 0 0 0 27.929 18.934'
        'Z',
    'M17.142 10.872A8.3 8.3 0 0 1 21.215 13.862L21.377 13.744'
        'A2.25 2.25 0 0 0 24.519 14.242L33.014 8.07'
        'A2.25 2.25 0 0 0 33.512 4.927A2.25 2.25 0 0 0 30.369 4.43'
        'L26.238 7.431A16.3 16.3 0 0 0 23.005 4.835L28.018 1.194'
        'A6.25 6.25 0 0 1 36.748 2.576A6.25 6.25 0 0 1 35.365 11.306'
        'L26.871 17.478A6.25 6.25 0 0 1 17.142 10.872Z',
    'M16.765 17.095A2.8 2.8 0 0 1 16.146 21.006'
        'A2.8 2.8 0 1 1 16.765 17.095Z',
  ],
);

class ShutterlinkLogo extends StatelessWidget {
  const ShutterlinkLogo({super.key, required this.size});

  static const _gradientFade = 0.3;

  final double size;

  static List<Color> themeColors(ColorScheme scheme) => [
    scheme.primary,
    Color.lerp(scheme.primary, scheme.onSurface, _gradientFade)!,
  ];

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: ShutterlinkLogoPainter(
        themeColors(Theme.of(context).colorScheme),
      ),
    ),
  );
}

class ShutterlinkLogoPainter extends CustomPainter {
  const ShutterlinkLogoPainter(this.colors);

  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = colors.first;
    if (colors.length > 1) {
      paint.shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ).createShader(shutterlinkLogo.fit(size));
    }
    canvas.drawPath(shutterlinkLogo.toSizedPath(size), paint);
  }

  @override
  bool shouldRepaint(ShutterlinkLogoPainter oldDelegate) =>
      !listEquals(oldDelegate.colors, colors);
}

class _PathBuilder extends PathProxy {
  final path = Path();

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);

  @override
  void lineTo(double x, double y) => path.lineTo(x, y);

  @override
  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) => path.cubicTo(x1, y1, x2, y2, x3, y3);

  @override
  void close() => path.close();
}
