import 'dart:io';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;

import '../feature/sessions/sessions_config.dart';

/// JPEGs Live transfer already took off the camera, kept until Sessions
/// decides on them so the collector does not download them again.
class SessionsPrefetch {
  SessionsPrefetch(this._directory, {this._clock = const Clock()});

  static const directoryName = 'sessions_prefetch';
  static const _extension = '.jpg';

  final Directory _directory;
  final Clock _clock;

  File fileFor(String key) =>
      File(p.join(_directory.path, '${Uri.encodeComponent(key)}$_extension'));

  /// Never fails: without a copy the collector downloads the photo itself.
  Future<void> keep(String key, File source) async {
    try {
      await _directory.create(recursive: true);
      await source.copy(fileFor(key).path);
    } on FileSystemException {
      return;
    }
  }

  /// Moves the copy of [key] to [target] if it holds all [size] bytes. An
  /// incomplete copy is deleted.
  Future<bool> take(String key, int size, File target) async {
    final file = fileFor(key);
    try {
      if (await file.length() == size) {
        await file.rename(target.path);
        return true;
      }
      await file.delete();
    } on FileSystemException {
      return false;
    }
    return false;
  }

  Future<Set<String>> keys() async => {
    for (final file in await _files()) ?_keyOf(file),
  };

  Future<void> discard(Iterable<String> keys) async {
    for (final key in keys) {
      await _delete(fileFor(key));
    }
  }

  /// Deletes copies older than [queueMaxAge] and those of [settled] photos.
  Future<void> sweep(Set<String> settled) async {
    final cutoff = _clock.now().subtract(queueMaxAge);
    for (final file in await _files()) {
      if (settled.contains(_keyOf(file)) ||
          (await file.stat()).modified.isBefore(cutoff)) {
        await _delete(file);
      }
    }
  }

  Future<List<File>> _files() async {
    if (!await _directory.exists()) return const [];
    return (await _directory.list().toList()).whereType<File>().toList();
  }

  static String? _keyOf(File file) {
    if (p.extension(file.path) != _extension) return null;
    try {
      return Uri.decodeComponent(p.basenameWithoutExtension(file.path));
    } on ArgumentError {
      return null;
    }
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      return;
    }
  }
}
