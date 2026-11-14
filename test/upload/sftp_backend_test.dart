@Tags(['sftp'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/upload/remote_path.dart';
import 'package:shutterlink/upload/sftp_backend.dart';
import 'package:shutterlink/upload/storage_backend.dart';

import 'support/dropping_proxy.dart';
import 'support/sshd_fixture.dart';
import 'support/upload_fixture.dart';

void main() {
  late SshdFixture sshd;
  late String fingerprint;
  late Directory tmp;
  final backends = <SftpBackend>[];

  setUpAll(() async {
    sshd = await SshdFixture.start();
    fingerprint = await sshd.hostKeyFingerprint();
  });

  tearDownAll(() => sshd.stop());

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sftp_test');
    final data = Directory(sshd.dataDir);
    await for (final entry in data.list()) {
      await entry.delete(recursive: true);
    }
  });

  tearDown(() async {
    for (final b in backends) {
      await b.close();
    }
    backends.clear();
    await tmp.delete(recursive: true);
  });

  SftpBackend backend({
    String? basePath,
    String? privateKey,
    String? pin,
    bool noPin = false,
    Future<Socket> Function(String, int)? connector,
  }) {
    final b = SftpBackend(
      host: '127.0.0.1',
      port: sshd.port,
      username: sshd.username,
      privateKey: privateKey ?? sshd.clientPrivateKey,
      basePath: basePath ?? '${sshd.dataDir}/photos',
      pinnedHostKey: noPin ? null : (pin ?? fingerprint),
      connector:
          connector ??
          (host, port) => Socket.connect(InternetAddress.loopbackIPv4, port),
    );
    backends.add(b);
    return b;
  }

  String local(String path) => '${sshd.dataDir}/photos/$path';

  List<String> listing() {
    final root = Directory('${sshd.dataDir}/photos');
    if (!root.existsSync()) return const [];
    return root
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path.substring(root.path.length + 1))
        .toList()
      ..sort();
  }

  group('testConnection', () {
    test('succeeds with a pinned host key', () async {
      await backend(basePath: sshd.dataDir).testConnection();
    });

    test('rejects an unknown host key and reports it', () async {
      await expectLater(
        backend(basePath: sshd.dataDir, noPin: true).testConnection(),
        throwsA(
          isA<UnknownHostKeyException>()
              .having((e) => e.fingerprint, 'fingerprint', fingerprint)
              .having((e) => e.keyType, 'keyType', 'ssh-ed25519')
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
    });

    test('rejects a host key that differs from the pin', () async {
      await expectLater(
        backend(basePath: sshd.dataDir, pin: 'SHA256:other').testConnection(),
        throwsA(isA<UnknownHostKeyException>()),
      );
    });

    test('reports a key that is not authorized', () async {
      await expectLater(
        backend(
          basePath: sshd.dataDir,
          privateKey: sshd.unauthorizedPrivateKey,
        ).testConnection(),
        throwsA(
          isA<AuthenticationException>()
              .having(
                (e) => e.message,
                'message',
                'Wrong username, password or key.',
              )
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
    });

    test('reports a missing base folder', () async {
      await expectLater(
        backend(basePath: '${sshd.dataDir}/missing').testConnection(),
        throwsA(
          isA<StorageException>().having(
            (e) => e.message,
            'message',
            'Base folder was not found.',
          ),
        ),
      );
    });
  });

  group('upload', () {
    test('creates the folders and commits via the temp name', () async {
      final bytes = bytesOf(300000);
      final progress = <int>[];
      final b = backend(basePath: '${sshd.dataDir}/photos/r6');
      final result = await b.upload(
        await uploadRequest(tmp, bytes),
        onProgress: (sent, total) {
          expect(total, bytes.length);
          progress.add(sent);
        },
      );
      expect(result, UploadResult.uploaded);
      expect(listing(), ['r6/2026-11-13/IMG_0001.JPG']);
      expect(
        File(local('r6/2026-11-13/IMG_0001.JPG')).readAsBytesSync(),
        bytes,
      );
      expect(progress.last, bytes.length);
    });

    test('reuses the session for several uploads', () async {
      final b = backend();
      for (final name in ['A.JPG', 'B.JPG']) {
        expect(
          await b.upload(
            await uploadRequest(
              tmp,
              bytesOf(10),
              name: name,
              tempName: '.$name.tmp',
            ),
          ),
          UploadResult.uploaded,
        );
      }
      expect(listing(), ['2026-11-13/A.JPG', '2026-11-13/B.JPG']);
    });

    test('a different file with the same name gets a suffix', () async {
      await Directory(local('2026-11-13')).create(recursive: true);
      await File(local('2026-11-13/IMG_0001.JPG')).writeAsBytes(bytesOf(5));
      final bytes = bytesOf(10);
      final b = backend();
      final index = await freeNameIndex(
        b,
        directory: '2026-11-13',
        filename: 'IMG_0001.JPG',
        size: bytes.length,
        sha256: sha256Of(bytes),
      );
      final name = candidateName('IMG_0001.JPG', index!);
      expect(name, 'IMG_0001_1.JPG');
      expect(
        await b.upload(await uploadRequest(tmp, bytes, name: name)),
        UploadResult.uploaded,
      );
      expect(listing(), [
        '2026-11-13/IMG_0001.JPG',
        '2026-11-13/IMG_0001_1.JPG',
      ]);
    });

    test('an identical file is not uploaded again', () async {
      final bytes = bytesOf(10);
      await Directory(local('2026-11-13')).create(recursive: true);
      await File(local('2026-11-13/IMG_0001.JPG')).writeAsBytes(bytes);
      final b = backend();
      expect(
        await freeNameIndex(
          b,
          directory: '2026-11-13',
          filename: 'IMG_0001.JPG',
          size: bytes.length,
          sha256: sha256Of(bytes),
        ),
        isNull,
      );
      expect(
        await b.upload(await uploadRequest(tmp, bytes)),
        UploadResult.alreadyPresent,
      );
    });

    test('a leftover temp file is overwritten, not appended to', () async {
      await Directory(local('2026-11-13')).create(recursive: true);
      await File(local('2026-11-13/.IMG_0001.JPG.tmp-fixed'))
          .writeAsBytes(bytesOf(5000, seed: 9));
      final bytes = bytesOf(100);
      expect(
        await backend().upload(await uploadRequest(tmp, bytes)),
        UploadResult.uploaded,
      );
      expect(listing(), ['2026-11-13/IMG_0001.JPG']);
      expect(File(local('2026-11-13/IMG_0001.JPG')).readAsBytesSync(), bytes);
    });

    test(
      'a dropped connection fails retryably and the retry reuses the temp',
      () async {
        final proxy = await DroppingProxy.start(
          sshd.port,
          dropAfterBytes: 100000,
        );
        addTearDown(proxy.close);
        final b = backend(connector: proxy.connect);
        final bytes = bytesOf(400000);
        final request = await uploadRequest(tmp, bytes);
        await expectLater(
          b.upload(request),
          throwsA(
            isA<StorageException>().having((e) => e.retryable, 'r', true),
          ),
        );
        expect(proxy.drops, 1);
        expect(await b.upload(request), UploadResult.uploaded);
        expect(listing(), ['2026-11-13/IMG_0001.JPG']);
        expect(File(local('2026-11-13/IMG_0001.JPG')).readAsBytesSync(), bytes);
      },
    );

    test('a permission error is reported', () async {
      final locked = Directory(local('2026-11-13'));
      await locked.create(recursive: true);
      await Process.run('chmod', ['555', locked.path]);
      addTearDown(() => Process.run('chmod', ['755', locked.path]));
      await expectLater(
        backend().upload(await uploadRequest(tmp, bytesOf(10))),
        throwsA(
          isA<StorageException>()
              .having((e) => e.message, 'message', 'Access denied.')
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
    });
  });
}
