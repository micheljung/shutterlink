import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../ptp/camera_client.dart';
import '../ptp/canon/canon_constants.dart';
import '../ptp/canon/canon_events.dart';
import '../ptp/canon/canon_live_view.dart';
import '../ptp/canon/canon_live_view_stats.dart';
import '../ptp/ptp_constants.dart';
import '../ptp/ptp_session.dart';
import '../ptpip/connection.dart';
import '../ptpip/packet.dart';
import '../usb/usb_container.dart';
import '../usb/usb_pipe.dart';
import 'probe_args.dart';

const _packetHeaderSize = 8;
const _packetTypeOffset = 4;
const _hexRadix = 16;
const _hexDigitsPerByte = 2;
const _maxInlineBytes = 32;
const _bytesPerKibibyte = 1024;
const _columnGap = '  ';
const _u32Size = 4;
const _usbContainerTypeOffset = 4;
const _usbContainerCodeOffset = 6;
const _percent = 100;
const _percentDecimals = 1;

String hex(int value) => '0x${value.toRadixString(_hexRadix)}';

String describeRefusal(PtpResponseException error) =>
    '${hex(error.responseCode)} (operation ${hex(error.operation)})';

String describeCanonProperty(int property) {
  final name = canonPropertyNames[property];
  return name == null ? hex(property) : '$name (${hex(property)})';
}

String _inlineBytes(Uint8List bytes) {
  final shown = bytes
      .take(_maxInlineBytes)
      .map((b) => b.toRadixString(_hexRadix).padLeft(_hexDigitsPerByte, '0'));
  return [...shown, if (bytes.length > _maxInlineBytes) '…'].join(' ');
}

/// One GetEvent record on a line: its raw type, then what it says.
String describeCanonRecord(CanonEventRecord record) {
  final type = hex(record.type);
  return switch (parseCanonEvent(record)) {
    CanonPropertyChanged(:final property, :final value, :final u32) =>
      '$type ${describeCanonProperty(property)} = '
          '${u32 == null ? '[${_inlineBytes(value)}]' : hex(u32)}',
    CanonAllowedValues(:final property, :final dataType, :final values) =>
      '$type ${describeCanonProperty(property)} allowed '
          '[${values.map(hex).join(' ')}] (type ${hex(dataType)})',
    CanonObjectAdded(:final handle, :final format) =>
      '$type ObjectAdded handle ${hex(handle)} format ${hex(format)}',
    CanonTransferRequested(:final handle) =>
      '$type TransferRequested handle ${hex(handle)}',
    CanonObjectRemoved(:final handle) =>
      '$type ObjectRemoved handle ${hex(handle)}',
    CanonStorageChanged() => '$type StorageInfoChanged',
    null =>
      '$type size ${record.bytes.length}: '
          '${_inlineBytes(Uint8List.sublistView(record.bytes, canonEventHeaderSize))}',
  };
}

/// The u32 value of [property] in a GetEvent batch, or null.
int? canonPropertyValue(List<CanonEventRecord> records, int property) => records
    .map(parseCanonEvent)
    .whereType<CanonPropertyChanged>()
    .lastWhereOrNull((event) => event.property == property)
    ?.u32;

/// The u32 of a CameraStatusChanged record, or null for any other record.
int? cameraStatusValue(CanonEventRecord record) {
  const valueAt = canonEventHeaderSize;
  if (record.type != CanonEosEvent.cameraStatusChanged ||
      record.bytes.length < valueAt + _u32Size) {
    return null;
  }
  return ByteData.sublistView(record.bytes).getUint32(valueAt, Endian.little);
}

String formatTable(List<String> headers, List<List<String>> rows) {
  final widths = [
    for (var column = 0; column < headers.length; column++)
      [headers, ...rows].map((row) => row[column].length).max,
  ];
  String line(List<String> cells) => [
    for (final (column, cell) in cells.indexed) cell.padRight(widths[column]),
  ].join(_columnGap).trimRight();
  return [line(headers), ...rows.map(line)].map((l) => '$l\n').join();
}

/// Counts the PTP requests sent by opcode, over PTP/IP or USB.
class TransactionLedger {
  final _sent = <int, int>{};

