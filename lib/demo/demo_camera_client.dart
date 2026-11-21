import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;

import '../data/exif.dart';
import '../ptp/ptp_constants.dart';
import '../ptpip/camera_client.dart';

/// A pretend camera whose card holds photos from this phone, with shots from
/// the phone's camera added as new shots. Deleting only takes a photo off the
/// card; the phone's file stays.
class DemoCameraClient implements CameraClient {
  DemoCameraClient._(this._photos) : _lastHandle = _photos.keys.fold(0, max);

  static const manufacturer = 'Shutterlink';
  static const model = 'Demo camera';
  static const storageId = 1;

  /// The width of an EOS thumbnail, so tiles load like a real card's.
  static const thumbnailWidth = 160;
  static const chunkSize = 512 * 1024;

  static Future<DemoCameraClient> open(List<File> photos) async {
    final entries = <int, (File, CameraObject)>{};
    for (final (index, file) in photos.indexed) {
      final handle = index + 1;
      entries[handle] = (file, await _object(handle, file));
    }
    return DemoCameraClient._(entries);
  }

  static Future<CameraObject> _object(int handle, File file) async {
    final stat = await file.stat();
    return CameraObject(
      handle: handle,
      storageId: storageId,
      filename: p.basename(file.path),
      size: stat.size,
      captureDate: exifCaptureDate(await _header(file)) ?? stat.modified,
      kind: CameraObjectKind.jpeg,
    );
  }

  static Future<Uint8List> _header(File file) async {
    final opened = await file.open();
    try {
      return await opened.read(exifReadCap);
    } finally {
      await opened.close();
    }
  }

  final Map<int, (File, CameraObject)> _photos;

  /// Handles are never reused, also not after a delete, as on a real card.
  int _lastHandle;
  final _disconnected = Completer<void>();
  final _added = StreamController<int>.broadcast();
  final _storageChanged = StreamController<void>.broadcast();

  @override
  CameraDeviceInfo get deviceInfo => const CameraDeviceInfo(
    manufacturer: manufacturer,
    model: model,
    deviceVersion: '',
    serialNumber: '',
    operationsSupported: [],
  );

  @override
  Future<void> get disconnected => _disconnected.future;

  @override
  Stream<int> get addedObjects => _added.stream;

  @override
  Stream<void> get storageChanged => _storageChanged.stream;

  @override
  Future<List<CameraObject>> listPhotos() async => [
    for (final (_, object) in _photos.values) object,
  ];

  @override
  Future<List<int>> newestFolderHandles() async => [..._photos.keys];

  @override
  Future<CameraObject?> objectInfo(int handle) async => _photos[handle]?.$2;

  @override
  Future<DateTime?> cameraTime() async => DateTime.now();

  /// Thumbnails are decoded from the photo, which turns them upright.
  @override
  bool get thumbnailsUpright => true;

  @override
  ReconnectPolicy? get reconnectPolicy => null;

  @override
  Future<Uint8List?> thumbnail(int handle, {CancelToken? cancelToken}) async {
    bool cancelled() => cancelToken?.isCancelled ?? false;
    final photo = _photos[handle];
    if (photo == null || cancelled()) return null;
    try {
      final bytes = await photo.$1.readAsBytes();
      if (cancelled()) return null;
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: thumbnailWidth,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      if (cancelled()) return null;
      return png?.buffer.asUint8List();
    } on Exception {
      return null;
    }
  }

  @override
  Future<void> download(
    CameraObject object,
    ChunkWriter write, {
    int offset = 0,
    int? length,
    TransferProgress? onProgress,
    CancelToken? cancelToken,
    int? chunkSize,
  }) async {
    final photo = _photos[object.handle];
    if (photo == null) {
      throw const PtpResponseException(
        PtpOperation.getPartialObject,
        PtpResponseCode.invalidObjectHandle,
      );
    }
    final file = await photo.$1.open();
    try {
      await file.setPosition(offset);
      final end = length == null
          ? object.size
          : min(object.size, offset + length);
      var received = offset;
      while (received < end) {
        if (cancelToken?.isCancelled ?? false) {
          throw const TransferCancelledException();
        }
        final chunk = await file.read(
          min(DemoCameraClient.chunkSize, end - received),
        );
        if (chunk.isEmpty) {
          throw FileSystemException('The photo ended early', photo.$1.path);
        }
        await write(chunk);
        received += chunk.length;
        onProgress?.call(received, object.size);
      }
    } finally {
      await file.close();
    }
  }

  /// Puts [shot] on the card and reports it the way a camera reports a new
  /// shot.
  Future<void> addShot(File shot) async {
    final handle = ++_lastHandle;
    final object = await _object(handle, shot);
    if (_disconnected.isCompleted) return;
    _photos[handle] = (shot, object);
    _added.add(handle);
  }

  @override
  bool get canDelete => true;

  @override
  Future<void> delete(int handle) async {
    if (_photos.remove(handle) != null && !_storageChanged.isClosed) {
      _storageChanged.add(null);
    }
  }

  @override
  Future<void> close() async {
    if (!_disconnected.isCompleted) _disconnected.complete();
    await _added.close();
    await _storageChanged.close();
  }
}
