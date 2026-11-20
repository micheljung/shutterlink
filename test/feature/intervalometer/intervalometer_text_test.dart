import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/intervalometer/interval_plan.dart';
import 'package:shutterlink/feature/intervalometer/interval_run.dart';
import 'package:shutterlink/feature/intervalometer/intervalometer_text.dart';
import 'package:shutterlink/remote/shutter_remote.dart';

void main() {
  final now = DateTime(2026, 11, 20, 12);
  final run = RunSnapshot(
    plan: const IntervalPlan(interval: Duration(seconds: 5), shots: 10),
    phase: RunPhase.waiting,
    taken: 2,
    missed: 1,
    startsAt: now,
  );

  String notification(RemoteLink link) =>
      IntervalometerText.notification(run, link: link, now: now);

  test('the notification says what the camera link needs', () {
    expect(notification(RemoteLink.connecting), contains('reconnecting'));
    expect(notification(RemoteLink.pairing), contains('Confirm the pairing'));
    expect(notification(RemoteLink.refused), contains('pair again'));
    expect(notification(RemoteLink.connected), isNot(contains('pair')));
  });
}
