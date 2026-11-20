import '../../remote/shutter_remote.dart';
import 'interval_plan.dart';
import 'interval_run.dart';

/// The intervalometer's words and number formats, shared by the screen, the
/// notification and the tests.
abstract final class IntervalometerText {
  static const title = 'Intervalometer';
  static const startingNotification = 'Starting…';
  static const until = 'Until stopped';

  static const pairingText =
      'Android asks whether to pair with the camera. Allow it within 30 '
      'seconds, in the dialog or in the notification if no dialog appears.';
  static const refusedTitle = 'The camera no longer accepts this phone';
  static const refusedText =
      'The camera no longer knows this phone. Shutterlink keeps looking, so '
      'pairing again on the camera is enough:';
  static const refusedSteps = [
    'On the camera, delete the connection information (MENU → Wireless '
        'settings → Bluetooth function).',
    'Start pairing on the camera.',
    'Confirm the pairing request on the phone within 30 seconds. It can '
        'take half a minute to appear; Pair again below finds the camera '
        'at once.',
  ];
  static const pairAgainLabel = 'Pair again';

  /// "45 s", "2.5 s", "12 min 30 s", "1 h 5 min".
  static String duration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(Duration.minutesPerHour);
    final seconds = duration.inSeconds.remainder(Duration.secondsPerMinute);
    final millis = duration.inMilliseconds.remainder(
      Duration.millisecondsPerSecond,
    );
    if (hours > 0) {
      return minutes == 0 ? '$hours h' : '$hours h $minutes min';
    }
    if (minutes > 0) {
      return seconds == 0 ? '$minutes min' : '$minutes min $seconds s';
    }
    if (millis == 0) return '$seconds s';
    final tenths = (duration.inMilliseconds / Duration.millisecondsPerSecond)
        .toStringAsFixed(1);
    return '$tenths s';
  }

  /// A countdown: "0:04", "12:30", "1:05:00".
  static String countdown(Duration duration) {
    final clamped = duration.isNegative ? Duration.zero : duration;
    // Rounded up, so it reaches 0:00 exactly when the shot fires.
    final total =
        (clamped.inMilliseconds + Duration.millisecondsPerSecond - 1) ~/
        Duration.millisecondsPerSecond;
    final hours = total ~/ Duration.secondsPerHour;
    final minutes = (total ~/ Duration.secondsPerMinute).remainder(
      Duration.minutesPerHour,
    );
    final seconds = total.remainder(Duration.secondsPerMinute);
    String two(int value) => value.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '$minutes:${two(seconds)}';
  }

  /// "21:04".
  static String timeOfDay(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  static String shots(int? shots) => switch (shots) {
    null => until,
    1 => '1 shot',
    _ => '$shots shots',
  };

  static String progress(RunSnapshot run) {
    final shots = run.plan.shots;
    return shots == null ? '${run.done}' : '${run.done} of $shots';
  }

  static String problem(PlanProblem problem, IntervalPlan plan) =>
      switch (problem) {
        PlanProblem.intervalTooShort =>
          'Make the interval at least '
              '${duration(plan.longestExposure + IntervalPlan.minGap)}, so '
              'the camera has a moment to save each '
              '${plan.control == ExposureControl.video ? 'clip' : 'shot'}.',
        PlanProblem.rampNeedsShotCount =>
          'Set a number of shots to ramp the exposure over.',
      };

  static String notification(
    RunSnapshot run, {
    required RemoteLink link,
    required DateTime now,
  }) {
    final connected = link == RemoteLink.connected;
    final parts = <String>[
      'Shot ${progress(run)}',
      if (link == RemoteLink.pairing)
        'Confirm the pairing request'
      else if (link == RemoteLink.refused)
        'Camera refuses this phone, pair again'
      else if (!connected)
        'Camera out of reach, reconnecting',
      if (run.phase == RunPhase.paused) 'Paused',
      if (run.missed > 0) '${run.missed} missed',
    ];
    final ends = run.endsAt(now);
    if (connected && run.phase != RunPhase.paused && ends != null) {
      parts.add('ends ${timeOfDay(ends)}');
    }
    return parts.join(' · ');
  }
}
