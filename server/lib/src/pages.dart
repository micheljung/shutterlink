import 'dart:convert';

import 'store.dart';
import 'tips.dart';
import 'web_assets.g.dart';

const HtmlEscape _text = HtmlEscape(HtmlEscapeMode.element);
const HtmlEscape _attribute = HtmlEscape(HtmlEscapeMode.attribute);

const List<String> _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const int _eagerImages = 8;
const String _pendingText = 'Preparing preview…';
const String _failedText = 'No preview. Tap to download';

String staticUrl(String file) => '/static/$file?v=${webAssets[file]!.version}';

final String _logo = utf8
    .decode(webAssets['logo.svg']!.bytes)
    .trim()
    .replaceFirst('<svg ', '<svg aria-hidden="true" focusable="false" ');

String _page(String title, String body, {String head = ''}) =>
    '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<meta name="color-scheme" content="dark">
<title>${_text.convert(title)}</title>
<link rel="icon" href="${staticUrl('logo.svg')}" type="image/svg+xml">
<link rel="stylesheet" href="${staticUrl('app.css')}">
$head</head>
<body>
<header class="site">
<a class="brand" href="/">$_logo<span class="wordmark">shutterlink</span></a>
</header>
<main>
$body
</main>
</body>
</html>
''';

final List<int> onTheirWayPage = utf8.encode(
  _page('Your photos are on their way', '''
<h1>Your photos are on their way</h1>
<p>The photographer uploads your photos once they are back online. Please check this page again later.</p>
<p><a href="/">Enter a different code</a></p>'''),
);

final List<int> landingPage = utf8.encode(
  _page('Shutterlink', '''
<h1>Your photos</h1>
<form action="/s" method="get">
<label for="code">Enter your code</label>
<input id="code" name="code" type="text" placeholder="four-words-like-this" autocomplete="off" autocapitalize="none" spellcheck="false" required>
<button type="submit">Show my photos</button>
</form>'''),
);

String _two(int value) => value.toString().padLeft(2, '0');

String formatExpiry(DateTime instant) {
  final t = instant.toUtc();
  final machine =
      '${t.year}-${_two(t.month)}-${_two(t.day)}'
      'T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}Z';
  final human = '${t.day} ${_months[t.month - 1]} ${t.year} (UTC)';
  return '<time datetime="$machine">$human</time>';
}

String _tile(String base, StoredPhoto photo, int index) {
  final key = photo.key;
  final href = _attribute.convert('$base/p/$key.jpg');
  final preview = photo.preview;
  final content = switch (preview.status) {
    PreviewStatus.ready =>
      '<img src="${_attribute.convert('$base/t/$key.jpg')}" '
          'alt="Photo ${index + 1}" '
          'loading="${index < _eagerImages ? 'eager' : 'lazy'}" '
          'decoding="async">',
    PreviewStatus.pending =>
      '<span class="placeholder pending">$_pendingText</span>',
    PreviewStatus.failed =>
      '<span class="placeholder failed">$_failedText</span>',
  };
  final viewer = preview.status == PreviewStatus.ready
      ? ' data-pswp-src="${_attribute.convert('$base/v/$key.jpg')}"'
            ' data-pswp-width="${preview.width}"'
            ' data-pswp-height="${preview.height}"'
      : '';
  return '<li><a href="$href" download="$key.jpg"$viewer>$content</a></li>';
}

/// [generationId] is `<bootId>-<g>` for the generation in [snapshot].
List<int> galleryPage(
  String code,
  SessionSnapshot snapshot,
  List<Tip> tips,
  String generationId,
) {
  final base = '/s/${Uri.encodeComponent(code)}';
  final photos = StringBuffer();
  for (final (index, photo) in snapshot.photos.indexed) {
    photos.writeln(_tile(base, photo, index));
  }
  final tipSection = StringBuffer();
  if (tips.isNotEmpty) {
    tipSection
      ..writeln('<section class="tips">')
      ..writeln('<h2>Say thanks</h2>')
      ..writeln(
        '<p>All downloads are free. If you like your photos, '
        'you can leave a tip.</p>',
      );
    for (final tip in tips) {
      tipSection.writeln(
        '<a class="button tip" href="${_attribute.convert(tip.url.toString())}" '
        'rel="noopener noreferrer external" target="_blank">'
        '${_text.convert(tip.label)}</a>',
      );
    }
    tipSection.writeln('</section>');
  }
  return utf8.encode(
    _page(
      'Your photos',
      '''
<h1>Your photos</h1>
<p class="expiry">Available until ${formatExpiry(snapshot.expiresAt)}</p>
<p><a class="button" href="${_attribute.convert('$base/all.zip')}" download>Download all (<span data-count>${snapshot.photos.length}</span>)</a></p>
<ul class="photos" data-live="${_attribute.convert('$base/photos.json')}" data-events="${_attribute.convert('$base/events')}" data-generation="${_attribute.convert(generationId)}">
$photos</ul>
$tipSection''',
      head:
          '<link rel="stylesheet" href="${staticUrl('photoswipe.css')}">\n'
          '<script type="module" src="${staticUrl('gallery.js')}"></script>\n',
    ),
  );
}