  void onUsbBulkOut(Uint8List bytes) {
    if (bytes.length < usbContainerHeaderSize) {
      return;
    }
    final view = ByteData.sublistView(bytes);
    if (view.getUint16(_usbContainerTypeOffset, Endian.little) ==
        UsbContainerType.command.code) {
      _count(view.getUint16(_usbContainerCodeOffset, Endian.little));
    }
  }

  void onPacket(PtpIpChannel channel, Uint8List frame) {
    if (channel != PtpIpChannel.command || frame.length < _packetHeaderSize) {
      return;
    }
    final type = ByteData.sublistView(frame)
        .getUint32(_packetTypeOffset, Endian.little);
    if (type != PtpIpPacketType.commandRequest) {
      return;
    }
    if (PtpIpPacket.decode(frame) case CommandRequest(:final opcode)) {
      _count(opcode);
    }
  }

  void _count(int opcode) =>
      _sent.update(opcode, (count) => count + 1, ifAbsent: () => 1);

  /// How many requests with one of [opcodes] were sent so far.
  int sentCount(Set<int> opcodes) =>
      opcodes.map((opcode) => _sent[opcode] ?? 0).sum;
}

/// A [UsbBulkPipe] that notes every command it sends in a
/// [TransactionLedger].
class LedgerUsbPipe implements UsbBulkPipe {
  LedgerUsbPipe(this._pipe, this._ledger);

  final UsbBulkPipe _pipe;
  final TransactionLedger _ledger;

  @override
  int get maxPacketSize => _pipe.maxPacketSize;

  @override
  int get maxTransfer => _pipe.maxTransfer;

  @override
  Future<void> bulkOut(Uint8List bytes) {
    _ledger.onUsbBulkOut(bytes);
    return _pipe.bulkOut(bytes);
  }

  @override
  Future<UsbRead> bulkIn(int maxLength, {bool timing = false}) =>
      _pipe.bulkIn(maxLength, timing: timing);

  @override
  Stream<Uint8List> get interrupt => _pipe.interrupt;

  @override
  Future<void> get detached => _pipe.detached;

  @override
  Future<void> clearHalt() => _pipe.clearHalt();

  @override
  Future<Uint8List> classRequest(
    int request, {
    required bool deviceToHost,
    int value = 0,
    int length = 0,
    Uint8List? data,
  }) => _pipe.classRequest(
    request,
    deviceToHost: deviceToHost,
    value: value,
    length: length,
    data: data,
  );

  @override
  Future<void> drainIn() => _pipe.drainIn();

  @override
  Future<void> close() => _pipe.close();
}

String liveViewReport(LiveViewSummary summary) {
  final seconds =
      summary.elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  final fps = seconds == 0 ? 0 : summary.frames / seconds;
  final meanSize = (summary.meanFrameBytes ?? 0) / _bytesPerKibibyte;
  final firstByte = summary.timeToFirstByte;
  final transfer = summary.transfer;
  final counts = summary.counts;
  final overhead = summary.channelOverhead;
  return 'Live view ${seconds.toStringAsFixed(1)} s: ${summary.frames} frames, '
      'average ${fps.toStringAsFixed(2)} fps\n'
      'Time to first byte: mean ${milliseconds(firstByte?.mean)}, '
      'p95 ${milliseconds(firstByte?.p95)}\n'
      'Transfer: mean ${milliseconds(transfer?.mean)}, '
      'p95 ${milliseconds(transfer?.p95)}\n'
      'Frame size: mean ${meanSize.toStringAsFixed(1)} KiB\n'
      'Not ready (0xa102) ${counts.notReady}, busy (0x2019) ${counts.busy}, '
      'errors ${counts.errors}, watchdog aborts ${summary.watchdogAborts}\n'
      '${overhead == null ? '' : _overheadLine(overhead, summary)}';
}

