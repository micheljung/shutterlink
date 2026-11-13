@Tags(['sftp-root'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/upload/sftp_backend.dart';
import 'package:shutterlink/upload/storage_backend.dart';

import 'support/sshd_fixture.dart';
import 'support/upload_fixture.dart';

void main() {
  late SshdFixture sshd;
  late Directory tmp;

  setUpAll(() async => sshd = await SshdFixture.start(password: true));
  tearDownAll(() => sshd.stop());

  setUp(() async => tmp = await Directory.systemTemp.createTemp('sftp_pw'));
  tearDown(() => tmp.delete(recursive: true));

  Future<SftpBackend> backend(String password) async => SftpBackend(
    host: '127.0.0.1',
    port: sshd.port,
    username: sshd.username,
    password: password,
    basePath: 'shutterlink-${DateTime.now().microsecondsSinceEpoch}',
    pinnedHostKey: await sshd.hostKeyFingerprint(),
  );

  test('uploads with password authentication', () async {
    final b = await backend(sshd.password);
    addTearDown(b.close);
    final bytes = bytesOf(20000);
    final request = await uploadRequest(tmp, bytes);
    expect(await b.upload(request), UploadResult.uploaded);
    expect(
      await b.probe(
        request.target,
        size: bytes.length,
        sha256: sha256Of(bytes),
      ),
      ProbeResult.identical,
    );
    await b.testConnection();
  });

  test('reports a wrong password', () async {
    final b = await backend('${sshd.password}-wrong');
    addTearDown(b.close);
    await expectLater(
      b.testConnection(),
      throwsA(
        isA<StorageException>().having(
          (e) => e.message,
          'message',
          'Wrong username, password or key.',
        ),
      ),
    );
  });
}
