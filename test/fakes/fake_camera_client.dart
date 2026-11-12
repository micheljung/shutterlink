import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:shutterlink/data/photo_saver.dart';
import 'package:shutterlink/feature/gallery/thumbnail_cache.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

const fakeChunkSize = 4;

CameraObject cameraObject(
  int handle,
  String filename, {
  int size = 10,
  DateTime? captureDate,
  int storageId = 1,
}) => CameraObject(
  handle: handle,
  storageId: storageId,
  filename: filename,
  size: size,
  captureDate: captureDate,
  kind: filename.toUpperCase().endsWith('.CR3')
      ? CameraObjectKind.raw
      : CameraObjectKind.jpeg,
);

Uint8List contentFor(CameraObject object) => Uint8List.fromList(
  List.generate(object.size, (i) => (object.handle + i) % 256),
);

class FakeCameraClient implements CameraClient {
  FakeCameraClient(this.objects, {this.disconnectAfterChunks});

  final List<CameraObject> objects;
  final int? disconnectAfterChunks;
  final requestedOffsets = <int, List<int>>{};
  final thumbnailRequests = <int>[];
  final thumbnailTokens = <CancelToken?>[];
  final downloadTokens = <int, List<CancelToken?>>{};
  final contentOverrides = <int, Uint8List>{};
  Map<int, CameraObject?> objectInfoOverrides = {};
  final _disconnected = Completer<void>();
  Completer<void>? chunkGate;
  Completer<void>? objectInfoGate;
  int _chunksSent = 0;
  bool closed = false;

  @override
  CameraDeviceInfo get deviceInfo => const CameraDeviceInfo(
    manufacturer: 'Canon Inc.',
    model: 'Canon EOS R',
    deviceVersion: '1-0',
    serialNumber: '1',
    operationsSupported: [],
  );

  @override
  Future<void> get disconnected => _disconnected.future;

  void simulateDisconnect() {
    if (!_disconnected.isCompleted) _disconnected.complete();
  }

  @override
  Future<List<CameraObject>> listPhotos() async => objects;

  @override
  Future<CameraObject?> objectInfo(int handle) async {
    await objectInfoGate?.future;
    if (objectInfoOverrides.containsKey(handle)) {
      return objectInfoOverrides[handle];
    }
    return objects.firstWhereOrNull((object) => object.handle == handle);
  }

  @override
  Future<Uint8List?> thumbnail(int handle, {CancelToken? cancelToken}) async {
    thumbnailRequests.add(handle);
    thumbnailTokens.add(cancelToken);
    return Uint8List.fromList([handle]);
  }

  @override
  Future<void> download(
    CameraObject object,
    ChunkWriter write, {
    int offset = 0,
    TransferProgress? onProgress,
    CancelToken? cancelToken,
  }) async {
    requestedOffsets.putIfAbsent(object.handle, () => []).add(offset);
    downloadTokens.putIfAbsent(object.handle, () => []).add(cancelToken);
    final content = contentOverrides[object.handle] ?? contentFor(object);
    var position = offset;
    while (position < content.length) {
      if (cancelToken?.isCancelled ?? false) {
        throw const TransferCancelledException();
      }
      if (disconnectAfterChunks != null &&
          _chunksSent >= disconnectAfterChunks!) {
        simulateDisconnect();
        throw const CameraDisconnectedException();
      }
      final end = (position + fakeChunkSize).clamp(0, content.length);
      await write(Uint8List.sublistView(content, position, end));
      _chunksSent++;
      position = end;
      onProgress?.call(position, content.length);
      final gate = chunkGate;
      if (gate != null) await gate.future;
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    simulateDisconnect();
  }
}

class RecordingPhotoSaver implements PhotoSaver {
  final saved = <({String? jpeg, String? raw})>[];
  final savedBytes = <String, Uint8List>{};
  Set<String> failFor = {};

  @override
  Future<void> save({File? jpeg, File? raw}) async {
    for (final file in [jpeg, raw]) {
      if (file == null) continue;
      final name = file.uri.pathSegments.last;
      if (failFor.contains(name)) throw FileSystemException('fail', file.path);
      savedBytes[name] = await file.readAsBytes();
      await file.delete();
    }
    saved.add((
      jpeg: jpeg?.uri.pathSegments.last,
      raw: raw?.uri.pathSegments.last,
    ));
  }
}

class MemoryThumbnailCache implements ThumbnailCache {
  @override
  Directory get directory => Directory.systemTemp;

  @override
  int get maxMemoryEntries => ThumbnailCache.defaultMaxMemoryEntries;

  @override
  int get memoryEntryCount => 0;

  @override
  Uint8List? peek(CameraObject object) => null;

  @override
  Future<Uint8List?> get(CameraObject object, ThumbnailFetcher fetch) async {
    await fetch(object.handle);
    return null;
  }
}
