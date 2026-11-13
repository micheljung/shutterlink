import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Opens a socket to [host] over an internet network chosen natively, so
/// uploads bypass the process binding to the camera's Wi-Fi.
class UploadTunnel {
  const UploadTunnel();

  static const channel = MethodChannel(
    'ch.micheljung.shutterlink/upload_tunnel',
  );

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
}
