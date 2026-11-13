import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shutterlink/data/network_status_feed.dart';
import 'package:shutterlink/data/upload_transport.dart';
import 'package:shutterlink/upload/network_policy.dart';

void main() {
  const wifi = NetworkStatus([
    NetworkInfo(
      transport: NetworkTransport.wifi,
      validated: true,
      metered: false,
    ),
  ]);
  const cellular = NetworkStatus([
    NetworkInfo(
      transport: NetworkTransport.cellular,
      validated: true,
      metered: true,
    ),
  ]);

  group('TunnelTransport', () {
    test('is available while any network is validated', () {
      final network = ValueNotifier(NetworkStatus.offline);
      final transport = TunnelTransport(
        network,
        connector: (host, port, {required allowMetered}) =>
            throw UnimplementedError(),
      );
      expect(transport.available.value, isFalse);
      network.value = cellular;
      expect(transport.available.value, isTrue);
      network.value = wifi;
      expect(transport.available.value, isTrue);
      network.value = NetworkStatus.offline;
      expect(transport.available.value, isFalse);
      transport.dispose();
    });

    test('connects through the connector and allows mobile data', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      server.listen(
        (request) => request.response
          ..statusCode = HttpStatus.noContent
          ..close(),
      );
      final calls = <(String, int, bool)>[];
      final transport = TunnelTransport(
        ValueNotifier(cellular),
        connector: (host, port, {required allowMetered}) {
          calls.add((host, port, allowMetered));
          return Socket.connect(InternetAddress.loopbackIPv4, server.port);
        },
      );
      final client = transport.client();
      final response = await client.get(
        Uri.parse('http://photos.example.com:${server.port}/'),
      );
      client.close();
      transport.dispose();
      await server.close(force: true);

      expect(response.statusCode, HttpStatus.noContent);
      expect(calls, [('photos.example.com', port, true)]);
    });

    test('creates clients with the injected factory', () {
      final client = http.Client();
      final transport = TunnelTransport(
        ValueNotifier(wifi),
        connector: (host, port, {required allowMetered}) =>
            throw UnimplementedError(),
        newClient: () => client,
      );
      expect(transport.client(), same(client));
      client.close();
      transport.dispose();
    });
  });

  group('NetworkStatusFeed', () {
    test('replays the latest status to every later listener', () async {
      final source = StreamController<NetworkStatus>.broadcast();
      final feed = NetworkStatusFeed(
        source.stream,
        initial: NetworkStatus.offline,
      );
      var notified = 0;
      feed.addListener(() => notified++);
      source.add(wifi);
      await pumpEventQueue();
      expect(feed.value, wifi);
      expect(notified, 1);

      final first = <NetworkStatus>[];
      final subscription = feed.statuses.listen(first.add);
      await pumpEventQueue();
      source.add(cellular);
      await pumpEventQueue();
      expect(first, [wifi, cellular]);
      expect(source.hasListener, isTrue);

      await subscription.cancel();
      await feed.dispose();
      expect(source.hasListener, isFalse);
      await source.close();
    });
  });
}
