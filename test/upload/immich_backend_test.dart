import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:shutterlink/upload/immich_backend.dart';
import 'package:shutterlink/upload/remote_path.dart';
import 'package:shutterlink/upload/storage_backend.dart';

import 'support/dropping_proxy.dart';
import 'support/immich_test_server.dart';
import 'support/serve.dart';
import 'support/upload_fixture.dart';

void main() {
  late ImmichTestServer server;
  late Directory tmp;
  final backends = <ImmichBackend>[];

  setUp(() async {
    server = await ImmichTestServer.start();
    tmp = await Directory.systemTemp.createTemp('immich_test');
  });

  tearDown(() async {
    for (final b in backends) {
      await b.close();
    }
    backends.clear();
    await server.close();
    await tmp.delete(recursive: true);
  });

  ImmichBackend backend({
    String apiKey = 'immich-key',
    String scheme = 'http',
    String path = '',
    Future<Socket> Function(String, int)? connector,
    String? pin,
    int? port,
  }) {
    final b = ImmichBackend(
      endpoint: Uri.parse(
        '$scheme://photos.example:${port ?? server.port}$path',
      ),
      apiKey: apiKey,
      connector: connector ?? loopbackConnector(port ?? server.port),
      pinnedCertificate: pin,
    );
    backends.add(b);
    return b;
  }

  Matcher storageError(Object message, {required bool retryable}) => throwsA(
    isA<StorageException>()
        .having((e) => e.message, 'message', message)
        .having((e) => e.retryable, 'retryable', retryable),
  );

  group('testConnection', () {
    test('pings and checks the upload permission', () async {
      await backend().testConnection();
      expect(server.requests, [
        'GET /api/server/ping',
        'POST /api/assets/bulk-upload-check',
      ]);
    });

    test('accepts the endpoint with a trailing /api/', () async {
      await backend(path: '/api/').testConnection();
      expect(server.requests.first, 'GET /api/server/ping');
    });

    test('keeps a sub-path the server is mounted under', () async {
      server.intercept = (request) => request.url.path.startsWith('immich/')
          ? Response.ok('{"res":"pong"}')
          : null;
      final b = backend(path: '/immich');
      await b.testConnection();
      expect(server.requests, [
        'GET /immich/api/server/ping',
        'POST /immich/api/assets/bulk-upload-check',
      ]);
    });

    test('reports a wrong API key', () async {
      await expectLater(
        backend(apiKey: 'nope').testConnection(),
        throwsA(
          isA<AuthenticationException>()
              .having(
                (e) => e.message,
                'message',
                'Immich rejected the API key.',
              )
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
    });

    test('reports a key without the upload permission', () async {
      server.permissions = const {};
      await expectLater(
        backend().testConnection(),
        throwsA(
          isA<AuthenticationException>().having(
            (e) => e.message,
            'message',
            contains('asset.upload'),
          ),
        ),
      );
    });

    test('reports a server that does not answer the ping', () async {
      server.intercept = (_) => Response.notFound('Not Found');
      await expectLater(
        backend().testConnection(),
        storageError(
          'photos.example is not an Immich server.',
          retryable: false,
        ),
      );
    });

    test('reports a ping without pong', () async {
      server.intercept = (_) => Response.ok('<html>Login</html>');
      await expectLater(
        backend().testConnection(),
        storageError(contains('not an Immich server'), retryable: false),
      );
    });

    test('a failing ping is not blamed on the API key', () async {
      server.intercept = (request) => request.url.path == 'api/server/ping'
          ? Response(401, body: '{"message":"Proxy login required"}')
          : null;
      await expectLater(
        backend().testConnection(),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            isNot(contains('API key')),
          ),
        ),
      );
    });

    test('reports server errors as retryable', () async {
      server.intercept = (_) => Response(503);
      await expectLater(
        backend().testConnection(),
        storageError(contains('503'), retryable: true),
      );
    });

    test('reports a refused connection', () async {
      final port = await closedPort();
      final b = ImmichBackend(
        endpoint: Uri.parse('http://127.0.0.1:$port'),
        apiKey: 'immich-key',
      );
      backends.add(b);
      await expectLater(
        b.testConnection(),
        storageError(
          startsWith('Connection to 127.0.0.1 failed'),
          retryable: true,
        ),
      );
    });
  });

  group('upload', () {
    test('posts the file to the timeline', () async {
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
      expect(progress.last, bytes.length);
      final asset = server.assets[sha1.convert(bytes).toString()]!;
      expect(asset.bytes, bytes);
      expect(asset.filename, 'IMG_0001.JPG');
      expect(asset.fields['filename'], 'IMG_0001.JPG');
      expect(asset.fields['deviceId'], 'shutterlink');
      expect(asset.fields['deviceAssetId'], 'IMG_0001.JPG-70000');
      final modified = (await request.source.lastModified()).toUtc();
      expect(DateTime.parse(asset.fields['fileCreatedAt']!), modified);
      expect(DateTime.parse(asset.fields['fileModifiedAt']!), modified);
      expect(server.requests, [
        'POST /api/assets/bulk-upload-check',
        'POST /api/assets',
      ]);
    });

    test('a file Immich already has counts as present', () async {
      final bytes = bytesOf(1000);
      final b = backend();
      expect(
        await b.upload(await uploadRequest(tmp, bytes)),
        UploadResult.uploaded,
      );
      expect(
        await b.upload(await uploadRequest(tmp, bytes, name: 'IMG_0001_1.JPG')),
        UploadResult.alreadyPresent,
      );
      expect(server.assets, hasLength(1));
      expect(
        server.requests.where((r) => r == 'POST /api/assets'),
        hasLength(1),
      );
      expect(server.requests.last, 'POST /api/assets/bulk-upload-check');
    });

    test('a file Immich already has is not sent again', () async {
      final bytes = bytesOf(1000);
      server.assets[sha1.convert(bytes).toString()] = ImmichAsset(
        'existing',
        bytes,
        const {},
        'OTHER.JPG',
      );
      expect(
        await backend().upload(await uploadRequest(tmp, bytes)),
        UploadResult.alreadyPresent,
      );
      expect(server.requests, ['POST /api/assets/bulk-upload-check']);
      expect(server.assets, hasLength(1));
    });

    test('a retry after a lost response finds the stored asset', () async {
      server.loseNextUploadResponse = true;
      final b = backend();
      final request = await uploadRequest(tmp, bytesOf(1000));
      await expectLater(
        b.upload(request),
        storageError(contains('502'), retryable: true),
      );
      expect(await b.upload(request), UploadResult.alreadyPresent);
      expect(
        server.requests.where((r) => r == 'POST /api/assets'),
        hasLength(1),
      );
      expect(server.assets, hasLength(1));
    });

    test('every name is free without asking the server', () async {
      final b = backend();
      final bytes = bytesOf(10);
      expect(
        await b.probe(
          const RemoteTarget(directory: '2026-11-13', name: 'IMG_0001.JPG'),
          size: bytes.length,
          sha256: sha256Of(bytes),
        ),
        ProbeResult.absent,
      );
      expect(
        await freeNameIndex(
          b,
          directory: '2026-11-13',
          filename: 'IMG_0001.JPG',
          size: bytes.length,
          sha256: sha256Of(bytes),
        ),
        0,
      );
      expect(server.requests, isEmpty);
    });

    test('quotes and line breaks cannot end the file name parameter', () async {
      const name = 'IMG "1"\r\nX: y.JPG';
      await backend().upload(await uploadRequest(tmp, bytesOf(10), name: name));
      final asset = server.assets.values.single;
      expect(asset.filename, 'IMG %221%22%0D%0AX: y.JPG');
      expect(asset.fields['filename'], name);
    });

    test('a wrong API key is not retryable', () async {
      await expectLater(
        backend(apiKey: 'nope').upload(await uploadRequest(tmp, bytesOf(10))),
        throwsA(isA<AuthenticationException>()),
      );
    });

    test('a missing upload permission is not retryable', () async {
      server.permissions = const {};
      await expectLater(
        backend().upload(await uploadRequest(tmp, bytesOf(10))),
        throwsA(
          isA<AuthenticationException>().having(
            (e) => e.message,
            'message',
            contains('asset.upload'),
          ),
        ),
      );
    });

    for (final status in [429, 500]) {
      test('error $status is retryable', () async {
        server.intercept = (_) => Response(
          status,
          body: '{"message":"Busy"}',
          headers: {'Content-Type': 'application/json'},
        );
        await expectLater(
          backend().upload(await uploadRequest(tmp, bytesOf(10))),
          storageError(
            'The server reported error $status (Busy).',
            retryable: true,
          ),
        );
      });
    }

    test('a rejected upload reports Immich\'s message', () async {
      server.intercept = (request) => request.url.path == 'api/assets'
          ? Response(400, body: '{"message":"Unsupported file type"}')
          : null;
      await expectLater(
        backend().upload(await uploadRequest(tmp, bytesOf(10))),
        storageError(
          'Unexpected server response 400 (Unsupported file type).',
          retryable: false,
        ),
      );
    });

    test('joins Immich\'s validation messages', () async {
      server.intercept = (request) => request.url.path == 'api/assets'
          ? Response(
              400,
              body: '{"message":["deviceId must be a string","bad date"]}',
            )
          : null;
      await expectLater(
        backend().upload(await uploadRequest(tmp, bytesOf(10))),
        storageError(
          'Unexpected server response 400 (deviceId must be a string; '
          'bad date).',
          retryable: false,
        ),
      );
    });

    test('a success without an asset status is not trusted', () async {
      server.intercept = (_) => Response.ok('<html>Proxy login</html>');
      await expectLater(
        backend().upload(await uploadRequest(tmp, bytesOf(10))),
        storageError(
          'Unexpected response from Immich for IMG_0001.JPG.',
          retryable: false,
        ),
      );
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

        await expectLater(
          b.upload(request),
          throwsA(
            isA<StorageException>().having((e) => e.retryable, 'r', true),
          ),
        );
        expect(server.assets, isEmpty);
        expect(await b.upload(request), UploadResult.uploaded);
        expect(proxy.drops, 1);
        expect(server.assets.values.single.bytes, bytes);
      },
    );
  });

  group('TLS trust on first use', () {
    late ImmichTestServer tlsServer;

    setUp(() async {
      tlsServer = await ImmichTestServer.start(tls: true);
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
      expect(tlsServer.assets.values.single.bytes, bytes);
    });
  });
}
