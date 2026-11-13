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
  test('captureDayOf uses the local capture day', () {
    expect(captureDayOf(DateTime(2026, 1, 5, 23, 59)), '2026-01-05');
    final utc = DateTime.utc(2026, 11, 13, 12);
    final l = utc.toLocal();
    expect(
      captureDayOf(utc),
      '${l.year}-${l.month.toString().padLeft(2, '0')}-'
      '${l.day.toString().padLeft(2, '0')}',
    );
  });

  test('candidateName suffixes the stem', () {
    expect(candidateName('IMG_0001.JPG', 0), 'IMG_0001.JPG');
    expect(candidateName('IMG_0001.JPG', 1), 'IMG_0001_1.JPG');
    expect(candidateName('IMG_0001.CR3', 12), 'IMG_0001_12.CR3');
    expect(candidateName('README', 2), 'README_2');
  });

  test('candidateIndexOf inverts candidateName, unknown names are 0', () {
    expect(candidateIndexOf('IMG_0001.JPG', 'IMG_0001_7.JPG'), 7);
    expect(candidateIndexOf('IMG_0001.JPG', 'IMG_0001.JPG'), 0);
    expect(candidateIndexOf('IMG_0001.JPG', 'other.JPG'), 0);
  });

  test('tempNameFor hides the file', () {
    expect(tempNameFor('IMG_0001.JPG', 'u1'), '.IMG_0001.JPG.tmp-u1');
    expect(tempNameFor('IMG_0001.JPG', 'u1'), isNot(endsWith('.part')));
  });

  test('pathSegments drops empty and dot segments', () {
    expect(pathSegments('/a//b/./c/'), ['a', 'b', 'c']);
    expect(pathSegments(''), isEmpty);
  });

  group('freeNameIndex', () {
    Future<int?> free(_Backend backend, {int from = 0}) => freeNameIndex(
      backend,
      directory: '2026-11-13',
      filename: 'IMG_0001.JPG',
      size: 1,
      sha256: 'x',
      from: from,
    );

    test('takes the original name when free', () async {
      expect(await free(_Backend({})), 0);
    });

    test('skips names holding different content', () async {
      final backend = _Backend({
        'IMG_0001.JPG': ProbeResult.different,
        'IMG_0001_1.JPG': ProbeResult.different,
      });
      expect(await free(backend), 2);
      expect(backend.probed, hasLength(3));
    });

    test('is null at an identical file', () async {
      expect(
        await free(
          _Backend({
            'IMG_0001.JPG': ProbeResult.different,
            'IMG_0001_1.JPG': ProbeResult.identical,
          }),
        ),
        isNull,
      );
    });

    test('can continue after a name taken during upload', () async {
      expect(await free(_Backend({}), from: 2), 2);
    });

    test('gives up after maxNameCandidates', () async {
      await expectLater(
        free(_Backend({}), from: maxNameCandidates),
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
