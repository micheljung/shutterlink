import 'package:flutter/material.dart';

import 'interval_plan.dart';

/// A starting point for a common kind of shoot; every value stays editable.
enum IntervalPreset {
  clouds(
    'Clouds',
    'Fast-moving sky in daylight.',
    Icons.cloud_outlined,
    IntervalPlan(interval: Duration(seconds: 3), shots: 300),
  ),
  sunset(
    'Sunset',
    'The sun going down, in camera exposure.',
    Icons.wb_twilight,
    IntervalPlan(interval: Duration(seconds: 5), shots: 480),
  ),
  cityNight(
    'City at night',
    'Traffic and lights after dark.',
    Icons.location_city,
    IntervalPlan(interval: Duration(seconds: 10), shots: 360),
  ),
  stars(
    'Stars',
    'The night sky turning, 20 s on BULB.',
    Icons.auto_awesome_outlined,
    IntervalPlan(
      control: ExposureControl.bulb,
      exposure: Duration(seconds: 20),
      interval: Duration(seconds: 22),
      shots: 300,
    ),
  ),
  dayToNight(
    'Day to night',
    'Sunset into stars, ramping BULB from 1 s to 20 s.',
    Icons.nights_stay_outlined,
    IntervalPlan(
      control: ExposureControl.bulb,
      exposure: Duration(seconds: 1),
      rampTo: Duration(seconds: 20),
      interval: Duration(seconds: 25),
      shots: 360,
    ),
  ),
  starTrails(
    'Star trails',
    'One hour of 1-minute BULB shots to stack.',
    Icons.blur_circular,
    IntervalPlan(
      control: ExposureControl.bulb,
      exposure: Duration(minutes: 1),
      interval: Duration(seconds: 62),
      shots: 60,
    ),
  ),
  longExposure(
    'Long exposure',
    'A single 5-minute BULB exposure.',
    Icons.hourglass_bottom,
    IntervalPlan(
      control: ExposureControl.bulb,
      exposure: Duration(minutes: 5),
      interval: Duration(minutes: 5, seconds: 1),
      shots: 1,
    ),
  );

  const IntervalPreset(this.label, this.description, this.icon, this.plan);

  final String label;
  final String description;
  final IconData icon;
  final IntervalPlan plan;

  /// The preset [plan] is, ignoring the start delay.
  static IntervalPreset? of(IntervalPlan plan) {
    final undelayed = plan.copyWith(startDelay: Duration.zero);
    for (final preset in values) {
      if (preset.plan == undelayed) return preset;
    }
    return null;
  }
}
