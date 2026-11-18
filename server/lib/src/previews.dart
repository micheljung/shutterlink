import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart';
import 'package:meta/meta.dart';

import 'limits.dart' as limits;
import 'store.dart';

const int thumbnailShortEdge = 400;
const int viewLongEdge = 2048;
const int _thumbnailQuality = 70;
const int _viewQuality = 80;
const List<int> _decodeScales = [8, 4, 2];

/// A second crashed attempt marks the photo failed; one is forgiven.
const int _crashedAttemptsToFail = 2;

const int _markerPrefix = 0xFF;
const int _soi = 0xD8;
const int _eoi = 0xD9;
const int _sos = 0xDA;
const int _tem = 0x01;
const int _rst0 = 0xD0;
const int _rst7 = 0xD7;
const int _sof0 = 0xC0;
const int _sof1 = 0xC1;
const int _sof2 = 0xC2;
const int _sof15 = 0xCF;
const int _dht = 0xC4;
const int _jpg = 0xC8;
const int _dac = 0xCC;
const int _lengthBytes = 2;

/// Length, precision, height, width and component count.
const int _minFrameLength = 8;

class JpegHeader {
  const JpegHeader(this.width, this.height, {required this.progressive});

  final int width;
  final int height;
  final bool progressive;
}

/// Reads the frame size from the SOF marker without decoding anything. Null
/// for anything but a baseline, extended sequential or progressive Huffman
/// JPEG, or when the header is cut short.
JpegHeader? readJpegHeader(Uint8List bytes) {
  if (bytes.length < _lengthBytes ||
      bytes[0] != _markerPrefix ||
      bytes[1] != _soi) {
    return null;
  }
  var i = _lengthBytes;
  while (i < bytes.length) {
    if (bytes[i] != _markerPrefix) return null;
    while (i < bytes.length && bytes[i] == _markerPrefix) {
      i++;
    }
    if (i >= bytes.length) return null;
    final marker = bytes[i++];
    if (marker == _tem || (marker >= _rst0 && marker <= _rst7)) continue;
    if (marker == 0 || marker == _soi || marker == _eoi || marker == _sos) {
      return null;
    }
    if (i + _lengthBytes > bytes.length) return null;
    final length = bytes[i] << 8 | bytes[i + 1];
    if (length < _lengthBytes || i + length > bytes.length) return null;
    if (marker == _sof0 || marker == _sof1 || marker == _sof2) {
      if (length < _minFrameLength) return null;
      final height = bytes[i + 3] << 8 | bytes[i + 4];
      final width = bytes[i + 5] << 8 | bytes[i + 6];
      if (width == 0 || height == 0) return null;
      return JpegHeader(width, height, progressive: marker == _sof2);
    }
    final isFrame =
        marker > _sof2 &&
        marker <= _sof15 &&
        marker != _dht &&
        marker != _jpg &&
        marker != _dac;
    if (isFrame) return null;
    i += length;
  }
  return null;
}

typedef JpegDecode = Image? Function(
  Uint8List bytes, {
  required int scale,
  required int maxPixels,
});

Image? _decodeJpg(
  Uint8List bytes, {
  required int scale,
  required int maxPixels,
}) => decodeJpg(bytes, scale: scale, maxPixels: maxPixels);

class PreviewRendition {
  const PreviewRendition(this.thumbnail, this.view, this.width, this.height);

  final Uint8List thumbnail;
  final Uint8List view;
  final int width;
  final int height;
}

/// Makes the thumbnail and view of a JPEG, or returns null if the header or
/// the size limits refuse it. Never upscales; strips EXIF.
PreviewRendition? renderPreview(
  Uint8List bytes, {
  int maxPixels = limits.previewMaxPixels,
  int maxProgressivePixels = limits.previewMaxProgressivePixels,
  JpegDecode decode = _decodeJpg,
}) {
  final header = readJpegHeader(bytes);
  if (header == null) return null;
  final limit = header.progressive ? maxProgressivePixels : maxPixels;
  if (header.width * header.height > limit) return null;
  final long = header.width > header.height ? header.width : header.height;
  final short = header.width > header.height ? header.height : header.width;
  final scale = _decodeScales.firstWhere(
    (s) => long ~/ s >= viewLongEdge && short ~/ s >= thumbnailShortEdge,
    orElse: () => 1,
  );
  final Image? decoded;
  try {
    decoded = decode(bytes, scale: scale, maxPixels: maxPixels);
  } on ImageException {
    return null;
  }
  if (decoded == null) return null;
  final view = _shrink(decoded, viewLongEdge, longEdge: true)
    ..exif = ExifData();
  final thumbnail = _shrink(view, thumbnailShortEdge, longEdge: false)
    ..exif = ExifData();
  return PreviewRendition(
    encodeJpg(thumbnail, quality: _thumbnailQuality, chroma: JpegChroma.yuv420),
    encodeJpg(view, quality: _viewQuality, chroma: JpegChroma.yuv420),
    view.width,
    view.height,
  );
}

Image _shrink(Image image, int edge, {required bool longEdge}) {
  final w = image.width;
  final h = image.height;
  final current = (w > h) == longEdge ? w : h;
  if (current <= edge) return image;
  final ratio = edge / current;
  int scaled(int side) {
    final value = (side * ratio).round();
    return value < 1 ? 1 : value;
  }

  return copyResize(
    image,
    width: scaled(w),
    height: scaled(h),
    interpolation: Interpolation.average,
  );
}

typedef _JobMessage = (SendPort, String, String, String, int, int);

