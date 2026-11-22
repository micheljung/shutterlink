import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptp/camera_client.dart';
import 'package:shutterlink/ptp/canon/canon_constants.dart';
import 'package:shutterlink/ptp/canon/canon_live_view_stats.dart';
import 'package:shutterlink/ptp/ptp_session.dart';

const _transactionId = 1;
const _frameBytes = 2048;
const _frameGap = Duration(milliseconds: 100);

PtpTiming _timing({
  int? firstByteMs,
  required int responseMs,
  int? overheadMs,
  int opcode = CanonEosOperation.getViewFinderData,
}) => PtpTiming(
  opcode: opcode,
  requestSent: DateTime(2026),
  firstByte: firstByteMs == null ? null : Duration(milliseconds: firstByteMs),
  response: Duration(milliseconds: responseMs),
  channelOverhead: overheadMs == null
      ? null
      : Duration(milliseconds: overheadMs),
);

void main() {
  late DateTime now;
  late LiveViewStats stats;

  setUp(() {
    now = DateTime(2026, 11, 21, 12);
    stats = LiveViewStats(clock: Clock(() => now));
  });

  void advance(Duration by) => now = now.add(by);

  void frames(int count, {Duration gap = _frameGap}) {
    for (var i = 0; i < count; i++) {
      advance(gap);
      stats.recordFrame(Uint8List(_frameBytes));
    }
  }

  void timedFrame(PtpTiming timing, {int bytes = _frameBytes}) => stats
    ..onTiming(_transactionId, timing)
    ..recordFrame(Uint8List(bytes));

  test('mean of durations', () {
    final values = [for (var i = 1; i <= 20; i++) Duration(milliseconds: i)];
    expect(meanDuration(values), const Duration(microseconds: 10500));
    expect(meanDuration([]), isNull);
  });

  test('milliseconds', () {
    expect(milliseconds(null), '-');
    expect(milliseconds(const Duration(microseconds: 1500)), '1.5 ms');
  });

  group('LiveViewSpread', () {
    test('is null without samples', () {
      expect(LiveViewSpread.of(const []), isNull);
    });

    test('mean and nearest-rank p95', () {
      final spread = LiveViewSpread.of([
        for (var ms = 1; ms <= 100; ms++) Duration(milliseconds: ms),
      ])!;

      expect(spread.mean, const Duration(microseconds: 50500));
      expect(spread.p95, const Duration(milliseconds: 95));
    });

    test('p95 of one sample is that sample', () {
      final spread = LiveViewSpread.of([const Duration(milliseconds: 7)])!;

      expect(spread.mean, const Duration(milliseconds: 7));
      expect(spread.p95, const Duration(milliseconds: 7));
    });
  });

  group('fps', () {
    test('counts the last second only', () {
      frames(20);
      advance(const Duration(milliseconds: 500));

      expect(stats.summarize().fps, 5);
    });

    test('averages since the start while shorter than 30 s', () {
      frames(20);

      final summary = stats.summarize();
      expect(summary.elapsed, const Duration(seconds: 2));
      expect(summary.averageFps, 10);
    });

    test('averages over the last 30 s once longer', () {
      frames(300, gap: const Duration(milliseconds: 200));
      frames(300);

      expect(stats.summarize().averageFps, 10);
      expect(stats.summarize().elapsed, const Duration(seconds: 90));
    });

    test('is zero right after a reset', () {
      frames(5);
      stats.reset();

      final summary = stats.summarize();
      expect(summary.fps, 0);
      expect(summary.averageFps, 0);
      expect(summary.frames, 0);
      expect(summary.lastFrameBytes, isNull);
      expect(summary.meanFrameBytes, isNull);
    });

    test('total frames and sizes outlast the 30 s window', () {
      frames(300, gap: const Duration(milliseconds: 200));
      stats.recordFrame(Uint8List(_frameBytes * 2));

      final summary = stats.summarize();
      expect(summary.frames, 301);
      expect(summary.lastFrameBytes, _frameBytes * 2);
      expect(summary.meanFrameBytes, _frameBytes * 302 / 301);
    });
  });

  test('timings split into ttfb, transfer and overhead', () {
    timedFrame(_timing(firstByteMs: 10, responseMs: 30, overheadMs: 2));
    timedFrame(_timing(firstByteMs: 20, responseMs: 60, overheadMs: 4));

    final summary = stats.summarize();
    expect(summary.timeToFirstByte!.mean, const Duration(milliseconds: 15));
    expect(summary.timeToFirstByte!.p95, const Duration(milliseconds: 20));
    expect(summary.transfer!.mean, const Duration(milliseconds: 30));
    expect(summary.transfer!.p95, const Duration(milliseconds: 40));
    expect(summary.channelOverhead!.mean, const Duration(milliseconds: 3));
  });

  test('a timing without overhead leaves the overhead empty', () {
    timedFrame(_timing(firstByteMs: 10, responseMs: 30));

    expect(stats.summarize().channelOverhead, isNull);
  });

  test('a timing without a first byte leaves ttfb and transfer empty', () {
    timedFrame(_timing(responseMs: 5));

    final summary = stats.summarize();
    expect(summary.timeToFirstByte, isNull);
    expect(summary.transfer, isNull);
  });

  test('only GetViewFinderData timings count', () {
    timedFrame(
      _timing(
        firstByteMs: 10,
        responseMs: 30,
        opcode: CanonEosOperation.getEvent,
      ),
    );

    expect(stats.summarize().timeToFirstByte, isNull);
  });

  test('a timing counts only with the frame it brought', () {
    stats
      ..onTiming(_transactionId, _timing(firstByteMs: 50, responseMs: 60))
      ..onTiming(_transactionId, _timing(firstByteMs: 10, responseMs: 30));
    expect(stats.summarize().timeToFirstByte, isNull);

    stats
      ..recordFrame(Uint8List(_frameBytes))
      ..recordFrame(Uint8List(_frameBytes));

    final firstByte = stats.summarize().timeToFirstByte!;
    expect(firstByte.mean, const Duration(milliseconds: 10));
    expect(firstByte.p95, const Duration(milliseconds: 10));
  });

  test('a retired loop takes its pending timing along', () {
    stats
      ..onTiming(_transactionId, _timing(firstByteMs: 10, responseMs: 30))
      ..retireLoop(noLiveViewCounts)
      ..recordFrame(Uint8List(_frameBytes));

    expect(stats.summarize().timeToFirstByte, isNull);
  });

  test('loop counters carry over a restart and reset to zero', () {
    stats.retireLoop((notReady: 3, busy: 1, errors: 1));

    expect(stats.summarize((notReady: 2, busy: 0, errors: 0)).counts, (
      notReady: 5,
      busy: 1,
      errors: 1,
    ));

    stats.reset((notReady: 2, busy: 0, errors: 0));

    expect(stats.summarize((notReady: 4, busy: 0, errors: 0)).counts, (
      notReady: 2,
      busy: 0,
      errors: 0,
    ));
  });

  test('watchdog aborts count until a reset', () {
    stats
      ..recordError(CameraDisconnectedException(TimeoutException(null)))
      ..recordError(TimeoutException(null))
      ..recordError(const CameraDisconnectedException())
      ..recordError(StateError('x'));
    expect(stats.summarize().watchdogAborts, 2);

    stats.reset();
    expect(stats.summarize().watchdogAborts, 0);
  });

  test('the text lists every stat', () {
    frames(9);
    advance(_frameGap);
    timedFrame(_timing(firstByteMs: 12, responseMs: 40, overheadMs: 3));
    stats
      ..recordError(TimeoutException(null))
      ..retireLoop((notReady: 7, busy: 2, errors: 1));

    final text = stats
        .summarize(noLiveViewCounts)
        .toText(transport: 'USB', output: 2);

    expect(
      text,
      'Transport USB\n'
      'EVF out   2\n'
      'Elapsed   0:01\n'
      'FPS       10.0 (30 s avg 10.0)\n'
      'TTFB      mean 12.0 ms, p95 12.0 ms\n'
      'Transfer  mean 28.0 ms, p95 28.0 ms\n'
      'Overhead  mean 3.0 ms, p95 3.0 ms\n'
      'Frame     2.0 KB\n'
      '0xA102    7\n'
      'Busy      2\n'
      'Errors    1\n'
      'Watchdog  1',
    );
  });
}
