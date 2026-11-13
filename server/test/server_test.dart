import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:shutterlink_server/shutterlink_server.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('serves uploads and galleries over HTTP in-process', () async {
    final dataDir = await tempDataDir();
    final server = await ShutterlinkServer.start(
      dataDir: dataDir,
      uploadToken: uploadToken,
      tips: [Tip.parse('PayPal=https://paypal.me/example')],
      clock: Clock.fixed(t0),
    );
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.close();
      await dataDir.delete(recursive: true);
    });
    expect(server.url.host, '127.0.0.1');
    expect(server.url.port, isNonZero);

    final bytes = photoBytes(1);
    final put = await client.openUrl(
      'PUT',
      server.url.resolve('/api/sessions/$codeA/photos/${keyOf(bytes)}'),
    );
    put.headers.set(HttpHeaders.authorizationHeader, 'Bearer $uploadToken');
    put.add(bytes);
    final putResponse = await put.close();
    expect(putResponse.statusCode, 201);
    expect(jsonDecode(await utf8.decodeStream(putResponse)), {
      'expiresAt': '2026-12-13T10:00:00.000Z',
    });

    final page = await client.getUrl(server.url.resolve('/s/$codeA'));
    final pageResponse = await page.close();
    expect(pageResponse.statusCode, 200);
    final html = await utf8.decodeStream(pageResponse);
    expect(html, contains(keyOf(bytes)));
    expect(html, contains('https://paypal.me/example'));
  });
}
