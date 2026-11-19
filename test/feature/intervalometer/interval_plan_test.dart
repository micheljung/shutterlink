import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/intervalometer/interval_plan.dart';
import 'package:shutterlink/feature/intervalometer/interval_presets.dart';

void main() {
  const bulb = IntervalPlan(
    control: ExposureControl.bulb,
    exposure: Duration(seconds: 10),
    interval: Duration(seconds: 12),
    shots: 10,
  );

  test('run time spans the intervals plus the last bulb exposure', () {
    expect(bulb.runTime, const Duration(seconds: 9 * 12 + 10));
    expect(
      const IntervalPlan(interval: Duration(seconds: 5), shots: 3).runTime,
      const Duration(seconds: 10),
    );
    expect(const IntervalPlan(shots: null).runTime, isNull);
  });

  test('clip length is shots over frame rate', () {
    expect(
      const IntervalPlan(shots: 240).clipLength(24),
      const Duration(seconds: 10),
    );
    expect(const IntervalPlan(shots: null).clipLength(24), isNull);
  });

  test('a bulb exposure that fills the interval is a problem', () {
    expect(bulb.problem, isNull);
    expect(
      bulb.copyWith(interval: const Duration(milliseconds: 10500)).problem,
      PlanProblem.intervalTooShort,
    );
    expect(
      bulb
          .copyWith(
            control: ExposureControl.camera,
            interval: Duration(seconds: 1),
          )
          .problem,
      isNull,
    );
  });

  test('ramping needs a shot count', () {
    expect(
      bulb
          .copyWith(rampTo: const Duration(seconds: 20), clearShots: true)
          .problem,
      PlanProblem.rampNeedsShotCount,
    );
  });

  test('a ramp is even in stops from first to last exposure', () {
    final ramp = bulb.copyWith(
      exposure: const Duration(seconds: 1),
      rampTo: const Duration(seconds: 16),
      interval: const Duration(seconds: 20),
      shots: 5,
    );
    expect(
      [for (var i = 0; i < 5; i++) ramp.exposureAt(i).inMilliseconds],
      [1000, 2000, 4000, 8000, 16000],
    );
    expect(ramp.longestExposure, const Duration(seconds: 16));
  });

  test('a longer exposure grows the interval only when it no longer fits', () {
    expect(
      bulb.withExposure(const Duration(seconds: 5)).interval,
      const Duration(seconds: 12),
    );
    expect(
      bulb.withExposure(const Duration(seconds: 30)).interval,
      const Duration(seconds: 31),
    );
  });

  test('the gap sets the interval', () {
    expect(
      bulb.withGap(const Duration(seconds: 3)).interval,
      const Duration(seconds: 13),
    );
    expect(bulb.gap, const Duration(seconds: 2));
  });

  test('switching to bulb makes room for the exposure', () {
    const camera = IntervalPlan(
      exposure: Duration(seconds: 20),
      interval: Duration(seconds: 5),
    );
    expect(
      camera.withControl(ExposureControl.bulb).interval,
      const Duration(seconds: 21),
    );
  });

  test('round-trips through JSON, including shooting until stopped', () {
    final ramp = bulb.copyWith(rampTo: const Duration(seconds: 25));
    expect(IntervalPlan.fromJson(ramp.toJson()), ramp);
    final endless = const IntervalPlan().copyWith(clearShots: true);
    expect(IntervalPlan.fromJson(endless.toJson()), endless);
  });

  test('a broken stored plan falls back to the defaults', () {
    expect(
      IntervalPlan.fromJson({
        'control': 'nonsense',
        'intervalMs': -5,
        'shots': 'many',
      }),
      const IntervalPlan().copyWith(clearShots: true),
    );
    expect(IntervalPlan.fromJson({}), const IntervalPlan());
  });

  test('every preset is a valid plan and is recognised', () {
    for (final preset in IntervalPreset.values) {
      expect(preset.plan.problem, isNull, reason: preset.label);
      expect(IntervalPreset.of(preset.plan), preset);
    }
    expect(IntervalPreset.of(const IntervalPlan(shots: 7)), isNull);
  });
}
