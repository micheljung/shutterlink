import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:equatable/equatable.dart';
import 'package:path/path.dart' as p;

import '../feature/sessions/session.dart';
import '../feature/sessions/sessions_config.dart';
import 'json_file.dart';

class UploadItem extends Equatable {
  const UploadItem({
    required this.photoKey,
    required this.sessionCode,
    required this.filePath,
    required this.enqueuedAt,
    required this.nextAttemptAt,
    this.attempts = 0,
    this.lastStatus,
  });

  factory UploadItem.fromJson(Map<String, Object?> json) => UploadItem(
    photoKey: json['photoKey']! as String,
    sessionCode: json['sessionCode']! as String,
    filePath: json['filePath']! as String,
    enqueuedAt: parseUtc(json['enqueuedAt']),
    nextAttemptAt: parseUtc(json['nextAttemptAt']),
    attempts: json['attempts']! as int,
    lastStatus: json['lastStatus'] as String?,
  );

  final String photoKey;
  final String sessionCode;
  final String filePath;
  final DateTime enqueuedAt;
  final DateTime nextAttemptAt;
  final int attempts;
  final String? lastStatus;

  bool isSameAs(UploadItem other) =>
      photoKey == other.photoKey && sessionCode == other.sessionCode;

  UploadItem copyWith({
    int? attempts,
    DateTime? nextAttemptAt,
    String? lastStatus,
  }) => UploadItem(
    photoKey: photoKey,
    sessionCode: sessionCode,
    filePath: filePath,
    enqueuedAt: enqueuedAt,
    nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
    attempts: attempts ?? this.attempts,
    lastStatus: lastStatus ?? this.lastStatus,
  );

  Map<String, Object?> toJson() => {
    'photoKey': photoKey,
    'sessionCode': sessionCode,
    'filePath': filePath,
    'enqueuedAt': formatUtc(enqueuedAt),
    'nextAttemptAt': formatUtc(nextAttemptAt),
    'attempts': attempts,
    'lastStatus': ?lastStatus,
  };

  @override
  List<Object?> get props => [
    photoKey,
    sessionCode,
    filePath,
    enqueuedAt,
    nextAttemptAt,
    attempts,
    lastStatus,
  ];
}

class SessionsUploadQueue {
  SessionsUploadQueue(
    File manifest, {
    this._uploadDirectory,
    this._clock = const Clock(),
  }) : _file = JsonFile(manifest, clock: _clock);

  /// A file the collector is still downloading is younger than this, so it
  /// is never swept as an orphan.
  static const orphanAge = Duration(hours: 1);

  static const fileName = 'sessions_upload_queue.json';

  final JsonFile _file;
  final Directory? _uploadDirectory;
  final Clock _clock;
  final _changes = StreamController<void>.broadcast();
  final _enqueued = StreamController<void>.broadcast();
  late final Future<_QueueData> _data = _load();

  Stream<void> get changes => _changes.stream;

  Stream<void> get enqueued => _enqueued.stream;

  Future<List<UploadItem>> items() async =>
      List.unmodifiable((await _data).items);

  Future<int> droppedCount() async => (await _data).dropped;

  Future<int> expiredCount() async => (await _data).expired;

  static Future<String> photoKeyOf(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<UploadItem?> enqueue({
    required String sessionCode,
    required File file,
  }) async {
    final photoKey = await photoKeyOf(file);
    final item = await _file.serialized(() async {
      final data = await _data;
      final now = _clock.now().toUtc();
      final candidate = UploadItem(
        photoKey: photoKey,
        sessionCode: sessionCode,
        filePath: file.path,
        enqueuedAt: now,
        nextAttemptAt: now,
      );
      final existing = data.items.where(candidate.isSameAs).firstOrNull;
      if (existing != null) {
        if (existing.filePath != file.path) await _delete(file.path);
        return null;
      }
      data.items.add(candidate);
      await _persist(data);
      return candidate;
    });
    if (item != null) _enqueued.add(null);
    return item;
  }

  Future<UploadItem?> nextDue() => _file.serialized(() async {
    final data = await _data;
    if (await _dropStale(data)) await _persist(data);
    final now = _clock.now().toUtc();
    final due = data.items.where((item) => !item.nextAttemptAt.isAfter(now));
    return due.isEmpty ? null : due.reduce(_earlier);
  });

  Future<DateTime?> nextAttemptAt() async {
    final items = (await _data).items;
    return items.isEmpty ? null : items.reduce(_earlier).nextAttemptAt;
  }

  Future<void> complete(UploadItem item, {bool expired = false}) =>
      _remove(item, (data) {
        if (expired) data.expired++;
      });

  Future<void> drop(UploadItem item) => _remove(item, (data) => data.dropped++);

  Future<void> reschedule(UploadItem item) => _file.serialized(() async {
    final data = await _data;
    final index = data.items.indexWhere(item.isSameAs);
    if (index < 0) return;
    data.items[index] = item;
    await _persist(data);
  });

  Future<void> _remove(UploadItem item, void Function(_QueueData data) count) =>
      _file.serialized(() async {
        final data = await _data;
        final index = data.items.indexWhere(item.isSameAs);
        if (index < 0) return;
        final removed = data.items.removeAt(index);
        count(data);
        await _delete(removed.filePath);
        await _persist(data);
      });

  static UploadItem _earlier(UploadItem a, UploadItem b) =>
      b.nextAttemptAt.isBefore(a.nextAttemptAt) ? b : a;

  Future<bool> _dropStale(_QueueData data) async {
    final cutoff = _clock.now().toUtc().subtract(queueMaxAge);
    final stale = data.items
        .where((item) => item.enqueuedAt.isBefore(cutoff))
        .toList();
    for (final item in stale) {
      data.items.remove(item);
      data.dropped++;
      await _delete(item.filePath);
    }
    return stale.isNotEmpty;
  }

  Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      return;
    }
  }

  Future<void> _persist(_QueueData data) async {
    await _file.save(data.toJson());
    _changes.add(null);
  }

  Future<_QueueData> _load() async {
    final data = await _file.read(
      _QueueData.fromJson,
      () => _QueueData([], 0, 0),
    );
    if (await _dropStale(data)) await _persist(data);
    await _sweepOrphans(data);
    return data;
  }

  Future<void> _sweepOrphans(_QueueData data) async {
    final directory = _uploadDirectory;
    if (directory == null || !await directory.exists()) return;
    final queued = {
      for (final item in data.items) p.canonicalize(item.filePath),
    };
    final cutoff = _clock.now().subtract(orphanAge);
    await for (final entity in directory.list()) {
      if (entity is! File || queued.contains(p.canonicalize(entity.path))) {
        continue;
      }
      if ((await entity.stat()).modified.isBefore(cutoff)) {
        await _delete(entity.path);
      }
    }
  }
}

class _QueueData {
  _QueueData(this.items, this.dropped, this.expired);

  factory _QueueData.fromJson(Map<String, Object?> json) => _QueueData(
    [
      for (final item in json['items'] as List<Object?>? ?? const [])
        UploadItem.fromJson(item! as Map<String, Object?>),
    ],
    json['dropped'] as int? ?? 0,
    json['expired'] as int? ?? 0,
  );

  final List<UploadItem> items;
  int dropped;
  int expired;

  Map<String, Object?> toJson() => {
    'items': [for (final item in items) item.toJson()],
    'dropped': dropped,
    'expired': expired,
  };
}
