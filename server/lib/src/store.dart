import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'cleanup.dart';
import 'codes.dart';
import 'limits.dart' as limits;
import 'locks.dart';

const int _secretLength = 32;
const int _tmpNameLength = 16;
const String _ownerOnlyMode = '600';
const String _photoExtension = '.jpg';

enum PutError { tooLarge, shaMismatch, expired, sessionFull }

class PutResult {
  const PutResult.stored({required this.created, required this.expiresAt})
    : error = null;
  const PutResult.failed(PutError this.error)
    : created = false,
      expiresAt = null;

  final bool created;
  final DateTime? expiresAt;
  final PutError? error;
}

class StoredPhoto {
  const StoredPhoto(this.key, this.file, this.size, this.modified);

  final String key;
  final File file;
  final int size;
  final DateTime modified;
}

class SessionSnapshot {
  const SessionSnapshot(this.photos, this.createdAt, this.expiresAt);

  final List<StoredPhoto> photos;
  final DateTime createdAt;
  final DateTime expiresAt;
}

class SessionStore {
  SessionStore._(
    this._root,
    this._secret, {
    required this.clock,
    required this.retention,
    required this.maxPhotoBytes,
    required this.maxSessionBytes,
    required this.maxSessionPhotos,
  });

  static Future<SessionStore> open(
    Directory root, {
    Clock clock = const Clock(),
    Duration retention = limits.defaultRetention,
    int maxPhotoBytes = limits.maxPhotoBytes,
    int maxSessionBytes = limits.maxSessionBytes,
    int maxSessionPhotos = limits.maxSessionPhotos,
  }) async {
    for (final name in const ['sessions', 'tombstones', 'tmp']) {
      await Directory(p.join(root.path, name)).create(recursive: true);
    }
    return SessionStore._(
      root,
      await _loadSecret(File(p.join(root.path, 'secret'))),
      clock: clock,
      retention: retention,
      maxPhotoBytes: maxPhotoBytes,
      maxSessionBytes: maxSessionBytes,
      maxSessionPhotos: maxSessionPhotos,
    );
  }

  static Future<List<int>> _loadSecret(File file) async {
    if (await file.exists()) return file.readAsBytes();
    final random = Random.secure();
    final secret = Uint8List.fromList(
      List.generate(_secretLength, (_) => random.nextInt(256)),
    );
    await file.writeAsBytes(secret, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', [_ownerOnlyMode, file.path]);
    }
    return secret;
  }

  final Directory _root;
  final List<int> _secret;
  final Clock clock;
  final Duration retention;
  final int maxPhotoBytes;
  final int maxSessionBytes;
  final int maxSessionPhotos;
  final KeyedMutex _mutex = KeyedMutex();
  final KeyedLock zipLocks = KeyedLock();

  String dirName(String code) => sessionDirName(_secret, code);

  Directory _sessionDir(String name) =>
      Directory(p.join(_root.path, 'sessions', name));
  Directory _photosDir(String name) =>
      Directory(p.join(_sessionDir(name).path, 'photos'));
  File _createdFile(String name) =>
      File(p.join(_sessionDir(name).path, 'created'));
  File _tombstone(String name) => File(p.join(_root.path, 'tombstones', name));
  Directory get _tmpDir => Directory(p.join(_root.path, 'tmp'));

