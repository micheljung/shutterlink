import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:collection/collection.dart';

import '../camera_client.dart';
import '../ptp_session.dart';
import 'canon_constants.dart';
import 'canon_live_view.dart';

const _fpsWindow = Duration(seconds: 1);
const _averageWindow = Duration(seconds: 30);
const _percentile = 95;
const _percent = 100;
const _bytesPerKilobyte = 1024;
const _millisecondDecimals = 1;
const _rateDecimals = 1;
const _kilobyteDecimals = 1;
const _labelWidth = 10;
const _secondsWidth = 2;

typedef LiveViewCounts = ({int notReady, int busy, int errors});

const noLiveViewCounts = (notReady: 0, busy: 0, errors: 0);

extension CanonLiveViewLoopCounts on CanonLiveViewLoop {
  LiveViewCounts get counts =>
      (notReady: notReadyCount, busy: busyCount, errors: errorCount);
}

String milliseconds(Duration? duration) => duration == null
    ? '-'
    : '${(duration.inMicroseconds / Duration.microsecondsPerMillisecond).toStringAsFixed(_millisecondDecimals)} ms';

/// Whether [error] is the session watchdog cutting a silent transaction.
bool _isWatchdogAbort(Object error) =>
    error is TimeoutException ||
    (error is CameraDisconnectedException && error.cause is TimeoutException);

Duration? meanDuration(List<Duration> values) => values.isEmpty
    ? null
    : Duration(
        microseconds: values.map((d) => d.inMicroseconds).sum ~/ values.length,
      );

/// The mean and nearest-rank 95th percentile of a set of durations.
class LiveViewSpread {
  const LiveViewSpread({required this.mean, required this.p95});

  /// Null for no samples.
  static LiveViewSpread? of(List<Duration> samples) {
    if (samples.isEmpty) {
      return null;
    }
    final sorted = samples.sorted((a, b) => a.compareTo(b));
    final rank = (_percentile * sorted.length / _percent).ceil();
    return LiveViewSpread(mean: meanDuration(samples)!, p95: sorted[rank - 1]);
  }

  final Duration mean;
  final Duration p95;
}

class LiveViewSummary {
  const LiveViewSummary({
    required this.elapsed,
    required this.frames,
    required this.fps,
    required this.averageFps,
    required this.counts,
    required this.watchdogAborts,
    this.timeToFirstByte,
    this.transfer,
    this.channelOverhead,
    this.lastFrameBytes,
    this.meanFrameBytes,
  });

  final Duration elapsed;

  /// Frames since the start.
  final int frames;

  /// Frames in the last second.
  final double fps;

  /// Frames per second over the last 30 s, or since the start if that is
  /// shorter.
  final double averageFps;

  final LiveViewSpread? timeToFirstByte;

  /// From the first byte to the response.
  final LiveViewSpread? transfer;

  final LiveViewSpread? channelOverhead;
  final int? lastFrameBytes;
  final double? meanFrameBytes;
  final LiveViewCounts counts;
  final int watchdogAborts;

  String toText({required String transport, required int output}) {
    String line(String label, String value) =>
        '${label.padRight(_labelWidth)}$value';
    String spread(LiveViewSpread? spread) => spread == null
        ? '-'
        : 'mean ${milliseconds(spread.mean)}, p95 ${milliseconds(spread.p95)}';
    final bytes = lastFrameBytes;
    return [
      line('Transport', transport),
      line('EVF out', '$output'),
      line('Elapsed', _clockTime(elapsed)),
      line(
        'FPS',
        '${fps.toStringAsFixed(_rateDecimals)} '
            '(${_averageWindow.inSeconds} s avg '
            '${averageFps.toStringAsFixed(_rateDecimals)})',
      ),
      line('TTFB', spread(timeToFirstByte)),
      line('Transfer', spread(transfer)),
      line('Overhead', spread(channelOverhead)),
      line(
        'Frame',
        bytes == null
            ? '-'
            : '${(bytes / _bytesPerKilobyte).toStringAsFixed(_kilobyteDecimals)} KB',
      ),
      line('0xA102', '${counts.notReady}'),
      line('Busy', '${counts.busy}'),
      line('Errors', '${counts.errors}'),
      line('Watchdog', '$watchdogAborts'),
    ].join('\n');
  }

  static String _clockTime(Duration duration) {
    final seconds = (duration.inSeconds % Duration.secondsPerMinute)
        .toString()
        .padLeft(_secondsWidth, '0');
    return '${duration.inMinutes}:$seconds';
  }
}

