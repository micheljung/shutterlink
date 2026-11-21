import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../ptp/camera_client.dart';
import '../ptp/canon/canon_constants.dart';
import '../ptp/canon/canon_events.dart';
import '../ptp/canon/canon_live_view.dart';
import '../ptp/canon/canon_live_view_stats.dart';
import '../ptp/ptp_camera_client.dart';
import '../ptp/ptp_constants.dart';
import 'probe_args.dart';
import 'probe_measurements.dart';

/// How long the set baseline is measured, and how long zoom and AF keep
/// live view running afterwards.
const probeMeasureWindow = Duration(seconds: 2);

/// The GetEvent intervals `--set` compares.
const setPollIntervals = [
  Duration(milliseconds: 250),
  Duration(milliseconds: 350),
  Duration(milliseconds: 500),
];

const _echoTimeout = Duration(seconds: 3);
const _second = Duration(seconds: 1);
const _diffOperations = {
  PtpOperation.getStorageIds,
  PtpOperation.getObjectHandles,
  PtpOperation.getObjectInfo,
};
const _operationNames = {
  CanonEosOperation.remoteReleaseOn: 'RemoteReleaseOn',
  CanonEosOperation.remoteReleaseOff: 'RemoteReleaseOff',
};

/// The Wi-Fi remote-shooting measurements of `bin/probe.dart`.
class RemoteProbe {
  RemoteProbe(
    this._out,
    this._client,
    this._ledger,
    this._options, {
    Uint8List? initialDump,
    this.measureWindow = probeMeasureWindow,
    Stream<Object?>? interrupts,
  }) : _initialRecords = initialDump == null
           ? null
           : canonEventRecords(initialDump),
       _interrupts = interrupts ?? ProcessSignal.sigint.watch();

  final StringSink _out;
  final PtpCameraClient _client;
  final TransactionLedger _ledger;
  final RemoteProbeOptions _options;
  final List<CanonEventRecord>? _initialRecords;
  final Duration measureWindow;
  final Stream<Object?> _interrupts;
  final _clock = Stopwatch()..start();
  final _interrupted = Completer<void>();
  late final _poller = CanonEventPoller(
    _client.session,
    _clock,
    interval: _options.pollInterval,
    onRefused: (code) => _out.writeln('GetEvent refused: ${hex(code)}'),
  );
  ProbeLiveView? _liveView;

  Future<int> run() async {
    final interrupts = _interrupts.listen((_) {
      if (!_interrupted.isCompleted) {
        _interrupted.complete();
      }
    });
    try {
      return await switch (_options.mode) {
        RemoteProbeMode.liveView => _runLiveView(),
        RemoteProbeMode.props => _runProps(),
        RemoteProbeMode.release => _runRelease(),
        RemoteProbeMode.set => _runSet(),
        RemoteProbeMode.zoom => _runZoom(),
        RemoteProbeMode.af => _runAf(),
      };
    } finally {
      await interrupts.cancel();
      await _poller.stop();
      await _liveView?.stop();
    }
  }

  Future<int> _runLiveView() async {
    final liveView = await _startLiveView();
    if (liveView == null) {
      return exitCameraRefused;
    }
    _poller.start();
    var second = 0;
    var reported = 0;
    final ticker = Timer.periodic(_second, (_) {
      second++;
      _out.writeln('${second}s: ${liveView.frames - reported} fps');
      reported = liveView.frames;
    });
    await _wait(
      Duration(seconds: _options.liveViewSeconds),
      orUntil: liveView.ended,
    );
    ticker.cancel();
    final summary = liveView.summary();
    await _poller.stop();
    await liveView.stop();
    _out.write(summary);
    await _saveFrame(liveView);
    return liveView.error == null ? exitOk : exitUnavailable;
  }

  Future<int> _runProps() async {
    final records = _initialRecords;
    if (records == null) {
      _out.writeln('The camera sent no initial GetEvent dump.');
    } else {
      final events = records.map(parseCanonEvent).toList();
      _out.writeln('Core settings:');
      for (final MapEntry(key: property) in canonPropertyNames.entries) {
        final value = canonPropertyValue(records, property);
        final allowed = events
            .whereType<CanonAllowedValues>()
            .where((event) => event.property == property)
            .lastOrNull;
        _out.writeln(
          '  ${describeCanonProperty(property)} = '
          '${value == null ? '-' : hex(value)}'
          '${allowed == null ? '' : ', allowed [${allowed.values.map(hex).join(' ')}]'}',
        );
      }
      _out.writeln('Initial dump:');
      for (final record in records) {
        if (record.type == CanonEosEvent.propValueChanged ||
            record.type == CanonEosEvent.availListChanged) {
          _out.writeln('  ${describeCanonRecord(record)}');
        }
      }
    }
    _out.writeln(
      'Polling GetEvent every ${_options.pollInterval.inMilliseconds} ms; '
      'move the mode dial. Press Ctrl-C to stop.',
    );
    final changes = _poller.records.listen(
      (timed) => _out.writeln(
        '${DateTime.now().toIso8601String()} '
        '${describeCanonRecord(timed.record)}',
      ),
    );
    _poller.start();
    await _wait(_options.duration);
    await _poller.stop();
    await changes.cancel();
    return exitOk;
  }