/// Time spent outside the wire, e.g. crossing to the USB worker, against
/// the mean time per frame.
String _overheadLine(LiveViewSpread overhead, LiveViewSummary summary) {
  final share = summary.frames == 0 || summary.elapsed == Duration.zero
      ? '-'
      : '${(_percent * overhead.mean.inMicroseconds * summary.frames / summary.elapsed.inMicroseconds).toStringAsFixed(_percentDecimals)} %';
  return 'Channel overhead: mean ${milliseconds(overhead.mean)}, '
      'p95 ${milliseconds(overhead.p95)}, $share of the frame time\n';
}

/// [CanonLiveViewLoop] with [LiveViewStats] fed from the session tap.
class ProbeLiveView {
  ProbeLiveView(this._session, {required int output})
    : _loop = CanonLiveViewLoop(_session, output: output);

  final PtpSession _session;
  final CanonLiveViewLoop _loop;
  final stats = LiveViewStats();
  final _ended = Completer<void>();
  StreamSubscription<Uint8List>? _frames;
  Uint8List? lastFrame;
  Object? error;

  int get frames => stats.frames;

  /// Completes when the loop stops, on its own or through [stop].
  Future<void> get ended => _ended.future;

  Future<void> start() async {
    _session.onTiming = stats.onTiming;
    _frames = _loop.frames.listen(
      (jpeg) {
        lastFrame = jpeg;
        stats.recordFrame(jpeg);
      },
      onError: (Object failure) {
        error = failure;
        stats.recordError(failure);
      },
      onDone: _end,
    );
    try {
      await _loop.start();
    } catch (_) {
      _session.onTiming = null;
      rethrow;
    }
    stats.reset();
  }

  Future<void> stop() async {
    await _loop.stop();
    await _frames?.cancel();
    _session.onTiming = null;
    _end();
  }

  String summary() =>
      liveViewReport(stats.summarize(_loop.counts)) +
      (error == null ? '' : 'Stopped by: $error\n');

  void _end() {
    if (!_ended.isCompleted) {
      _ended.complete();
    }
  }
}

typedef TimedCanonRecord = ({Duration at, CanonEventRecord record});

/// Polls Canon GetEvent on [interval], stamping each record with [clock].
/// [stop] and [start] may alternate, and [interval] may change in between.
class CanonEventPoller {
  CanonEventPoller(
    this._session,
    this._clock, {
    required this.interval,
    this.onRefused,
  });

  final PtpSession _session;
  final Stopwatch _clock;
  Duration interval;

  /// Called once per response code the camera refuses GetEvent with.
  final void Function(int code)? onRefused;

  final _records = StreamController<TimedCanonRecord>.broadcast(sync: true);
  final _refusedCodes = <int>{};
  Future<void>? _loop;
  Completer<void>? _wake;
  int? _cameraStatus;
  bool _running = false;

  Stream<TimedCanonRecord> get records => _records.stream;

  /// Whether the last CameraStatusChanged said a capture is under way.
  bool get isCapturing => _cameraStatus == CanonCameraStatus.capturing;

  void start() {
    if (_running) {
      return;
    }
    _running = true;
    _loop = _run();
  }

  Future<void> stop() async {
    _running = false;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) {
      wake.complete();
    }
    await _loop;
  }

  /// When the first record passing [test] arrives within [timeout], or null.
  Future<Duration?> waitFor(
    bool Function(CanonEventRecord record) test,
    Duration timeout,
  ) {
    final found = Completer<Duration?>();
    final timer = Timer(timeout, () {
      if (!found.isCompleted) {
        found.complete(null);
      }
    });
    final subscription = records.listen((timed) {
      if (!found.isCompleted && test(timed.record)) {
        found.complete(timed.at);
      }
    });
    return found.future.whenComplete(() {
      timer.cancel();
      return subscription.cancel();
    });
  }

  Future<void> _run() async {
    while (_running) {
      final started = _clock.elapsed;
      try {
        final result = await _session.execute(CanonEosOperation.getEvent);
        final at = _clock.elapsed;
        for (final record in canonEventRecords(result.data)) {
          _cameraStatus = cameraStatusValue(record) ?? _cameraStatus;
          _records.add((at: at, record: record));
        }
      } on PtpResponseException catch (error) {
        if (_refusedCodes.add(error.responseCode)) {
          onRefused?.call(error.responseCode);
        }
      } on CameraDisconnectedException {
        _running = false;
      }
      final wait = interval - (_clock.elapsed - started);
      if (_running && wait > Duration.zero) {
        final wake = _wake = Completer<void>();
        final timer = Timer(wait, () {
          if (!wake.isCompleted) {
            wake.complete();
          }
        });
        await wake.future;
        timer.cancel();
      }
    }
  }
}

