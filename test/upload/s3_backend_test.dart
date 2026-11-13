import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:shutterlink/upload/remote_path.dart';
import 'package:shutterlink/upload/s3_backend.dart';
import 'package:shutterlink/upload/storage_backend.dart';

import 'support/dropping_proxy.dart';
import 'support/s3_test_server.dart';
import 'support/serve.dart';
import 'support/upload_fixture.dart';

void main() {
  late S3TestServer server;
  late Directory tmp;
  final backends = <S3Backend>[];

  setUp(() async {
    server = await S3TestServer.start();
    tmp = await Directory.systemTemp.createTemp('s3_test');
  });

  tearDown(() async {
    for (final b in backends) {
      await b.close();
    }
    backends.clear();
    await server.close();
    await tmp.delete(recursive: true);
  });

  S3Backend backend({
    bool pathStyle = true,
    String bucket = 'photos',
    String basePath = 'camera',
    String accessKey = 'AKIDTEST',
    String secretKey = 'test-secret',
    String region = 'eu-central-1',
    String scheme = 'http',
    Future<Socket> Function(String, int)? connector,
    List<String>? hosts,
    String? pin,
    int? port,
  }) {
    final b = S3Backend(
      endpoint: Uri.parse('$scheme://s3.test:${port ?? server.port}'),
      region: region,
      bucket: bucket,
      basePath: basePath,
      accessKey: accessKey,
      secretKey: secretKey,
      pathStyle: pathStyle,
      connector:
          connector ?? loopbackConnector(port ?? server.port, hosts: hosts),
      pinnedCertificate: pin,
    );
    backends.add(b);
    return b;
  }

  Map<String, S3Object> objects() => server.buckets['photos']!;

  group('testConnection', () {
    test('succeeds path-style', () async {
      await backend().testConnection();
    });

    test('succeeds with virtual-host addressing', () async {
      final hosts = <String>[];
      await backend(pathStyle: false, hosts: hosts).testConnection();
      expect(hosts, ['photos.s3.test']);
    });

    test('reports a wrong secret key', () async {
      await expectLater(
        backend(secretKey: 'wrong').testConnection(),
        throwsA(
          isA<StorageException>()
              .having(
                (e) => e.message,
                'message',
                'Access denied (SignatureDoesNotMatch).',
              )
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
    });

    test('reports an unknown access key', () async {
      await expectLater(
        backend(accessKey: 'nobody').testConnection(),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            'Access denied (InvalidAccessKeyId).',
          ),
        ),
      );
    });

    test('reports a missing bucket', () async {
      await expectLater(
        backend(bucket: 'nope').testConnection(),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            'Bucket nope was not found (NoSuchBucket).',
          ),
        ),
      );
    });

    test('reports an unknown host', () async {
      await expectLater(
        backend(
          connector: (host, _) =>
              throw SocketException("Failed host lookup: '$host'"),
        ).testConnection(),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            startsWith('Server s3.test not found'),
          ),
        ),
      );
    });
  });

  group('upload', () {
    for (final pathStyle in [true, false]) {
      test('stores under base/date/name (pathStyle: $pathStyle)', () async {
        final bytes = bytesOf(50000);
        final request = await uploadRequest(tmp, bytes);
        final progress = <int>[];
        final result = await backend(pathStyle: pathStyle)
            .upload(request, onProgress: (sent, _) => progress.add(sent));
        expect(result, UploadResult.uploaded);
        final object = objects()['camera/2026-11-13/IMG_0001.JPG']!;
        expect(object.bytes, bytes);
        expect(object.meta['x-amz-meta-sha256'], sha256Of(bytes));
        expect(objects().keys, ['camera/2026-11-13/IMG_0001.JPG']);
        expect(progress.last, bytes.length);
      });
    }

    test('encodes names that need escaping', () async {
      final bytes = bytesOf(10);
      final request = await uploadRequest(
        tmp,
        bytes,
        name: 'My Shot (1)+ü.JPG',
      );
      expect(
        await backend(basePath: 'a b').upload(request),
        UploadResult.uploaded,
      );
      expect(objects().keys, ['a b/2026-11-13/My Shot (1)+ü.JPG']);
    });

    test('a different object with the same name gets a suffix', () async {
      objects()['camera/2026-11-13/IMG_0001.JPG'] = S3Object(bytesOf(10), {
        'x-amz-meta-sha256': 'other',
      });
      final bytes = bytesOf(10, seed: 1);
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
      expect(
        await b.upload(await uploadRequest(tmp, bytes, name: name)),
        UploadResult.uploaded,
      );
      expect(objects()['camera/2026-11-13/IMG_0001_1.JPG']!.bytes, bytes);
    });

    test('an identical object is not uploaded again', () async {
      final bytes = bytesOf(10);
      objects()['camera/2026-11-13/IMG_0001.JPG'] = S3Object(bytes, {
        'x-amz-meta-sha256': sha256Of(bytes),
      });
      expect(
        await backend().upload(await uploadRequest(tmp, bytes)),
        UploadResult.alreadyPresent,
      );
      expect(server.requests.where((r) => r.startsWith('PUT')), isEmpty);
    });

    test(
      'a key taken during the upload is reported, not overwritten',
      () async {
        server.intercept = (request) {
          if (request.method == 'PUT') {
            objects()['camera/2026-11-13/IMG_0001.JPG'] = S3Object(
              bytesOf(3),
              const {},
            );
          }
          return null;
        };
        expect(
          await backend().upload(await uploadRequest(tmp, bytesOf(10))),
          UploadResult.nameTaken,
        );
        expect(objects().values.single.bytes, bytesOf(3));
      },
    );

    test(
      'an identical object appearing during the upload counts as done',
      () async {
        final bytes = bytesOf(10);
        server.intercept = (request) {
          if (request.method == 'PUT') {
            objects()['camera/2026-11-13/IMG_0001.JPG'] = S3Object(bytes, {
              'x-amz-meta-sha256': sha256Of(bytes),
            });
          }
          return null;
        };
        expect(
          await backend().upload(await uploadRequest(tmp, bytes)),
          UploadResult.alreadyPresent,
        );
      },
    );

    test('falls back to an unconditional PUT on 501', () async {
      server.supportsConditionalWrites = false;
      final bytes = bytesOf(10);
      expect(
        await backend().upload(await uploadRequest(tmp, bytes)),
        UploadResult.uploaded,
      );
      expect(server.requests.where((r) => r.startsWith('PUT')), hasLength(2));
      expect(objects()['camera/2026-11-13/IMG_0001.JPG']!.bytes, bytes);
    });

    test('an object that fails verification is not accepted', () async {
      server.intercept = (request) {
        if (request.method == 'PUT') {
          objects()['camera/2026-11-13/IMG_0001.JPG'] = S3Object(
            bytesOf(4),
            const {},
          );
          return Response.ok(null);
        }
        return null;
      };
      await expectLater(
        backend().upload(await uploadRequest(tmp, bytesOf(10))),
        throwsA(
          isA<StorageException>()
              .having((e) => e.message, 'message', contains('verified'))
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });

    test('a failing PUT is reported', () async {
      server.intercept = (request) =>
          request.method == 'PUT' ? Response(507) : null;
      await expectLater(
        backend().upload(await uploadRequest(tmp, bytesOf(10))),
        throwsA(isA<StorageException>().having((e) => e.retryable, 'r', true)),
      );
    });

    test('a failing HEAD is reported', () async {
      server.intercept = (request) =>
          request.method == 'HEAD' ? Response.forbidden(null) : null;
      await expectLater(
        backend().upload(await uploadRequest(tmp, bytesOf(10))),
        throwsA(isA<StorageException>().having((e) => e.retryable, 'r', false)),
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
        Object? error;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            expect(await b.upload(request), UploadResult.uploaded);
            break;
          } on StorageException catch (e) {
            error = e;
            expect(e.retryable, isTrue);
          }
        }
        expect(error, isNotNull);
        expect(proxy.drops, 1);
        expect(objects()['camera/2026-11-13/IMG_0001.JPG']!.bytes, bytes);
      },
    );
  });

  group('TLS trust on first use', () {
    late S3TestServer tlsServer;

    setUp(() async => tlsServer = await S3TestServer.start(tls: true));
    tearDown(() => tlsServer.close());

    test('an untrusted certificate reports its fingerprint', () async {
      await expectLater(
        backend(scheme: 'https', port: tlsServer.port).testConnection(),
        throwsA(
          isA<UntrustedCertificateException>().having(
            (e) => e.fingerprint,
            'fingerprint',
            await testCertificateFingerprint(),
          ),
        ),
      );
    });

    test('a pinned certificate is accepted', () async {
      final b = backend(
        scheme: 'https',
        port: tlsServer.port,
        pin: await testCertificateFingerprint(),
      );
      await b.testConnection();
      expect(
        await b.upload(await uploadRequest(tmp, bytesOf(10))),
        UploadResult.uploaded,
      );
    });
  });
}
