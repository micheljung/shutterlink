import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'support.dart';

/// Parent environment without any `SHUTTERLINK_` variable, so only what a
/// test passes counts.
Map<String, String> cleanEnvironment([Map<String, String> extra = const {}]) =>
    {
      for (final entry in Platform.environment.entries)
        if (!entry.key.startsWith('SHUTTERLINK_')) entry.key: entry.value,
      ...extra,
    };

/// Runs `bin/server.dart` to completion.
Future<ProcessResult> runServer(
  List<String> arguments, {
  Map<String, String> environment = const {},
}) => Process.run(
  Platform.resolvedExecutable,
  ['bin/server.dart', ...arguments],
  environment: cleanEnvironment(environment),
  includeParentEnvironment: false,
);

/// `bin/server.dart` running as a child process.
class ServerProcess {
  ServerProcess._(this.process, this.url, this._stderr);

  final Process process;
  final Uri url;
  final StringBuffer _stderr;

  String get stderr => '$_stderr';

  /// Starts the server on a free port with [uploadToken] in the environment
  /// and waits until it listens. Kills it on test teardown if still running.
  static Future<ServerProcess> start(
    Directory dataDir, {
    List<String> arguments = const [],
    Map<String, String> environment = const {},
  }) async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'bin/server.dart',
        '--data-dir',
        dataDir.path,
        '--port',
        '0',
        ...arguments,
      ],
      environment: cleanEnvironment({
        'SHUTTERLINK_UPLOAD_TOKEN': uploadToken,
        ...environment,
      }),
      includeParentEnvironment: false,
    );
    final stderr = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    final line = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.contains('listening on'), orElse: () => '')
        .timeout(const Duration(seconds: 30));
    if (line.isEmpty) {
      throw StateError('Server did not start: $stderr');
    }
    return ServerProcess._(
      process,
      Uri.parse(line.substring(line.indexOf('http'))),
      stderr,
    );
  }

  /// Kills the process if it is still running and waits for it to exit.
  Future<void> kill() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
  }
}
