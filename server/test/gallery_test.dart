import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink_server/src/limits.dart' as limits;
import 'package:shutterlink_server/src/pages.dart';
import 'package:shutterlink_server/src/tips.dart';
import 'package:shutterlink_server/src/web_assets.g.dart';
import 'package:test/test.dart';

import 'support.dart';

final List<Tip> _tips = [
  Tip.parse('PayPal=https://paypal.me/example'),
  Tip.parse('TWINT <fast>=https://example.com/twint?a=1&b=2'),
];

const String _noCache = 'no-cache';

String _versioned(String file) => '/static/$file?v=${webAssets[file]!.version}';

String _text(String html) => html.replaceAll(RegExp('<[^>]*>'), '');

Directory _sessionDir(TestApp server, String code) => Directory(
  p.join(server.dataDir.path, 'sessions', server.app.store.dirName(code)),
);

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
      expect(css.headers['cache-control'], _noCache);
      expect(await bodyBytes(css), webAssets['app.css']!.bytes);
    });

    test('tiles work without JS and show their preview state', () async {
      final ready = jpegBytes(1);
      final failed = photoBytes(2);
      final pending = jpegBytes(3);
      for (final bytes in [ready, failed, pending]) {
        await server.upload(codeA, bytes);
      }
      await server.awaitPreviews();
      await for (final entity in Directory(
        p.join(_sessionDir(server, codeA).path, 'previews'),
      ).list()) {
        if (p.basename(entity.path).startsWith(keyOf(pending))) {
          await entity.delete();
        }
      }
      final page = await bodyText(await server.get('/s/$codeA'));
      final base = '/s/$codeA';
      final tiles = RegExp(r'<li>.*?</li>').allMatches(page).toList();
      expect(tiles, hasLength(3));
      for (final bytes in [ready, failed, pending]) {
        final key = keyOf(bytes);
        expect(
          tiles.where(
            (t) => t[0]!.startsWith(
              '<li><a href="$base/p/$key.jpg" download="$key.jpg"',
            ),
          ),
          hasLength(1),
        );
      }
      final readyKey = keyOf(ready);
      expect(
        page,
        contains(
          '<li><a href="$base/p/$readyKey.jpg" download="$readyKey.jpg" '
          'data-pswp-src="$base/v/$readyKey.jpg" '
          'data-pswp-width="48" data-pswp-height="48">'
          '<img src="$base/t/$readyKey.jpg" alt="Photo',
        ),
      );
      final pendingTile = tiles.singleWhere(
        (t) => t[0]!.contains(keyOf(pending)),
      )[0]!;
      final failedTile = tiles.singleWhere(
        (t) => t[0]!.contains(keyOf(failed)),
      )[0]!;
      for (final tile in [pendingTile, failedTile]) {
        expect(tile, isNot(contains('<img')));
        expect(tile, isNot(contains('data-pswp')));
      }
      expect(pendingTile, contains('class="placeholder pending"'));
      expect(failedTile, contains('class="placeholder failed"'));
      expect(_text(pendingTile), isNotEmpty);
      expect(_text(failedTile), isNotEmpty);
      expect(_text(pendingTile), isNot(_text(failedTile)));
      expect(
        page,
        contains(
          '<a class="button" href="$base/all.zip" download>'
          'Download all (<span data-count>3</span>)</a>',
        ),
      );
      expect(page, isNot(contains('style=')));
      expect(page, isNot(contains(RegExp('<script(?! type="module" src=)'))));
    });

    test('loads the first images eagerly and the rest lazily', () async {
      const photos = 10;
      for (var i = 0; i < photos; i++) {
        await server.upload(codeA, jpegBytes(i));
      }
      await server.awaitPreviews();
      final page = await bodyText(await server.get('/s/$codeA'));
      final loading = RegExp(r'loading="(\w+)" decoding="async"')
          .allMatches(page)
          .map((m) => m[1])
          .toList();
      expect(loading, hasLength(photos));
      expect(loading.take(8), everyElement('eager'));
      expect(loading.skip(8), everyElement('lazy'));
    });

    test('the live attributes match photos.json', () async {
      await server.upload(codeA, jpegBytes(1));
      await server.awaitPreviews();
      final page = await bodyText(await server.get('/s/$codeA'));
      final json = await server.get('/s/$codeA/photos.json');
      await bodyBytes(json);
      expect(
        page,
        contains(
          '<ul class="photos" data-live="/s/$codeA/photos.json" '
          'data-events="/s/$codeA/events" '
          'data-generation="${json.headers['etag']!.replaceAll('"', '')}">',
        ),
      );
    });

    test('pages link versioned assets', () async {
      await server.upload(codeA, photoBytes(1));
      final gallery = await bodyText(await server.get('/s/$codeA'));
      for (final file in ['app.css', 'photoswipe.css']) {
        expect(
          gallery,
          contains('<link rel="stylesheet" href="${_versioned(file)}">'),
        );
      }
      expect(
        gallery,
        contains(
          '<script type="module" src="${_versioned('gallery.js')}"></script>',
        ),
      );
      for (final page in [
        await bodyText(await server.get('/')),
        utf8.decode(onTheirWayPage),
        gallery,
      ]) {
        expect(page, contains(_versioned('app.css')));
        expect(page, contains('<span class="wordmark">shutterlink</span>'));
        expect(page, contains('<svg aria-hidden="true"'));
        expect(page, isNot(contains('style=')));
      }
    });

    test('static files are immutable only at their version', () async {
      for (final MapEntry(key: file, value: asset) in webAssets.entries) {
        final current = await server.get(_versioned(file));
        expect(current.statusCode, 200, reason: file);
        expect(current.headers['content-type'], asset.contentType);
        expect(
          current.headers['cache-control'],
          'public, max-age=31536000, immutable',
        );
        expect(await bodyBytes(current), asset.bytes);
        for (final path in [
          '/static/$file',
          '/static/$file?v=000000000000',
          '/static/$file?v=${asset.version}x',
        ]) {
          final stale = await server.get(path);
          expect(stale.headers['cache-control'], _noCache, reason: path);
          expect(await bodyBytes(stale), asset.bytes);
        }
      }
      expect(
        webAssets['gallery.js']!.contentType,
        startsWith('text/javascript'),
      );
      expect(webAssets['manrope-800.woff2']!.contentType, 'font/woff2');
      for (final path in [
        '/static/missing.js',
        '/static/PHOTOSWIPE-LICENSE',
        '/static/..%2Fpubspec.yaml',
        '/static/',
      ]) {
        final response = await server.get(path);
        expect(response.headers['cache-control'], 'no-store', reason: path);
        expect(await bodyBytes(response), onTheirWayPage, reason: path);
      }
    });

    test('a deleted photo is gone from every view', () async {
      final kept = jpegBytes(1);
      final deleted = jpegBytes(2);
      await server.upload(codeA, kept);
      await server.upload(codeA, deleted);
      await server.awaitPreviews();
      final key = keyOf(deleted);
      final page = await bodyText(await server.get('/s/$codeA'));
      final urls = [
        for (final kind in ['p', 't', 'v']) '/s/$codeA/$kind/$key.jpg',
      ];
      for (final url in urls) {
        expect(page, contains('"$url"'));
        final before = await server.get(url);
        expect(before.headers['content-type'], 'image/jpeg', reason: url);
        await bodyBytes(before);
      }

      final response = await server.post('/s/$codeA/p/$key/delete');
      expect(response.statusCode, 204);
      expect(await bodyBytes(response), isEmpty);

      for (final url in urls) {
        final after = await server.get(url);
        expect(after.headers['content-type'], startsWith('text/html'));
        expect(await bodyBytes(after), onTheirWayPage, reason: url);
      }
      final json = await bodyJson(await server.get('/s/$codeA/photos.json'));
      expect(json['count'], 1);
      expect((json['photos']! as List).map((p) => (p as Map)['key']), [
        keyOf(kept),
      ]);
      final zip = await server.get('/s/$codeA/all.zip');
      final archive = ZipDecoder().decodeBytes(await bodyBytes(zip));
      expect(archive.files.map((f) => f.name), ['${keyOf(kept)}.jpg']);
      final after = await bodyText(await server.get('/s/$codeA'));
      expect(after, isNot(contains(key)));
    });

    test('a deleted Session looks like an unknown code', () async {
      final bytes = jpegBytes(1);
      await server.upload(codeA, bytes);
      await server.awaitPreviews();
      final sessionDir = _sessionDir(server, codeA);

      final response = await server.post('/s/$codeA/delete');
      expect(response.statusCode, 204);
      expect(await sessionDir.exists(), isFalse);
      expect(
        await File(
          p.join(
            server.dataDir.path,
            'tombstones',
            server.app.store.dirName(codeA),
          ),
        ).exists(),
        isTrue,
      );

      for (final path in [
        '',
        '/p/${keyOf(bytes)}.jpg',
        '/t/${keyOf(bytes)}.jpg',
        '/all.zip',
      ]) {
        expect(
          await bodyBytes(await server.get('/s/$codeA$path')),
          onTheirWayPage,
          reason: path,
        );
      }
      for (final path in ['/photos.json', '/events']) {
        final deleted = await server.get('/s/$codeA$path');
        final unknown = await server.get('/s/$unknownCode$path');
        expect(deleted.statusCode, unknown.statusCode, reason: path);
        expect(deleted.headers, unknown.headers, reason: path);
        if (path == '/events') {
          expect(await deleted.read().first, await unknown.read().first);
        } else {
          expect(await bodyText(deleted), await bodyText(unknown));
        }
      }
    });

    test('deleting unknown codes and photos answers like success', () async {
      final bytes = photoBytes(1);
      await server.upload(codeA, bytes);
      final key = keyOf(bytes);
      final otherKey = keyOf(photoBytes(2));
      for (final path in [
        '/s/$unknownCode/p/$key/delete',
        '/s/$codeA/p/$otherKey/delete',
        '/s/$codeA/p/not-a-key/delete',
        '/s/not-a-code/p/$key/delete',
        '/s/$unknownCode/delete',
        '/s/not-a-code/delete',
      ]) {
        final response = await server.post(path);
        expect(response.statusCode, 204, reason: path);
        expect(await bodyBytes(response), isEmpty, reason: path);
      }
      for (final path in [
        '/s/$unknownCode/p/$key/delete',
        '/s/$codeA/p/$otherKey/delete',
        '/s/$unknownCode/delete',
      ]) {
        final response = await server.post(path, formPost);
        expect(response.statusCode, 303, reason: path);
        expect(
          response.headers['location'],
          path.startsWith('/s/$codeA') ? '/s/$codeA' : '/s/$unknownCode',
        );
      }
      expect(await server.app.store.photo(codeA, key), isNotNull);
      expect(
        await Directory(p.join(server.dataDir.path, 'tombstones'))
            .list()
            .isEmpty,
        isTrue,
      );
    });

    test('the delete forms work without JS', () async {
      final kept = photoBytes(1);
      final deleted = photoBytes(2);
      await server.upload(codeA, kept);
      await server.upload(codeA, deleted);

      final photo = await server.post(
        '/s/Apple-Banana-Cherry-Delta/p/${keyOf(deleted)}/delete',
        formPost,
      );
      expect(photo.statusCode, 303);
      expect(photo.headers['location'], '/s/$codeA');
      expect(await server.app.store.photo(codeA, keyOf(deleted)), isNull);

      final session = await server.post('/s/$codeA/delete', formPost);
      expect(session.statusCode, 303);
      expect(session.headers['location'], '/s/$codeA');
      expect(await bodyBytes(await server.get('/s/$codeA')), onTheirWayPage);
    });

    test('the page has a delete form per tile and one for all', () async {
      final bytes = jpegBytes(1);
      await server.upload(codeA, bytes);
      await server.awaitPreviews();
      final page = await bodyText(await server.get('/s/$codeA'));
      final base = '/s/$codeA';
      final key = keyOf(bytes);
      expect(
        page,
        matches(
          RegExp(
            '<li><a href="$base/p/$key.jpg"[^>]*>.*?</a>'
            '<form class="delete" method="post" action="$base/p/$key/delete">'
            '<button type="submit" title="Delete photo" '
            'aria-label="Delete photo 1"><svg aria-hidden="true"[^<]*<path[^>]*>'
            '</svg></button></form></li>',
          ),
        ),
      );
      expect(
        page,
        contains(
          '<form class="delete-gallery" method="post" action="$base/delete">'
          '<button type="submit">Delete gallery</button></form>',
        ),
      );
    });

    test('previews are cached until the Session expires', () async {
      final bytes = jpegBytes(1);
      await server.upload(codeA, bytes);
      await server.awaitPreviews();
      const elapsed = Duration(days: 29, hours: 23, minutes: 59, seconds: 30);
      server.now.now = t0.add(elapsed);
      final remaining = (limits.defaultRetention - elapsed).inSeconds;
      for (final kind in ['t', 'v']) {
        final response = await server.get(
          '/s/$codeA/$kind/${keyOf(bytes)}.jpg',
        );
        expect(
          response.headers['cache-control'],
          'private, max-age=$remaining',
        );
        await bodyBytes(response);
      }
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
