import 'dart:math';

import 'package:equatable/equatable.dart';

/// Who times each exposure.
enum ExposureControl {
  /// The camera's own shutter speed; the app only fires.
  camera,

  /// The camera is on BULB; the app opens and closes each exposure.
  bulb,

  /// The app records a clip of [IntervalPlan.exposure] each interval.
  video,
}

enum PlanProblem {
  /// A bulb exposure or clip would still run when the next shot is due.
  intervalTooShort,

  /// Ramping needs a last shot to ramp towards.
  rampNeedsShotCount,
}

/// What an intervalometer run shoots: when, how often and how long.
class IntervalPlan extends Equatable {
  const IntervalPlan({
    this.control = ExposureControl.camera,
    this.exposure = const Duration(seconds: 1),
    this.rampTo,
    this.interval = const Duration(seconds: 5),
    this.shots = 100,
    this.startDelay = Duration.zero,
  });

  /// The camera needs this long after a bulb exposure or clip to save it
  /// and be ready again.
  static const minGap = Duration(seconds: 1);
  static const minInterval = Duration(seconds: 1);
  static const minExposure = Duration(seconds: 1);
  static const maxDuration = Duration(hours: 24);
  static const maxShots = 99999;
  static const clipFrameRates = [24, 25, 30, 60];
  static const defaultFrameRate = 24;

  final ExposureControl control;

  /// The bulb exposure of the first shot, or the length of each clip.
  final Duration exposure;

  /// The bulb exposure of the last shot; the shots between ramp evenly in
  /// stops. Null keeps every exposure the same.
  final Duration? rampTo;

  /// From the start of one shot to the start of the next.
  final Duration interval;

  /// Null shoots until stopped.
  final int? shots;
  final Duration startDelay;

  bool get bulb => control == ExposureControl.bulb;

  /// The app times each shot's length: a bulb exposure or a clip.
  bool get timed => control != ExposureControl.camera;

  bool get ramps => bulb && rampTo != null;

  /// The longest exposure of the run, which the interval has to fit.
  Duration get longestExposure {
    final rampTo = this.rampTo;
    if (!ramps || rampTo == null) return exposure;
    return rampTo > exposure ? rampTo : exposure;
  }

  /// The break after the first timed shot; the camera's own exposure is
  /// unknown.
  Duration get gap => interval - exposure;

  PlanProblem? get problem {
    if (ramps && shots == null) return PlanProblem.rampNeedsShotCount;
    if (timed && interval < longestExposure + minGap) {
      return PlanProblem.intervalTooShort;
    }
    return null;
  }

  bool get isValid => problem == null;

  /// The bulb exposure of shot [index], counted from zero. Ramps
  /// geometrically, so each step changes the brightness by the same stops.
  Duration exposureAt(int index) {
    final rampTo = this.rampTo;
    final shots = this.shots;
    if (!ramps || rampTo == null || shots == null || shots < 2) {
      return exposure;
    }
    final progress = (index.clamp(0, shots - 1)) / (shots - 1);
    final from = exposure.inMicroseconds;
    final to = rampTo.inMicroseconds;
    final micros = from * pow(to / from, progress);
    return Duration(
      milliseconds: (micros / Duration.microsecondsPerMillisecond).round(),
    );
  }

  /// From the first shot to the end of the last one, without the start
  /// delay. Null when shooting until stopped.
  Duration? get runTime {
    final shots = this.shots;
    if (shots == null) return null;
    final last = timed ? exposureAt(shots - 1) : Duration.zero;
    return interval * (shots - 1) + last;
  }

  /// How long a time-lapse of all shots plays at [fps].
  Duration? clipLength(int fps) {
    final shots = this.shots;
    if (shots == null) return null;
    return Duration(
      microseconds: (shots * Duration.microsecondsPerSecond / fps).round(),
    );
  }

  /// Shots that fit into [duration] when starting one at its start.
  static int shotsFor(Duration duration, Duration interval) =>
      max(1, duration.inMilliseconds ~/ interval.inMilliseconds + 1);

  /// Changes the exposure and keeps the interval when it still fits, so the
  /// clip's pace stays; otherwise the interval grows to fit.
  IntervalPlan withExposure(Duration exposure) {
    final next = copyWith(exposure: exposure);
    final needed = next.longestExposure + minGap;
    return next.timed && next.interval < needed
        ? next.copyWith(interval: needed)
        : next;
  }

  /// Sets the break after a timed shot, which sets the interval.
  IntervalPlan withGap(Duration gap) => copyWith(interval: exposure + gap);

  IntervalPlan withRampTo(Duration? rampTo) {
    final next = rampTo == null
        ? copyWith(clearRampTo: true)
        : copyWith(rampTo: rampTo);
    final needed = next.longestExposure + minGap;
    return next.timed && next.interval < needed
        ? next.copyWith(interval: needed)
        : next;
  }

  IntervalPlan withControl(ExposureControl control) {
    final next = copyWith(control: control);
    if (!next.timed) return next;
    final needed = next.longestExposure + minGap;
    return next.interval < needed ? next.copyWith(interval: needed) : next;
  }

  IntervalPlan copyWith({
    ExposureControl? control,
    Duration? exposure,
    Duration? rampTo,
    bool clearRampTo = false,
    Duration? interval,
    int? shots,
    bool clearShots = false,
    Duration? startDelay,
  }) => IntervalPlan(
    control: control ?? this.control,
    exposure: exposure ?? this.exposure,
    rampTo: clearRampTo ? null : rampTo ?? this.rampTo,
    interval: interval ?? this.interval,
    shots: clearShots ? null : shots ?? this.shots,
    startDelay: startDelay ?? this.startDelay,
  );

  Map<String, Object?> toJson() => {
    'control': control.name,
    'exposureMs': exposure.inMilliseconds,
    'rampToMs': rampTo?.inMilliseconds,
    'intervalMs': interval.inMilliseconds,
    'shots': shots,
    'startDelayMs': startDelay.inMilliseconds,
  };

  /// Falls back to the defaults for anything missing or out of range, so a
  /// stored plan never breaks the screen.
  static IntervalPlan fromJson(Map<String, Object?> json) {
    const defaults = IntervalPlan();
    Duration? millis(String key, Duration min) {
      final value = json[key];
      if (value is! int) return null;
      final duration = Duration(milliseconds: value);
      return duration < min || duration > maxDuration ? null : duration;
    }

    final control = ExposureControl.values
        .where((control) => control.name == json['control'])
        .firstOrNull;
    final shots = json['shots'];
    return IntervalPlan(
      control: control ?? defaults.control,
      exposure: millis('exposureMs', minExposure) ?? defaults.exposure,
      rampTo: millis('rampToMs', minExposure),
      interval: millis('intervalMs', minInterval) ?? defaults.interval,
      shots: json.containsKey('shots')
          ? (shots is int && shots >= 1 && shots <= maxShots ? shots : null)
          : defaults.shots,
      startDelay: millis('startDelayMs', Duration.zero) ?? Duration.zero,
    );
  }

  @override
  List<Object?> get props => [
    control,
    exposure,
    rampTo,
    interval,
    shots,
    startDelay,
  ];
}