/// Live view throughput and per-frame timing since the last [reset].
///
/// [onTiming] is a [PtpSession.onTiming] tap. A frame arrives before the
/// next request completes, so the latest GetViewFinderData timing is its
/// own; "not ready" and "busy" answers bring no frame and stay out of the
/// timings.
///
/// The loop counters come from whichever loop is running, so a restarted
/// loop's are carried over with [retireLoop].
class LiveViewStats {
  LiveViewStats({Clock clock = const Clock()})
    : _clock = clock,
      _since = clock.now();

  final Clock _clock;
  DateTime _since;
  final _frameTimes = Queue<DateTime>();
  final _timeToFirstByte = <Duration>[];
  final _transfer = <Duration>[];
  final _channelOverhead = <Duration>[];
  PtpTiming? _pendingTiming;
  int _frames = 0;
  int _frameBytes = 0;
  int? _lastFrameBytes;
  LiveViewCounts _retired = noLiveViewCounts;
  int _watchdogAborts = 0;

  /// Frames since the last [reset].
  int get frames => _frames;

  void onTiming(int transactionId, PtpTiming timing) {
    if (timing.opcode == CanonEosOperation.getViewFinderData) {
      _pendingTiming = timing;
    }
  }

  void recordFrame(Uint8List jpeg) {
    final now = _clock.now();
    _frameTimes.add(now);
    _prune(now);
    _frames++;
    _frameBytes += jpeg.length;
    _lastFrameBytes = jpeg.length;
    final timing = _pendingTiming;
    if (timing != null) {
      _recordTiming(timing);
      _pendingTiming = null;
    }
  }

  /// Counts [error] if it is a watchdog abort.
  void recordError(Object error) {
    if (_isWatchdogAbort(error)) _watchdogAborts++;
  }

  void retireLoop(LiveViewCounts counts) {
    _retired = _sum(_retired, counts);
    _pendingTiming = null;
  }

  /// Starts over; [running] are the counters of the loop still running,
  /// which from now on count from zero.
  void reset([LiveViewCounts running = noLiveViewCounts]) {
    _since = _clock.now();
    _frameTimes.clear();
    _timeToFirstByte.clear();
    _transfer.clear();
    _channelOverhead.clear();
    _frames = 0;
    _frameBytes = 0;
    _lastFrameBytes = null;
    _retired = (
      notReady: -running.notReady,
      busy: -running.busy,
      errors: -running.errors,
    );
    _watchdogAborts = 0;
  }

  LiveViewSummary summarize([LiveViewCounts running = noLiveViewCounts]) {
    final now = _clock.now();
    _prune(now);
    final elapsed = now.difference(_since);
    final fpsStart = now.subtract(_fpsWindow);
    final averaged = elapsed < _averageWindow ? elapsed : _averageWindow;
    return LiveViewSummary(
      elapsed: elapsed,
      frames: _frames,
      fps:
          _frameTimes.where((time) => time.isAfter(fpsStart)).length /
          _fpsWindow.inSeconds,
      averageFps: averaged == Duration.zero
          ? 0
          : _frameTimes.length *
                Duration.microsecondsPerSecond /
                averaged.inMicroseconds,
      timeToFirstByte: LiveViewSpread.of(_timeToFirstByte),
      transfer: LiveViewSpread.of(_transfer),
      channelOverhead: LiveViewSpread.of(_channelOverhead),
      lastFrameBytes: _lastFrameBytes,
      meanFrameBytes: _frames == 0 ? null : _frameBytes / _frames,
      counts: _sum(_retired, running),
      watchdogAborts: _watchdogAborts,
    );
  }

  void _recordTiming(PtpTiming timing) {
    final firstByte = timing.firstByte;
    if (firstByte != null) {
      _timeToFirstByte.add(firstByte);
      _transfer.add(timing.response - firstByte);
    }
    final overhead = timing.channelOverhead;
    if (overhead != null) _channelOverhead.add(overhead);
  }

  void _prune(DateTime now) {
    final start = now.subtract(_averageWindow);
    while (_frameTimes.isNotEmpty && !_frameTimes.first.isAfter(start)) {
      _frameTimes.removeFirst();
    }
  }

  static LiveViewCounts _sum(LiveViewCounts a, LiveViewCounts b) => (
    notReady: a.notReady + b.notReady,
    busy: a.busy + b.busy,
    errors: a.errors + b.errors,
  );
}
