import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../ptpip/camera_client.dart';

typedef ThumbnailFetcher = Future<Uint8List?> Function(int handle);

class ThumbnailCache {
  ThumbnailCache({
    required this.directory,
    this.maxMemoryEntries = defaultMaxMemoryEntries,
  });

  static const defaultMaxMemoryEntries = 100;

  final Directory directory;
  final int maxMemoryEntries;

  final _memory = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List?>>{};

  int get memoryEntryCount => _memory.length;

  Uint8List? peek(CameraObject object) => _memory[cacheKey(object)];

  Future<Uint8List?> get(CameraObject object, ThumbnailFetcher fetch) {
    final key = cacheKey(object);
    final cached = _memory.remove(key);
    if (cached != null) {
      _memory[key] = cached;
      return Future.value(cached);
    }
    return _pending[key] ??= _load(key, object, fetch).whenComplete(() {
      _pending.remove(key);
    });
  }

  Future<Uint8List?> _load(
    String key,
    CameraObject object,
    ThumbnailFetcher fetch,
  ) async {
    final file = File(p.join(directory.path, '$key.jpg'));
    Uint8List? bytes;
    if (await file.exists()) {
      bytes = await file.readAsBytes();
    } else {
      bytes = await fetch(object.handle);
      if (bytes != null) {
        await directory.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
      }
    }
    if (bytes != null) _remember(key, bytes);
    return bytes;
  }

  void _remember(String key, Uint8List bytes) {
    _memory.remove(key);
    _memory[key] = bytes;
    while (_memory.length > maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }

  static final _unsafeCharacters = RegExp(r'[^A-Za-z0-9._-]');

  static String cacheKey(CameraObject object) {
    final date = object.captureDate?.millisecondsSinceEpoch ?? 0;
    final name = object.filename.replaceAll(_unsafeCharacters, '_');
    return '${name}_${object.size}_$date';
  }
}
