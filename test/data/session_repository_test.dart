import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/session_repository.dart';
import 'package:shutterlink/feature/sessions/session.dart';
import 'package:shutterlink/feature/sessions/session_code.dart';
import 'package:shutterlink/feature/sessions/sessions_config.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 13, 10);
  const minute = Duration(minutes: 1);
  late Directory root;
  late File file;
  late DateTime now;

  SessionRepository repository() => SessionRepository(
    file,
    clock: Clock(() => now),
    codes: SessionCodeGenerator(random: Random(1)),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sessions');
    file = File(p.join(root.path, SessionRepository.fileName));
    now = t0;
  });

  tearDown(() => root.delete(recursive: true));

  test('start ends the previous interval', () async {
    final sessions = repository();
    final a = await sessions.start();
    now = t0.add(minute);
    final b = await sessions.start();

    final all = await sessions.all();
    expect(all.map((s) => s.code), [a.code, b.code]);
    expect(a.code, isNot(b.code));
    expect(all.first.intervals, [ActivityInterval(t0, t0.add(minute))]);
    expect(all.last.intervals, [ActivityInterval(t0.add(minute))]);
    expect((await sessions.active())?.id, b.id);
    expect(normalizeSessionCode(b.code), b.code);
  });

  test('stop leaves no active Session', () async {
    final sessions = repository();
    await sessions.start();
    now = t0.add(minute);

    await sessions.stop();

    expect(await sessions.active(), isNull);
    expect((await sessions.all()).single.intervals.single.end, t0.add(minute));
  });

  test('reactivate adds an interval and stops the active one', () async {
    final sessions = repository();
    final a = await sessions.start();
    now = t0.add(minute);
    await sessions.start();
    now = t0.add(minute * 2);

    final reactivated = await sessions.reactivate(a.id);

    expect(reactivated.intervals, [
      ActivityInterval(t0, t0.add(minute)),
      ActivityInterval(t0.add(minute * 2)),
    ]);
    final all = await sessions.all();
    expect(all.where((s) => s.isActive).single.id, a.id);
    expect(all.last.intervals.single.end, t0.add(minute * 2));
  });

  test('reactivating the active Session changes nothing', () async {
    final sessions = repository();
    final a = await sessions.start();

    expect(await sessions.reactivate(a.id), a);
  });

  test('reactivation is blocked when expired or near expiry', () async {
    final sessions = repository();
    final a = await sessions.start();
    final b = await sessions.start();
    await sessions.start();
    final expiresAt = t0.add(retention);
    await sessions.setExpiresAt(a.code, expiresAt);
    await sessions.markExpired(b.code);

    now = expiresAt.subtract(reactivationMargin);
    expect((await sessions.reactivate(a.id)).isActive, isTrue);
    await sessions.stop();

    now = now.add(minute);
    await expectLater(
      sessions.reactivate(a.id),
      throwsA(isA<ReactivationBlockedException>()),
    );
    await expectLater(
      sessions.reactivate(b.id),
      throwsA(isA<ReactivationBlockedException>()),
    );
  });

  test('round-trips every instant as UTC', () async {
    final sessions = repository();
    final a = await sessions.start();
    now = t0.add(minute);
    await sessions.stop();
    await sessions.setExpiresAt(a.code, t0.add(retention).toLocal());
    final offset = ClockOffset(
      offset: const Duration(seconds: 90, milliseconds: 500),
      measuredAt: t0,
      source: ClockOffsetSource.syncShot,
    );
    await sessions.setClockOffset(offset);
    await sessions.setMarkedAt(t0.add(minute).toLocal());

    final reloaded = repository();
    final session = (await reloaded.all()).single;
    expect(session, (await sessions.all()).single);
    expect(session.expiresAt, t0.add(retention));
    expect(session.expiresAt!.isUtc, isTrue);
    expect(session.intervals.single.end!.isUtc, isTrue);
    expect(await reloaded.clockOffset(), offset);
    expect(await reloaded.markedAt(), t0.add(minute));
    expect(
      await file.readAsString(),
      allOf(contains('2026-11-13T10:00:00.000Z'), isNot(contains('+'))),
    );
  });

  test('parsing rejects non-UTC timestamps', () {
    expect(() => parseUtc('2026-11-13T10:00:00'), throwsFormatException);
    expect(
      () => parseUtc('2026-11-13T10:00:00+01:00'),
      isNot(throwsA(anything)),
    );
    expect(parseUtc('2026-11-13T10:00:00+01:00').isUtc, isTrue);
  });

  test('a malformed or non-UTC file loads as empty', () async {
    final sessions = repository();
    await sessions.start();
    final json = (await file.readAsString()).replaceAll('Z"', '"');
    await file.writeAsString(json);

    expect(await repository().all(), isEmpty);

    await file.writeAsString('{not json');
    expect(await repository().all(), isEmpty);
    expect(jsonDecode(json), isA<Map<String, Object?>>());
  });

  test('notifies changes and ignores unknown codes', () async {
    final sessions = repository();
    final changes = sessions.changes.take(2).length;
    final a = await sessions.start();
    await sessions.markExpired('unknown-code-for-test');
    await sessions.markExpired(a.code);
    await sessions.markExpired(a.code);

    expect(await changes, 2);
    expect((await sessions.all()).single.expired, isTrue);
  });
}
