import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/upload_item.dart';

void main() {
  final item = UploadItem(
    id: '1|IMG_0001.JPG||jpeg',
    filename: 'IMG_0001.JPG',
    kind: CameraObjectKind.jpeg,
    captureDay: '2026-11-13',
    size: 3,
    sha256: 'abc',
    localPath: '/staging/a/IMG_0001.JPG',
    destinationFingerprint: 'fp',
  );

  test('walks the happy path', () {
    final done = item
        .moveTo(UploadState.saving, pendingRef: () => 'content://1')
        .moveTo(
          UploadState.savedToGallery,
          pendingRef: () => null,
          mediaRef: () => 'content://1',
        )
        .moveTo(UploadState.uploading)
        .moveTo(UploadState.uploaded)
        .moveTo(UploadState.localDeleted);

    expect(done.state, UploadState.localDeleted);
    expect(done.mediaRef, 'content://1');
    expect(done.pendingRef, isNull);
    expect(done.state.isTerminal, isTrue);
  });

  test('rejects skipping the gallery save or uploading twice', () {
    expect(() => item.moveTo(UploadState.uploading), throwsStateError);
    expect(
      () => item
          .copyWith(state: UploadState.localDeleted)
          .moveTo(UploadState.uploaded),
      throwsStateError,
    );
  });

  test('kept copies can still be removed later', () {
    final kept = item
        .copyWith(state: UploadState.uploaded)
        .moveTo(UploadState.localKept, deleteDenied: true);

    expect(kept.deleteDenied, isTrue);
    expect(
      kept.moveTo(UploadState.localDeleted).state,
      UploadState.localDeleted,
    );
  });

  test('retarget forgets the previous destination', () {
    final uploading = item.copyWith(
      state: UploadState.uploading,
      remoteName: () => 'IMG_0001.JPG',
      tempName: () => '.IMG_0001.JPG.tmp-1',
      attempts: 3,
      nextAttemptAt: () => DateTime.utc(2026),
      lastError: () => 'boom',
      needsAttention: true,
    );

    final moved = uploading.retarget('fp2');

    expect(moved.state, UploadState.savedToGallery);
    expect(moved.destinationFingerprint, 'fp2');
    expect([
      moved.remoteName,
      moved.tempName,
      moved.nextAttemptAt,
      moved.lastError,
    ], everyElement(isNull));
    expect(moved.attempts, 0);
    expect(moved.needsAttention, isFalse);
    expect(
      item.retarget('fp2').state,
      UploadState.staged,
      reason: 'other states are kept',
    );
  });

  test('round-trips through JSON', () {
    final full = item.copyWith(
      state: UploadState.uploading,
      mediaRef: () => 'content://1',
      remoteName: () => 'IMG_0001_1.JPG',
      tempName: () => '.IMG_0001_1.JPG.tmp-1',
      attempts: 2,
      nextAttemptAt: () => DateTime.utc(2026, 11, 13, 10),
      lastError: () => 'boom',
      needsAttention: true,
      deleteDenied: true,
    );

    expect(UploadItem.fromJson(full.toJson()), full);
    expect(UploadItem.fromJson(item.toJson()), item);
  });

  test('ignores entries it cannot interpret', () {
    expect(UploadItem.fromJson('nope'), isNull);
    expect(UploadItem.fromJson({...item.toJson(), 'state': 'flying'}), isNull);
    expect(UploadItem.fromJson({...item.toJson(), 'size': 'big'}), isNull);
  });
}
