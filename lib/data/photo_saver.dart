import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

abstract interface class PhotoSaver {
  /// Saves fully downloaded files of one shot. Files are temporary and
  /// removed afterwards.
  Future<void> save({File? jpeg, File? raw});
}

enum SaverPlatform {
  android,
  ios,
  other;

  static SaverPlatform get current => Platform.isAndroid
      ? android
      : Platform.isIOS
      ? ios
      : other;
}

typedef DirectoryProvider = Future<Directory> Function();

class PlatformPhotoSaver implements PhotoSaver {
  PlatformPhotoSaver({
    SaverPlatform? platform,
    DirectoryProvider? documentsDirectory,
    this.timeout = defaultTimeout,
  }) : _platform = platform ?? SaverPlatform.current,
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory;

  static const album = 'Shutterlink';
  static const defaultTimeout = Duration(minutes: 2);
  static const channel = MethodChannel('ch.micheljung.shutterlink/photos');
  static const saveRawMethod = 'saveRaw';

  final SaverPlatform _platform;
  final DirectoryProvider _documentsDirectory;
  final Duration timeout;

  @override
  Future<void> save({File? jpeg, File? raw}) async {
    try {
      switch (_platform) {
        case SaverPlatform.android:
          await _ensureGalleryAccess(toAlbum: true);
          if (jpeg != null) await _saveJpeg(jpeg, toAlbum: true);
          if (raw != null) {
            await _invokeSaveRaw({'raw': raw.path});
          }
        case SaverPlatform.ios:
          if (raw == null) {
            if (jpeg != null) await _saveJpegWithAccess(jpeg);
          } else {
            await _saveRawIos(jpeg: jpeg, raw: raw);
          }
        case SaverPlatform.other:
          if (jpeg != null) await _saveJpegWithAccess(jpeg);
          if (raw != null) await _copyToDocuments(raw);
      }
    } finally {
      for (final file in [jpeg, raw]) {
        if (file != null && file.existsSync()) await file.delete();
      }
    }
  }

  Future<void> _saveRawIos({File? jpeg, required File raw}) async {
    try {
      await _invokeSaveRaw({'raw': raw.path, 'jpeg': jpeg?.path});
    } on Exception {
      if (jpeg != null) await _saveJpegWithAccess(jpeg);
      await _copyToDocuments(raw);
    }
  }

  Future<void> _invokeSaveRaw(Map<String, Object?> arguments) =>
      channel.invokeMethod<void>(saveRawMethod, arguments).timeout(timeout);

  Future<void> _ensureGalleryAccess({required bool toAlbum}) async {
    if (!await Gal.hasAccess(toAlbum: toAlbum)) {
      await Gal.requestAccess(toAlbum: toAlbum);
    }
  }

  // iOS albums require full photo library access; add-only suffices without.
  Future<void> _saveJpegWithAccess(File jpeg) async {
    await _ensureGalleryAccess(toAlbum: false);
    await _saveJpeg(jpeg, toAlbum: false);
  }

  Future<void> _saveJpeg(File jpeg, {required bool toAlbum}) =>
      Gal.putImage(jpeg.path, album: toAlbum ? album : null).timeout(timeout);

  Future<File> _copyToDocuments(File file) async {
    final directory = await _documentsDirectory();
    return file.copy(_uniquePath(directory, p.basename(file.path)));
  }

  static String _uniquePath(Directory directory, String name) {
    final stem = p.basenameWithoutExtension(name);
    final extension = p.extension(name);
    var candidate = p.join(directory.path, name);
    for (var suffix = 1; File(candidate).existsSync(); suffix++) {
      candidate = p.join(directory.path, '$stem-$suffix$extension');
    }
    return candidate;
  }
}
