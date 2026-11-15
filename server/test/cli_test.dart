import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support.dart';

const int _usageExitCode = 64;

/// Environment without the token variable, so only the flags count.
final Map<String, String> _noTokenEnvironment = {
  for (final entry in Platform.environment.entries)
    if (entry.key != 'SHUTTERLINK_UPLOAD_TOKEN') entry.key: entry.value,
};

Future<ProcessResult> _run(List<String> arguments) => Process.run(
  Platform.resolvedExecutable,
  ['bin/server.dart', ...arguments],
  environment: _noTokenEnvironment,
  includeParentEnvironment: false,
);

void main() {
  late Directory dataDir;

  setUp(() async => dataDir = await tempDataDir());
  tearDown(() => dataDir.delete(recursive: true));

  test('accepts the upload token directly on the command line', () async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        'bin/server.dart',
        '--data-dir',
        dataDir.path,
        '--port',
        '0',
        '--upload-token',
        '  $uploadToken\n',
      ],
      environment: _noTokenEnvironment,
      includeParentEnvironment: false,
    );
    addTearDown(() async {
      process.kill();
      await process.exitCode;
    });
    final stderrText = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(stderrText.write);
    final line = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.contains('listening on'), orElse: () => '')
        .timeout(const Duration(seconds: 30));
    expect(line, isNotEmpty, reason: '$stderrText');
    final base = Uri.parse(line.substring(line.indexOf('http')));

    final client = HttpClient();
    addTearDown(client.close);
    Future<int> authStatus(String token) async {
      final request = await client.getUrl(base.resolve('/api/auth'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    expect(await authStatus(uploadToken), HttpStatus.noContent);
    expect(await authStatus('wrong-token'), HttpStatus.unauthorized);
  });

  test('refuses both --upload-token and --upload-token-file', () async {
    final tokenFile = File('${dataDir.path}/token')
      ..writeAsStringSync(uploadToken);
    final result = await _run([
      '--data-dir',
      dataDir.path,
      '--upload-token',
      uploadToken,
      '--upload-token-file',
      tokenFile.path,
    ]);
    expect(result.exitCode, _usageExitCode, reason: '${result.stderr}');
    expect('${result.stderr}', contains('not both'));
  });

  test('refuses a blank --upload-token', () async {
    final result = await _run([
      '--data-dir',
      dataDir.path,
      '--upload-token',
      '   ',
    ]);
    expect(result.exitCode, _usageExitCode, reason: '${result.stderr}');
    expect('${result.stderr}', contains('upload token is required'));
  });
}
