import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../data/photo_saver.dart';
import '../ptpip/camera_client.dart';

enum MediaRowState {
  /// Inserted but not yet published (Android `IS_PENDING=1`).
  pending,
  published,

  /// Never existed, deleted, or reclaimed by the system.
  missing,
}

/// The gallery copy is no longer owned by the app (e.g. after a restore), so
/// removing it needs the user's consent.
class MediaOwnershipLostException implements Exception {
  const MediaOwnershipLostException(this.uri);

  final String uri;

  @override
  String toString() => 'MediaOwnershipLostException($uri)';
}

/// A gallery save in two steps, so a crash between them can be resumed.
abstract interface class MediaSaver {
  /// Reserves a gallery entry and returns its reference.
  Future<String> beginSave({
    required String filename,
    required CameraObjectKind kind,
  });

  /// Writes [path] into the reserved entry and publishes it.
  Future<String> finishSave(
    String pendingRef, {
    required String path,
    required CameraObjectKind kind,
  });

  Future<MediaRowState> query(String ref);

  /// Throws [MediaOwnershipLostException] when consent is required.
  Future<void> delete(String ref);

  /// Asks the user to remove [refs] in one prompt. Returns whether they agreed.
  Future<bool> requestDelete(List<String> refs);
}

/// Android MediaStore bridge.
class ChannelMediaSaver implements MediaSaver {
  const ChannelMediaSaver({this.timeout = PlatformPhotoSaver.defaultTimeout});

  static const channel = MethodChannel('ch.micheljung.shutterlink/media');
  static const ownershipLostCode = 'ownership_lost';

  final Duration timeout;

  @override
  Future<String> beginSave({
    required String filename,
    required CameraObjectKind kind,
  }) => _invokeString('beginSave', {'name': filename, 'kind': kind.name});

  @override
  Future<String> finishSave(
    String pendingRef, {
    required String path,
    required CameraObjectKind kind,
  }) => _invokeString('finishSave', {
    'uri': pendingRef,
    'path': path,
    'kind': kind.name,
  });

  @override
  Future<MediaRowState> query(String ref) async => MediaRowState.values.byName(
    await _invokeString('queryMedia', {'uri': ref}),
  );

  @override
  Future<void> delete(String ref) async {
    try {
      await channel
          .invokeMethod<void>('deleteMedia', {'uri': ref})
          .timeout(timeout);
    } on PlatformException catch (error) {
      if (error.code == ownershipLostCode) {
        throw MediaOwnershipLostException(ref);
      }
      rethrow;
    }
  }

  @override
  Future<bool> requestDelete(List<String> refs) async =>
      await channel.invokeMethod<bool>('requestDelete', {'uris': refs}) ??
      false;

  Future<String> _invokeString(String method, Map<String, Object?> args) async {
    final result = await channel
        .invokeMethod<String>(method, args)
        .timeout(timeout);
    if (result == null) {
      throw PlatformException(code: 'no_result', message: method);
    }
    return result;
  }
}

/// For platforms without a resumable save. A crash mid-save repeats the save.
class PhotoSaverMediaSaver implements MediaSaver {
  const PhotoSaverMediaSaver(this._saver);

  static const pendingRef = 'pending';

  final PhotoSaver _saver;

  @override
  Future<String> beginSave({
    required String filename,
    required CameraObjectKind kind,
  }) async => pendingRef;

  @override
  Future<String> finishSave(
    String pendingRef, {
    required String path,
    required CameraObjectKind kind,
  }) async {
    final file = File(path);
    final saved = await _saver.save(
      jpeg: kind == CameraObjectKind.jpeg ? file : null,
      raw: kind == CameraObjectKind.raw ? file : null,
      deleteSources: false,
    );
    return saved.single.uri ?? '';
  }

  @override
  Future<MediaRowState> query(String ref) async => MediaRowState.missing;

  @override
  Future<void> delete(String ref) async =>
      throw MediaOwnershipLostException(ref);

  @override
  Future<bool> requestDelete(List<String> refs) async => false;
}
