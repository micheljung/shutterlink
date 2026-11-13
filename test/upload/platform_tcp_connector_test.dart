import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/data/upload_tunnel.dart';
import 'package:shutterlink/upload/platform_tcp_connector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const token = 'secret';

  late ServerSocket nativeTunnel;
  late List<MethodCall> calls;

  setUp(() async {
    nativeTunnel = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    calls = [];
    messenger.setMockMethodCallHandler(UploadTunnel.channel, (call) async {
      calls.add(call);
      return {'port': nativeTunnel.port, 'token': token, 'networkType': 'wifi'};
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(UploadTunnel.channel, null);
    await nativeTunnel.close();
  });

  void failWith(String code) => messenger.setMockMethodCallHandler(
    UploadTunnel.channel,
    (_) async => throw PlatformException(code: code, message: 'refused'),
  );

  test('connects through the tunnel with the metered flag', () async {
    final received = nativeTunnel.first.then(
      (client) => client.first.then(ascii.decode),
    );
    final connect = platformTcpConnector(isAndroid: true);

    final socket = await connect('dav.example.com', 443, allowMetered: false);

    expect(await received, token);
    expect(calls.single.arguments, {
      'host': 'dav.example.com',
      'port': 443,
      'allowMetered': false,
    });
    socket.destroy();
  });

  test('a missing network is a retryable wait', () async {
    failWith(UploadTunnel.noNetworkCode);

    await expectLater(
      platformTcpConnector(isAndroid: true)('h', 1, allowMetered: true),
      throwsA(
        isA<NoNetworkException>().having(
          (e) => e.retryable,
          'retryable',
          isTrue,
        ),
      ),
    );
  });

  test('other tunnel failures surface as socket errors', () async {
    failWith('tunnel_failed');

    await expectLater(
      platformTcpConnector(isAndroid: true)('h', 1, allowMetered: true),
      throwsA(
        isA<SocketException>().having((e) => e.message, 'message', 'refused'),
      ),
    );
  });

  test('connects directly off Android', () async {
    final accepted = nativeTunnel.first;

    final socket = await platformTcpConnector(isAndroid: false)(
      InternetAddress.loopbackIPv4.address,
      nativeTunnel.port,
      allowMetered: false,
    );

    await accepted;
    expect(calls, isEmpty);
    socket.destroy();
  });
}
