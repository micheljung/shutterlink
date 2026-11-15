import 'dart:async';
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
    'upload-token',
    help:
        'Upload token. Visible in the process list and shell history; '
        'prefer --upload-token-file or $_tokenEnvironment in production.',
  )
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
  ..addFlag(
    'healthcheck',
    negatable: false,
    help:
        'Check that a server is answering on --address/--port, exit 0 if '
        'so and 1 otherwise. Starts no server.',
  )
  ..addFlag('help', abbr: 'h', negatable: false);

const Duration _healthcheckTimeout = Duration(seconds: 3);

/// Asks a running server for `/healthz`. A wildcard bind address is checked
/// on loopback.
Future<int> _healthcheck(String address, String portOption) async {
  final port = int.tryParse(portOption);
  if (port == null) _usage('Invalid --port');
  final host = address == '0.0.0.0' || address == '::' ? '127.0.0.1' : address;
  final client = HttpClient()..connectionTimeout = _healthcheckTimeout;
  try {
    final request = await client
        .get(host, port, '/healthz')
        .timeout(_healthcheckTimeout);
    final response = await request.close().timeout(_healthcheckTimeout);
    await response.drain<void>();
    return response.statusCode == HttpStatus.noContent ? 0 : 1;
  } on Object catch (e) {
    stderr.writeln('Health check failed: $e');
    return 1;
  } finally {
    client.close(force: true);
  }
}

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
  if (options.flag('healthcheck')) {
    exit(
      await _healthcheck(options.option('address')!, options.option('port')!),
    );
  }

  final dataDir = options.option('data-dir');
  if (dataDir == null) _usage('--data-dir is required');
  final port = int.tryParse(options.option('port')!);
  if (port == null) _usage('Invalid --port');
  final retentionDays = int.tryParse(options.option('retention-days')!);
  if (retentionDays == null || retentionDays <= 0) {
    _usage('Invalid --retention-days');
  }

  final tokenArgument = options.option('upload-token');
  final tokenFile = options.option('upload-token-file');
  if (tokenArgument != null && tokenFile != null) {
    _usage('Pass either --upload-token or --upload-token-file, not both.');
  }
  final token =
      (tokenArgument ??
              (tokenFile != null
                  ? await File(tokenFile).readAsString()
                  : Platform.environment[_tokenEnvironment] ?? ''))
          .trim();
  if (token.isEmpty) {
    _usage(
      'An upload token is required (--upload-token, --upload-token-file or '
      '$_tokenEnvironment).',
    );
  }

  final List<Tip> tips;
  try {
    tips = [for (final spec in options.multiOption('tip')) Tip.parse(spec)];
  } on FormatException catch (e) {
    _usage('Invalid --tip: ${e.message} (${e.source})');
  }

  // Listen explicitly so both subscriptions can be cancelled: a watch left
  // open keeps the process alive after the server has closed. Subscribe
  // before announcing the URL, so a signal sent right after startup stops
  // the server instead of killing the process.
  final stopRequested = Completer<void>();
  final signals = [
    ProcessSignal.sigint,
    if (!Platform.isWindows) ProcessSignal.sigterm,
  ];
  final subscriptions = [
    for (final signal in signals)
      signal.watch().listen((_) {
        if (!stopRequested.isCompleted) stopRequested.complete();
      }),
  ];
  final server = await ShutterlinkServer.start(
    dataDir: Directory(dataDir),
    uploadToken: token,
    tips: tips,
    retention: Duration(days: retentionDays),
    address: options.option('address'),
    port: port,
  );
  stdout.writeln('Shutterlink server listening on ${server.url}');
  await stopRequested.future;
  await Future.wait([for (final s in subscriptions) s.cancel()]);
  await server.close();
}
