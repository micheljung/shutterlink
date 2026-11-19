import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'cleanup.dart';
import 'codes.dart';
import 'limits.dart' as limits;
import 'locks.dart';

const int _secretLength = 32;
const int _tmpNameLength = 16;
const String _ownerOnlyMode = '600';
const String _photoExtension = '.jpg';
const int _byteValues = 256;
const int _bootIdLength = 8;
const String _readySuffix = '.ready';
const String _failedSuffix = '.failed';
const String _attemptSuffix = '.attempt';

final RegExp _readyPattern = RegExp(r'^([0-9a-f]{64})\.(\d+)x(\d+)\.ready$');
final RegExp _failedPattern = RegExp(r'^([0-9a-f]{64})\.failed$');
final RegExp _attemptPattern = RegExp(
  r'^([0-9a-f]{64})\.([0-9a-f]+)\.attempt$',
);

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

enum PreviewStatus { pending, ready, failed }

class PreviewInfo {
  const PreviewInfo.ready(int this.width, int this.height)
    : status = PreviewStatus.ready;
  const PreviewInfo._(this.status) : width = null, height = null;

  static const PreviewInfo pending = PreviewInfo._(PreviewStatus.pending);
  static const PreviewInfo failed = PreviewInfo._(PreviewStatus.failed);

  final PreviewStatus status;
  final int? width;
  final int? height;
}

enum PreviewKind {
  thumbnail('.t.jpg'),
  view('.v.jpg');

  const PreviewKind(this.suffix);

  final String suffix;
}

class PreviewFile {
  const PreviewFile(this.file, this.size, this.expiresAt);

  final File file;
  final int size;
  final DateTime expiresAt;
}

class StoredPhoto {
  const StoredPhoto(
    this.key,
    this.file,
    this.size,
    this.modified, [
    this.preview = PreviewInfo.pending,
  ]);

  final String key;
  final File file;
  final int size;
  final DateTime modified;
  final PreviewInfo preview;

  StoredPhoto withPreview(PreviewInfo preview) =>
      StoredPhoto(key, file, size, modified, preview);
}

class PendingPreview {
  const PendingPreview(this.key, this.crashedAttempts);

  final String key;

  /// Attempts left by earlier boots that never finished.
  final int crashedAttempts;
}

class SessionSnapshot {
  const SessionSnapshot(
    this.photos,
    this.createdAt,
    this.expiresAt,
    this.generation,
  );

  final List<StoredPhoto> photos;
  final DateTime createdAt;
  final DateTime expiresAt;