/// RemoteReleaseOn(half) → On(full) → Off(full) → Off(half), as libgphoto2
/// presses the shutter.
List<(int opcode, List<int> params)> canonReleaseSequence(
  ReleaseParams params,
) => [
  (
    CanonEosOperation.remoteReleaseOn,
    [params.half, CanonRemoteRelease.withAutofocus],
  ),
  (
    CanonEosOperation.remoteReleaseOn,
    [params.full, CanonRemoteRelease.withAutofocus],
  ),
  (CanonEosOperation.remoteReleaseOff, [params.full]),
  (CanonEosOperation.remoteReleaseOff, [params.half]),
];

/// A normalized point in a coordinate space of [space].
({int x, int y}) scalePoint(ProbePoint point, ProbeSize space) =>
    (x: (point.x * space.width).round(), y: (point.y * space.height).round());

/// The SetLiveAfFrame data-out: `u32 x, u32 y`.
Uint8List canonAfFramePayload(int x, int y) {
  final payload = ByteData(2 * _u32Size)
    ..setUint32(0, x, Endian.little)
    ..setUint32(_u32Size, y, Endian.little);
  return payload.buffer.asUint8List();
}

typedef DiffRun = ({List<int> handles, int transactions, Duration took});

/// When each step after a remote release happened, relative to [trigger].
class ReleaseTimeline {
  ReleaseTimeline(this.trigger);

  final Duration trigger;
  final _finished = Completer<void>();
  Duration? released;
  Duration? captureStarted;
  Duration? storageChanged;
  Duration? objectAdded;
  Duration? captureDone;
  Duration? newHandle;
  Duration? thumbnail;
  int? addedHandle;
  bool busy = false;
  DiffRun? coldDiff;
  DiffRun? warmDiff;

  /// Completes on the first new file or the camera going idle again; a
  /// StorageInfoChanged alone comes too early to diff.
  Future<void> get finished => _finished.future;

  bool get isFinished => _finished.isCompleted;

  /// Whether any event of the capture arrived.
  bool get sawCapture => captureStarted != null || objectAdded != null;

  /// Notes [record], arriving at [at] on the same clock as [trigger], and
  /// returns how long after the trigger it came.
  Duration note(Duration at, CanonEventRecord record) {
    final since = at - trigger;
    switch (cameraStatusValue(record)) {
      case CanonCameraStatus.capturing:
        captureStarted ??= since;
      case CanonCameraStatus.idle when captureStarted != null:
        captureDone ??= since;
        _finish();
    }
    switch (parseCanonEvent(record)) {
      case CanonStorageChanged():
        storageChanged ??= since;
      case CanonObjectAdded(:final handle, :final format)
          when format != PtpObjectFormat.association && objectAdded == null:
        objectAdded = since;
        addedHandle = handle;
        _finish();
      default:
    }
    return since;
  }

  void _finish() {
    if (!_finished.isCompleted) {
      _finished.complete();
    }
  }

  static const tableHeaders = [
    'Shot',
    'Release',
    'Started',
    '0xc185',
    'Added',
    'Done',
    'Handle',
    'Thumb',
    'Cold diff',
    'Warm diff',
  ];

  List<String> row(int shot) => [
    '$shot',
    milliseconds(released),
    milliseconds(captureStarted),
    milliseconds(storageChanged),
    milliseconds(objectAdded),
    milliseconds(captureDone),
    milliseconds(newHandle),
    milliseconds(thumbnail),
    _describeDiff(coldDiff),
    _describeDiff(warmDiff),
  ];

  static String _describeDiff(DiffRun? diff) =>
      diff == null ? '-' : '${diff.transactions} tx ${milliseconds(diff.took)}';
}
