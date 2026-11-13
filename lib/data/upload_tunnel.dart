import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../upload/network_policy.dart';

/// Opens a socket to [host] over an internet network chosen natively, so
/// uploads bypass the process binding to the camera's Wi-Fi.
class UploadTunnel {
  const UploadTunnel();

  static const channel = MethodChannel(
    'ch.micheljung.shutterlink/upload_tunnel',
  );
  static const networksChannel = EventChannel(
    'ch.micheljung.shutterlink/upload_tunnel/networks',
  );

  /// No network the call may use has internet access right now.
  static const noNetworkCode = 'no_network';

  Future<({Socket socket, String networkType})> connect(
    String host,
    int port, {
    required bool allowMetered,
  }) async {
    final tunnel = await channel.invokeMapMethod<String, Object?>(
      'openTunnel',
      {'host': host, 'port': port, 'allowMetered': allowMetered},
    );
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      tunnel!['port']! as int,
    );
    socket.add(ascii.encode(tunnel['token']! as String));
    return (socket: socket, networkType: tunnel['networkType']! as String);
  }

  /// The networks the device currently has, updated on every change.
  Stream<NetworkStatus> networkStatus() => networksChannel
      .receiveBroadcastStream()
      .map((event) => NetworkStatus(_networks(event as List<Object?>)));

  static List<NetworkInfo> _networks(List<Object?> networks) => [
    for (final network in networks.cast<Map<Object?, Object?>>())
      NetworkInfo(
        transport: switch (network['transport']) {
          'wifi' => NetworkTransport.wifi,
          'cellular' => NetworkTransport.cellular,
          _ => NetworkTransport.other,
        },
        validated: network['validated']! as bool,
        metered: network['metered']! as bool,
      ),
  ];
}
