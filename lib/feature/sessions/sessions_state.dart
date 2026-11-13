import 'package:equatable/equatable.dart';

import 'session.dart';

class SessionsState extends Equatable {
  const SessionsState({
    this.loaded = false,
    this.sessions = const [],
    this.blockedId,
    this.markedAt,
  });

  final bool loaded;
  final List<Session> sessions;
  final String? blockedId;
  final DateTime? markedAt;

  Session? get active =>
      sessions.where((session) => session.isActive).firstOrNull;

  @override
  List<Object?> get props => [loaded, sessions, blockedId, markedAt];
}
