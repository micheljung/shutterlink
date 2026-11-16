import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../data/cr3_preview.dart';
import '../../data/exif.dart';
import '../../ptpip/camera_client.dart';
import '../gallery/photo_group.dart';

/// How much of the file is read first for its orientation: a JPEG's EXIF, or
/// a CR3's `moov` box with CMT1.
const headReadLength = exifReadCap;

/// How much one camera request of a preview load asks for. Small enough
/// that leaving a page frees the link soon even on a weak signal, where a
/// request in flight can't be stopped.
const previewChunkLength = 256 * 1024;

/// Loads the full-size image of one photo for the preview: the JPEG, or the
/// preview embedded in a CR3. It reads the head of the file first, to learn
/// which way up the photo is before the rest arrives.
///
/// A paused load keeps what it received and resumes from there.
class FullImageLoad extends ChangeNotifier {
  FullImageLoad(this._client, this.group);

  final CameraClient _client;
  final PhotoGroup group;
  final _received = BytesBuilder(copy: false);
  CancelToken? _cancelToken;
  Future<void> _running = Future.value();
  Uint8List? _full;
  int _quarterTurns = 0;
  int _fullQuarterTurns = 0;
  bool _orientationRead = false;
  bool _headOnly = false;
  bool _finished = false;
  bool _held = false;
  bool _disposed = false;

  CameraObject get _source => (group.jpeg ?? group.raw)!;

  /// The full-size image, once loaded.
  Uint8List? get full => _full;

  /// Whether the full-size image is on its way, not just the orientation.
  bool get loading => _cancelToken != null && !_headOnly;

  /// Clockwise quarter turns that show the photo upright.
  int get quarterTurns => _quarterTurns;

  /// Whether [quarterTurns] was read from the photo itself.
  bool get orientationRead => _orientationRead;

  /// Takes [turns], known from an earlier look at the photo, until the
  /// photo's own head says otherwise.
  void assumeTurns(int turns) {
    if (_orientationRead || turns == _quarterTurns) return;
    _quarterTurns = turns;
    _notify();
  }

  /// Quarter turns [full] needs on top of the one its own EXIF gives it.
  int get fullQuarterTurns => _fullQuarterTurns;

  /// Starts or resumes loading; with [orientationOnly], only reads the head
  /// of the file. Does nothing while a run is on or once that part is done.
  /// A full start during an orientation-only run extends that run.
  Future<void> start({bool orientationOnly = false}) async {
    if (_disposed || _held) return;
    if (_cancelToken != null) {
      if (_headOnly && !orientationOnly) {
        _headOnly = false;
        _notify();
      }
      return;
    }
    if (orientationOnly ? _orientationRead : _finished) return;
    final token = _cancelToken = CancelToken();
    _headOnly = orientationOnly;
    final previous = _running;
    final done = Completer<void>();
    _running = done.future;
    try {
      // A paused run may still be writing its last chunk.
      await previous;
      // The previous run may have finished the part this one is for.
      if (token.isCancelled || (_headOnly ? _orientationRead : _finished)) {
        return;
      }
      _notify();
      if (!_orientationRead) await _readHead(token);
      if (_headOnly || token.isCancelled) return;
      final full = group.jpeg == null
          ? await _readRawPreview(token)
          : await _readJpeg(token);
      _finish(full);
    } on TransferCancelledException {
      // Paused or disposed; the bytes so far are kept.
    } on Exception {
      // The thumbnail stays on screen.
    } finally {
      done.complete();
      if (identical(_cancelToken, token)) _cancelToken = null;
      _notify();
    }
  }

  /// Stops loading at the next chunk and keeps what was received.
  void pause() {
    final token = _cancelToken;
    if (token == null) return;
    token.cancel();
    _cancelToken = null;
    _notify();
  }

  /// Pauses and returns what was received of the photo's file, for a
  /// download to resume from instead of fetching it again.
  /// The load then holds until [release], so it doesn't fetch the photo
  /// alongside the download.
  Map<CameraObject, Uint8List> handOver() {
    pause();
    _held = true;
    final full = _full;
    final bytes = group.jpeg != null && full != null
        ? full
        : _received.toBytes();
    return bytes.isEmpty ? const {} : {_source: bytes};
  }

