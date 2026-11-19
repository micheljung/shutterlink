import 'dart:async';

import 'package:clock/clock.dart' as clocks;
import 'package:equatable/equatable.dart';

import '../../remote/shutter_remote.dart';
import 'interval_plan.dart';

enum RunPhase {
  /// Counting down the start delay.
  starting,

  /// Between shots.
  waiting,

  /// A bulb exposure or a clip is running.
  exposing,
  paused,
  finished,
  stopped,
}

/// Where a run is, for the screen and the notification.
class RunSnapshot extends Equatable {
  const RunSnapshot({
    required this.plan,
    required this.phase,
    required this.taken,
    required this.missed,
    required this.startsAt,
    this.nextShotAt,
    this.exposureStartedAt,
    this.exposureEndsAt,
    this.pausedAt,
    this.lastShotAt,
    this.closeFailed = false,
  });

  final IntervalPlan plan;
  final RunPhase phase;

  /// Shots the camera was told to take.
  final int taken;

  /// Shots that were due while the camera could not be reached.
  final int missed;

  /// When the first shot is due, or was.
  final DateTime startsAt;
  final DateTime? nextShotAt;
  final DateTime? exposureStartedAt;
  final DateTime? exposureEndsAt;
  final DateTime? pausedAt;
  final DateTime? lastShotAt;

  /// A bulb exposure or clip could not be ended and may still be running
  /// on the camera; it is ended once the camera is back.
  final bool closeFailed;

  /// Shots due so far, taken or missed.
  int get done => taken + missed;

  bool get active => phase != RunPhase.finished && phase != RunPhase.stopped;

  /// The share of planned shots done; null when shooting until stopped.
  double? get progress {
    final shots = plan.shots;
    if (shots == null) return null;
    return (done / shots).clamp(0, 1).toDouble();
  }

  /// When the last shot will be done, at the current pace.
  DateTime? endsAt(DateTime now) {
    final shots = plan.shots;
    if (shots == null || !active) return null;
    final remaining = shots - done;
    if (remaining <= 0) return exposureEndsAt ?? now;
    final last = plan.timed ? plan.exposureAt(shots - 1) : Duration.zero;
    final next = switch (phase) {
      RunPhase.paused => now.add(_pausedLeft),
      _ => nextShotAt ?? now,
    };
    return next.add(plan.interval * (remaining - 1) + last);
  }

  /// What was left until the next shot when the run was paused.
  Duration get _pausedLeft {
    final next = nextShotAt;
    final paused = pausedAt;
    if (next == null || paused == null) return Duration.zero;
    final left = next.difference(paused);
    return left.isNegative ? Duration.zero : left;
  }

  @override
  List<Object?> get props => [
    plan,
    phase,
    taken,
    missed,
    startsAt,
    nextShotAt,
    exposureStartedAt,
    exposureEndsAt,
    pausedAt,
    lastShotAt,
    closeFailed,
  ];
}

/// Fires the shutter on [plan]'s schedule. Shot n is due at the start plus n
/// intervals, so slow clicks never add up to drift. A shot due while the
/// camera is unreachable is counted as missed and the schedule carries on,
/// which keeps a time-lapse's pace and ramp intact.
class IntervalRun {
  IntervalRun({required this.plan, required this._remote, clocks.Clock? clock})
    : _clock = clock ?? clocks.clock {
    _origin = _clock.now().add(plan.startDelay);
    _snapshot = RunSnapshot(
      plan: plan,
      phase: plan.startDelay > Duration.zero
          ? RunPhase.starting
          : RunPhase.waiting,
      taken: 0,
      missed: 0,
      startsAt: _origin,
      nextShotAt: _origin,
    );
  }

  /// From this interval on, the camera may fall asleep between shots, so it
  /// is woken [wakeLead] before each one.
  static const wakeFrom = Duration(minutes: 2);
  static const wakeLead = Duration(seconds: 5);

  final IntervalPlan plan;
  final ShutterRemote _remote;
  final clocks.Clock _clock;
  final _snapshots = StreamController<RunSnapshot>.broadcast();

  late RunSnapshot _snapshot;
  late DateTime _origin;

