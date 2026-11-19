import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../feature/intervalometer/interval_plan.dart';
import '../remote/shutter_remote.dart';

/// The paired Bluetooth camera and the last plan, so the next shoot starts
/// where the last one left off.
class IntervalometerRepository {
  IntervalometerRepository(this._prefs);

  static const cameraKey = 'intervalometer_camera';
  static const planKey = 'intervalometer_plan';
  static const frameRateKey = 'intervalometer_frame_rate';

  final SharedPreferences _prefs;

  RemoteCamera? get camera => RemoteCamera.fromJson(_decode(cameraKey));

  Future<void> setCamera(RemoteCamera? camera) => camera == null
      ? _prefs.remove(cameraKey)
      : _prefs.setString(cameraKey, jsonEncode(camera.toJson()));

  IntervalPlan get plan {
    final json = _decode(planKey);
    return json is Map<String, Object?>
        ? IntervalPlan.fromJson(json)
        : const IntervalPlan();
  }

  Future<void> setPlan(IntervalPlan plan) =>
      _prefs.setString(planKey, jsonEncode(plan.toJson()));

  int get frameRate {
    final rate = _prefs.getInt(frameRateKey);
    return IntervalPlan.clipFrameRates.contains(rate)
        ? rate!
        : IntervalPlan.defaultFrameRate;
  }

  Future<void> setFrameRate(int rate) => _prefs.setInt(frameRateKey, rate);

  Object? _decode(String key) {
    final text = _prefs.getString(key);
    if (text == null) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
}
