import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;

import '../ptp/ptp_constants.dart';
import '../ptpip/camera_client.dart';
import 'exif_date.dart';

/// A pretend camera whose card holds photos from this phone. Deleting only
/// takes a photo off the card; the phone's file stays.
class DemoCameraClient implements CameraClient {
  DemoCameraClient._(this._photos);

  static const manufacturer = 'Shutterlink';
  static const model = 'Demo camera';
  static const storageId = 1;

  /// The width of an EOS thumbnail, so tiles load like a real card's.
  static const thumbnailWidth = 160;
  static const chunkSize = 512 * 1024;

  static Future<DemoCameraClient> open(List<File> photos) async {
    final entries = <int, (File, CameraObject)>{};
    for (final (index, file) in photos.indexed) {
      final stat = await file.stat();
      final handle = index + 1;
      entries[handle] = (
        file,
        CameraObject(
          handle: handle,
          storageId: storageId,
          filename: p.basename(file.path),
          size: stat.size,
          captureDate: exifCaptureDate(await _header(file)) ?? stat.modified,
          kind: CameraObjectKind.jpeg,
        ),
      );
    }
    return DemoCameraClient._(entries);
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
    TransferProgress? onProgress,
    CancelToken? cancelToken,
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
      var received = offset;
      while (received < object.size) {
        if (cancelToken?.isCancelled ?? false) {
          throw const TransferCancelledException();
        }
        final chunk = await file.read(min(chunkSize, object.size - received));
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
