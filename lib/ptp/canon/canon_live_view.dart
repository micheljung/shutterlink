import 'dart:async';
import 'dart:math' show min;
import 'dart:typed_data';

import '../ptp_constants.dart';
import '../ptp_session.dart';
import '../ptp_transport.dart';
import 'canon_constants.dart';

/// The first wait after the camera had no frame; it doubles up to
/// [canonLiveViewMaxBackoff] while frames stay away.
const canonLiveViewMinBackoff = Duration(milliseconds: 20);
const canonLiveViewMaxBackoff = Duration(milliseconds: 50);

const _u32Size = 4;
const _recordHeaderSize = 2 * _u32Size;
const _propertyPayloadSize = 3 * _u32Size;
const _backoffGrowth = 2;

/// The JPEG payloads in a GetViewFinderData response. Its records are
/// `u32 length, u32 type, payload`; a malformed record ends the list.
List<Uint8List> canonViewFinderJpegs(Uint8List data) {
  final view = ByteData.sublistView(data);
  final jpegs = <Uint8List>[];
  var offset = 0;
  while (offset + _recordHeaderSize <= data.length) {
    final length = view.getUint32(offset, Endian.little);
    final type = view.getUint32(offset + _u32Size, Endian.little);
    if (length < _recordHeaderSize || offset + length > data.length) {
      break;
    }
    if (type == CanonViewFinder.jpegRecordType) {
      jpegs.add(
        Uint8List.sublistView(
          data,
          offset + _recordHeaderSize,
          offset + length,
        ),
      );
    }
    offset += length;
  }
  return jpegs;
}

/// The SetDevicePropValueEx data-out that sets [property] to a u32 [value].
Uint8List canonPropertyPayload(int property, int value) {
  final payload = ByteData(_propertyPayloadSize)
    ..setUint32(0, _propertyPayloadSize, Endian.little)
    ..setUint32(_u32Size, property, Endian.little)
    ..setUint32(2 * _u32Size, value, Endian.little);
  return payload.buffer.asUint8List();
}

/// Canon EOS live view on a [PtpSession]: [start] sends the viewfinder to
/// the host, then frames are fetched one GetViewFinderData at a time until
/// [stop] is called or [frames] is cancelled. Stopping hands the viewfinder
/// back to the camera's screen.
///
/// Requests share the session's queue with every other command, so the
/// event poller and downloads interleave with frames.
class CanonLiveViewLoop {
  CanonLiveViewLoop(
    this._session, {
    this.output = CanonEvfOutput.pc,
    this.minFrameInterval,
  });

  final PtpSession _session;

  /// The EVF output (0xD1B0) while live view runs, one of [CanonEvfOutput].
  final int output;

  /// The shortest time between two frames; null fetches as fast as the
  /// camera answers.
  final Duration? minFrameInterval;

  late final _frames = StreamController<Uint8List>(onCancel: stop);
  Future<void>? _startup;
  Future<void>? _loop;
  Future<void>? _stopped;
  bool _stopping = false;
  int _notReadyCount = 0;
  int _busyCount = 0;
  int _errorCount = 0;

  /// JPEG frames in arrival order. A failure other than "not ready" or
  /// "busy" arrives as an error, after which the stream closes. Listen
  /// before [start]: frames are buffered without bound until then.
  Stream<Uint8List> get frames => _frames.stream;

  /// Answers of 0xA102: the camera had no new frame.
  int get notReadyCount => _notReadyCount;

  /// Answers of 0x2019.
  int get busyCount => _busyCount;

  /// Failures that stopped live view, including a failed [start].
  int get errorCount => _errorCount;

  /// Turns the EVF on and routes it to the host, then starts fetching.
  /// Throws if the camera refuses either property; live view is stopped then.
  Future<void> start() async {
    if (_startup != null || _stopped != null) {
      throw StateError('CanonLiveViewLoop can only be started once');
    }
    assert(_frames.hasListener, 'Listen to frames before start');
    final startup = _startup = _enable();
    try {
      await startup;
    } catch (_) {
      _errorCount++;
      await stop();
      rethrow;
    }
    if (!_stopping) {
      _loop = _run();
    }
  }

  /// Stops fetching, restores the EVF output to the camera's screen and
  /// closes [frames]. Safe to call more than once.
  Future<void> stop() => _stopped ??= _shutdown();

  Future<void> _enable() async {
    await _setProperty(CanonEosProperty.evfMode, CanonEvfMode.on);
    await _setProperty(CanonEosProperty.evfOutputDevice, output);
  }

  Future<void> _shutdown() async {
    _stopping = true;
    final startup = _startup;
    if (startup != null) {
      await startup.then<void>((_) {}, onError: (_) {});
      await _loop;
      // The camera may already be gone, and then there is nothing to restore.
      await _setProperty(
        CanonEosProperty.evfOutputDevice,
        CanonEvfOutput.tft,
      ).then<void>((_) {}, onError: (_) {});
    }
    unawaited(_frames.close());
  }

  Future<void> _run() async {
    var backoff = canonLiveViewMinBackoff;
    final sinceFrame = Stopwatch();
    Future<void> backOff() async {
      await Future<void>.delayed(backoff);
      backoff = Duration(
        microseconds: min(
          backoff.inMicroseconds * _backoffGrowth,
          canonLiveViewMaxBackoff.inMicroseconds,
        ),
      );
    }

    while (!_stopping) {
      final cap = minFrameInterval;
      if (cap != null && sinceFrame.isRunning && sinceFrame.elapsed < cap) {
        await Future<void>.delayed(cap - sinceFrame.elapsed);
        continue;
      }
      final PtpTransactionResult result;
      try {
        result = await _session.execute(
          CanonEosOperation.getViewFinderData,
          params: const [CanonViewFinder.requestParameter],
          acceptedCodes: const {
            PtpResponseCode.ok,
            PtpResponseCode.deviceBusy,
            CanonEosResponseCode.deviceNotReady,
          },
        );
      } catch (error, stackTrace) {
        if (!_stopping) {
          _errorCount++;
          _frames.addError(error, stackTrace);
          unawaited(stop());
        }
        return;
      }
      if (_stopping) {
        return;
      }
      switch (result.code) {
        case CanonEosResponseCode.deviceNotReady:
          _notReadyCount++;
          await backOff();
        case PtpResponseCode.deviceBusy:
          _busyCount++;
          await backOff();
        default:
          final jpegs = canonViewFinderJpegs(result.data);
          if (jpegs.isEmpty) {
            await backOff();
            continue;
          }
          jpegs.forEach(_frames.add);
          backoff = canonLiveViewMinBackoff;
          sinceFrame
            ..reset()
            ..start();
      }
    }
  }

  Future<void> _setProperty(int property, int value) async {
    await _session.execute(
      CanonEosOperation.setDevicePropValueEx,
      dataOut: canonPropertyPayload(property, value),
    );
  }
}