  /// Shot slots used, taken or missed.
  int _index = 0;
  Timer? _shotTimer;
  Timer? _wakeTimer;
  Timer? _closeTimer;

  /// A bulb exposure or clip is running on the camera.
  bool _open = false;

  /// The click on its way to the camera; a stop waits for it, since a click
  /// toggles BULB and recordings.
  Future<bool>? _clicking;
  StreamSubscription<RemoteLink>? _links;

  RunSnapshot get snapshot => _snapshot;

  Stream<RunSnapshot> get snapshots => _snapshots.stream;

  bool get _due => _snapshot.active && _snapshot.phase != RunPhase.paused;

  bool get _allUsed {
    final shots = plan.shots;
    return shots != null && _index >= shots;
  }

  void start() {
    _origin = _clock.now().add(plan.startDelay);
    _snapshot = _with(startsAt: _origin);
    _links = _remote.links.listen(_linkChanged);
    _emit(_snapshot);
    _scheduleNext();
  }

  DateTime _dueAt(int index) => _origin.add(plan.interval * index);

  void _scheduleNext() {
    _shotTimer?.cancel();
    _wakeTimer?.cancel();
    if (!_due) return;
    if (_allUsed) {
      if (!_open) _finish(RunPhase.finished);
      return;
    }
    final due = _dueAt(_index);
    _shotTimer = Timer(_until(due), _fire);
    if (plan.interval >= wakeFrom) {
      _wakeTimer = Timer(_until(due.subtract(wakeLead)), _wake);
    }
  }

  Duration _until(DateTime time) {
    final wait = time.difference(_clock.now());
    return wait.isNegative ? Duration.zero : wait;
  }

  Future<void> _wake() async {
    if (!_due || _remote.link != RemoteLink.connected) return;
    try {
      await _remote.wake();
    } on Exception {
      // The shot itself tells whether the camera is there.
    }
  }

  Future<void> _fire() async {
    if (!_due || _clicking != null) return;
    final now = _clock.now();
    // Slots that passed entirely, e.g. while the phone slept, are missed
    // rather than shot in a burst.
    var skipped = 0;
    final shots = plan.shots;
    while (!_dueAt(_index + 1).isAfter(now) &&
        (shots == null || _index + 1 < shots)) {
      _index++;
      skipped++;
    }
    final index = _index++;
    final missed = _snapshot.missed + skipped;
    if (_open || _remote.link != RemoteLink.connected) {
      _emit(_with(missed: missed + 1));
      // The last exposure never closed; opening another would close it.
      if (_open && _remote.link == RemoteLink.connected) {
        await _close();
      } else {
        _scheduleNext();
      }
      return;
    }
    final clicked = await _click();
    if (!clicked) {
      if (!_snapshot.active) return;
      _emit(_with(missed: missed + 1));
      _scheduleNext();
      return;
    }
    final taken = _snapshot.taken + 1;
    final paused = _snapshot.phase == RunPhase.paused;
    if (!plan.timed) {
      if (!_snapshot.active) return;
      _emit(
        _with(
          phase: paused ? RunPhase.paused : RunPhase.waiting,
          taken: taken,
          missed: missed,
          lastShotAt: now,
        ),
      );
      _scheduleNext();
      return;
    }
    // Opened: a stop that came meanwhile closes it right after this.
    _open = true;
    if (!_snapshot.active) return;
    final length = plan.exposureAt(index);
    _emit(
      _with(
        phase: paused ? RunPhase.paused : RunPhase.exposing,
        taken: taken,
        missed: missed,
        lastShotAt: now,
        exposureStartedAt: now,
        exposureEndsAt: now.add(length),
      ),
    );
    _shotTimer?.cancel();
    _closeTimer = Timer(length, _close);
  }

  /// Callers await the same future as [stop], and before it, so a stop sees
  /// what the click did.
  Future<bool> _click() {
    final click = _sendClick().whenComplete(() => _clicking = null);
    _clicking = click;
    return click;
  }

  Future<bool> _sendClick() async {
    try {
      await (plan.control == ExposureControl.video
          ? _remote.toggleRecording()
          : _remote.shoot());
      return true;
    } on Exception {
      // Any failure counts as a missed shot; the schedule must go on.
      return false;
    }
  }