  Future<int> _runRelease() async {
    final liveView = await _startLiveView();
    if (liveView == null) {
      _out.writeln('Measuring without live view.');
    }
    _poller.start();
    var known = (await _client.newestFolderHandles()).toSet();
    final rows = <List<String>>[];
    for (var shot = 1; shot <= _options.shots; shot++) {
      _out.writeln('Shot $shot:');
      final timeline = ReleaseTimeline(_clock.elapsed);
      String since() => milliseconds(_clock.elapsed - timeline.trigger);
      final events = _poller.records.listen((timed) {
        final at = timeline.note(timed.at, timed.record);
        _out.writeln(
          '  +${milliseconds(at)} ${describeCanonRecord(timed.record)}',
        );
      });
      for (final (opcode, params) in canonReleaseSequence(
        _options.releaseParams,
      )) {
        final code = await _send(opcode, params: params);
        _out.writeln(
          '  +${since()} ${_operationNames[opcode]}(${params.first}) '
          '-> ${hex(code)}',
        );
      }
      timeline.released = _clock.elapsed - timeline.trigger;
      await _wait(_options.releaseTimeout, orUntil: timeline.stored);
      if (!timeline.isStored) {
        _out.writeln(
          '  No 0xc185 or new object within '
          '${_options.releaseTimeout.inSeconds} s.',
        );
      }
      final cold = timeline.coldDiff = await _diff();
      final fresh = cold.handles.where((h) => !known.contains(h)).toList();
      if (fresh.isNotEmpty) {
        timeline.newHandle = _clock.elapsed - timeline.trigger;
      }
      final warm = timeline.warmDiff = await _diff();
      known = {...known, ...cold.handles, ...warm.handles};
      _out
        ..writeln(
          '  Diff cold: ${cold.transactions} transactions in '
          '${milliseconds(cold.took)}; warm: ${warm.transactions} '
          'transactions in ${milliseconds(warm.took)}',
        )
        ..writeln('  New handles: ${fresh.map(hex).join(' ')}');
      for (final handle in fresh) {
        final thumbnail = await _client.session.execute(
          PtpOperation.getThumb,
          params: [handle],
          acceptedCodes: const {
            PtpResponseCode.ok,
            PtpResponseCode.noThumbnailPresent,
            PtpResponseCode.invalidObjectHandle,
          },
        );
        _out.writeln(
          '  +${since()} GetThumb ${hex(handle)} -> ${hex(thumbnail.code)}, '
          '${thumbnail.data.length} bytes',
        );
        if (thumbnail.code == PtpResponseCode.ok) {
          timeline.thumbnail = _clock.elapsed - timeline.trigger;
          break;
        }
      }
      await events.cancel();
      rows.add(timeline.row(shot));
    }
    _out.write(formatTable(ReleaseTimeline.tableHeaders, rows));
    return exitOk;
  }

  Future<int> _runSet() async {
    final (:property, :value) = _options.assignment!;
    final original = _initialRecords == null
        ? null
        : canonPropertyValue(_initialRecords, property);
    _out.writeln(
      '${describeCanonProperty(property)} is '
      '${original == null ? 'not in the initial dump' : hex(original)}; '
      'setting ${hex(value)}.',
    );
    final liveView = await _startLiveView();
    if (liveView == null) {
      _out.writeln('Measuring echo without live view.');
    }
    final baseline = await _fps(liveView, () => _wait(measureWindow));
    _out.writeln('Without GetEvent polling: ${_fpsText(baseline)}');
    final rows = <List<String>>[];
    var current = original;
    for (final interval in setPollIntervals) {
      _poller.interval = interval;
      _poller.start();
      final echoes = <Duration>[];
      var missed = 0;
      var refused = 0;
      final fps = await _fps(liveView, () async {
        for (var trial = 1; trial <= _options.trials; trial++) {
          final target = trial.isEven && original != null ? original : value;
          final sent = _clock.elapsed;
          final code = await _send(
            CanonEosOperation.setDevicePropValueEx,
            dataOut: canonPropertyPayload(property, target),
          );
          final label =
              '  ${interval.inMilliseconds} ms trial $trial '
              '${hex(target)}';
          if (code != PtpResponseCode.ok) {
            refused++;
            _out.writeln('$label: refused ${hex(code)}');
            continue;
          }
          current = target;
          final echo = await _poller.waitFor(
            (record) => switch (parseCanonEvent(record)) {
              CanonPropertyChanged(property: final changed) =>
                changed == property,
              _ => false,
            },
            _echoTimeout,
          );
          if (echo == null) {
            missed++;
            _out.writeln('$label: no echo');
          } else {
            echoes.add(echo - sent);
            _out.writeln('$label: echo after ${milliseconds(echo - sent)}');
          }
        }
      });
      await _poller.stop();
      rows.add([
        '${interval.inMilliseconds} ms',
        milliseconds(meanDuration(echoes)),
        milliseconds(echoes.maxOrNull),
        '$missed',
        '$refused',
        _fpsText(fps),
        fps == null || baseline == null
            ? '-'
            : (baseline - fps).toStringAsFixed(2),
      ]);
    }
    if (original != null && current != original) {
      final code = await _send(
        CanonEosOperation.setDevicePropValueEx,
        dataOut: canonPropertyPayload(property, original),
      );
      _out.writeln('Restored ${hex(original)} -> ${hex(code)}');
    }
    _out.write(
      formatTable([
        'Interval',
        'Echo mean',
        'Echo max',
        'Missed',
        'Refused',
        'fps',
        'fps cost',
      ], rows),
    );
    return exitOk;
  }

