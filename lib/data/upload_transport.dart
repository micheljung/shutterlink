import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../upload/network_policy.dart';
import '../upload/tcp_connector.dart';

abstract interface class UploadTransport {
  ValueListenable<bool> get available;

  http.Client client();
}

/// Uploads over any network the system validated for internet access,
/// through [connector], so Sessions keep uploading while the process is
/// bound to the camera's Wi-Fi. JPEGs are small enough for mobile data.
class TunnelTransport implements UploadTransport {
  TunnelTransport(
    this._network, {
    required NetworkTcpConnector connector,
    this._newClient,
  }) : _connector = withMeteredPolicy(connector, allowMetered: true) {
    _network.addListener(_update);
  }

  final ValueListenable<NetworkStatus> _network;
  final TcpConnector _connector;
  final http.Client Function()? _newClient;
  late final _available = ValueNotifier(_hasInternet);

  @override
  ValueListenable<bool> get available => _available;

  @override
  http.Client client() =>
      _newClient?.call() ?? IOClient(httpClientFor(_connector));

  void dispose() {
    _network.removeListener(_update);
    _available.dispose();
  }

  bool get _hasInternet =>
      _network.value.hasUnmeteredInternet || _network.value.hasMeteredInternet;

  void _update() => _available.value = _hasInternet;
}
