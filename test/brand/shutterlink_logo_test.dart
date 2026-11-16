import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/brand/brand_theme.dart';
import 'package:shutterlink/brand/shutterlink_logo.dart';

const _boundsTolerance = 0.01;
const _sampleStep = 0.01;

Rect _tightBounds(Path path) {
  final points = [
    for (final metric in path.computeMetrics())
      for (var d = 0.0; d <= metric.length; d += _sampleStep)
        metric.getTangentForOffset(d)!.position,
  ];
  return Rect.fromLTRB(
    points.map((p) => p.dx).reduce((a, b) => a < b ? a : b),
    points.map((p) => p.dy).reduce((a, b) => a < b ? a : b),
    points.map((p) => p.dx).reduce((a, b) => a > b ? a : b),
    points.map((p) => p.dy).reduce((a, b) => a > b ? a : b),
  );
}

void main() {
  group('LogoGeometry', () {
    test('parses moves, lines and closes', () {
      const geometry = LogoGeometry(
        viewBox: Rect.fromLTWH(0, 0, 10, 10),
        paths: ['M0 0L10 0L10 10Z'],
      );
      final path = geometry.toPath();
      expect(path.getBounds(), const Rect.fromLTWH(0, 0, 10, 10));
      expect(path.contains(const Offset(8, 2)), isTrue);
      expect(path.contains(const Offset(2, 8)), isFalse);
    });

    test('parses arcs on the side their sweep flag names', () {
      const geometry = LogoGeometry(
        viewBox: Rect.fromLTWH(0, 0, 10, 10),
        paths: ['M0 10A10 10 0 0 1 10 0L10 10Z'],
      );
      final path = geometry.toPath();
      expect(path.contains(const Offset(5, 5)), isTrue);
      expect(path.contains(const Offset(1, 1)), isFalse);
    });

    test('the logo uses only M, L, C, Q, A and Z commands', () {
      for (final data in shutterlinkLogo.paths) {
        expect(data, matches(RegExp(r'^M[MLCQAZ0-9 .\-]*Z$')));
      }
    });

    test('the logo fills its viewBox', () {
      final bounds = _tightBounds(shutterlinkLogo.toPath());
      final box = shutterlinkLogo.viewBox;
      expect(bounds.left, closeTo(box.left, _boundsTolerance));
      expect(bounds.top, closeTo(box.top, _boundsTolerance));
      expect(bounds.right, closeTo(box.right, _boundsTolerance));
      expect(bounds.bottom, closeTo(box.bottom, _boundsTolerance));
    });

    test('scales into the centre of any size', () {
      for (final size in const [Size(24, 24), Size(200, 100), Size(50, 300)]) {
        final bounds = _tightBounds(shutterlinkLogo.toSizedPath(size));
        final area = Offset.zero & size;
        expect(area.inflate(_boundsTolerance).contains(bounds.topLeft), isTrue);
        expect(
          area.inflate(_boundsTolerance).contains(bounds.bottomRight),
          isTrue,
        );
        expect(bounds.center.dx, closeTo(area.center.dx, _boundsTolerance));
        expect(bounds.center.dy, closeTo(area.center.dy, _boundsTolerance));
      }
    });

    test('writes the same path data into the SVG', () {
      final svg = shutterlinkLogo.toSvg(const [BrandColors.seed]);
      expect(svg, contains('viewBox="0 0 37.942 33.241"'));
      for (final data in shutterlinkLogo.paths) {
        expect(svg, contains('<path fill="#0097a7" d="$data"/>'));
      }
    });

    test('writes a gradient for more than one colour', () {
      final svg = shutterlinkLogo.toSvg(const [Colors.black, Colors.white]);
      expect(svg, contains('<stop offset="0" stop-color="#000000"/>'));
      expect(svg, contains('<stop offset="1" stop-color="#ffffff"/>'));
      expect(svg, contains('fill="url(#'));
    });
  });

  testWidgets('ShutterlinkLogo paints at several sizes', (tester) async {
    for (final size in const [16.0, 48.0, 136.0, 512.0]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: BrandTheme.dark(),
          home: Center(child: ShutterlinkLogo(size: size)),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(ShutterlinkLogo)), Size.square(size));
    }
  });
}
