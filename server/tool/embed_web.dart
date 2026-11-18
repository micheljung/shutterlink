import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shutterlink_server/src/web_embed.dart';

/// Regenerates `lib/src/web_assets.g.dart` from `web/`. Run by hand after
/// editing anything in `web/`: `fvm dart run tool/embed_web.dart`.
Future<void> main() async {
  final server = p.dirname(p.dirname(Platform.script.toFilePath()));
  final output = p.join(server, 'lib', 'src', 'web_assets.g.dart');
  try {
    final sources = await readWebSources(Directory(p.join(server, 'web')));
    final source = generateWebAssetsSource(buildWebAssets(sources));
    await File(output).writeAsString(source);
  } on EmbedException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
    return;
  }
  final format = await Process.run(Platform.resolvedExecutable, [
    'format',
    output,
  ]);
  if (format.exitCode != 0) {
    stderr.write(format.stderr);
    exitCode = format.exitCode;
  }
}
