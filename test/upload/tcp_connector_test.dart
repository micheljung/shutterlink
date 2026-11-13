import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/upload/tcp_connector.dart';

void main() {
  test('withMeteredPolicy passes the flag to the connector', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((s) => s.destroy());
    final seen = <bool>[];
    Future<Socket> connector(
      String host,
      int port, {
      required bool allowMetered,
    }) {
      seen.add(allowMetered);
      return directNetworkConnector(host, port, allowMetered: allowMetered);
    }

    for (final allowMetered in [true, false]) {
      final socket = await withMeteredPolicy(
        connector,
        allowMetered: allowMetered,
      )('127.0.0.1', server.port);
      socket.destroy();
    }
    expect(seen, [true, false]);
  });
}
