@Tags(['brand-assets'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/brand/brand_theme.dart';
import 'package:shutterlink/brand/shutterlink_logo.dart';

const _outputDirectory = 'assets/brand';
const _iconSize = 1024.0;
const _iconMarkDiagonal = 640.0;

// Adaptive icons are 108dp; launchers may mask all but a 66dp circle.
const _adaptiveSafeZone = _iconSize * 66 / 108;
const _adaptiveMarkDiagonal = _adaptiveSafeZone * 0.9;

// Android 12 draws a 960px (xxxhdpi) icon with a background colour and
// keeps only a 640px circle of it.
const _android12SplashSize = 960.0;
const _android12Circle = 640.0;
const _splashMarkDiagonal = _android12Circle * 0.85;
// Same mark size as Android 12, so the splash looks alike on every version.
const _splashSize = 768.0;

final _markSize = shutterlinkLogo.viewBox.size;
final _markViewBoxDiagonal = _markSize.bottomRight(Offset.zero).distance;

void main() {
  final light = BrandTheme.colorScheme(Brightness.light);
  final dark = BrandTheme.colorScheme(Brightness.dark);
  final lightMark = ShutterlinkLogo.themeColors(light);
  final darkMark = ShutterlinkLogo.themeColors(dark);

  test('app icon', () async {
    await _render(
      'icon.png',
      size: _iconSize,
      diagonal: _iconMarkDiagonal,
      colors: darkMark,
      background: dark.surface,
    );
    await _render(
      'icon_foreground.png',
      size: _iconSize,
      diagonal: _adaptiveMarkDiagonal,
      colors: darkMark,
    );
    await _render(
      'icon_monochrome.png',
      size: _iconSize,
      diagonal: _adaptiveMarkDiagonal,
      colors: const [Colors.white],
    );
  });

  test('splash', () async {
    await _render(
      'splash.png',
      size: _splashSize,
      diagonal: _splashMarkDiagonal,
      colors: lightMark,
    );
    await _render(
      'splash_dark.png',
      size: _splashSize,
      diagonal: _splashMarkDiagonal,
      colors: darkMark,
    );
    await _render(
      'splash_android12.png',
      size: _android12SplashSize,
      diagonal: _splashMarkDiagonal,
      colors: lightMark,
    );
    await _render(
      'splash_android12_dark.png',
      size: _android12SplashSize,
      diagonal: _splashMarkDiagonal,
      colors: darkMark,
    );
  });

  test('logo svg', () async {
    final file = File(p.join(_outputDirectory, 'logo.svg'));
    await file.parent.create(recursive: true);
    await file.writeAsString(shutterlinkLogo.toSvg(const [BrandColors.seed]));
  });
}

/// Draws the mark centred on a [size] square, its bounding box [diagonal]
/// pixels across corner to corner.
Future<void> _render(
  String name, {
  required double size,
  required double diagonal,
  required List<Color> colors,
  Color? background,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  if (background != null) {
    canvas.drawColor(background, BlendMode.src);
  }
  final scale = diagonal / _markViewBoxDiagonal;
  final mark = _markSize * scale;
  canvas.translate((size - mark.width) / 2, (size - mark.height) / 2);
  ShutterlinkLogoPainter(colors).paint(canvas, mark);
  final image = await recorder.endRecording().toImage(
    size.round(),
    size.round(),
  );
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final file = File(p.join(_outputDirectory, name));
  await file.parent.create(recursive: true);
  await file.writeAsBytes(png!.buffer.asUint8List());
}