  /// The generation read in the same critical section as [photos].
  final int generation;
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
  }) : bootId = _randomHex(_bootIdLength);

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
      await _loadSecret(
        File(p.join(root.path, 'secret')),
        Directory(p.join(root.path, 'tmp')),
      ),
      clock: clock,
      retention: retention,
      maxPhotoBytes: maxPhotoBytes,
      maxSessionBytes: maxSessionBytes,
      maxSessionPhotos: maxSessionPhotos,
    );
  }

  /// Fails on a secret of the wrong length: a new one would orphan every
  /// stored Session.
  static Future<List<int>> _loadSecret(File file, Directory tmpDir) async {
    if (await file.exists()) {
      final secret = await file.readAsBytes();
      if (secret.length != _secretLength) {
        throw StateError(
          '${file.path} holds ${secret.length} bytes, expected '
          '$_secretLength. Restore it from a backup.',
        );
      }
      return secret;
    }
    final random = Random.secure();
    final secret = Uint8List.fromList(
      List.generate(_secretLength, (_) => random.nextInt(_byteValues)),
    );
    final tmp = _tmpFileIn(tmpDir);
    await tmp.writeAsBytes(secret, flush: true);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', [_ownerOnlyMode, tmp.path]);
      if (chmod.exitCode != 0) {
        await tmp.delete();
        throw FileSystemException('chmod failed: ${chmod.stderr}', tmp.path);
      }
    }
    await tmp.rename(file.path);
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

  /// Random per [open], so a generation from an earlier boot never matches.
  final String bootId;

  /// Called synchronously, inside the Session mutex, after a new photo is
  /// stored. It must not await anything that takes the Session mutex.
  void Function(String name, String key)? onCommitted;

  /// Called synchronously after each generation bump, under the same rules
  /// as [onCommitted].
  void Function(String name, int generation)? onBump;

  /// Called synchronously after a purge removed the Session's generation.
  void Function(String name)? onPurged;

  int _seq = 0;
  final Map<String, (int, DateTime)> _generation = {};

  @visibleForTesting
  int snapshotCalls = 0;

  String dirName(String code) => sessionDirName(_secret, code);

  Directory _sessionDir(String name) =>
      Directory(p.join(_root.path, 'sessions', name));
  Directory _photosDir(String name) =>
      Directory(p.join(_sessionDir(name).path, 'photos'));
  Directory _previewsDir(String name) =>
      Directory(p.join(_sessionDir(name).path, 'previews'));
  File _previewPath(String name, String key, PreviewKind kind) =>
      File(p.join(_previewsDir(name).path, '$key${kind.suffix}'));
  File _attemptFile(String name, String key) =>
      File(p.join(_previewsDir(name).path, '$key.$bootId$_attemptSuffix'));
  File _createdFile(String name) =>
      File(p.join(_sessionDir(name).path, 'created'));
  File _tombstone(String name) => File(p.join(_root.path, 'tombstones', name));
  Directory _deletedDir(String name) =>
      Directory(p.join(_sessionDir(name).path, 'deleted'));
  File _photoTombstone(String name, String key) =>
      File(p.join(_deletedDir(name).path, key));
  Directory get _tmpDir => Directory(p.join(_root.path, 'tmp'));

  /// A fresh path in `tmp/`, which the cleanup sweeps if it is left behind.
  File newTmpFile() => _tmpFileIn(_tmpDir);

  File photoFile(String name, String key) =>
      File(p.join(_photosDir(name).path, '$key$_photoExtension'));

  static File _tmpFileIn(Directory dir) =>
      File(p.join(dir.path, _randomHex(_tmpNameLength)));

  static String _randomHex(int length) {
    final random = Random.secure();
    return List.generate(
      length,
      (_) => random.nextInt(_byteValues).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<PutResult> put(String code, String key, Stream<List<int>> body) async {
    final tmp = newTmpFile();
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
    final target = photoFile(name, key);
    if (await target.exists() || await _photoTombstone(name, key).exists()) {
      final created = await _readCreated(name) ?? await _writeCreated(name);
      return PutResult.stored(
        created: false,
        expiresAt: created.add(retention),
      );
    }
    final existing = await _listPhotos(name);
    final total = existing.fold<int>(0, (sum, photo) => sum + photo.size);
    if (existing.length >= maxSessionPhotos || total + size > maxSessionBytes) {
      return const PutResult.failed(PutError.sessionFull);
    }
    await _sessionDir(name).create(recursive: true);
    final created = await _readCreated(name) ?? await _writeCreated(name);
    await _photosDir(name).create();
    await _previewsDir(name).create();
    await tmp.rename(target.path);
    _bump(name, created);
    try {
      onCommitted?.call(name, key);
    } catch (e) {
      stderr.writeln('Preview scheduling failed: $e');
    }
    return PutResult.stored(created: true, expiresAt: created.add(retention));
  }

  void _bump(String name, DateTime created) {
    final generation = ++_seq;
    _generation[name] = (generation, created.add(retention));
    try {
      onBump?.call(name, generation);
    } catch (e) {
      stderr.writeln('Change notification failed: $e');
    }
  }

  /// The Session's change counter, unique within this boot, or null for a
  /// Session that is unknown, empty, purged or expired. Takes no lock.
  int? generationOf(String name) {
    final entry = _generation[name];
    if (entry == null) return null;
    final (generation, expiresAt) = entry;
    return clock.now().isBefore(expiresAt) ? generation : null;
  }

  Future<DateTime?> _readCreated(String name) async {
    final file = _createdFile(name);
    if (!await file.exists()) return null;
    return DateTime.tryParse((await file.readAsString()).trim());
  }

  Future<DateTime> _writeCreated(String name) async {
    final now = clock.now().toUtc();
    final tmp = newTmpFile();
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
    snapshotCalls++;
    final name = dirName(code);
    return _mutex.run(name, () async {
      if (await _tombstone(name).exists()) return null;
      final created = await _readCreated(name);
      if (created == null) return null;
      final photos = await _listPhotos(name);
      if (photos.isEmpty) return null;
      final (previews, _) = await _listPreviews(name);
      final expiresAt = created.add(retention);
      final (generation, _) = _generation.putIfAbsent(
        name,
        () => (++_seq, expiresAt),
      );
      return SessionSnapshot(
        [
          for (final photo in photos)
            photo.withPreview(previews[photo.key] ?? PreviewInfo.pending),
        ],
        created,
        expiresAt,
        generation,
      );
    });
  }

  Future<(Map<String, PreviewInfo>, Map<String, List<String>>)> _listPreviews(
    String name,
  ) async {
    final states = <String, PreviewInfo>{};
    final attempts = <String, List<String>>{};
    final dir = _previewsDir(name);
    if (!await dir.exists()) return (states, attempts);
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final base = p.basename(entity.path);
      if (_readyPattern.firstMatch(base) case final m?) {
        states[m[1]!] = PreviewInfo.ready(int.parse(m[2]!), int.parse(m[3]!));
      } else if (_failedPattern.firstMatch(base) case final m?) {
        states.putIfAbsent(m[1]!, () => PreviewInfo.failed);
      } else if (_attemptPattern.firstMatch(base) case final m?) {
        attempts.putIfAbsent(m[1]!, () => []).add(m[2]!);
      }
    }
    return (states, attempts);
  }

  /// The created time of a live Session that previews may be written to.
  /// Null after a purge, so a late job never recreates the Session.
  Future<DateTime?> _previewTarget(String name) async {
    if (await _tombstone(name).exists()) return null;
    if (!await _sessionDir(name).exists()) return null;
    return _readCreated(name);
  }

  /// Like [_previewTarget], but also null once the photo was deleted, so a
  /// late job never brings its previews back.
  Future<DateTime?> _photoPreviewTarget(String name, String key) async {
    final created = await _previewTarget(name);
    if (created == null || !await photoFile(name, key).exists()) return null;
    return created;
  }

  Future<void> _deleteAttempts(String name, String key) async {
    await for (final entity in _previewsDir(name).list()) {
      final base = p.basename(entity.path);
      if (base.startsWith('$key.') && base.endsWith(_attemptSuffix)) {
        await entity.delete();
      }
    }
  }

  Stream<String> sessionNames() =>
      Directory(p.join(_root.path, 'sessions'))
          .list()
          .where((entity) => entity is Directory)
          .map((entity) => p.basename(entity.path));

  /// Seeds the generation of a live Session and lists its photos without a
  /// preview marker. Expired, empty and purged Sessions give an empty list.
  Future<List<PendingPreview>> scanSession(String name) {
    return _mutex.run(name, () async {
      final created = await _previewTarget(name);
      if (created == null) return const [];
      if (!clock.now().isBefore(created.add(retention))) return const [];
      final photos = await _listPhotos(name);
      if (photos.isEmpty) return const [];
      _generation.putIfAbsent(name, () => (++_seq, created.add(retention)));
      final (states, attempts) = await _listPreviews(name);
      return [
        for (final photo in photos)
          if (!states.containsKey(photo.key))
            PendingPreview(
              photo.key,
              (attempts[photo.key] ?? const [])
                  .where((boot) => boot != bootId)
                  .length,
            ),
      ];
    });
  }

  /// Records that this boot started a job, so a crash can be told apart
  /// from a clean shutdown. False if the Session is gone.
  Future<bool> writeAttempt(String name, String key) {
    return _mutex.run(name, () async {
      if (await _photoPreviewTarget(name, key) == null) return false;
      await _previewsDir(name).create();
      await _attemptFile(name, key).create();
      return true;
    });
  }

  Future<void> deleteAttempt(String name, String key) {
    return _mutex.run(name, () async {
      final attempt = _attemptFile(name, key);
      if (await attempt.exists()) await attempt.delete();
    });
  }

  /// Moves finished renditions into place. Writes nothing, and deletes the
  /// tmp files, if the Session or the photo is gone.
  Future<bool> commitPreview(
    String name,
    String key,
    File thumbnail,
    File view,
    int width,
    int height,
  ) {
    return _mutex.run(name, () async {
      try {
        final created = await _photoPreviewTarget(name, key);
        if (created == null) return false;
        await _previewsDir(name).create();
        await thumbnail.rename(
          _previewPath(name, key, PreviewKind.thumbnail).path,
        );
        await view.rename(_previewPath(name, key, PreviewKind.view).path);
        await File(
          p.join(_previewsDir(name).path, '$key.${width}x$height$_readySuffix'),
        ).create();
        await _deleteAttempts(name, key);
        _bump(name, created);
        return true;
      } finally {
        for (final file in [thumbnail, view]) {
          if (await file.exists()) await file.delete();
        }
      }
    });
  }

  Future<bool> markFailed(String name, String key) {
    return _mutex.run(name, () async {
      final created = await _photoPreviewTarget(name, key);
      if (created == null) return false;
      await _previewsDir(name).create();
      await File(p.join(_previewsDir(name).path, '$key$_failedSuffix'))
          .create();
      await _deleteAttempts(name, key);
      _bump(name, created);
      return true;
    });
  }

  Future<PreviewFile?> previewFile(String code, String key, PreviewKind kind) {
    final name = dirName(code);
    return _mutex.run(name, () async {
      if (!isValidKey(key) || await _tombstone(name).exists()) return null;
      final created = await _readCreated(name);
      if (created == null || !await photoFile(name, key).exists()) return null;
      final file = _previewPath(name, key, kind);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      return PreviewFile(file, stat.size, created.add(retention));
    });
  }

  Future<StoredPhoto?> photo(String code, String key) {
    final name = dirName(code);
    return _mutex.run(name, () async {
      if (!isValidKey(key) || await _tombstone(name).exists()) return null;
      if (await _readCreated(name) == null) return null;
      final file = photoFile(name, key);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      return StoredPhoto(key, file, stat.size, stat.modified);
    });
  }

  /// Deletes the photo and its previews for good: a later upload of the
  /// same photo is accepted but not stored. Does nothing for an unknown
  /// Session or photo.
  Future<void> deletePhoto(String code, String key) {
    final name = dirName(code);
    return _mutex.run(name, () async {
      if (!isValidKey(key) || await _tombstone(name).exists()) return;
      final created = await _readCreated(name);
      final original = photoFile(name, key);
      if (created == null || !await original.exists()) return;
      await _deletedDir(name).create();
      await _photoTombstone(name, key).create();
      final previews = _previewsDir(name);
      if (await previews.exists()) {
        await for (final entity in previews.list()) {
          if (p.basename(entity.path).startsWith('$key.')) {
            await entity.delete();
          }
        }
      }
      await original.delete();
      _bump(name, created);
      if ((await _listPhotos(name)).isEmpty) _generation.remove(name);
    });
  }

  /// Deletes the Session like an expiry, even while a zip is being built.
  /// Does nothing for an unknown Session.
  Future<void> deleteSession(String code) {
    final name = dirName(code);
    return _mutex.run(name, () async {
      if (await _tombstone(name).exists()) return;
      if (!await _sessionDir(name).exists()) return;
      final created = await _readCreated(name);
      if (created != null) _bump(name, created);
      await _removeSession(name, clock.now().toUtc());
    });
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
      final modified = (await entity.stat()).modified;
      if (now.difference(modified) >= cleanupInterval) {
        await entity.delete(recursive: true);
      }
    }
  }

  Future<void> _purgeSession(String name, DateTime now) async {
    if (zipLocks.isLocked(name)) return;
    if (!await _sessionDir(name).exists()) return;
    final created =
        await _readCreated(name) ??
        (await _sessionDir(name).stat()).modified.toUtc();
    if (now.isBefore(created.add(retention))) return;
    await _removeSession(name, now);
  }

  /// Moves the Session into a fresh directory in `tmp/` first, so it
  /// disappears at once and a crash mid-delete leaves only what the tmp
  /// sweep removes. The fresh directory keeps the sweep away meanwhile.
  Future<void> _removeSession(String name, DateTime now) async {
    await _tombstone(name).writeAsString(now.toIso8601String(), flush: true);
    final holder = await Directory(newTmpFile().path).create();
    await _sessionDir(name).rename(p.join(holder.path, name));
    await holder.delete(recursive: true);
    _generation.remove(name);
    try {
      onPurged?.call(name);
    } catch (e) {
      stderr.writeln('Purge notification failed: $e');
    }
  }
}