  /// Ends the running exposure or clip, then waits for the next shot.
  Future<void> _close() async {
    _closeTimer?.cancel();
    if (!_open || _clicking != null) return;
    if (_remote.link != RemoteLink.connected || !await _click()) {
      if (!_snapshot.active) return;
      _emit(_with(closeFailed: true));
      // Shots are missed until the camera takes the closing click.
      _scheduleNext();
      return;
    }
    _open = false;
    if (!_snapshot.active) return;
    _emit(
      _with(
        phase: _snapshot.phase == RunPhase.paused
            ? RunPhase.paused
            : RunPhase.waiting,
        clearExposure: true,
        closeFailed: false,
      ),
    );
    _scheduleNext();
  }

  void _linkChanged(RemoteLink link) {
    if (link != RemoteLink.connected || !_open) return;
    if (_closeTimer?.isActive ?? false) return;
    unawaited(_close());
  }

  void pause() {
    if (!_due) return;
    _shotTimer?.cancel();
    _wakeTimer?.cancel();
    _emit(_with(phase: RunPhase.paused, pausedAt: _clock.now()));
  }

  /// Picks up with as much time to the next shot as was left at the pause.
  void resume() {
    final pausedAt = _snapshot.pausedAt;
    if (_snapshot.phase != RunPhase.paused || pausedAt == null) return;
    final now = _clock.now();
    _origin = _origin.add(now.difference(pausedAt));
    final exposing = _closeTimer?.isActive ?? false;
    _emit(
      _with(
        phase: exposing
            ? RunPhase.exposing
            : _index == 0 && now.isBefore(_origin)
            ? RunPhase.starting
            : RunPhase.waiting,
        nextShotAt: _allUsed ? null : _dueAt(_index),
        clearPausedAt: true,
      ),
    );
    if (!exposing) _scheduleNext();
  }

  /// Ends the run, closing a bulb exposure or clip that is still running.
  /// Whether one may still be running on the camera shows in the last
  /// snapshot's [RunSnapshot.closeFailed].
  Future<void> stop() async {
    if (!_snapshot.active) return;
    _finish(RunPhase.stopped);
    // A click on its way may have just opened or closed one.
    await _clicking;
    if (!_open) return;
    if (_remote.link == RemoteLink.connected && await _click()) {
      _open = false;
      return;
    }
    _emit(_with(closeFailed: true));
  }

  void _finish(RunPhase phase) {
    _shotTimer?.cancel();
    _wakeTimer?.cancel();
    _closeTimer?.cancel();
    _emit(
      _with(
        phase: phase,
        clearNext: true,
        clearExposure: true,
        clearPausedAt: true,
      ),
    );
  }

  Future<void> dispose() async {
    await stop();
    await _links?.cancel();
    await _snapshots.close();
  }

  RunSnapshot _with({
    RunPhase? phase,
    int? taken,
    int? missed,
    DateTime? nextShotAt,
    bool clearNext = false,
    DateTime? exposureStartedAt,
    DateTime? exposureEndsAt,
    bool clearExposure = false,
    DateTime? pausedAt,
    bool clearPausedAt = false,
    DateTime? lastShotAt,
    bool? closeFailed,
    DateTime? startsAt,
  }) => RunSnapshot(
    plan: plan,
    phase: phase ?? _snapshot.phase,
    taken: taken ?? _snapshot.taken,
    missed: missed ?? _snapshot.missed,
    startsAt: startsAt ?? _origin,
    nextShotAt: clearNext || _allUsed ? null : nextShotAt ?? _dueAt(_index),
    exposureStartedAt: clearExposure
        ? null
        : exposureStartedAt ?? _snapshot.exposureStartedAt,
    exposureEndsAt: clearExposure
        ? null
        : exposureEndsAt ?? _snapshot.exposureEndsAt,
    pausedAt: clearPausedAt ? null : pausedAt ?? _snapshot.pausedAt,
    lastShotAt: lastShotAt ?? _snapshot.lastShotAt,
    closeFailed: closeFailed ?? _snapshot.closeFailed,
  );

  void _emit(RunSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_snapshots.isClosed) _snapshots.add(snapshot);
  }
}
