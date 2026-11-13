import 'dart:io';

import 'package:flutter/services.dart';

import '../data/upload_tunnel.dart';
import 'storage_backend.dart';
import 'tcp_connector.dart';

/// Connects through the native tunnel on Android and directly elsewhere.
NetworkTcpConnector platformTcpConnector({
  UploadTunnel tunnel = const UploadTunnel(),
  bool? isAndroid,
}) {
  if (!(isAndroid ?? Platform.isAndroid)) return directNetworkConnector;
  return (host, port, {required allowMetered}) async {
    try {
      final connection = await tunnel.connect(
        host,
        port,
        allowMetered: allowMetered,
      );
      return connection.socket;
    } on PlatformException catch (error) {
      if (error.code == UploadTunnel.noNetworkCode) {
        throw const NoNetworkException();
      }
      throw SocketException(error.message ?? error.code);
    }
  };
}
