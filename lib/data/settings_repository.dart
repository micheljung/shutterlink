import 'package:shared_preferences/shared_preferences.dart';

enum DownloadFormat { jpeg, raw, both }

class SettingsRepository {
  SettingsRepository(this._prefs);

  static const formatKey = 'download_format';
  static const hostOverrideKey = 'camera_host_override';
  static const sessionsServerUrlKey = 'sessions_server_url';
  static const onboardingSeenKey = 'onboarding_seen';
  static const qrSessionAliveAtKey = 'qr_session_alive_at';
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

  /// When QR Session last ran with an open window, while it is running; a
  /// window found open at startup was cut off then, not stopped.
  DateTime? get qrSessionAliveAt {
    final millis = _prefs.getInt(qrSessionAliveAtKey);
    return millis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  Future<void> setQrSessionAliveAt(DateTime? aliveAt) async {
    if (aliveAt == null) {
      if (_prefs.containsKey(qrSessionAliveAtKey)) {
        await _prefs.remove(qrSessionAliveAtKey);
      }
      return;
    }
    await _prefs.setInt(qrSessionAliveAtKey, aliveAt.millisecondsSinceEpoch);
  }
}
