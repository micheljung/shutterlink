import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:shutterlink/upload/remote_path.dart';
import 'package:shutterlink/upload/storage_backend.dart';
import 'package:shutterlink/upload/webdav_backend.dart';

import 'support/dropping_proxy.dart';
import 'support/serve.dart';
import 'support/upload_fixture.dart';
import 'support/webdav_test_server.dart';

const _davRoot = 'remote.php/dav/files/alice';

void main() {
  late WebDavTestServer server;
  late Directory tmp;
  final backends = <WebDavBackend>[];

  setUp(() async {
    server = await WebDavTestServer.start(collections: ['$_davRoot/Photos']);
    tmp = await Directory.systemTemp.createTemp('webdav_test');
  });

  tearDown(() async {
    for (final b in backends) {
      await b.close();
    }
    backends.clear();
    await server.close();
    await tmp.delete(recursive: true);
  });

  WebDavBackend backend({
    String password = 'secret',
    String basePath = 'Photos',
    String scheme = 'http',
    Future<Socket> Function(String, int)? connector,
    String? pin,
    int? port,
  }) {
    final b = WebDavBackend(
      endpoint: Uri.parse(
        '$scheme://localhost:${port ?? server.port}/$_davRoot/',
      ),
      basePath: basePath,
      username: 'alice',
      password: password,
      connector: connector ?? loopbackConnector(port ?? server.port),
      pinnedCertificate: pin,
    );
    backends.add(b);
    return b;
  }

  String remote(String path) => '$_davRoot/Photos/$path';

  group('testConnection', () {
    test('succeeds for an existing base folder', () async {
      await backend().testConnection();
      expect(server.requests, ['PROPFIND /$_davRoot/Photos']);
    });

    test('reports a wrong password', () async {
      await expectLater(
        backend(password: 'nope').testConnection(),
        throwsA(
          isA<AuthenticationException>()
              .having(
                (e) => e.message,
                'message',
                'Wrong username or password.',
              )
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
    });

    test('reports a missing base folder', () async {
      await expectLater(
        backend(basePath: 'Nope').testConnection(),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            'Base folder was not found.',
          ),
        ),
      );
    });

    test('reports an unknown host', () async {
      final b = backend(
        connector: (host, port) =>
            throw SocketException("Failed host lookup: '$host'"),
      );
      await expectLater(
        b.testConnection(),
        throwsA(
          isA<StorageException>()
              .having((e) => e.message, 'message', contains('not found'))
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });

    test('reports a refused connection', () async {
      final port = await closedPort();
      final b = WebDavBackend(
        endpoint: Uri.parse('http://127.0.0.1:$port/'),
        username: 'alice',
        password: 'secret',
      );
      backends.add(b);
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
    });

    test('reports server errors as retryable', () async {
      server.intercept = (_) => Response(503);
      await expectLater(
        backend().testConnection(),
        throwsA(
          isA<StorageException>()
              .having((e) => e.message, 'message', contains('503'))
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });
  });

  group('upload', () {
    test('creates the date folder and commits via a temp name', () async {
      final bytes = bytesOf(70000);
      final request = await uploadRequest(tmp, bytes);
      final progress = <int>[];

      final result = await backend().upload(
        request,
        onProgress: (sent, total) {
          expect(total, bytes.length);
          progress.add(sent);
        },
      );

      expect(result, UploadResult.uploaded);
      expect(server.collections, contains(remote('2026-11-13')));
      expect(server.files[remote('2026-11-13/IMG_0001.JPG')], bytes);
      expect(server.files.keys, [remote('2026-11-13/IMG_0001.JPG')]);
      expect(progress.last, bytes.length);
      expect(
        server.requests,
        contains('PUT /${remote('2026-11-13/.IMG_0001.JPG.tmp-fixed')}'),
      );
      expect(server.requests.where((r) => r.endsWith('.part')), isEmpty);
    });

    test('creates a missing base folder chain', () async {
      final request = await uploadRequest(tmp, bytesOf(10));
      await backend(basePath: 'Photos/Camera/R6').upload(request);
      expect(server.files.keys, [
        '$_davRoot/Photos/Camera/R6/2026-11-13/IMG_0001.JPG',
      ]);
    });

    test('a different file with the same name gets a suffix', () async {
      server.collections.add(remote('2026-11-13'));
      server.files[remote('2026-11-13/IMG_0001.JPG')] = bytesOf(5);
      final bytes = bytesOf(10);
      final b = backend();

      final index = await freeNameIndex(
        b,
        directory: '2026-11-13',
        filename: 'IMG_0001.JPG',
        size: bytes.length,
        sha256: sha256Of(bytes),
      );
      final name = candidateName('IMG_0001.JPG', index!);
      expect(name, 'IMG_0001_1.JPG');

      final request = await uploadRequest(tmp, bytes, name: name);
      expect(await b.upload(request), UploadResult.uploaded);
      expect(server.files[remote('2026-11-13/IMG_0001.JPG')], bytesOf(5));
      expect(server.files[remote('2026-11-13/IMG_0001_1.JPG')], bytes);
    });

    test('an identical file is not uploaded again', () async {
      final bytes = bytesOf(10);
      server.collections.add(remote('2026-11-13'));
      server.files[remote('2026-11-13/IMG_0001.JPG')] = bytes;
      final b = backend();

      final index = await freeNameIndex(
        b,
        directory: '2026-11-13',
        filename: 'IMG_0001.JPG',
        size: bytes.length,
        sha256: sha256Of(bytes),
      );
      expect(index, isNull);
      expect(
        await b.upload(await uploadRequest(tmp, bytes)),
        UploadResult.alreadyPresent,
      );
      expect(server.requests.where((r) => r.startsWith('PUT')), isEmpty);
    });

    test(
      'a name taken during the upload is reported, not overwritten',
      () async {
        final b = backend();
        server.intercept = (request) {
          if (request.method == 'MOVE') {
            server.files[remote('2026-11-13/IMG_0001.JPG')] = bytesOf(3);
          }
          return null;
        };
        final result = await b.upload(await uploadRequest(tmp, bytesOf(10)));
        expect(result, UploadResult.nameTaken);
        expect(server.files.keys, [remote('2026-11-13/IMG_0001.JPG')]);
        expect(server.files.values.single, bytesOf(3));
      },
    );

    test(
      'an identical file appearing during the upload counts as done',
      () async {
        server.intercept = (request) {
          if (request.method == 'MOVE') {
            server.files[remote('2026-11-13/IMG_0001.JPG')] = bytesOf(10);
          }
          return null;
        };
        final result = await backend().upload(
          await uploadRequest(tmp, bytesOf(10)),
        );
        expect(result, UploadResult.alreadyPresent);
        expect(server.files.keys, [remote('2026-11-13/IMG_0001.JPG')]);
      },
    );

    test('a retry reuses the temp name and leaves no orphan', () async {
      var failMove = true;
      server.intercept = (request) {
        if (request.method == 'MOVE' && failMove) {
          failMove = false;
          return Response(500);
        }
        return null;
      };
      final b = backend();
      final request = await uploadRequest(tmp, bytesOf(100));
      await expectLater(
        b.upload(request),
        throwsA(isA<StorageException>().having((e) => e.retryable, 'r', true)),
      );
      expect(await b.upload(request), UploadResult.uploaded);
      expect(server.requests.where((r) => r.startsWith('PUT')).toSet(), {
        'PUT /${remote('2026-11-13/.IMG_0001.JPG.tmp-fixed')}',
      });
      expect(server.files.keys, [remote('2026-11-13/IMG_0001.JPG')]);
    });

    test(
      'a dropped connection fails retryably and the retry succeeds',
      () async {
        final proxy = await DroppingProxy.start(
          server.port,
          dropAfterBytes: 20000,
        );
        addTearDown(proxy.close);
        final b = backend(connector: proxy.connect);
        final bytes = bytesOf(200000);
        final request = await uploadRequest(tmp, bytes);

        Object? error;
        // The first connection may be spent on the PROPFIND/MKCOL requests,
        // so keep retrying like the queue would until the cut has happened.
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            expect(await b.upload(request), UploadResult.uploaded);
            break;
          } on StorageException catch (e) {
            error = e;
            expect(e.retryable, isTrue);
          }
        }
        expect(proxy.drops, 1);
        expect(error, isNotNull);
        expect(server.files[remote('2026-11-13/IMG_0001.JPG')], bytes);
        expect(server.files.keys, [remote('2026-11-13/IMG_0001.JPG')]);
      },
    );

    test('a committed file with the wrong size is not accepted', () async {
      server.intercept = (request) {
        if (request.method == 'MOVE') {
          final temp = server.files.keys.single;
          server.files.remove(temp);
          server.files[remote('2026-11-13/IMG_0001.JPG')] = bytesOf(4);
          return Response(201);
        }
        return null;
      };
      await expectLater(
        backend().upload(await uploadRequest(tmp, bytesOf(10))),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            contains('4 bytes instead of 10'),
          ),
        ),
      );
    });

    test('a failing PUT is reported', () async {
      server.intercept = (request) =>
          request.method == 'PUT' ? Response.forbidden('') : null;
      await expectLater(
        backend().upload(await uploadRequest(tmp, bytesOf(10))),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            'Access denied.',
          ),
        ),
      );
    });

    test('a folder that cannot be created is reported', () async {
      server.intercept = (request) =>
          request.method == 'MKCOL' ? Response(507) : null;
      await expectLater(
        backend().upload(await uploadRequest(tmp, bytesOf(10))),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            contains('507'),
          ),
        ),
      );
    });
  });

  group('TLS trust on first use', () {
    late WebDavTestServer tlsServer;

    setUp(() async {
      tlsServer = await WebDavTestServer.start(
        collections: ['$_davRoot/Photos'],
        tls: true,
      );
    });

    tearDown(() => tlsServer.close());

    test('an untrusted certificate reports its fingerprint', () async {
      final expected = await testCertificateFingerprint();
      await expectLater(
        backend(scheme: 'https', port: tlsServer.port).testConnection(),
        throwsA(
          isA<UntrustedCertificateException>()
              .having((e) => e.fingerprint, 'fingerprint', expected)
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
    });

    test('a pinned certificate is accepted', () async {
      final pin = await testCertificateFingerprint();
      final b = backend(scheme: 'https', port: tlsServer.port, pin: pin);
      await b.testConnection();
      final bytes = bytesOf(1000);
      expect(
        await b.upload(await uploadRequest(tmp, bytes)),
        UploadResult.uploaded,
      );
      expect(tlsServer.files[remote('2026-11-13/IMG_0001.JPG')], bytes);
    });

    test('a different pin is rejected', () async {
      final b = backend(scheme: 'https', port: tlsServer.port, pin: 'AA:BB');
      await expectLater(
        b.testConnection(),
        throwsA(isA<UntrustedCertificateException>()),
      );
    });
  });
}