  /// Lets a load held by [handOver] start again.
  void release() => _held = false;

  /// Takes the full-size image from [file], the whole of [object] fetched by
  /// a download, so the preview needn't fetch it again. Ignores other files.
  Future<void> adopt(CameraObject object, File file) async {
    if (_disposed || _finished || object != _source) return;
    pause();
    await _running;
    if (_disposed || _finished) return;
    final Uint8List bytes;
    try {
      bytes = await _readStart(file, object.jpegOrPreviewLength);
    } on FileSystemException {
      return;
    }
    if (_disposed || _finished) return;
    _received
      ..clear()
      ..add(bytes);
    if (group.jpeg != null) {
      _finish(_received.takeBytes());
    } else {
      _finish(_previewOf(_received.toBytes()));
    }
  }

  static Future<Uint8List> _readStart(File file, int? length) async {
    if (length == null) return file.readAsBytes();
    final handle = await file.open();
    try {
      return await handle.read(min(length, await handle.length()));
    } finally {
      await handle.close();
    }
  }

  Future<void> _readHead(CancelToken token) async {
    final headLength = min(headReadLength, _source.size);
    final missing = headLength - _received.length;
    if (missing > 0) {
      await _client.download(
        _source,
        (chunk) async {
          _received.add(chunk);
          // As soon as the head is in, not once the transfer winds down.
          if (_received.length >= headLength) _orientationFromHead();
        },
        offset: _received.length,
        length: missing,
        cancelToken: token,
      );
    }
    if (token.isCancelled) throw const TransferCancelledException();
    _orientationFromHead();
  }

  void _orientationFromHead() {
    if (_orientationRead) return;
    final head = _received.toBytes();
    if (group.jpeg != null) {
      _readOrientation(exifOrientation(head));
    } else {
      final orientation = cr3Orientation(head);
      // A CMT1 beyond the head is looked for again with the preview.
      if (orientation != null) _readOrientation(orientation);
    }
  }

  Future<Uint8List> _readJpeg(CancelToken token) async {
    final jpeg = group.jpeg!;
    while (_received.length < jpeg.size) {
      if (token.isCancelled) throw const TransferCancelledException();
      final before = _received.length;
      await _client.download(
        jpeg,
        (chunk) async => _received.add(chunk),
        offset: before,
        length: min(previewChunkLength, jpeg.size - before),
        cancelToken: token,
      );
      if (_received.length == before) {
        throw FileSystemException('The camera sent nothing', jpeg.filename);
      }
    }
    return _received.takeBytes();
  }

  Future<Uint8List?> _readRawPreview(CancelToken token) => readCr3Preview(
    _client,
    group.raw!,
    cancelToken: token,
    step: previewChunkLength,
    into: _received,
  );

  Uint8List? _previewOf(Uint8List cr3) {
    final range = cr3PreviewRange(cr3);
    return range == null
        ? null
        : Uint8List.sublistView(cr3, range.offset, range.offset + range.length);
  }

  void _finish(Uint8List? full) {
    _finished = true;
    if (!_orientationRead) {
      _readOrientation(
        group.jpeg != null
            ? exifOrientation(full ?? Uint8List(0))
            : cr3Orientation(_received.toBytes()),
      );
    }
    if (full != null) {
      _full = full;
      _fullQuarterTurns = extraQuarterTurns(_quarterTurns, full);
    }
    _notify();
  }

  void _readOrientation(int? orientation) {
    _orientationRead = true;
    _quarterTurns = quarterTurnsOf(orientation);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelToken?.cancel();
    _cancelToken = null;
    super.dispose();
  }
}

extension on CameraObject {
  /// How much of the file holds what the preview shows: all of a JPEG, the
  /// start of a CR3.
  int? get jpegOrPreviewLength =>
      kind == CameraObjectKind.jpeg ? null : cr3PreviewReadCap;
}
