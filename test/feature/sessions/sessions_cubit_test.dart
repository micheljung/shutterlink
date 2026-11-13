import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/session_repository.dart';
import 'package:shutterlink/feature/sessions/sessions_config.dart';
import 'package:shutterlink/feature/sessions/sessions_cubit.dart';
import 'package:shutterlink/feature/sessions/sessions_state.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 13, 10);
  const minute = Duration(minutes: 1);
  late Directory root;
  late DateTime now;
  late SessionRepository repository;
  late SessionsCubit cubit;

  Future<SessionsState> loaded(bool Function(SessionsState state) test) async =>
      test(cubit.state) ? cubit.state : cubit.stream.firstWhere(test);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sessions_cubit');
    now = t0;
    repository = SessionRepository(
      File(p.join(root.path, SessionRepository.fileName)),
      clock: Clock(() => now),
    );
    cubit = SessionsCubit(repository, clock: Clock(() => now));
  });

  tearDown(() async {
    await cubit.close();
    await root.delete(recursive: true);
  });

  test('start, stop and reactivate keep one active Session', () async {
    final a = await cubit.start();
    var state = await loaded((state) => state.active?.id == a.id);
    expect(state.sessions.single.code, a.code);

    now = t0.add(minute);
    final b = await cubit.start();
    state = await loaded((state) => state.active?.id == b.id);
    expect(state.sessions.map((session) => session.id), [b.id, a.id]);

    now = t0.add(minute * 2);
    await cubit.reactivate(state.sessions.last);
    state = await loaded((state) => state.active?.id == a.id);
    expect(state.sessions.last.intervals, hasLength(2));

    await cubit.stop();
    state = await loaded((state) => state.active == null);
    expect(state.sessions, hasLength(2));
  });

  test('blocked reactivation marks the Session expired', () async {
    final a = await cubit.start();
    await repository.stop();
    await repository.setExpiresAt(a.code, t0.add(retention));
    now = t0.add(retention - reactivationMargin + minute);
    final state = await loaded(
      (state) => state.sessions.singleOrNull?.expiresAt != null,
    );
    expect(cubit.canReactivate(state.sessions.single), isFalse);

    final reactivated = await cubit.reactivate(state.sessions.single);

    expect(reactivated, isNull);
    expect(cubit.state.blockedId, a.id);
    expect(cubit.state.active, isNull);
  });

  test('an expired Session cannot be reactivated', () async {
    final a = await cubit.start();
    await repository.stop();
    await repository.markExpired(a.code);
    final state = await loaded(
      (state) => state.sessions.singleOrNull?.expired ?? false,
    );

    expect(cubit.canReactivate(state.sessions.single), isFalse);
    expect(await cubit.reactivate(state.sessions.single), isNull);
    expect(cubit.state.blockedId, a.id);
  });

  test('mark now records the time', () async {
    await cubit.markNow();

    final state = await loaded((state) => state.markedAt != null);
    expect(state.markedAt, t0);
  });
}
