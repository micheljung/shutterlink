import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract final class BrandColors {
  static const seed = Color(0xFF0097A7);
  static const accent = Color(0xFFFF7A45);
  static const darkSurface = Color(0xFF0B1214);
  static const _onlineOnDark = Color(0xFF3DD68C);
  static const _onlineOnLight = Color(0xFF1A8F52);

  /// The camera's own screen, dark in either theme.
  static const cameraScreen = Color(0xFF14181B);
  static const cameraScreenBorder = Color(0xFF2B3237);
  static const cameraScreenText = Color(0xFFE6ECEF);
  static const cameraScreenDim = Color(0xFF9AA6AD);
  static const cameraScreenAccent = Color(0xFF5CD7E4);

  static Color online(Brightness brightness) =>
      brightness == Brightness.dark ? _onlineOnDark : _onlineOnLight;
}

abstract final class BrandTheme {
  static const fontFamily = 'Manrope';
  static const fontLicenseAsset = 'assets/fonts/OFL.txt';
  static const _variant = DynamicSchemeVariant.content;
  static const _buttonMinimumSize = Size(64, 56);
  static const _buttonLabelSpacing = 0.2;
  static const _textButtonFontSize = 15.0;
  static const _bodyLineHeight = 1.4;

  static void registerFontLicense() => LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      fontFamily,
    ], await rootBundle.loadString(fontLicenseAsset));
  });

  static ThemeData light() => _theme(Brightness.light);

  static ThemeData dark() => _theme(Brightness.dark);

  static ColorScheme colorScheme(Brightness brightness) {
    final accent = ColorScheme.fromSeed(
      seedColor: BrandColors.accent,
      brightness: brightness,
      dynamicSchemeVariant: _variant,
    );
    final scheme = ColorScheme.fromSeed(
      seedColor: BrandColors.seed,
      brightness: brightness,
      dynamicSchemeVariant: _variant,
    );
    return scheme.copyWith(
      surface: brightness == Brightness.dark ? BrandColors.darkSurface : null,
      tertiary: accent.primary,
      onTertiary: accent.onPrimary,
      tertiaryContainer: accent.primaryContainer,
      onTertiaryContainer: accent.onPrimaryContainer,
    );
  }

  static ThemeData _theme(Brightness brightness) {
    final base = ThemeData(
      colorScheme: colorScheme(brightness),
      fontFamily: fontFamily,
    );
    final label = base.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: _buttonLabelSpacing,
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        bodyLarge: base.textTheme.bodyLarge?.copyWith(height: _bodyLineHeight),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: _buttonMinimumSize,
          textStyle: label,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: _buttonMinimumSize,
          textStyle: label,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: base.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: _textButtonFontSize,
          ),
        ),
      ),
    );
  }
}
