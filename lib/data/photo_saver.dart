import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ptpip/camera_client.dart';

/// A file stored in the gallery. [uri] identifies it for a later delete when
/// the platform reports one.
class SavedMedia extends Equatable {
  const SavedMedia(this.kind, [this.uri]);

  final CameraObjectKind kind;
  final String? uri;

  @override
  List<Object?> get props => [kind, uri];
}

abstract interface class PhotoSaver {
  /// Saves fully downloaded files of one shot. With [deleteSources] the files
  /// are treated as temporary and removed afterwards.
  Future<List<SavedMedia>> save({
    File? jpeg,
    File? raw,
    bool deleteSources = true,
  });
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
  Future<List<SavedMedia>> save({
    File? jpeg,
    File? raw,
    bool deleteSources = true,
  }) async {
    try {
      switch (_platform) {
        case SaverPlatform.android:
          await _ensureGalleryAccess(toAlbum: true);
          return [
            if (jpeg != null) await _saveJpeg(jpeg, toAlbum: true),
            if (raw != null) await _invokeSaveRaw({'raw': raw.path}),
          ];
        case SaverPlatform.ios:
          if (raw == null) {
            return [if (jpeg != null) await _saveJpegWithAccess(jpeg)];
          }
          return await _saveRawIos(jpeg: jpeg, raw: raw);
        case SaverPlatform.other:
          return [
            if (jpeg != null) await _saveJpegWithAccess(jpeg),
            if (raw != null) await _copyToDocuments(raw),
          ];
      }
    } finally {
      if (deleteSources) {
        for (final file in [jpeg, raw]) {
          if (file != null && file.existsSync()) await file.delete();
        }
      }
    }
  }

  Future<List<SavedMedia>> _saveRawIos({File? jpeg, required File raw}) async {
    try {
      final saved = await _invokeSaveRaw({'raw': raw.path, 'jpeg': jpeg?.path});
      return [if (jpeg != null) SavedMedia(CameraObjectKind.jpeg), saved];
    } on Exception {
      return [
        if (jpeg != null) await _saveJpegWithAccess(jpeg),
        await _copyToDocuments(raw),
      ];
    }
  }

  Future<SavedMedia> _invokeSaveRaw(Map<String, Object?> arguments) async {
    final uri = await channel
        .invokeMethod<Object?>(saveRawMethod, arguments)
        .timeout(timeout);
    return SavedMedia(CameraObjectKind.raw, uri is String ? uri : null);
  }

  Future<void> _ensureGalleryAccess({required bool toAlbum}) async {
    if (!await Gal.hasAccess(toAlbum: toAlbum)) {
      await Gal.requestAccess(toAlbum: toAlbum);
    }
  }

  // iOS albums require full photo library access; add-only suffices without.
  Future<SavedMedia> _saveJpegWithAccess(File jpeg) async {
    await _ensureGalleryAccess(toAlbum: false);
    return _saveJpeg(jpeg, toAlbum: false);
  }

  Future<SavedMedia> _saveJpeg(File jpeg, {required bool toAlbum}) async {
    await Gal.putImage(
      jpeg.path,
      album: toAlbum ? album : null,
    ).timeout(timeout);
    return const SavedMedia(CameraObjectKind.jpeg);
  }

  Future<SavedMedia> _copyToDocuments(File file) async {
    final directory = await _documentsDirectory();
    final copy = await file.copy(_uniquePath(directory, p.basename(file.path)));
    return SavedMedia(CameraObjectKind.raw, copy.path);
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
