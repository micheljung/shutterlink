import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shutterlink_server/src/app.dart';
import 'package:shutterlink_server/src/pages.dart';
import 'package:shutterlink_server/src/tips.dart';
import 'package:test/test.dart';

import 'support.dart';

const String _codeC = 'lunar-magic-noble-ocean';
const Duration _day = Duration(days: 1);

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
          '/s/$codeA/../secret',
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
      final bytes = photoBytes(1);
      await server.upload(codeA, bytes);
      for (final path in [
        '/s/$codeB/p/${keyOf(bytes)}.jpg',
        '/s/$codeB/all.zip',
        '/s/$codeB',
      ]) {
        expect(await bodyBytes(await server.get(path)), onTheirWayPage);
      }
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
      final bytes = photoBytes(1);
      await server.upload(codeA, bytes);
      final responses = <Response>[
        await server.get('/'),
        await server.get('/s/$codeA'),
        await server.get('/s/$unknownCode'),
        await server.get('/s/$codeA/p/${keyOf(bytes)}.jpg'),
        await server.get('/s/$codeA/all.zip'),
        await server.get('/static/app.css'),
        await server.get('/s?code=$codeA'),
        await server.call(putRequest(codeA, keyOf(bytes), bytes, token: 'x')),
        await server.call(Request('POST', origin.resolve('/'))),
      ];
      for (final response in responses) {
        for (final MapEntry(:key, :value) in securityHeaders.entries) {
          expect(response.headers[key], value);
        }
        await bodyBytes(response);
      }
      expect(
        securityHeaders['content-security-policy'],
        "default-src 'none'; img-src 'self'; style-src 'self'; "
        "form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      );
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
