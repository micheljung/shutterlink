import 'dart:io';

import 'package:test/test.dart';

import 'process_support.dart';
import 'support.dart';

void main() {
  test('GET /healthz answers 204 with no body and no token', () async {
    final server = await TestApp.open();
    addTearDown(server.close);

    final response = await server.get('/healthz');

    expect(response.statusCode, HttpStatus.noContent);
    expect(await bodyBytes(response), isEmpty);
  });

  group('--healthcheck', () {
    late Directory dataDir;

    setUp(() async => dataDir = await tempDataDir());
    tearDown(() => dataDir.delete(recursive: true));

    test('exits 0 when the server answers', () async {
      final server = await ServerProcess.start(dataDir);
      addTearDown(server.kill);

      // No --data-dir and no token: the check needs neither.
      final result = await runServer([
        '--healthcheck',
        '--port',
        '${server.url.port}',
      ]);

      expect(result.exitCode, 0, reason: '${result.stderr}');
    });

    test('exits 1 when nothing listens on the port', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();

      final result = await runServer(['--healthcheck', '--port', '$port']);

      expect(result.exitCode, 1);
      expect('${result.stderr}', contains('Health check failed'));
    });

    test('checks a wildcard bind address on loopback', () async {
      final server = await ServerProcess.start(
        dataDir,
        arguments: ['--address', '0.0.0.0'],
      );
      addTearDown(server.kill);

      final result = await runServer([
        '--healthcheck',
        '--address',
        '0.0.0.0',
        '--port',
        '${server.url.port}',
      ]);

      expect(result.exitCode, 0, reason: '${result.stderr}');
    });
  });
}
