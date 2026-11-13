import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/session_repository.dart';
import 'session.dart';
import 'sessions_state.dart';

class SessionsCubit extends Cubit<SessionsState> {
  SessionsCubit(this._repository, {this._clock = const Clock()})
    : super(const SessionsState()) {
    _changes = _repository.changes.listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  final SessionRepository _repository;
  final Clock _clock;
  late final StreamSubscription<void> _changes;
  String? _blockedId;

  DateTime get now => _clock.now().toUtc();

  bool canReactivate(Session session) => session.canReactivateAt(now);

  Future<Session> start() async {
    _blockedId = null;
    return _repository.start();
  }

  Future<Session?> reactivate(Session session) async {
    try {
      _blockedId = null;
      return await _repository.reactivate(session.id);
    } on ReactivationBlockedException {
      _blockedId = session.id;
      await _load();
      return null;
    }
  }

  Future<void> stop() => _repository.stop();

  Future<void> markNow() => _repository.setMarkedAt(now);

  Future<void> _load() async {
    final sessions = await _repository.all();
    final markedAt = await _repository.markedAt();
    if (isClosed) return;
    emit(
      SessionsState(
        loaded: true,
        sessions: sessions.reversed.toList(),
        blockedId: _blockedId,
        markedAt: markedAt,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _changes.cancel();
    return super.close();
  }
}
