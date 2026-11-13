import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/upload/remote_path.dart';
import 'package:shutterlink/upload/storage_backend.dart';

class _Backend implements StorageBackend {
  _Backend(this.results);

  final Map<String, ProbeResult> results;
  final probed = <String>[];

  @override
  Future<ProbeResult> probe(
    RemoteTarget target, {
    required int size,
    required String sha256,
  }) async {
    probed.add('$target');
    return results[target.name] ?? ProbeResult.absent;
  }

  @override
  Future<UploadResult> upload(
    UploadRequest request, {
    UploadProgress? onProgress,
  }) => throw UnimplementedError();

  @override
  Future<void> testConnection() async {}

  @override
  Future<void> close() async {}
}

void main() {
  test('remoteDirectoryFor uses the local capture day', () {
    expect(remoteDirectoryFor(DateTime(2026, 1, 5, 23, 59)), '2026-01-05');
    final utc = DateTime.utc(2026, 11, 13, 12);
    expect(remoteDirectoryFor(utc), () {
      final l = utc.toLocal();
      return '${l.year}-${l.month.toString().padLeft(2, '0')}-'
          '${l.day.toString().padLeft(2, '0')}';
    }());
  });

  test('candidateName suffixes the stem', () {
    expect(candidateName('IMG_0001.JPG', 0), 'IMG_0001.JPG');
    expect(candidateName('IMG_0001.JPG', 1), 'IMG_0001_1.JPG');
    expect(candidateName('IMG_0001.CR3', 12), 'IMG_0001_12.CR3');
    expect(candidateName('README', 2), 'README_2');
  });

  test('tempNameFor hides the file and is unique', () {
    final a = tempNameFor('IMG_0001.JPG');
    expect(a, matches(RegExp(r'^\.IMG_0001\.JPG\.tmp-[0-9a-f-]{36}$')));
    expect(a, isNot(endsWith('.part')));
    expect(tempNameFor('IMG_0001.JPG'), isNot(a));
  });

  test('pathSegments drops empty and dot segments', () {
    expect(pathSegments('/a//b/./c/'), ['a', 'b', 'c']);
    expect(pathSegments(''), isEmpty);
  });

  group('resolveRemoteName', () {
    Future<ResolvedName> resolve(_Backend backend, {int startIndex = 0}) =>
        resolveRemoteName(
          backend,
          directory: '2026-11-13',
          filename: 'IMG_0001.JPG',
          size: 1,
          sha256: 'x',
          startIndex: startIndex,
        );

    test('takes the original name when free', () async {
      final r = await resolve(_Backend({}));
      expect(
        r.target,
        const RemoteTarget(directory: '2026-11-13', name: 'IMG_0001.JPG'),
      );
      expect(r.alreadyPresent, isFalse);
    });

    test('skips names holding different content', () async {
      final backend = _Backend({
        'IMG_0001.JPG': ProbeResult.different,
        'IMG_0001_1.JPG': ProbeResult.different,
      });
      final r = await resolve(backend);
      expect(r.target.name, 'IMG_0001_2.JPG');
      expect(backend.probed, hasLength(3));
    });

    test('stops at an identical file', () async {
      final r = await resolve(
        _Backend({
          'IMG_0001.JPG': ProbeResult.different,
          'IMG_0001_1.JPG': ProbeResult.identical,
        }),
      );
      expect(r.target.name, 'IMG_0001_1.JPG');
      expect(r.alreadyPresent, isTrue);
    });

    test('can continue after a name taken during upload', () async {
      final r = await resolve(_Backend({}), startIndex: 2);
      expect(r.target.name, 'IMG_0001_2.JPG');
    });

    test('gives up after maxNameCandidates', () async {
      await expectLater(
        resolve(_Backend({}), startIndex: maxNameCandidates),
        throwsA(
          isA<StorageException>().having(
            (e) => e.retryable,
            'retryable',
            false,
          ),
        ),
      );
    });
  });

  test('RemoteTarget and UploadRequest compare by value', () {
    const target = RemoteTarget(directory: '2026-11-13', name: 'A.JPG');
    expect(target.toString(), '2026-11-13/A.JPG');
    UploadRequest request() => UploadRequest(
      source: File('/tmp/a'),
      target: target,
      tempName: '.A.JPG.tmp-1',
      size: 1,
      sha256: 'x',
    );
    expect(request(), request());
  });
}
