@Tags(['brand-assets'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/brand/brand_theme.dart';
import 'package:shutterlink/brand/shutterlink_logo.dart';

const _outputDirectory = String.fromEnvironment(
  'FEATURE_GRAPHIC_DIR',
  defaultValue: 'fastlane/metadata/android/en-US/images',
);
const _width = 1024;
const _height = 500;
const _markDiagonal = 300.0;
const _margin = 96.0;
const _wordmarkSize = 96.0;
const _taglineSize = 34.0;
const _textGap = 56.0;
const _titleGap = 16.0;
const _taglineOpacity = 0.78;
const _glowOpacity = 0.35;
const _wordmark = 'shutterlink';
const _tagline = 'Photos from your camera,\nstraight to where they belong.';
const _fontWeights = ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold'];

void main() {
  test('feature graphic', () async {
    final loader = FontLoader(BrandTheme.fontFamily);
    for (final weight in _fontWeights) {
      loader.addFont(
        File('assets/fonts/${BrandTheme.fontFamily}-$weight.ttf')
            .readAsBytes()
            .then(ByteData.sublistView),
      );
    }
    await loader.load();

    final dark = BrandTheme.colorScheme(Brightness.dark);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const bounds = Rect.fromLTWH(0, 0, 1.0 * _width, 1.0 * _height);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ui.Gradient.linear(bounds.topLeft, bounds.bottomRight, [
          dark.surface,
          Color.lerp(dark.surface, dark.primary, 0.28)!,
        ]),
    );
    canvas.drawCircle(
      const Offset(_margin + _markDiagonal / 2, _height / 2),
      _markDiagonal,
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(_margin + _markDiagonal / 2, _height / 2),
          _markDiagonal,
          [
            dark.primary.withValues(alpha: _glowOpacity),
            dark.primary.withValues(alpha: 0),
          ],
        ),
    );

    final markSize = shutterlinkLogo.viewBox.size;
    final scale = _markDiagonal / markSize.bottomRight(Offset.zero).distance;
    final mark = markSize * scale;
    canvas.save();
    canvas.translate(_margin, (_height - mark.height) / 2);
    ShutterlinkLogoPainter(ShutterlinkLogo.themeColors(dark))
        .paint(canvas, mark);
    canvas.restore();

    final textLeft = _margin + mark.width + _textGap;
    final title = _paragraph(
      _wordmark,
      textLeft,
      TextStyle(
        fontFamily: BrandTheme.fontFamily,
        fontSize: _wordmarkSize,
        fontWeight: FontWeight.w800,
        color: dark.onSurface,
      ),
    );
    final tagline = _paragraph(
      _tagline,
      textLeft,
      TextStyle(
        fontFamily: BrandTheme.fontFamily,
        fontSize: _taglineSize,
        fontWeight: FontWeight.w500,
        height: 1.35,
        color: dark.onSurface.withValues(alpha: _taglineOpacity),
      ),
    );
    final top = (_height - title.height - _titleGap - tagline.height) / 2;
    canvas
      ..drawParagraph(title, Offset(textLeft, top))
      ..drawParagraph(
        tagline,
        Offset(textLeft, top + title.height + _titleGap),
      );

    final image = await recorder.endRecording().toImage(_width, _height);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File(p.join(_outputDirectory, 'featureGraphic.png'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png!.buffer.asUint8List());
  });
}

ui.Paragraph _paragraph(String text, double left, TextStyle style) {
  final builder =
      ui.ParagraphBuilder(
          ui.ParagraphStyle(
            textAlign: TextAlign.left,
            fontFamily: style.fontFamily,
            fontSize: style.fontSize,
            fontWeight: style.fontWeight,
            height: style.height,
          ),
        )
        ..pushStyle(style.getTextStyle())
        ..addText(text);
  return builder.build()
    ..layout(ui.ParagraphConstraints(width: _width - left - _margin));
}
