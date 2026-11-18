import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shutterlink_server/src/app.dart';
import 'package:shutterlink_server/src/limits.dart' as limits;
import 'package:shutterlink_server/src/pages.dart';
import 'package:shutterlink_server/src/tips.dart';
import 'package:shutterlink_server/src/web_assets.g.dart';
import 'package:test/test.dart';

import 'support.dart';

const String _codeC = 'lunar-magic-noble-ocean';
const Duration _day = Duration(days: 1);
const String _noStore = 'no-store';

void main() {
  late TestApp server;

  tearDown(() => server.close());

  group('uniform responses', () {
    setUp(() async => server = await TestApp.open());

    test(
      'traversal attempts never escape and look like unknown codes',
      () async {
        final bytes = photoBytes(1);
        await server.upload(codeA, bytes);
        final key = keyOf(bytes);
        for (final path in [
          '/s/..%2F..%2Fsecret',
          '/s/$codeA/p/..%2F..%2F..%2Fsecret.jpg',
          '/s/$codeA/p/..%2Fcreated.jpg',
          '/s/$codeA/p/${key.toUpperCase()}.jpg',
          '/s/$codeA/p/$key',
          '/s/$codeA/t/..%2F..%2F..%2Fsecret.jpg',
          '/s/$codeA/t/..%2Fcreated.jpg',
          '/s/$codeA/t/${key.toUpperCase()}.jpg',
          '/s/$codeA/t/$key',
          '/s/$codeA/v/..%2F..%2F..%2Fsecret.jpg',
          '/s/$codeA/v/..%2Fphotos%2F$key.jpg',
          '/s/$codeA/v/$key.t.jpg',
          '/s/..%2F..%2Fsecret/photos.json',
          '/s/..%2F..%2Fsecret/events',
          '/s/..%2F..%2Fsecret/t/$key.jpg',
          '/s/$codeA/../secret',
          '/static/..%2F..%2Fpubspec.yaml',
          '/static/..%2Fweb_assets.g.dart',
          '/static/%2E%2E%2Fapp.css',
          '/s/..%2Fsessions/all.zip',
          '/secret',
          '/sessions',
        ]) {
          final response = await server.get(path);
          expect(response.statusCode, 200, reason: path);
          expect(await bodyBytes(response), onTheirWayPage, reason: path);
        }
        for (final (code, key) in [
          ('..%2F..%2Ftmp', keyOf(bytes)),
          (codeA, '..%2F..%2Fsecret'),
          (codeA, '${'0' * 63}%2F'),
        ]) {
          final response = await server.call(putRequest(code, key, bytes));
          expect(response.statusCode, 400);
        }
        final names = await server.dataDir
            .list(recursive: true)
            .map((e) => p.relative(e.path, from: server.dataDir.path))
            .toList();
        expect(
          names.where(
            (n) => !n.startsWith(RegExp('sessions|tombstones|tmp|secret')),
          ),
          isEmpty,
        );
      },
    );

    test('wrong code with the right key reveals nothing', () async {
      final bytes = jpegBytes(1);
      await server.upload(codeA, bytes);
      await server.awaitPreviews();
      final key = keyOf(bytes);
      for (final kind in ['t', 'v']) {
        final own = await server.get('/s/$codeA/$kind/$key.jpg');
        expect(own.headers['content-type'], 'image/jpeg');
        await bodyBytes(own);
      }
      for (final path in [
        '/s/$codeB/p/$key.jpg',
        '/s/$codeB/t/$key.jpg',
        '/s/$codeB/v/$key.jpg',
        '/s/$codeB/all.zip',
        '/s/$codeB',
      ]) {
        expect(await bodyBytes(await server.get(path)), onTheirWayPage);
      }
      final wrong = await server.get('/s/$codeB/photos.json');
      final unknown = await server.get('/s/$unknownCode/photos.json');
      expect(wrong.headers, unknown.headers);
      expect(await bodyText(wrong), await bodyText(unknown));
    });

    test('invalid ?code= renders directly and never echoes input', () async {
      for (final raw in [
        '<script>alert(1)</script>',
        '//evil.example',
        'https://evil.example/a-b-c-d',
        'apple-banana-cherry-delta%0d%0aSet-Cookie:x',
        '',
      ]) {
        final response = await server.get(
          '/s?code=${Uri.encodeQueryComponent(raw)}',
        );
        expect(response.statusCode, 200, reason: raw);
        expect(response.headers['location'], isNull);
        expect(await bodyBytes(response), onTheirWayPage);
      }
      expect((await server.get('/s')).headers['location'], isNull);
      final valid = await server.get('/s?code=%20APPLE-banana-cherry-delta%20');
      expect(valid.statusCode, 303);
      expect(valid.headers['location'], '/s/$codeA');
    });

    test('security headers on every response', () async {
      final bytes = jpegBytes(1);
      await server.upload(codeA, bytes);
      await server.awaitPreviews();
      final key = keyOf(bytes);
      final etag = (await server.get('/s/$codeA/photos.json')).headers['etag']!;
      final expiresIn = limits.defaultRetention.inSeconds;
      final responses = <(Response, String)>[
        (await server.get('/'), _noStore),
        (await server.get('/s/$codeA'), _noStore),
        (await server.get('/s/$unknownCode'), _noStore),
        (await server.get('/s/$codeA/p/$key.jpg'), _noStore),
        (await server.get('/s/$codeA/all.zip'), _noStore),
        (await server.get('/static/app.css'), 'no-cache'),
        (
          await server.get(
            '/static/app.css?v=${webAssets['app.css']!.version}',
          ),
          'public, max-age=31536000, immutable',
        ),
        (await server.get('/static/unknown.css'), _noStore),
        (await server.get('/healthz'), _noStore),
        (await server.get('/s?code=$codeA'), _noStore),
        (
          await server.call(putRequest(codeA, key, bytes, token: 'x')),
          _noStore,
        ),
        (await server.call(Request('POST', origin.resolve('/'))), _noStore),
        (await server.get('/s/$codeA/events'), _noStore),
        (
          await server.call(
            Request('HEAD', origin.resolve('/s/$codeA/events')),
          ),
          _noStore,
        ),
        (
          await server.get('/s/$codeA/t/$key.jpg'),
          'private, max-age=$expiresIn',
        ),
        (
          await server.get('/s/$codeA/v/$key.jpg'),
          'private, max-age=$expiresIn',
        ),
        (await server.get('/s/$codeA/t/${'0' * 64}.jpg'), _noStore),
        (await server.get('/s/$codeA/photos.json'), 'no-cache'),
        (await server.get('/s/$unknownCode/photos.json'), 'no-cache'),
        (
          await server.call(
            Request(
              'GET',
              origin.resolve('/s/$codeA/photos.json'),
              headers: {'if-none-match': etag},
            ),
          ),
          'no-cache',
        ),
      ];
      for (final (response, cacheControl) in responses) {
        for (final MapEntry(:key, :value) in securityHeaders.entries) {
          if (key == 'cache-control') continue;
          expect(response.headers[key], value);
        }
        expect(response.headers['cache-control'], cacheControl);
        if (response.headers['content-type'] == 'text/event-stream') {
          await response.read().first;
        } else {
          await bodyBytes(response);
        }
      }
      expect(responses.last.$1.statusCode, 304);
      expect(server.app.doorbell.openStreams, 0);
      expect(
        securityHeaders['content-security-policy'],
        "default-src 'none'; img-src 'self'; style-src 'self'; "
        "script-src 'self'; connect-src 'self'; font-src 'self'; "
        "form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      );
      expect(securityHeaders['cache-control'], _noStore);
    });

    test('no plain code or SHA-256 of the code on disk', () async {
      await server.upload(codeA, photoBytes(1));
      final plainHash = sha256.convert(utf8.encode(codeA)).toString();
      await for (final entity in server.dataDir.list(recursive: true)) {
        expect(entity.path, isNot(contains(plainHash)));
        expect(entity.path, isNot(contains(codeA)));
        if (entity is File) {
          final content = latin1.decode(await entity.readAsBytes());
          expect(content, isNot(contains(plainHash)));
          expect(content, isNot(contains(codeA)));
        }
      }
    });
  });

  group('zip limits', () {
    setUp(() async {
      server = await TestApp.open(zipQueueTimeout: const Duration(seconds: 1));
      for (final code in [codeA, codeB, _codeC]) {
        await server.upload(code, photoBytes(code.length));
      }
    });

    test('a third concurrent zip gets the same 503 for any code', () async {
      final held = [
        await server.get('/s/$codeB/all.zip'),
        await server.get('/s/$_codeC/all.zip'),
      ];
      final busy = await Future.wait([
        server.get('/s/$codeA/all.zip'),
        server.get('/s/$unknownCode/all.zip'),
        server.get('/s/not-valid/all.zip'),
      ]);
      final bodies = <String>{};
      for (final response in busy) {
        expect(response.statusCode, 503);
        expect(response.headers['retry-after'], '1');
        bodies.add(await bodyText(response));
      }
      expect(bodies, hasLength(1));

      final waiting = server.get('/s/$codeA/all.zip');
      await bodyBytes(held.first);
      final served = await waiting;
      expect(served.statusCode, 200);
      expect(served.headers['content-type'], 'application/zip');
      await bodyBytes(served);
      await bodyBytes(held.last);
    });

    test(
      'a Session purged before its build starts gives "on their way"',
      () async {
        final held = [
          await server.get('/s/$codeB/all.zip'),
          await server.get('/s/$_codeC/all.zip'),
        ];
        final waiting = server.get('/s/$codeA/all.zip');
        server.now.now = t0.add(_day * 31);
        await server.app.store.purgeExpired();
        await bodyBytes(held.first);
        final response = await waiting;
        expect(response.statusCode, 200);
        expect(await bodyBytes(response), onTheirWayPage);
        await bodyBytes(held.last);
      },
    );
  });

  test('a stalled zip download frees its slot and its Session', () async {
    const idle = Duration(milliseconds: 300);
    server = await TestApp.open(
      zipConcurrency: 1,
      zipQueueTimeout: idle ~/ 6,
      zipIdleTimeout: idle,
    );
    await server.upload(codeA, photoBytes(1));
    await server.upload(codeB, photoBytes(2));

    final stalled = await server.get('/s/$codeA/all.zip');
    expect(stalled.statusCode, 200);
    expect((await server.get('/s/$codeB/all.zip')).statusCode, 503);
    await Future<void>.delayed(idle * 2);

    final next = await server.get('/s/$codeA/all.zip');
    expect(next.statusCode, 200);
    await bodyBytes(next);
    await expectLater(bodyBytes(stalled), throwsA(isA<TimeoutException>()));
  });

  test('rejects javascript: and other non-http tips', () async {
    server = await TestApp.open();
    for (final spec in [
      'Pay=javascript:alert(1)',
      'Pay=data:text/html,x',
      'Pay=ftp://example.com',
      'Pay=https://',
      '=https://example.com',
      'no-separator',
    ]) {
      expect(() => Tip.parse(spec), throwsFormatException, reason: spec);
    }
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'bin/server.dart',
        '--data-dir',
        server.dataDir.path,
        '--tip',
        'Pay=javascript:alert(1)',
      ],
      environment: {'SHUTTERLINK_UPLOAD_TOKEN': uploadToken},
    );
    expect(result.exitCode, 64, reason: '${result.stderr}');
  });

  test('startup requires an upload token', () async {
    server = await TestApp.open();
    await expectLater(
      () => ShutterlinkApp.open(dataDir: Directory('unused'), uploadToken: ''),
      throwsArgumentError,
    );
  });
}
