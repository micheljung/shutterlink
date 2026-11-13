import 'dart:convert';

import 'store.dart';
import 'tips.dart';

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

String _page(String title, String body) =>
    '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${_text.convert(title)}</title>
<link rel="stylesheet" href="/static/app.css">
</head>
<body>
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

List<int> galleryPage(String code, SessionSnapshot snapshot, List<Tip> tips) {
  final base = '/s/${Uri.encodeComponent(code)}';
  final photos = StringBuffer();
  var index = 0;
  for (final photo in snapshot.photos) {
    index++;
    final href = _attribute.convert('$base/p/${photo.key}.jpg');
    photos.writeln(
      '<li><a href="$href" download="${photo.key}.jpg">'
      '<img src="$href" alt="Photo $index" loading="lazy"></a></li>',
    );
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
    _page('Your photos', '''
<h1>Your photos</h1>
<p class="expiry">Available until ${formatExpiry(snapshot.expiresAt)}</p>
<p><a class="button" href="${_attribute.convert('$base/all.zip')}" download>Download all (${snapshot.photos.length})</a></p>
<ul class="photos">
$photos</ul>
$tipSection'''),
  );
}

final List<int> appCss = utf8.encode('''
body { margin: 0; font-family: system-ui, sans-serif; background: #111; color: #eee; }
main { max-width: 960px; margin: 0 auto; padding: 1.5rem; }
a { color: #8cf; }
.button, button { display: inline-block; padding: 0.6rem 1rem; border: 0; border-radius: 0.4rem; background: #8cf; color: #111; font: inherit; text-decoration: none; cursor: pointer; }
.photos { list-style: none; padding: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 0.75rem; }
.photos img { width: 100%; height: 200px; object-fit: cover; border-radius: 0.4rem; }
.tips .tip { margin: 0 0.5rem 0.5rem 0; }
form { display: flex; flex-direction: column; gap: 0.75rem; max-width: 24rem; }
input { padding: 0.6rem; font: inherit; border-radius: 0.4rem; border: 1px solid #555; background: #222; color: inherit; }
''');
