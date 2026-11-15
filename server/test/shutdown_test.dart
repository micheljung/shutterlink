@TestOn('!windows')
library;

import 'dart:io';

import 'package:test/test.dart';

import 'process_support.dart';
import 'support.dart';

void main() {
  late Directory dataDir;

  setUp(() async => dataDir = await tempDataDir());
  tearDown(() => dataDir.delete(recursive: true));

  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    test('exits with code 0 on $signal', () async {
      final server = await ServerProcess.start(dataDir);
      addTearDown(server.kill);

      server.process.kill(signal);

      final exitCode = await server.process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('still running 10 s after $signal'),
      );
      expect(exitCode, 0, reason: server.stderr);
    });
  }
}
