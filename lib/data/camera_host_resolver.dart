import 'package:network_info_plus/network_info_plus.dart';

import 'settings_repository.dart';

typedef GatewayLookup = Future<String?> Function();

class CameraHostResolver {
  CameraHostResolver(this._settings, {GatewayLookup? wifiGateway})
    : _wifiGateway = wifiGateway ?? NetworkInfo().getWifiGatewayIP;

  static const fallbackHost = '192.168.1.2';

  final SettingsRepository _settings;
  final GatewayLookup _wifiGateway;

  String? get override => _settings.hostOverride;

  Future<String> resolve({String? boundGateway}) async =>
      override ?? await gateway(boundGateway: boundGateway);

  Future<String> gateway({String? boundGateway}) async {
    if (_usable(boundGateway)) return boundGateway!;
    final gateway = await _wifiGateway();
    if (_usable(gateway)) return gateway!;
    return fallbackHost;
  }

  static const _unsetAddress = '0.0.0.0';

  bool _usable(String? host) =>
      host != null && host.isNotEmpty && host != _unsetAddress;
}