void _previewJob(_JobMessage message) {
  final (port, source, thumbnailPath, viewPath, maxPixels, maxProgressive) =
      message;
  final rendition = renderPreview(
    File(source).readAsBytesSync(),
    maxPixels: maxPixels,
    maxProgressivePixels: maxProgressive,
  );
  if (rendition == null) Isolate.exit(port, null);
  File(thumbnailPath).writeAsBytesSync(rendition.thumbnail, flush: true);
  File(viewPath).writeAsBytesSync(rendition.view, flush: true);
  Isolate.exit(port, [rendition.width, rendition.height]);
}

typedef _Item = ({String name, String key});

class PreviewQueue {
  PreviewQueue(
    this._store, {
    this._concurrency = limits.previewConcurrency,
    this._maxPixels = limits.previewMaxPixels,
    this._maxProgressivePixels = limits.previewMaxProgressivePixels,
    @visibleForTesting this._holdScan,
    @visibleForTesting Future<void>? holdWorkers,
  }) {
    _store.onCommitted = enqueueLive;
    if (holdWorkers != null) {
      _held = true;
      unawaited(
        holdWorkers.whenComplete(() {
          _held = false;
          _schedule();
        }),
      );
    }
  }

  final SessionStore _store;
  final int _concurrency;
  final int _maxPixels;
  final int _maxProgressivePixels;
  final Future<void>? _holdScan;
  final List<_Item> _live = [];
  final Queue<_Item> _backfill = Queue();

  /// Queued and in-flight items, so neither lane nor the scan repeats one.
  final Set<String> _known = {};
  final Map<String, Isolate> _isolates = {};
  final Set<Future<void>> _jobs = {};
  Future<void>? _scan;
  bool _scanning = false;
  bool _held = false;
  bool _pumpScheduled = false;
  bool _closing = false;
  final Completer<void> _closed = Completer();
  Completer<void>? _idle;

  static String _id(String name, String key) => '$name/$key';

  bool get _isIdle =>
      !_scanning && _live.isEmpty && _backfill.isEmpty && _jobs.isEmpty;

  Future<void> get idle {
    if (_isIdle) return Future.value();
    return (_idle ??= Completer()).future;
  }

  void enqueueLive(String name, String key) {
    if (_closing || !_known.add(_id(name, key))) return;
    _live.add((name: name, key: key));
    _schedule();
  }

  void _enqueueBackfill(String name, String key) {
    if (_closing || !_known.add(_id(name, key))) return;
    _backfill.add((name: name, key: key));
    _schedule();
  }

  Future<void> scan() {
    if (_scan == null) _scanning = true;
    return _scan ??= _runScan();
  }

  Future<void> _runScan() async {
    try {
      if (_holdScan case final hold?) await Future.any([hold, _closed.future]);
      await for (final name in _store.sessionNames()) {
        if (_closing) break;
        for (final pending in await _store.scanSession(name)) {
          if (_closing) break;
          if (_known.contains(_id(name, pending.key))) continue;
          if (pending.crashedAttempts >= _crashedAttemptsToFail) {
            await _store.markFailed(name, pending.key);
          } else {
            _enqueueBackfill(name, pending.key);
          }
        }
      }
    } catch (e) {
      stderr.writeln('Preview scan failed: $e');
    } finally {
      _scanning = false;
      _checkIdle();
    }
  }

  void _schedule() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    Timer.run(_pump);
  }

  void _pump() {
    _pumpScheduled = false;
    if (_closing || _held) return;
    while (_jobs.length < _concurrency &&
        (_live.isNotEmpty || _backfill.isNotEmpty)) {
      final item = _live.isNotEmpty
          ? _live.removeLast()
          : _backfill.removeFirst();
      late final Future<void> job;
      job = _run(item).whenComplete(() {
        _jobs.remove(job);
        _known.remove(_id(item.name, item.key));
        _schedule();
        _checkIdle();
      });
      _jobs.add(job);
    }
  }

  void _checkIdle() {
    if (!_isIdle) return;
    _idle?.complete();
    _idle = null;
  }

  Future<void> _run(_Item item) async {
    final (:name, :key) = item;
    final id = _id(name, key);
    final thumbnail = _store.newTmpFile();
    final view = _store.newTmpFile();
    try {
      if (!await _store.writeAttempt(name, key)) return;
      if (_closing) {
        await _store.deleteAttempt(name, key);
        return;
      }
      final port = ReceivePort();
      final Object? result;
      try {
        final Isolate isolate;
        try {
          isolate = await Isolate.spawn<_JobMessage>(
            _previewJob,
            (
              port.sendPort,
              _store.photoFile(name, key).path,
              thumbnail.path,
              view.path,
              _maxPixels,
              _maxProgressivePixels,
            ),
            onExit: port.sendPort,
            onError: port.sendPort,
          );
        } catch (_) {
          await _store.deleteAttempt(name, key);
          rethrow;
        }
        _isolates[id] = isolate;
        if (_closing) isolate.kill(priority: Isolate.immediate);
        result = await port.first;
      } finally {
        port.close();
        _isolates.remove(id);
      }
      if (_closing) {
        await _store.deleteAttempt(name, key);
      } else if (result case [final int width, final int height]) {
        await _store.commitPreview(name, key, thumbnail, view, width, height);
      } else {
        await _store.markFailed(name, key);
      }
    } catch (e) {
      stderr.writeln('Preview failed: $e');
    } finally {
      for (final file in [thumbnail, view]) {
        if (await file.exists()) await file.delete();
      }
    }
  }

  /// Stops the scan and every job. A job ended this way leaves no marker,
  /// so its photo is generated again after the next start.
  Future<void> close() async {
    _closing = true;
    if (!_closed.isCompleted) _closed.complete();
    _live.clear();
    _backfill.clear();
    for (final isolate in _isolates.values) {
      isolate.kill(priority: Isolate.immediate);
    }
    await Future.wait([..._jobs, ?_scan]);
  }
}
