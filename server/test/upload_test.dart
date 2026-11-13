import 'package:shutterlink_server/src/limits.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestApp server;

  setUp(() async => server = await TestApp.open(maxSessionBytes: 5000));
  tearDown(() => server.close());

  test('rejects missing or wrong tokens with 401 JSON', () async {
    final bytes = photoBytes(1);
    for (final token in [null, 'wrong', '']) {
      final response = await server.call(
        putRequest(codeA, keyOf(bytes), bytes, token: token),
      );
      expect(response.statusCode, 401);
      expect(await bodyJson(response), {'error': 'unauthorized'});
    }
    expect(await server.app.store.snapshot(codeA), isNull);
  });

  test('stores once and re-PUT is idempotent', () async {
    final bytes = photoBytes(1);
    final first = await server.upload(codeA, bytes);
    expect(first.statusCode, 201);
    final expiresAt = t0.add(defaultRetention).toIso8601String();
    expect(await bodyJson(first), {'expiresAt': expiresAt});

    server.now.now = t0.add(const Duration(days: 1));
    final second = await server.upload(codeA, bytes);
    expect(second.statusCode, 200);
    expect(await bodyJson(second), {'expiresAt': expiresAt});
    expect((await server.app.store.snapshot(codeA))!.photos, hasLength(1));
  });

  test('normalizes the code', () async {
    final bytes = photoBytes(1);
    final response = await server.upload('Apple-Banana-Cherry-Delta', bytes);
    expect(response.statusCode, 201);
    expect((await server.app.store.snapshot(codeA))!.photos, hasLength(1));
  });

  test('sha_mismatch', () async {
    final response = await server.call(
      putRequest(codeA, keyOf(photoBytes(2)), photoBytes(1)),
    );
    expect(response.statusCode, 400);
    expect(await bodyJson(response), {'error': 'sha_mismatch'});
  });

  test('too_large when streamed without Content-Length', () async {
    final bytes = photoBytes(1, 4097);
    final response = await server.call(
      putRequest(codeA, keyOf(bytes), bytes, withLength: false),
    );
    expect(response.statusCode, 413);
    expect(await bodyJson(response), {'error': 'too_large'});
  });

  test('too_large from Content-Length without reading the body', () async {
    final bytes = photoBytes(1, 4097);
    final response = await server.call(putRequest(codeA, keyOf(bytes), bytes));
    expect(response.statusCode, 413);
    expect(await bodyJson(response), {'error': 'too_large'});
  });

  test('session_full', () async {
    expect((await server.upload(codeA, photoBytes(1, 3000))).statusCode, 201);
    final response = await server.upload(codeA, photoBytes(2, 3000));
    expect(response.statusCode, 413);
    expect(await bodyJson(response), {'error': 'session_full'});
    expect((await server.upload(codeB, photoBytes(2, 3000))).statusCode, 201);
  });

  test('bad_code and bad_key', () async {
    final bytes = photoBytes(1);
    final badCode = await server.call(
      putRequest('not-a-code', keyOf(bytes), bytes),
    );
    expect(badCode.statusCode, 400);
    expect(await bodyJson(badCode), {'error': 'bad_code'});
    final badKey = await server.call(putRequest(codeA, 'abc', bytes));
    expect(badKey.statusCode, 400);
    expect(await bodyJson(badKey), {'error': 'bad_key'});
  });

  test('410 expired after purge', () async {
    expect((await server.upload(codeA, photoBytes(1))).statusCode, 201);
    server.now.now = t0.add(const Duration(days: 31));
    await server.app.store.purgeExpired();
    final response = await server.upload(codeA, photoBytes(2));
    expect(response.statusCode, 410);
    expect(await bodyJson(response), {'error': 'expired'});
  });

  test('concurrent PUTs to one code respect maxSessionBytes', () async {
    final responses = await Future.wait([
      for (var i = 0; i < 6; i++) server.upload(codeA, photoBytes(i, 2000)),
    ]);
    final statuses = responses.map((r) => r.statusCode).toList();
    expect(statuses.where((s) => s == 201), hasLength(2));
    expect(statuses.where((s) => s == 413), hasLength(4));
    final stored = (await server.app.store.snapshot(codeA))!.photos;
    expect(stored.fold<int>(0, (sum, p) => sum + p.size), 4000);
  });
}
