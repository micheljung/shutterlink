import 'dart:io';

import 'package:clock/clock.dart';

import '../feature/sessions/session.dart';
import '../feature/sessions/sessions_config.dart';
import '../ptpip/camera_client.dart';
import 'download_history.dart';
import 'json_file.dart';

enum SeenState { queued, excluded }

class SessionSeenStore {
  SessionSeenStore(File file, {this._clock = const Clock()})
    : _file = JsonFile(file);

  static const fileName = 'sessions_seen.json';

  final JsonFile _file;
  final Clock _clock;
  late final Future<_SeenData> _data = _read();

  static String keyOf(String cameraKey, CameraObject object) =>
      DownloadHistoryRepository.entryKey(cameraKey, object);

  Future<Map<String, SeenState>> states() async {
    final data = await _pruned();
    return {
      for (final MapEntry(:key, :value) in data.entries.entries)
        key: value.state,
    };
  }

  Future<SeenState?> stateOf(String key) async =>
      (await _pruned()).entries[key]?.state;

  Future<Set<String>?> baseline(String cameraKey) async =>
      (await _data).baselines[cameraKey]?.toSet();

  Future<void> markQueued(String cameraKey, Iterable<String> keys) =>
      _mark(cameraKey, keys, SeenState.queued);

  Future<void> markExcluded(String cameraKey, Iterable<String> keys) =>
      _mark(cameraKey, keys, SeenState.excluded);

  Future<void> pruneExcluded(String cameraKey, Set<String> listed) => _update(
    (data) => data.entries.removeWhere(
      (key, entry) =>
          entry.camera == cameraKey &&
          entry.state == SeenState.excluded &&
          !listed.contains(key),
    ),
  );

  Future<void> setBaseline(String cameraKey, Iterable<String> keys) =>
      _update((data) => data.baselines[cameraKey] = keys.toList());

  Future<void> _mark(String cameraKey, Iterable<String> keys, SeenState state) {
    final now = _clock.now().toUtc();
    return _update((data) {
      for (final key in keys) {
        if (state == SeenState.queued &&
            data.entries[key]?.state == SeenState.excluded) {
          continue;
        }
        data.entries[key] = _SeenEntry(cameraKey, state, now);
      }
    });
  }

  Future<_SeenData> _pruned() async {
    final data = await _data;
    final cutoff = _clock.now().toUtc().subtract(queueMaxAge);
    data.entries.removeWhere(
      (_, entry) =>
          entry.state == SeenState.queued && entry.at.isBefore(cutoff),
    );
    return data;
  }

  Future<void> _update(void Function(_SeenData data) change) =>
      _file.serialized(() async {
        final data = await _pruned();
        change(data);
        await _file.save(data.toJson());
      });

  Future<_SeenData> _read() =>
      _file.read(_SeenData.fromJson, () => _SeenData({}, {}));
}

class _SeenEntry {
  const _SeenEntry(this.camera, this.state, this.at);

  factory _SeenEntry.fromJson(Map<String, Object?> json) => _SeenEntry(
    json['camera']! as String,
    SeenState.values.byName(json['state']! as String),
    parseUtc(json['at']),
  );

  final String camera;
  final SeenState state;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'camera': camera,
    'state': state.name,
    'at': formatUtc(at),
  };
}

class _SeenData {
  _SeenData(this.entries, this.baselines);

  factory _SeenData.fromJson(Map<String, Object?> json) => _SeenData(
    {
      for (final MapEntry(:key, :value)
          in (json['entries'] as Map<String, Object?>? ?? const {}).entries)
        key: _SeenEntry.fromJson(value! as Map<String, Object?>),
    },
    {
      for (final MapEntry(:key, :value)
          in (json['baselines'] as Map<String, Object?>? ?? const {}).entries)
        key: (value! as List<Object?>).cast<String>().toList(),
    },
  );

  final Map<String, _SeenEntry> entries;
  final Map<String, List<String>> baselines;

  Map<String, Object?> toJson() => {
    'entries': {
      for (final MapEntry(:key, :value) in entries.entries) key: value.toJson(),
    },
    'baselines': baselines,
  };
}
