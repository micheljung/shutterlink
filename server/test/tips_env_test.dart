import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'process_support.dart';
import 'support.dart';

const int _usageExitCode = 64;

void main() {
  late Directory dataDir;

  setUp(() async => dataDir = await tempDataDir());
  tearDown(() => dataDir.delete(recursive: true));

  /// Starts the server, uploads one photo to [codeA] and returns its gallery.
  Future<String> galleryWith({
    List<String> arguments = const [],
    required String tips,
  }) async {
    final server = await ServerProcess.start(
      dataDir,
      arguments: arguments,
      environment: {'SHUTTERLINK_TIPS': tips},
    );
    addTearDown(server.kill);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final bytes = photoBytes(1);
    final put = await client.openUrl(
      'PUT',
      server.url.resolve('/api/sessions/$codeA/photos/${keyOf(bytes)}'),
    );
    put.headers.set(HttpHeaders.authorizationHeader, 'Bearer $uploadToken');
    put.add(bytes);
    final putResponse = await put.close();
    await putResponse.drain<void>();
    expect(putResponse.statusCode, HttpStatus.created);

    final get = await client.getUrl(server.url.resolve('/s/$codeA'));
    final response = await get.close();
    expect(response.statusCode, HttpStatus.ok);
    return utf8.decodeStream(response);
  }

  test('shows every tip from SHUTTERLINK_TIPS, in order', () async {
    final page = await galleryWith(
      tips:
          'PayPal=https://example.com/paypal\nTWINT=https://example.com/twint',
    );

    final paypal = page.indexOf('https://example.com/paypal');
    final twint = page.indexOf('https://example.com/twint');
    expect(paypal, isNonNegative);
    expect(twint, greaterThan(paypal));
    expect(page, contains('PayPal'));
    expect(page, contains('TWINT'));
  });

  test('a --tip flag replaces SHUTTERLINK_TIPS', () async {
    final page = await galleryWith(
      arguments: ['--tip', 'Flag=https://example.com/flag'],
      tips: 'Env=https://example.com/env',
    );

    expect(page, contains('https://example.com/flag'));
    expect(page, isNot(contains('https://example.com/env')));
  });

  test('tolerates blank lines and CRLF line endings', () async {
    final page = await galleryWith(
      tips:
          '\r\n  PayPal=https://example.com/paypal  \r\n\r\n'
          'TWINT=https://example.com/twint\r\n',
    );

    expect(page, contains('href="https://example.com/paypal"'));
    expect(page, contains('href="https://example.com/twint"'));
  });

  test('refuses a javascript: URL in SHUTTERLINK_TIPS', () async {
    final result = await runServer(
      ['--data-dir', dataDir.path],
      environment: {
        'SHUTTERLINK_UPLOAD_TOKEN': uploadToken,
        'SHUTTERLINK_TIPS':
            'PayPal=https://example.com/paypal\nPay=javascript:alert(1)',
      },
    );

    expect(result.exitCode, _usageExitCode, reason: '${result.stderr}');
    expect('${result.stderr}', contains('Invalid SHUTTERLINK_TIPS'));
  });
}
