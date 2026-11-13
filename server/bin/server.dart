import 'dart:io';

import 'package:args/args.dart';
import 'package:shutterlink_server/shutterlink_server.dart';

const int _usageExitCode = 64;
const String _tokenEnvironment = 'SHUTTERLINK_UPLOAD_TOKEN';
const String _defaultPort = '8080';
const String _defaultAddress = '127.0.0.1';

final ArgParser _parser = ArgParser()
  ..addOption('port', defaultsTo: _defaultPort, help: 'Port to listen on.')
  ..addOption(
    'address',
    defaultsTo: _defaultAddress,
    help: 'Address to bind; put a reverse proxy in front of it.',
  )
  ..addOption('data-dir', help: 'Directory for all data (required).')
  ..addOption(
    'upload-token-file',
    help: 'File holding the upload token (or set $_tokenEnvironment).',
  )
  ..addMultiOption('tip', help: 'Tip link as "Label=URL"; repeatable.')
  ..addOption(
    'retention-days',
    defaultsTo: '${defaultRetention.inDays}',
    help: 'Days a Session is kept after its first upload.',
  )
  ..addFlag('help', abbr: 'h', negatable: false);

Never _usage(String message) {
  stderr
    ..writeln(message)
    ..writeln(_parser.usage);
  exit(_usageExitCode);
}

Future<void> main(List<String> arguments) async {
  final ArgResults options;
  try {
    options = _parser.parse(arguments);
    if (options.flag('help')) {
      stdout.writeln(_parser.usage);
      return;
    }
  } on ArgParserException catch (e) {
    _usage(e.message);
  }

  final dataDir = options.option('data-dir');
  if (dataDir == null) _usage('--data-dir is required');
  final port = int.tryParse(options.option('port')!);
  if (port == null) _usage('Invalid --port');
  final retentionDays = int.tryParse(options.option('retention-days')!);
  if (retentionDays == null || retentionDays <= 0) {
    _usage('Invalid --retention-days');
  }

  final tokenFile = options.option('upload-token-file');
  final token =
      (tokenFile != null
              ? await File(tokenFile).readAsString()
              : Platform.environment[_tokenEnvironment] ?? '')
          .trim();
  if (token.isEmpty) {
    _usage(
      'An upload token is required (--upload-token-file or '
      '$_tokenEnvironment).',
    );
  }

  final List<Tip> tips;
  try {
    tips = [for (final spec in options.multiOption('tip')) Tip.parse(spec)];
  } on FormatException catch (e) {
    _usage('Invalid --tip: ${e.message} (${e.source})');
  }

  final server = await ShutterlinkServer.start(
    dataDir: Directory(dataDir),
    uploadToken: token,
    tips: tips,
    retention: Duration(days: retentionDays),
    address: options.option('address'),
    port: port,
  );
  stdout.writeln('Shutterlink server listening on ${server.url}');
  await Future.any([
    ProcessSignal.sigint.watch().first,
    if (!Platform.isWindows) ProcessSignal.sigterm.watch().first,
  ]);
  await server.close();
}
