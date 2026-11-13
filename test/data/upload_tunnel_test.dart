import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/data/upload_tunnel.dart';
import 'package:shutterlink/upload/network_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const token = 'abc123';

  late ServerSocket nativeTunnel;
  late List<MethodCall> calls;

  setUp(() async {
    nativeTunnel = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    calls = [];
    messenger.setMockMethodCallHandler(UploadTunnel.channel, (call) async {
      calls.add(call);
      return {
        'port': nativeTunnel.port,
        'token': token,
        'networkType': 'cellular',
      };
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(UploadTunnel.channel, null);
    await nativeTunnel.close();
  });

  test('sends the token first, then carries bytes both ways', () async {
    final received = Completer<String>();
    nativeTunnel.listen((client) {
      final buffer = <int>[];
      client.listen((bytes) {
        buffer.addAll(bytes);
        if (buffer.length < '${token}ping'.length) return;
        received.complete(ascii.decode(buffer));
        client.add(ascii.encode('pong'));
      });
    });

    final tunnel = await const UploadTunnel().connect(
      'example.com',
      443,
      allowMetered: true,
    );
    final reply = tunnel.socket.first;
    tunnel.socket.add(ascii.encode('ping'));

    expect(await received.future, '${token}ping');
    expect(ascii.decode(await reply), 'pong');
    expect(tunnel.networkType, 'cellular');
    expect(calls.single.method, 'openTunnel');
    expect(calls.single.arguments, {
      'host': 'example.com',
      'port': 443,
      'allowMetered': true,
    });
    tunnel.socket.destroy();
  });

  test('a native failure surfaces as a PlatformException', () async {
    messenger.setMockMethodCallHandler(
      UploadTunnel.channel,
      (_) async => throw PlatformException(code: 'no_network'),
    );

    await expectLater(
      const UploadTunnel().connect('example.com', 443, allowMetered: false),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'no_network'),
      ),
    );
  });

  test('maps native network snapshots to a status', () async {
    messenger.setMockStreamHandler(
      UploadTunnel.networksChannel,
      MockStreamHandler.inline(
        onListen: (_, events) {
          events.success([]);
          events.success([
            {'transport': 'wifi', 'validated': false, 'metered': false},
            {'transport': 'cellular', 'validated': true, 'metered': true},
            {'transport': 'ethernet', 'validated': true, 'metered': false},
          ]);
        },
      ),
    );
    addTearDown(
      () => messenger.setMockStreamHandler(UploadTunnel.networksChannel, null),
    );

    expect(await const UploadTunnel().networkStatus().take(2).toList(), [
      NetworkStatus.offline,
      const NetworkStatus([
        NetworkInfo(
          transport: NetworkTransport.wifi,
          validated: false,
          metered: false,
        ),
        NetworkInfo(
          transport: NetworkTransport.cellular,
          validated: true,
          metered: true,
        ),
        NetworkInfo(
          transport: NetworkTransport.other,
          validated: true,
          metered: false,
        ),
      ]),
    ]);
  });
}
