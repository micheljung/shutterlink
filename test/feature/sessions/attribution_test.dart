import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/sessions/attribution.dart';
import 'package:shutterlink/feature/sessions/session.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 13, 10);
  const minute = Duration(minutes: 1);
  const cameraLag = Duration(seconds: 90);

  Session session(String code, List<ActivityInterval> intervals) => Session(
    id: code,
    code: code,
    createdAt: intervals.first.start,
    intervals: intervals,
  );

  final a = session('a', [ActivityInterval(t0, t0.add(minute))]);
  final b = session('b', [
    ActivityInterval(t0.add(minute * 2), t0.add(minute * 3)),
    ActivityInterval(t0.add(minute * 5)),
  ]);
  final sessions = [a, b];

  Session? at(DateTime instant, {DateTime? openUntil}) =>
      attribute(instant, sessions, Duration.zero, openUntil: openUntil);

  test('intervals are half-open', () {
    expect(at(t0), a);
    expect(at(t0.add(minute).subtract(const Duration(microseconds: 1))), a);
    expect(at(t0.add(minute)), isNull);
    expect(at(t0.subtract(const Duration(microseconds: 1))), isNull);
  });

  test('a photo in a gap or before every Session matches nothing', () {
    expect(at(t0.add(minute * 4)), isNull);
    expect(at(t0.subtract(minute)), isNull);
  });

  test('a reactivated Session matches either interval', () {
    expect(at(t0.add(minute * 2)), b);
    expect(at(t0.add(minute * 5)), b);
  });

  test('an open interval runs until openUntil', () {
    final cap = t0.add(minute * 10);

    expect(at(t0.add(minute * 60)), b);
    expect(at(cap.subtract(const Duration(seconds: 1)), openUntil: cap), b);
    expect(at(cap, openUntil: cap), isNull);
  });

  test('a null capture date is never attributed', () {
    expect(attribute(null, sessions, Duration.zero), isNull);
  });

  test('applies the offset to a lagging camera clock', () {
    final camera = t0.add(const Duration(seconds: 30)).subtract(cameraLag);

    expect(attribute(camera, sessions, Duration.zero), isNull);
    expect(attribute(camera, sessions, cameraLag), a);
    expect(
      attribute(t0.add(minute * 4).subtract(cameraLag), sessions, cameraLag),
      isNull,
    );
  });

  test('compares local capture times in UTC across a DST change', () {
    final dstEnd = DateTime.utc(2026, 10, 25, 1);
    final around = session('dst', [
      ActivityInterval(dstEnd.subtract(minute * 30), dstEnd.add(minute * 30)),
    ]);
    final before = dstEnd.subtract(minute * 10).toLocal();
    final after = dstEnd.add(minute * 10).toLocal();
    final outside = dstEnd.add(minute * 90).toLocal();

    expect(attribute(before, [around], Duration.zero), around);
    expect(attribute(after, [around], Duration.zero), around);
    expect(attribute(outside, [around], Duration.zero), isNull);
  });
}