  File _newTmpFile() {
    final random = Random.secure();
    final name = List.generate(
      _tmpNameLength,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return File(p.join(_tmpDir.path, name));
  }

  Future<PutResult> put(String code, String key, Stream<List<int>> body) async {
    final tmp = _newTmpFile();
    try {
      final (size, error) = await _receive(body, tmp, key);
      if (error != null) return PutResult.failed(error);
      final name = dirName(code);
      return await _mutex.run(name, () => _commit(name, key, tmp, size));
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  Future<(int, PutError?)> _receive(
    Stream<List<int>> body,
    File tmp,
    String key,
  ) async {
    Digest? digest;
    final hasher = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single),
    );
    final sink = tmp.openWrite();
    var size = 0;
    try {
      await for (final chunk in body) {
        size += chunk.length;
        if (size > maxPhotoBytes) return (size, PutError.tooLarge);
        hasher.add(chunk);
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    hasher.close();
    return (size, digest.toString() == key ? null : PutError.shaMismatch);
  }

  Future<PutResult> _commit(String name, String key, File tmp, int size) async {
    if (await _tombstone(name).exists()) {
      return const PutResult.failed(PutError.expired);
    }
    final target = File(p.join(_photosDir(name).path, '$key$_photoExtension'));
    if (await target.exists()) {
      final created = await _readCreated(name);
      return PutResult.stored(
        created: false,
        expiresAt: created!.add(retention),
      );
    }
    final existing = await _listPhotos(name);
    final total = existing.fold<int>(0, (sum, photo) => sum + photo.size);
    if (existing.length >= maxSessionPhotos || total + size > maxSessionBytes) {
      return const PutResult.failed(PutError.sessionFull);
    }
    await _photosDir(name).create(recursive: true);
    final created = await _readCreated(name) ?? await _writeCreated(name);
    await tmp.rename(target.path);
    return PutResult.stored(created: true, expiresAt: created.add(retention));
  }

  Future<DateTime?> _readCreated(String name) async {
    final file = _createdFile(name);
    if (!await file.exists()) return null;
    return DateTime.tryParse((await file.readAsString()).trim());
  }

  Future<DateTime> _writeCreated(String name) async {
    final now = clock.now().toUtc();
    final tmp = _newTmpFile();
    await tmp.writeAsString(now.toIso8601String(), flush: true);
    await tmp.rename(_createdFile(name).path);
    return now;
  }

  Future<List<StoredPhoto>> _listPhotos(String name) async {
    final dir = _photosDir(name);
    if (!await dir.exists()) return const [];
    final photos = <StoredPhoto>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final base = p.basename(entity.path);
      if (!base.endsWith(_photoExtension)) continue;
      final key = base.substring(0, base.length - _photoExtension.length);
      if (!isValidKey(key)) continue;
      final stat = await entity.stat();
      photos.add(StoredPhoto(key, entity, stat.size, stat.modified));
    }
    photos.sort((a, b) {
      final byTime = a.modified.compareTo(b.modified);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
    return photos;
  }

  Future<SessionSnapshot?> snapshot(String code) {
    final name = dirName(code);
    return _mutex.run(name, () async {
      if (await _tombstone(name).exists()) return null;
      final created = await _readCreated(name);
      if (created == null) return null;
      final photos = await _listPhotos(name);
      if (photos.isEmpty) return null;
      return SessionSnapshot(photos, created, created.add(retention));
    });
  }

  Future<StoredPhoto?> photo(String code, String key) async {
    final snapshot = await this.snapshot(code);
    if (snapshot == null) return null;
    for (final photo in snapshot.photos) {
      if (photo.key == key) return photo;
    }
    return null;
  }

  Future<void> purgeExpired() async {
    final now = clock.now().toUtc();
    await for (final entity in Directory(
      p.join(_root.path, 'sessions'),
    ).list()) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      await _mutex.run(name, () => _purgeSession(name, now));
    }
    await for (final entity in Directory(
      p.join(_root.path, 'tombstones'),
    ).list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      await _mutex.run(name, () async {
        final purgedAt = DateTime.tryParse(
          (await entity.readAsString()).trim(),
        );
        if (purgedAt == null ||
            !now.isBefore(purgedAt.add(limits.tombstoneRetention))) {
          await entity.delete();
        }
      });
    }
    await for (final entity in _tmpDir.list()) {
      if (entity is! File) continue;
      final modified = (await entity.stat()).modified;
      if (now.difference(modified) >= cleanupInterval) {
        await entity.delete();
      }
    }
  }

  Future<void> _purgeSession(String name, DateTime now) async {
    if (zipLocks.isLocked(name)) return;
    final created = await _readCreated(name);
    if (created == null || now.isBefore(created.add(retention))) return;
    await _tombstone(name).writeAsString(now.toIso8601String(), flush: true);
    await _sessionDir(name).delete(recursive: true);
  }
}
