import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/brand/brand_theme.dart';

const _textContrast = 4.5;
// WCAG 1.4.11: progress bars and other non-text parts.
const _nonTextContrast = 3.0;

double _contrast(Color a, Color b) {
  final luminances = [a.computeLuminance(), b.computeLuminance()]..sort();
  const flare = 0.05;
  return (luminances.last + flare) / (luminances.first + flare);
}

String _hex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

void main() {
  for (final brightness in Brightness.values) {
    group('$brightness', () {
      final scheme = BrandTheme.colorScheme(brightness);
      final textPairs = {
        'onSurface/surface': (scheme.onSurface, scheme.surface),
        'onSurfaceVariant/surface': (scheme.onSurfaceVariant, scheme.surface),
        'onSurface/surfaceContainerLow': (
          scheme.onSurface,
          scheme.surfaceContainerLow,
        ),
        // Mode card descriptions.
        'onSurfaceVariant/surfaceContainerLow': (
          scheme.onSurfaceVariant,
          scheme.surfaceContainerLow,
        ),
        'onSurfaceVariant/surfaceContainerHighest': (
          scheme.onSurfaceVariant,
          scheme.surfaceContainerHighest,
        ),
        'primary/surface': (scheme.primary, scheme.surface),
        'onPrimary/primary': (scheme.onPrimary, scheme.primary),
        'onPrimaryContainer/primaryContainer': (
          scheme.onPrimaryContainer,
          scheme.primaryContainer,
        ),
        'onSecondaryContainer/secondaryContainer': (
          scheme.onSecondaryContainer,
          scheme.secondaryContainer,
        ),
        'tertiary/surface': (scheme.tertiary, scheme.surface),
        'onTertiary/tertiary': (scheme.onTertiary, scheme.tertiary),
        'onTertiaryContainer/tertiaryContainer': (
          scheme.onTertiaryContainer,
          scheme.tertiaryContainer,
        ),
        'onErrorContainer/errorContainer': (
          scheme.onErrorContainer,
          scheme.errorContainer,
        ),
        // Preview: hint text and placeholder icons on its black background.
        'white/black': (Colors.white, Colors.black),
        // Session QR sheet: black modules on a white quiet zone.
        'black/white': (Colors.black, Colors.white),
      };
      for (final MapEntry(key: name, value: (foreground, background))
          in textPairs.entries) {
        test('$name reaches $_textContrast:1', () {
          expect(
            _contrast(foreground, background),
            greaterThanOrEqualTo(_textContrast),
          );
        });
      }

      test('the online dot stands out on the surface', () {
        expect(
          _contrast(BrandColors.online(brightness), scheme.surface),
          greaterThanOrEqualTo(_nonTextContrast),
        );
      });

      test('the preview progress bar stands out on black', () {
        expect(
          _contrast(scheme.primary, Colors.black),
          greaterThanOrEqualTo(_nonTextContrast),
        );
      });
    });
  }

  group('the camera screen illustration', () {
    final textPairs = {
      'text': BrandColors.cameraScreenText,
      'dim': BrandColors.cameraScreenDim,
      'accent': BrandColors.cameraScreenAccent,
    };
    for (final MapEntry(key: name, value: foreground) in textPairs.entries) {
      test('$name reaches $_textContrast:1', () {
        expect(
          _contrast(foreground, BrandColors.cameraScreen),
          greaterThanOrEqualTo(_textContrast),
        );
      });
    }
  });

  test('dark surface is the brand surface', () {
    expect(
      BrandTheme.colorScheme(Brightness.dark).surface,
      BrandColors.darkSurface,
    );
  });

  test('themes use the bundled font', () {
    for (final theme in [BrandTheme.light(), BrandTheme.dark()]) {
      expect(theme.textTheme.bodyLarge?.fontFamily, BrandTheme.fontFamily);
    }
  });

  test('icon and splash configs use the theme surfaces', () {
    final light = _hex(BrandTheme.colorScheme(Brightness.light).surface);
    final dark = _hex(BrandColors.darkSurface);
    final splash = File('flutter_native_splash.yaml').readAsStringSync();
    expect(splash, contains('color: "$light"'));
    expect(splash, contains('icon_background_color: "$light"'));
    expect(splash, contains('color_dark: "$dark"'));
    expect(splash, contains('icon_background_color_dark: "$dark"'));
    expect(
      File('flutter_launcher_icons.yaml').readAsStringSync(),
      contains('adaptive_icon_background: "$dark"'),
    );
  });

  test('registers the font licence', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    BrandTheme.registerFontLicense();
    final entries = await LicenseRegistry.licenses.toList();
    expect(
      entries.where(
        (entry) =>
            entry.packages.contains(BrandTheme.fontFamily) &&
            entry.paragraphs.any(
              (paragraph) => paragraph.text.contains('SIL Open Font License'),
            ),
      ),
      isNotEmpty,
    );
  });
}
