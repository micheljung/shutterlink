import 'package:shared_preferences/shared_preferences.dart';

const _localHosts = {'localhost', '127.0.0.1', '::1'};

bool isValidSessionsServerUrl(String? url) {
  final text = url?.trim() ?? '';
  if (text.contains(RegExp(r'\s'))) return false;
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return false;
  if (uri.path.contains('//') || uri.hasQuery || uri.hasFragment) {
    return false;
  }
  return uri.scheme == 'https' ||
      (uri.scheme == 'http' && _localHosts.contains(uri.host));
}

enum DownloadFormat { jpeg, raw, both }

class SettingsRepository {
  SettingsRepository(this._prefs);

  static const formatKey = 'download_format';
  static const hostOverrideKey = 'camera_host_override';
  static const sessionsServerUrlKey = 'sessions_server_url';
  static const onboardingSeenKey = 'onboarding_seen';
  static const liveShareAliveAtKey = 'live_share_alive_at';

  // TODO: Remove with migrateLegacyKeys once versionCode 6 is released.
  static const legacyLiveShareAliveAtKey = 'qr_session_alive_at';
  static const defaultFormat = DownloadFormat.jpeg;

  final SharedPreferences _prefs;

  // TODO: Remove once versionCode 6 is released.
  Future<void> migrateLegacyKeys() async {
    final aliveAt = _prefs.getInt(legacyLiveShareAliveAtKey);
    if (aliveAt == null) return;
    if (!_prefs.containsKey(liveShareAliveAtKey)) {
      await _prefs.setInt(liveShareAliveAtKey, aliveAt);
    }
    await _prefs.remove(legacyLiveShareAliveAtKey);
  }

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

  /// When Live Share last ran with an open window, while it is running; a
  /// window found open at startup was cut off then, not stopped.
  DateTime? get liveShareAliveAt {
    final millis = _prefs.getInt(liveShareAliveAtKey);
    return millis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  Future<void> setLiveShareAliveAt(DateTime? aliveAt) async {
    if (aliveAt == null) {
      if (_prefs.containsKey(liveShareAliveAtKey)) {
        await _prefs.remove(liveShareAliveAtKey);
      }
      return;
    }
    await _prefs.setInt(liveShareAliveAtKey, aliveAt.millisecondsSinceEpoch);
  }
}
