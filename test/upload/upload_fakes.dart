import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/media_saver.dart';
import 'package:shutterlink/upload/storage_backend.dart';

/// An in-memory remote that commits like the real backends: temp file first,
/// then a non-overwriting rename.
class FakeStorageServer {
  final files = <String, Uint8List>{};
  final tempWrites = <String>[];
  final connections = <bool>[];

  /// Runs after the temp file is written, before the commit.
  Future<void> Function(UploadRequest request)? beforeCommit;

  /// Fails this many upload calls with [failure] before succeeding.
  int failUploads = 0;
  StorageException failure = const StorageException('Connection reset');

  /// Makes closing a backend fail.
  bool failClose = false;

  StorageBackend backend({bool allowMetered = false}) {
    connections.add(allowMetered);
    return _FakeBackend(this);
  }

  bool get hasTempFiles => files.keys.any((path) => path.contains('.tmp-'));
}

class _FakeBackend implements StorageBackend {
  _FakeBackend(this._server);

  final FakeStorageServer _server;

  @override
  Future<ProbeResult> probe(
    RemoteTarget target, {
    required int size,
    required String sha256,
  }) async {
    final existing = _server.files['$target'];
    if (existing == null) return ProbeResult.absent;
    return _same(existing, size, sha256)
        ? ProbeResult.identical
        : ProbeResult.different;
  }

  @override
  Future<UploadResult> upload(
    UploadRequest request, {
    UploadProgress? onProgress,
  }) async {
    if (_server.failUploads > 0) {
      _server.failUploads--;
      throw _server.failure;
    }
    final temp = '${request.target.directory}/${request.tempName}';
    final bytes = await request.source.readAsBytes();
    _server.files[temp] = bytes;
    _server.tempWrites.add(temp);
    onProgress?.call(bytes.length, request.size);
    await _server.beforeCommit?.call(request);
    final target = '${request.target}';
    final existing = _server.files[target];
    _server.files.remove(temp);
    if (existing == null) {
      _server.files[target] = bytes;
      return UploadResult.uploaded;
    }
    return _same(existing, request.size, request.sha256)
        ? UploadResult.alreadyPresent
        : UploadResult.nameTaken;
  }

  static bool _same(Uint8List bytes, int size, String hash) =>
      bytes.length == size && sha256.convert(bytes).toString() == hash;

  @override
  Future<void> testConnection() async {}

  @override
  Future<void> close() async {
    if (_server.failClose) throw const SocketException('Broken pipe');
  }
}

class MediaRow {
  MediaRow(this.name, {this.path, this.pending = true});

  final String name;
  String? path;
  bool pending;
}

class FakeMediaSaver implements MediaSaver {
  final rows = <String, MediaRow>{};
  final calls = <String>[];
  final ownershipLost = <String>{};
  int failFinish = 0;
  bool approveDelete = true;
  int _next = 0;

  List<MediaRow> get published =>
      rows.values.where((row) => !row.pending).toList();

  @override
  Future<String> beginSave({
    required String filename,
    required CameraObjectKind kind,
  }) async {
    final uri = 'content://media/${++_next}';
    calls.add('begin $filename');
    rows[uri] = MediaRow(filename);
    return uri;
  }

  @override
  Future<String> finishSave(
    String pendingRef, {
    required String path,
    required CameraObjectKind kind,
  }) async {
    calls.add('finish $pendingRef');
    if (failFinish > 0) {
      failFinish--;
      throw const FileSystemException('MediaStore unavailable');
    }
    rows[pendingRef]!
      ..path = path
      ..pending = false;
    return pendingRef;
  }

  @override
  Future<MediaRowState> query(String ref) async {
    calls.add('query $ref');
    final row = rows[ref];
    if (row == null) return MediaRowState.missing;
    return row.pending ? MediaRowState.pending : MediaRowState.published;
  }

  @override
  Future<void> delete(String ref) async {
    calls.add('delete $ref');
    if (ownershipLost.contains(ref)) throw MediaOwnershipLostException(ref);
    rows.remove(ref);
  }

  @override
  Future<bool> requestDelete(List<String> refs) async {
    calls.add('requestDelete ${refs.join(',')}');
    if (approveDelete) refs.forEach(rows.remove);
    return approveDelete;
  }
}

class FakeTimer implements Timer {
  FakeTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (_active) _callback();
    _active = false;
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

class FakeTimers {
  final all = <FakeTimer>[];

  Timer create(Duration delay, void Function() wake) {
    final timer = FakeTimer(delay, wake);
    all.add(timer);
    return timer;
  }

  FakeTimer? get active => all.lastWhereOrNull((timer) => timer.isActive);
}

/// Jitter factor exactly 1.
class MidRandom implements Random {
  @override
  double nextDouble() => 0.5;

  @override
  bool nextBool() => false;

  @override
  int nextInt(int max) => 0;
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 1000 && !condition(); i++) {
    await pumpEventQueue();
  }
  expect(condition(), isTrue, reason: 'condition never became true');
}
