import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/sessions_upload_queue.dart';
import 'package:shutterlink/data/upload_client.dart';
import 'package:shutterlink/upload/storage_backend.dart';

const _idle = Duration(milliseconds: 200);
const _chunkSize = 64 * 1024;
const _chunks = 8;

void main() {
  const code = 'apple-bread-cider-dough';
  const html = '<html><body>413 Request Entity Too Large</body></html>';
  final expiresAt = DateTime.utc(2026, 12, 13, 10);
  final expiresJson = '{"expiresAt":"${expiresAt.toIso8601String()}"}';

  group('classify', () {
    test('2xx with expiresAt is done', () {
      for (final status in [HttpStatus.ok, HttpStatus.created]) {
        final result = UploadClient.classify(status, expiresJson);
        expect(result, isA<UploadDone>());
        expect((result as UploadDone).expiresAt, expiresAt);
      }
    });

    for (final (description, status, body, type) in [
      ('2xx without JSON', 200, 'OK', isA<UploadMisconfigured>()),
      ('410 expired', 410, '{"error":"expired"}', isA<UploadExpired>()),
      ('bare 410', 410, '', isA<UploadMisconfigured>()),
      ('401', 401, '{"error":"unauthorized"}', isA<UploadUnauthorized>()),
      ('bare 401', 401, '', isA<UploadUnauthorized>()),
      (
        '400 sha_mismatch',
        400,
        '{"error":"sha_mismatch"}',
        isA<UploadRejected>(),
      ),
      ('400 bad_code', 400, '{"error":"bad_code"}', isA<UploadRejected>()),
      ('400 bad_key', 400, '{"error":"bad_key"}', isA<UploadRejected>()),
      ('413 too_large', 413, '{"error":"too_large"}', isA<UploadRejected>()),
      (
        '413 session_full',
        413,
        '{"error":"session_full"}',
        isA<UploadRejected>(),
      ),
      ('bare nginx 413', 413, html, isA<UploadMisconfigured>()),
      (
        '400 unknown error',
        400,
        '{"error":"nope"}',
        isA<UploadMisconfigured>(),
      ),
      ('408', 408, '', isA<UploadRetry>()),
      ('429', 429, '', isA<UploadRetry>()),
      ('500', 500, '', isA<UploadRetry>()),
      ('503', 503, html, isA<UploadRetry>()),
      ('301', 301, '', isA<UploadMisconfigured>()),
      ('403', 403, '', isA<UploadMisconfigured>()),
      ('404', 404, '', isA<UploadMisconfigured>()),
      ('418', 418, '', isA<UploadMisconfigured>()),
    ]) {
      test(description, () {
        expect(UploadClient.classify(status, body), type);
      });
    }
  });

  group('checkToken', () {
    final serverUrl = Uri.parse('https://example.com/shutterlink/');

    for (final (description, status, body, expected) in [
      ('204', HttpStatus.noContent, '', TokenCheck.valid),
      (
        '401',
        HttpStatus.unauthorized,
        '{"error":"unauthorized"}',
        TokenCheck.rejected,
      ),
      ('404', HttpStatus.notFound, '', TokenCheck.unsupported),
      ('HTML of an old server', HttpStatus.ok, html, TokenCheck.unsupported),
      ('502', HttpStatus.badGateway, html, TokenCheck.unsupported),
    ]) {
      test('maps $description', () async {
        late http.Request sent;
        final result = await const UploadClient().checkToken(
          MockClient((request) async {
            sent = request;
            return http.Response(body, status);
          }),
          serverUrl: serverUrl,
          token: 'secret',
        );
        expect(result, expected);
        expect(sent.method, 'GET');
        expect(sent.url.toString(), 'https://example.com/shutterlink/api/auth');
        expect(sent.headers['authorization'], 'Bearer secret');
      });
    }

    for (final (description, error) in [
      ('a socket error', const SocketException('refused')),
      ('a client error', http.ClientException('closed')),
      ('a TLS failure', const HandshakeException('certificate expired')),
      ('a generic TLS error', const TlsException('bad record')),
      (
        'a network policy error',
        const StorageException('Waiting for a network.'),
      ),
    ]) {
      test('maps $description to unreachable', () async {
        final result = await const UploadClient().checkToken(
          MockClient((_) async => throw error),
          serverUrl: serverUrl,
          token: 'secret',
        );
        expect(result, TokenCheck.unreachable);
      });
    }

    test('maps a timeout to unreachable', () async {
      final result = await const UploadClient().checkToken(
        MockClient((_) => Completer<http.Response>().future),
        serverUrl: serverUrl,
        token: 'secret',
        timeout: _idle,
      );
      expect(result, TokenCheck.unreachable);
    });
  });

  test('builds the photo URL under a path prefix', () {
    expect(
      UploadClient.photoUrl(
        Uri.parse('https://example.com/shutterlink/'),
        code,
        'ab',
      ).toString(),
      'https://example.com/shutterlink/api/sessions/$code/photos/ab',
    );
  });

  group('upload', () {
    late Directory root;
    late UploadItem item;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('upload_client');
      final file = File(p.join(root.path, 'a.jpg'))
        ..writeAsBytesSync([1, 2, 3]);
      item = UploadItem(
        photoKey: await SessionsUploadQueue.photoKeyOf(file),
        sessionCode: code,
        filePath: file.path,
        enqueuedAt: expiresAt,
        nextAttemptAt: expiresAt,
      );
    });

    tearDown(() => root.delete(recursive: true));

    test('PUTs the file with the bearer token', () async {
      late http.Request received;
      final client = MockClient((request) async {
        received = request;
        return http.Response(expiresJson, HttpStatus.created);
      });

      final result = await const UploadClient().upload(
        client,
        serverUrl: Uri.parse('https://example.com'),
        token: 'secret',
        item: item,
      );

      expect(result, isA<UploadDone>());
      expect(received.method, 'PUT');
      expect(
        received.url.toString(),
        'https://example.com/api/sessions/$code/photos/${item.photoKey}',
      );
      expect(received.headers['authorization'], 'Bearer secret');
      expect(received.bodyBytes, [1, 2, 3]);
    });

    test('a socket error is retried', () async {
      final result = await const UploadClient().upload(
        MockClient((_) => throw const SocketException('unreachable')),
        serverUrl: Uri.parse('https://example.com'),
        token: 'secret',
        item: item,
      );

      expect(result, isA<UploadRetry>());
    });

    for (final (description, error, type) in [
      ('no network is retried', const NoNetworkException(), isA<UploadRetry>()),
      (
        'an untrusted certificate needs the server fixed',
        const UntrustedCertificateException('ab'),
        isA<UploadMisconfigured>(),
      ),
    ]) {
      test(description, () async {
        final result = await const UploadClient().upload(
          MockClient((_) => throw error),
          serverUrl: Uri.parse('https://example.com'),
          token: 'secret',
          item: item,
        );

        expect(result, type);
      });
    }

    test('a missing file is rejected', () async {
      File(item.filePath).deleteSync();

      final result = await const UploadClient().upload(
        MockClient((_) async => http.Response(expiresJson, HttpStatus.ok)),
        serverUrl: Uri.parse('https://example.com'),
        token: 'secret',
        item: item,
      );

      expect(result, isA<UploadRejected>());
    });

    test('a server that stops answering times out', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) => request.drain<void>());
      final client = http.Client();
      addTearDown(() async {
        client.close();
        await server.close(force: true);
      });

      final result = await const UploadClient(idleTimeout: _idle).upload(
        client,
        serverUrl: Uri.parse('http://127.0.0.1:${server.port}'),
        token: 'secret',
        item: item,
      );

      expect(result, isA<UploadRetry>());
      expect(result.status, 'timeout');
    });

    test('an upload that keeps sending outlasts the idle timeout', () async {
      final chunk = List.filled(_chunkSize, 1);
      final file = File(item.filePath)
        ..writeAsBytesSync([for (var i = 0; i < _chunks; i++) ...chunk]);
      final big = UploadItem(
        photoKey: await SessionsUploadQueue.photoKeyOf(file),
        sessionCode: code,
        filePath: file.path,
        enqueuedAt: expiresAt,
        nextAttemptAt: expiresAt,
      );
      final client = MockClient.streaming((request, body) async {
        await for (final _ in body) {
          await Future<void>.delayed(_idle ~/ 2);
        }
        return http.StreamedResponse(
          Stream.value(utf8.encode(expiresJson)),
          HttpStatus.created,
        );
      });

      final result = await const UploadClient(idleTimeout: _idle).upload(
        client,
        serverUrl: Uri.parse('https://example.com'),
        token: 'secret',
        item: big,
      );

      expect(result, isA<UploadDone>());
    });

    test('a file that cannot be read is rejected, not timed out', () async {
      final file = File(item.filePath);
      await Process.run('chmod', ['000', file.path]);
      addTearDown(() => Process.run('chmod', ['600', file.path]));
      final result = await const UploadClient(idleTimeout: _idle).upload(
        MockClient.streaming((request, body) async {
          await body.drain<void>();
          return http.StreamedResponse(
            Stream.value(utf8.encode(expiresJson)),
            HttpStatus.created,
          );
        }),
        serverUrl: Uri.parse('https://example.com'),
        token: 'secret',
        item: item,
      );

      expect(result, isA<UploadRejected>());
      expect(result.status, 'missing_file');
    });
  });
}
