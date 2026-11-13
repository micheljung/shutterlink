import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:uuid/uuid.dart';

import '../feature/sessions/session.dart';
import '../feature/sessions/session_code.dart';
import 'json_file.dart';

class ReactivationBlockedException implements Exception {
  const ReactivationBlockedException(this.session);

  final Session session;

  @override
  String toString() => 'ReactivationBlockedException(${session.code})';
}

class SessionRepository {
  SessionRepository(
    File file, {
    this._clock = const Clock(),
    SessionCodeGenerator? codes,
    this._uuid = const Uuid(),
  }) : _file = JsonFile(file, clock: _clock),
       _codes = codes ?? SessionCodeGenerator();

  static const fileName = 'sessions.json';

  final JsonFile _file;
  final Clock _clock;
  final SessionCodeGenerator _codes;
  final Uuid _uuid;
  final _changes = StreamController<void>.broadcast();
  late final Future<_SessionsData> _data = _read();

  Stream<void> get changes => _changes.stream;

  Future<List<Session>> all() async =>
      List.unmodifiable((await _data).sessions);

  Future<Session?> active() async =>
      (await _data).sessions.where((session) => session.isActive).firstOrNull;

  Future<ClockOffset?> clockOffset() async => (await _data).clockOffset;

  Future<DateTime?> markedAt() async => (await _data).markedAt;

  Future<Session> start() => _update((data, now) {
    _stopActive(data, now);
    final existing = {for (final session in data.sessions) session.code};
    var code = _codes.next();
    while (existing.contains(code)) {
      code = _codes.next();
    }
    final session = Session(
      id: _uuid.v4(),
      code: code,
      createdAt: now,
      intervals: [ActivityInterval(now)],
    );
    data.sessions.add(session);
    return session;
  });

  Future<Session> reactivate(String id) => _update((data, now) {
    final index = data.sessions.indexWhere((session) => session.id == id);
    if (index < 0) throw ArgumentError.value(id, 'id', 'Unknown Session');
    final target = data.sessions[index];
    if (target.isActive) return target;
    if (!target.canReactivateAt(now)) {
      throw ReactivationBlockedException(target);
    }
    _stopActive(data, now);
    final reactivated = target.copyWith(
      intervals: [...target.intervals, ActivityInterval(now)],
    );
    data.sessions[index] = reactivated;
    return reactivated;
  });

  Future<void> stop() => _update(_stopActive);

  Future<void> markExpired(String code) => _updateSession(
    code,
    (session) => session.expired ? null : session.copyWith(expired: true),
  );

  Future<void> setExpiresAt(String code, DateTime expiresAt) => _updateSession(
    code,
    (session) => session.expiresAt == expiresAt.toUtc()
        ? null
        : session.copyWith(expiresAt: expiresAt.toUtc()),
  );

  Future<void> setClockOffset(ClockOffset offset) =>
      _update((data, _) => data.clockOffset = offset);

  Future<void> setMarkedAt(DateTime? markedAt) =>
      _update((data, _) => data.markedAt = markedAt?.toUtc());

  void _stopActive(_SessionsData data, DateTime now) {
    for (final (index, session) in data.sessions.indexed) {
      if (!session.isActive) continue;
      data.sessions[index] = session.copyWith(
        intervals: [
          ...session.intervals.take(session.intervals.length - 1),
          ActivityInterval(session.intervals.last.start, now),
        ],
      );
    }
  }

  Future<void> _updateSession(
    String code,
    Session? Function(Session session) change,
  ) => _file.serialized(() async {
    final data = await _data;
    final index = data.sessions.indexWhere((session) => session.code == code);
    if (index < 0) return;
    final changed = change(data.sessions[index]);
    if (changed == null) return;
    data.sessions[index] = changed;
    await _persist(data);
  });

  Future<T> _update<T>(T Function(_SessionsData data, DateTime now) change) =>
      _file.serialized(() async {
        final data = await _data;
        final result = change(data, _clock.now().toUtc());
        await _persist(data);
        return result;
      });

  Future<void> _persist(_SessionsData data) async {
    await _file.save(data.toJson());
    _changes.add(null);
  }

  Future<_SessionsData> _read() =>
      _file.read(_SessionsData.fromJson, _SessionsData.new);
}

class _SessionsData {
  _SessionsData({List<Session>? sessions, this.clockOffset, this.markedAt})
    : sessions = sessions ?? [];

  factory _SessionsData.fromJson(Map<String, Object?> json) => _SessionsData(
    sessions: [
      for (final session in json['sessions'] as List<Object?>? ?? const [])
        Session.fromJson(session! as Map<String, Object?>),
    ],
    clockOffset: json['clockOffset'] == null
        ? null
        : ClockOffset.fromJson(json['clockOffset']! as Map<String, Object?>),
    markedAt: json['markedAt'] == null ? null : parseUtc(json['markedAt']),
  );

  final List<Session> sessions;
  ClockOffset? clockOffset;
  DateTime? markedAt;

  Map<String, Object?> toJson() => {
    'sessions': [for (final session in sessions) session.toJson()],
    if (clockOffset case final offset?) 'clockOffset': offset.toJson(),
    if (markedAt case final markedAt?) 'markedAt': formatUtc(markedAt),
  };
}
