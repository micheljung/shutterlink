import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink_server/src/web_assets.g.dart';
import 'package:shutterlink_server/src/web_embed.dart';
import 'package:test/test.dart';

final Directory _web = Directory('web');
final RegExp _checksumLine = RegExp(r'^([0-9a-f]{64})  (\S+)$');

void main() {
  late Map<String, List<int>> sources;

  setUpAll(() async => sources = await readWebSources(_web));

  Map<String, List<int>> withText(String name, String text) => {
    ...sources,
    name: utf8.encode(text),
  };

  String textOf(String name) => utf8.decode(sources[name]!);

  test('the embedded assets match web/', () {
    final built = buildWebAssets(sources);
    expect(webAssets.keys, webSources);
    for (final MapEntry(key: name, value: asset) in built.entries) {
      final embedded = webAssets[name]!;
      expect(embedded.bytes, asset.bytes, reason: '$name is stale');
      expect(embedded.version, asset.version, reason: name);
      expect(embedded.version, versionOf(embedded.bytes), reason: name);
      expect(embedded.contentType, asset.contentType, reason: name);
    }
  });

  test('no embedded asset holds a placeholder', () {
    for (final MapEntry(key: name, value: asset) in webAssets.entries) {
      expect(
        latin1.decode(asset.bytes),
        isNot(contains(placeholderStart)),
        reason: name,
      );
    }
  });

  test('references point at the current versions', () {
    final gallery = utf8.decode(webAssets['gallery.js']!.bytes);
    for (final vendored in [
      'photoswipe-lightbox.esm.min.js',
      'photoswipe.esm.min.js',
    ]) {
      expect(gallery, contains('$vendored?v=${webAssets[vendored]!.version}'));
    }
    final css = utf8.decode(webAssets['app.css']!.bytes);
    for (final font in ['manrope-600.woff2', 'manrope-800.woff2']) {
      expect(css, contains('/static/$font?v=${webAssets[font]!.version}'));
    }
  });

  test('PhotoSwipe is vendored unmodified', () async {
    final lines = await File(p.join(_web.path, 'PHOTOSWIPE-VERSION'))
        .readAsLines();
    expect(lines.first, contains('5.4.4'));
    final checksums = {
      for (final match in lines.skip(1).map(_checksumLine.firstMatch))
        match![2]!: match[1]!,
    };
    expect(
      checksums.keys,
      unorderedEquals([
        'photoswipe.esm.min.js',
        'photoswipe-lightbox.esm.min.js',
        'photoswipe.css',
        'PHOTOSWIPE-LICENSE',
      ]),
    );
    for (final MapEntry(key: name, value: checksum) in checksums.entries) {
      final bytes = await File(p.join(_web.path, name)).readAsBytes();
      expect(sha256.convert(bytes).toString(), checksum, reason: name);
      if (webAssets[name] case final asset?) {
        expect(sha256.convert(asset.bytes).toString(), checksum, reason: name);
      }
    }
  });

  test('a one-byte edit makes the embedded file stale', () {
    final css = textOf('app.css');
    final edited = buildWebAssets(
      withText('app.css', '${css.substring(0, css.length - 1)} '),
    );
    expect(edited['app.css']!.bytes, isNot(webAssets['app.css']!.bytes));
    expect(edited['app.css']!.version, isNot(webAssets['app.css']!.version));
  });

  test('a changed dependency changes its referrers', () {
    final edited = buildWebAssets({
      ...sources,
      'manrope-600.woff2': [...sources['manrope-600.woff2']!, 0],
    });
    expect(edited['app.css']!.version, isNot(webAssets['app.css']!.version));
    expect(edited['gallery.js']!.version, webAssets['gallery.js']!.version);
  });

  test('unresolved placeholders fail', () {
    for (final text in [
      '{{v:missing.woff2}}',
      '{{v:manrope-600.woff2',
      '{{v:}}',
    ]) {
      expect(
        () => buildWebAssets(withText('app.css', '${textOf('app.css')}$text')),
        throwsA(isA<EmbedException>()),
        reason: text,
      );
    }
  });

  test('forward references fail', () {
    for (final text in ['{{v:gallery.js}}', '{{v:app.css}}']) {
      expect(
        () => buildWebAssets(withText('app.css', text)),
        throwsA(
          isA<EmbedException>().having(
            (e) => e.message,
            'message',
            contains('before it is built'),
          ),
        ),
        reason: text,
      );
    }
  });

  test('text that would break a raw string literal fails', () {
    for (final text in ["a '''b", "ends in '"]) {
      final built = buildWebAssets(withText('gallery.js', text));
      expect(
        () => generateWebAssetsSource(built),
        throwsA(isA<EmbedException>()),
        reason: text,
      );
    }
  });
}
