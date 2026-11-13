import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink_server/src/pages.dart';
import 'package:shutterlink_server/src/tips.dart';
import 'package:test/test.dart';

import 'support.dart';

final List<Tip> _tips = [
  Tip.parse('PayPal=https://paypal.me/example'),
  Tip.parse('TWINT <fast>=https://example.com/twint?a=1&b=2'),
];

void main() {
  late TestApp server;

  tearDown(() => server.close());

  group('without tips', () {
    setUp(() async => server = await TestApp.open());

    test('isolates Sessions', () async {
      final a = photoBytes(1);
      final b = photoBytes(2);
      await server.upload(codeA, a);
      await server.upload(codeB, b);

      final pageA = await bodyText(await server.get('/s/$codeA'));
      expect(pageA, contains('/s/$codeA/p/${keyOf(a)}.jpg'));
      expect(pageA, isNot(contains(keyOf(b))));
      final pageB = await bodyText(await server.get('/s/$codeB'));
      expect(pageB, contains(keyOf(b)));
      expect(pageB, isNot(contains(keyOf(a))));
    });

    test('unknown and empty codes are byte-equal "on their way"', () async {
      await server.upload(codeA, photoBytes(1));
      final emptyDir = Directory(
        p.join(
          server.dataDir.path,
          'sessions',
          server.app.store.dirName(codeB),
        ),
      );
      await Directory(p.join(emptyDir.path, 'photos')).create(recursive: true);
      await File(p.join(emptyDir.path, 'created'))
          .writeAsString(t0.toIso8601String());
      final unknown = await server.get('/s/$unknownCode');
      final empty = await server.get('/s/$codeB');
      expect(unknown.statusCode, 200);
      expect(empty.statusCode, 200);
      expect(await bodyBytes(unknown), onTheirWayPage);
      expect(await bodyBytes(empty), onTheirWayPage);
      expect(String.fromCharCodes(onTheirWayPage), contains('on their way'));
    });

    test('downloads single photos and all.zip', () async {
      final a1 = photoBytes(1);
      final a2 = photoBytes(2, 3000);
      await server.upload(codeA, a1);
      await server.upload(codeA, a2);

      final single = await server.get('/s/$codeA/p/${keyOf(a2)}.jpg');
      expect(single.statusCode, 200);
      expect(single.headers['content-type'], 'image/jpeg');
      expect(await bodyBytes(single), a2);

      final zip = await server.get('/s/$codeA/all.zip');
      expect(zip.headers['content-type'], 'application/zip');
      final archive = ZipDecoder().decodeBytes(await bodyBytes(zip));
      final contents = {for (final f in archive.files) f.name: f.content};
      expect(
        contents.keys,
        unorderedEquals(['${keyOf(a1)}.jpg', '${keyOf(a2)}.jpg']),
      );
      expect(contents['${keyOf(a1)}.jpg'], a1);
      expect(contents['${keyOf(a2)}.jpg'], a2);
    });

    test('shows the expiry date 30 days after the first upload', () async {
      await server.upload(codeA, photoBytes(1));
      server.now.now = t0.add(const Duration(days: 3));
      await server.upload(codeA, photoBytes(2));
      final page = await bodyText(await server.get('/s/$codeA'));
      expect(
        page,
        contains(
          '<time datetime="2026-12-13T10:00:00Z">13 December 2026 (UTC)</time>',
        ),
      );
    });

    test('no tip section without tips', () async {
      await server.upload(codeA, photoBytes(1));
      final page = await bodyText(await server.get('/s/$codeA'));
      expect(page, isNot(contains('class="tips"')));
    });

    test('landing page has a code form and /s redirects', () async {
      final landing = await bodyText(await server.get('/'));
      expect(landing, contains('<form action="/s" method="get">'));
      expect(landing, contains('Enter your code'));
      final redirect = await server.get('/s?code=Apple-Banana-Cherry-Delta');
      expect(redirect.statusCode, 303);
      expect(redirect.headers['location'], '/s/$codeA');
    });

    test('serves the stylesheet', () async {
      final css = await server.get('/static/app.css');
      expect(css.statusCode, 200);
      expect(css.headers['content-type'], startsWith('text/css'));
    });
  });

  test('tip links are rendered escaped and never gate downloads', () async {
    final bytes = photoBytes(1);
    server = await TestApp.open();
    await server.upload(codeA, bytes);
    final plainPhoto = await bodyBytes(
      await server.get('/s/$codeA/p/${keyOf(bytes)}.jpg'),
    );
    final plainZip = await bodyBytes(await server.get('/s/$codeA/all.zip'));
    await server.close();

    server = await TestApp.open(tips: _tips);
    await server.upload(codeA, bytes);
    final page = await bodyText(await server.get('/s/$codeA'));
    expect(page, contains('class="tips"'));
    expect(page, contains('href="https://paypal.me/example"'));
    expect(page, contains('>PayPal</a>'));
    expect(page, contains('href="https://example.com/twint?a=1&amp;b=2"'));
    expect(page, contains('>TWINT &lt;fast&gt;</a>'));
    expect(
      await bodyBytes(await server.get('/s/$codeA/p/${keyOf(bytes)}.jpg')),
      plainPhoto,
    );
    expect(await bodyBytes(await server.get('/s/$codeA/all.zip')), plainZip);
  });
}
