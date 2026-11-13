import 'package:clock/clock.dart';
import 'package:collection/collection.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/session_repository.dart';
import '../../data/session_seen_store.dart';
import '../../ptpip/camera_client.dart';
import '../gallery/photo_group.dart';
import 'clock_sync_state.dart';
import 'session.dart';

const syncShotPollInterval = Duration(seconds: 2);
const syncShotTimeout = Duration(seconds: 60);
const standardReadTolerance = Duration(seconds: 2);
const syncShotTolerance = Duration(seconds: 5);
const offsetFreshness = Duration(days: 7);

typedef Delay = Future<void> Function(Duration duration);

Future<void> _defaultDelay(Duration duration) => Future.delayed(duration);

Duration _abs(Duration duration) => duration.isNegative ? -duration : duration;

DateTime _midpoint(DateTime start, DateTime end) =>
    start.add(end.difference(start) ~/ 2);

class ClockSyncCubit extends Cubit<ClockState> {
  ClockSyncCubit({
    required this._client,
    required this._cameraKey,
    required this._sessions,
    required this._seen,
    this._clock = const Clock(),
    this._delay = _defaultDelay,
  }) : super(const ClockPending());

  final CameraClient _client;
  final String _cameraKey;
  final SessionRepository _sessions;
  final SessionSeenStore _seen;
  final Clock _clock;
  final Delay _delay;
  List<PhotoGroup> _candidates = const [];
  int _syncAttempt = 0;

  Future<void> start() async {
    final before = _now();
    DateTime? cameraTime;
    try {
      cameraTime = await _client.cameraTime();
    } on Exception {
      cameraTime = null;
    }
    final after = _now();
    final stored = await _sessions.clockOffset();
    if (cameraTime != null) {
      final measured = _midpoint(before, after).difference(cameraTime.toUtc());
      if (stored != null &&
          _abs(measured - stored.offset) <= standardReadTolerance) {
        return _emit(ClockResolved(ClockResolution.fresh, stored.offset));
      }
      await _apply(measured, ClockOffsetSource.standardRead);
      return _emit(
        ClockResolved(
          stored == null ? ClockResolution.fresh : ClockResolution.corrected,
          measured,
          previous: stored?.offset,
        ),
      );
    }
    if (await _sessions.markedAt() != null) {
      try {
        _candidates = await _markCandidates();
      } on Exception {
        _candidates = const [];
      }
      if (_candidates.isNotEmpty) {
        return _emit(ClockAwaitingMarkedPhoto(_candidates.first, index: 0));
      }
    }
    await _resolveWithoutMeasurement();
  }

  Future<void> useLastOffset() async {
    final stored = await _sessions.clockOffset();
    _emit(
      ClockResolved(
        ClockResolution.assumed,
        stored?.offset ?? Duration.zero,
        previous: stored?.offset,
      ),
    );
  }

  Future<void> markNow() => _sessions.setMarkedAt(_now());

  Future<void> confirmMarkedPhoto() async {
    final current = state;
    final markedAt = await _sessions.markedAt();
    if (current is! ClockAwaitingMarkedPhoto || markedAt == null) return;
    final group = current.candidate;
    final stored = await _sessions.clockOffset();
    final offset = markedAt.difference(group.captureDate!.toUtc());
    await _exclude(group);
    await _apply(offset, ClockOffsetSource.markedPhoto);
    await _sessions.setMarkedAt(null);
    _emit(
      ClockResolved(
        ClockResolution.markedPhoto,
        offset,
        previous: stored?.offset,
      ),
    );
  }

  Future<void> nextMarkedPhoto() async {
    final current = state;
    if (current is! ClockAwaitingMarkedPhoto) return;
    final next = current.index + 1;
    if (next < _candidates.length) {
      return _emit(ClockAwaitingMarkedPhoto(_candidates[next], index: next));
    }
    await _promptAfterMark(ClockSyncFailure.noPhoto);
  }

  Future<void> skipMarkedPhoto() => _promptAfterMark(null);

  Future<void> syncShot() async {
    if (state is ClockSyncing) return;
    final attempt = ++_syncAttempt;
    _emit(const ClockSyncing());
    try {
      await _pollForSyncShot(attempt);
    } on Exception {
      if (attempt == _syncAttempt) await _failSync(ClockSyncFailure.timeout);
    }
  }

