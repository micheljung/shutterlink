import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/upload/sftp_backend.dart';
import 'package:shutterlink/upload/storage_backend.dart';

import 'support/upload_fixture.dart';

// Failures that need no SSH server; the server cases live in the
// sftp-tagged tests.
void main() {
  test('reports an unreadable private key', () async {
    final b = SftpBackend(
      host: 'sftp.test',
      username: 'alice',
      privateKey: 'not a key',
      pinnedHostKey: 'SHA256:x',
    );
    await expectLater(
      b.testConnection(),
      throwsA(
        isA<StorageException>()
            .having(
              (e) => e.message,
              'message',
              'The private key could not be read.',
            )
            .having((e) => e.retryable, 'retryable', false),
      ),
    );
    await b.close();
  });

  test('reports an unknown host', () async {
    final b = SftpBackend(
      host: 'sftp.test',
      username: 'alice',
      password: 'secret',
      pinnedHostKey: 'SHA256:x',
      connector: (host, _) =>
          throw SocketException("Failed host lookup: '$host'"),
    );
    await expectLater(
      b.probe(
        const RemoteTarget(directory: '2026-11-13', name: 'A.JPG'),
        size: 1,
        sha256: 'x',
      ),
      throwsA(
        isA<StorageException>()
            .having(
              (e) => e.message,
              'message',
              startsWith('Server sftp.test not found'),
            )
            .having((e) => e.retryable, 'retryable', true),
      ),
    );
    await b.close();
  });

  test('reports a refused connection and reconnects next time', () async {
    final port = await closedPort();
    var attempts = 0;
    final b = SftpBackend(
      host: '127.0.0.1',
      port: port,
      username: 'alice',
      password: 'secret',
      pinnedHostKey: 'SHA256:x',
      connector: (host, port) {
        attempts++;
        return Socket.connect(host, port);
      },
    );
    for (var i = 0; i < 2; i++) {
      await expectLater(
        b.testConnection(),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            startsWith('Connection to 127.0.0.1 failed'),
          ),
        ),
      );
    }
    expect(attempts, 2);
    await b.close();
  });

  test('reports a server that is not speaking SSH', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
      socket.destroy();
    });
    addTearDown(server.close);
    final b = SftpBackend(
      host: '127.0.0.1',
      port: server.port,
      username: 'alice',
      password: 'secret',
      pinnedHostKey: 'SHA256:x',
    );
    await expectLater(
      b.testConnection(),
      throwsA(
        isA<StorageException>()
            .having(
              (e) => e.message,
              'message',
              startsWith('Connection to 127.0.0.1 failed'),
            )
            .having((e) => e.retryable, 'retryable', true),
      ),
    );
    await b.close();
  });
}