  Future<int> _runZoom() async {
    final liveView = await _startLiveView();
    final level = _options.zoom!;
    final code = await _send(CanonEosOperation.zoom, params: [level]);
    _out.writeln('Zoom $level (0x9158) -> ${hex(code)}');
    await _settle(liveView);
    return exitOk;
  }

  Future<int> _runAf() async {
    final liveView = await _startLiveView();
    final (:x, :y) = scalePoint(_options.af!, _options.afSpace);
    final frame = await _send(
      CanonEosOperation.setLiveAfFrame,
      dataOut: canonAfFramePayload(x, y),
    );
    _out.writeln('SetLiveAfFrame $x,$y (0x915a) -> ${hex(frame)}');
    if (frame != PtpResponseCode.ok) {
      final position = await _send(
        CanonEosOperation.zoomPosition,
        params: [x, y],
      );
      _out.writeln('ZoomPosition $x,$y (0x9159) -> ${hex(position)}');
      final focus = await _send(CanonEosOperation.doAf);
      _out.writeln('DoAf (0x9154) -> ${hex(focus)}');
    }
    await _settle(liveView);
    return exitOk;
  }

  Future<ProbeLiveView?> _startLiveView() async {
    final liveView = ProbeLiveView(_client.session, output: _options.evfOutput);
    try {
      await liveView.start();
    } on PtpResponseException catch (error) {
      _out.writeln('Live view refused: ${describeRefusal(error)}');
      return null;
    }
    _out.writeln('Live view on (EVF output ${_options.evfOutput}).');
    return _liveView = liveView;
  }

  Future<void> _settle(ProbeLiveView? liveView) async {
    if (liveView == null) {
      return;
    }
    final frames = liveView.frames;
    await _wait(measureWindow, orUntil: liveView.ended);
    _out.writeln(
      '${liveView.frames - frames} frames in the next '
      '${measureWindow.inMilliseconds} ms',
    );
    await _saveFrame(liveView);
  }

  Future<void> _saveFrame(ProbeLiveView liveView) async {
    final path = _options.saveFrame;
    if (path == null) {
      return;
    }
    final frame = liveView.lastFrame;
    if (frame == null) {
      _out.writeln('No frame to save.');
      return;
    }
    await File(path).writeAsBytes(frame);
    _out.writeln('Saved the last frame (${frame.length} bytes) -> $path');
  }

  /// The frame rate while [during] runs, or null without live view.
  Future<double?> _fps(
    ProbeLiveView? liveView,
    Future<void> Function() during,
  ) async {
    final frames = liveView?.frames ?? 0;
    final started = _clock.elapsed;
    await during();
    final seconds =
        (_clock.elapsed - started).inMicroseconds /
        Duration.microsecondsPerSecond;
    return liveView == null || seconds == 0
        ? null
        : (liveView.frames - frames) / seconds;
  }

  static String _fpsText(double? fps) =>
      fps == null ? '-' : '${fps.toStringAsFixed(2)} fps';

  Future<DiffRun> _diff() async {
    final before = _ledger.sentCount(_diffOperations);
    final started = _clock.elapsed;
    final handles = await _client.newestFolderHandles();
    return (
      handles: handles,
      transactions: _ledger.sentCount(_diffOperations) - before,
      took: _clock.elapsed - started,
    );
  }

  /// The response code, whether the camera accepted the command or not.
  Future<int> _send(
    int opcode, {
    List<int> params = const [],
    Uint8List? dataOut,
  }) async {
    try {
      return (await _client.session.execute(
        opcode,
        params: params,
        dataOut: dataOut,
      )).code;
    } on PtpResponseException catch (error) {
      return error.responseCode;
    }
  }

  /// Until [limit] passes, [orUntil] completes or Ctrl-C is pressed.
  Future<void> _wait(Duration? limit, {Future<void>? orUntil}) async {
    final done = Completer<void>();
    void finish([Object? _]) {
      if (!done.isCompleted) {
        done.complete();
      }
    }

    final timer = limit == null ? null : Timer(limit, finish);
    unawaited(_interrupted.future.then(finish));
    unawaited(orUntil?.then(finish));
    await done.future;
    timer?.cancel();
  }
}