  Future<void> _pollForSyncShot(int attempt) async {
    final deadline = _now().add(syncShotTimeout);
    var missedAt = _now();
    var known = _keysOf(await _client.listPhotos());
    while (attempt == _syncAttempt && !isClosed) {
      if (!_now().isBefore(deadline)) {
        return _failSync(ClockSyncFailure.timeout);
      }
      await _delay(syncShotPollInterval);
      if (attempt != _syncAttempt || isClosed) return;
      final listingStart = _now();
      final objects = await _client.listPhotos();
      final foundAt = _now();
      final added = groupPhotos(
        objects.where((object) => !known.contains(_keyOf(object))),
      ).where((group) => group.captureDate != null).toList();
      if (added.isNotEmpty) {
        return _finishSync(added, missedAt, foundAt);
      }
      missedAt = listingStart;
      known = _keysOf(objects);
    }
  }

  Future<void> cancelSync() async {
    if (state is! ClockSyncing) return;
    _syncAttempt++;
    await _resolveWithoutMeasurement();
  }

  Future<void> _finishSync(
    List<PhotoGroup> added,
    DateTime missedAt,
    DateTime foundAt,
  ) async {
    for (final group in added) {
      await _exclude(group);
    }
    if (foundAt.difference(missedAt) > syncShotTolerance * 2) {
      return _failSync(ClockSyncFailure.windowTooLong);
    }
    final shot = added.reduce(
      (a, b) => a.newestHandle <= b.newestHandle ? a : b,
    );
    final stored = await _sessions.clockOffset();
    final offset = _midpoint(
      missedAt,
      foundAt,
    ).difference(shot.captureDate!.toUtc());
    await _apply(offset, ClockOffsetSource.syncShot);
    _emit(
      ClockResolved(ClockResolution.syncShot, offset, previous: stored?.offset),
    );
  }

  Future<void> _failSync(ClockSyncFailure failure) async {
    final stored = await _sessions.clockOffset();
    _emit(ClockPrompt(lastOffset: stored?.offset, failure: failure));
  }

  Future<void> _promptAfterMark(ClockSyncFailure? failure) async {
    await _sessions.setMarkedAt(null);
    final stored = await _sessions.clockOffset();
    _emit(ClockPrompt(lastOffset: stored?.offset, failure: failure));
  }

  Future<void> _resolveWithoutMeasurement() async {
    final stored = await _sessions.clockOffset();
    if (stored == null ||
        _now().difference(stored.measuredAt) > offsetFreshness) {
      return _emit(ClockPrompt(lastOffset: stored?.offset));
    }
    _emit(ClockResolved(ClockResolution.stored, stored.offset));
  }

  Future<List<PhotoGroup>> _markCandidates() async {
    final baseline = await _seen.baseline(_cameraKey);
    final groups = groupPhotos(
      (await _client.listPhotos()).where(
        (object) =>
            object.captureDate != null &&
            !(baseline?.contains(_keyOf(object)) ?? false),
      ),
    );
    if (baseline == null) return groups;
    return groups.sorted((a, b) {
      final byHandle = _firstHandle(a).compareTo(_firstHandle(b));
      return byHandle != 0
          ? byHandle
          : a.captureDate!.compareTo(b.captureDate!);
    });
  }

  static int _firstHandle(PhotoGroup group) =>
      [group.jpeg?.handle, group.raw?.handle].nonNulls.min;

  Future<void> _exclude(PhotoGroup group) =>
      _seen.markExcluded(_cameraKey, [?group.jpeg, ?group.raw].map(_keyOf));

  Future<void> _apply(Duration offset, ClockOffsetSource source) =>
      _sessions.setClockOffset(
        ClockOffset(offset: offset, measuredAt: _now(), source: source),
      );

  String _keyOf(CameraObject object) =>
      SessionSeenStore.keyOf(_cameraKey, object);

  Set<String> _keysOf(List<CameraObject> objects) =>
      objects.map(_keyOf).toSet();

  DateTime _now() => _clock.now().toUtc();

  void _emit(ClockState state) {
    if (!isClosed) emit(state);
  }
}
