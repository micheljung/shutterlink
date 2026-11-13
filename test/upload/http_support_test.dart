import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/upload/http_support.dart';
import 'package:shutterlink/upload/storage_backend.dart';
import 'package:shutterlink/upload/tcp_connector.dart';

void main() {
  test('statusException maps statuses to readable messages', () {
    expect(statusException(401, 'x').message, 'Wrong username or password.');
    expect(
      statusException(403, 'x', detail: 'Quota').message,
      'Access denied (Quota).',
    );
    expect(statusException(404, 'Bucket b').message, 'Bucket b was not found.');
    expect(statusException(503, 'x').retryable, isTrue);
    expect(statusException(429, 'x').retryable, isTrue);
    expect(statusException(400, 'x').retryable, isFalse);
    expect(statusException(400, 'x').message, contains('400'));
  });

  test('networkException distinguishes DNS failures', () {
    expect(
      networkException(
        const SocketException(
          'Failed host lookup',
          osError: OSError('No address associated with hostname', 7),
        ),
        'dav.example',
      ).message,
      startsWith('Server dav.example not found'),
    );
    expect(
      networkException(
        const SocketException('x', osError: OSError('Connection refused', 111)),
        'dav.example',
      ).message,
      'Connection to dav.example failed: Connection refused',
    );
  });

  group('sendHttp', () {
    late ServerSocket server;
    late HttpClient client;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      client = httpClientFor(directConnector);
    });

    tearDown(() async {
      client.close(force: true);
      await server.close();
    });

    test('reports a connection closed mid-request as retryable', () async {
      server.listen((socket) => socket.destroy());
      await expectLater(
        sendHttp(client, 'GET', Uri.parse('http://127.0.0.1:${server.port}/')),
        throwsA(
          isA<StorageException>()
              .having((e) => e.message, 'message', contains('interrupted'))
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });

    test('reports a failed TLS handshake', () async {
      server.listen((socket) {
        socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
        socket.destroy();
      });
      await expectLater(
        sendHttp(client, 'GET', Uri.parse('https://127.0.0.1:${server.port}/')),
        throwsA(
          isA<StorageException>()
              .having((e) => e.message, 'message', startsWith('Secure'))
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
    });

    test('streams a file of unknown length', () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(http.close);
      http.listen((request) async {
        final length = await request.fold<int>(0, (n, c) => n + c.length);
        request.response
          ..write('$length')
          ..close();
      });
      final tmp = await Directory.systemTemp.createTemp('http_support');
      addTearDown(() => tmp.delete(recursive: true));
      final file = File('${tmp.path}/f')..writeAsBytesSync(List.filled(7, 1));
      final result = await sendHttp(
        client,
        'PUT',
        Uri.parse('http://127.0.0.1:${http.port}/'),
        file: file,
      );
      expect(result.ok, isTrue);
      expect(result.body, '7');
    });
  });
}
