import 'package:shared_preferences/shared_preferences.dart';

enum DownloadFormat { jpeg, raw, both }

class SettingsRepository {
  SettingsRepository(this._prefs);

  static const formatKey = 'download_format';
  static const hostOverrideKey = 'camera_host_override';
  static const sessionsServerUrlKey = 'sessions_server_url';
  static const onboardingSeenKey = 'onboarding_seen';
  static const defaultFormat = DownloadFormat.jpeg;

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

  String? get hostOverride => _prefs.getString(hostOverrideKey);

  Future<void> setHostOverride(String? host) {
    final trimmed = host?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return _prefs.remove(hostOverrideKey);
    }
    return _prefs.setString(hostOverrideKey, trimmed);
  }

  String? get sessionsServerUrl => _prefs.getString(sessionsServerUrlKey);

  Future<void> setSessionsServerUrl(String? url) {
    final trimmed = url?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return _prefs.remove(sessionsServerUrlKey);
    }
    return _prefs.setString(sessionsServerUrlKey, trimmed);
  }

  bool get onboardingSeen => _prefs.getBool(onboardingSeenKey) ?? false;

  Future<void> setOnboardingSeen() => _prefs.setBool(onboardingSeenKey, true);
}
