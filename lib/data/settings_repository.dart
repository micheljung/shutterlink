import 'package:shared_preferences/shared_preferences.dart';

enum DownloadFormat { jpeg, raw, both }

enum PreviewQuality { thumbnail, full }

class SettingsRepository {
  SettingsRepository(this._prefs);

  static const formatKey = 'download_format';
  static const hostOverrideKey = 'camera_host_override';
  static const previewQualityKey = 'preview_quality';
  static const defaultFormat = DownloadFormat.jpeg;
  static const defaultPreviewQuality = PreviewQuality.thumbnail;

  final SharedPreferences _prefs;

  DownloadFormat get format {
    final name = _prefs.getString(formatKey);
    return DownloadFormat.values.firstWhere(
      (format) => format.name == name,
      orElse: () => defaultFormat,
    );
  }

  Future<void> setFormat(DownloadFormat format) =>
      _prefs.setString(formatKey, format.name);

  PreviewQuality get previewQuality {
    final name = _prefs.getString(previewQualityKey);
    return PreviewQuality.values.firstWhere(
      (quality) => quality.name == name,
      orElse: () => defaultPreviewQuality,
    );
  }

  Future<void> setPreviewQuality(PreviewQuality quality) =>
      _prefs.setString(previewQualityKey, quality.name);

  String? get hostOverride => _prefs.getString(hostOverrideKey);

  Future<void> setHostOverride(String? host) {
    final trimmed = host?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return _prefs.remove(hostOverrideKey);
    }
    return _prefs.setString(hostOverrideKey, trimmed);
  }
}
