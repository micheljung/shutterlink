import 'dart:async';
import 'dart:developer';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:collection/collection.dart';

import 'camera_client.dart';
import 'camera_profile.dart';
import 'dataset.dart';
import 'profile_registry.dart';
import 'ptp_constants.dart';
import 'ptp_session.dart';
import 'ptp_transport.dart';

const ptpDownloadChunkSize = 1024 * 1024;
const _dcimFolderName = 'DCIM';
final _dcfFolderName = RegExp(r'^(\d{3})[0-9A-Z_]{5}$');

typedef PtpBootstrap = ({
  PtpSession session,
  PtpDeviceInfo info,
  ProfileConnection profile,
});

/// Standard PTP on any transport, with vendor behaviour from a profile.
class PtpCameraClient implements CameraClient {
  PtpCameraClient(
    this._transport,
    this._session,
    this.ptpDeviceInfo,
    this._profile,
  ) : deviceInfo = CameraDeviceInfo(
        manufacturer: ptpDeviceInfo.manufacturer,
        model: ptpDeviceInfo.model,
        deviceVersion: ptpDeviceInfo.deviceVersion,
        serialNumber: ptpDeviceInfo.serialNumber,
        operationsSupported: ptpDeviceInfo.operationsSupported,
      ) {
    _profile.events.listen(_onProfileEvent);
    _transport.disconnected.then((_) => _closeEvents());
  }

  final PtpTransport _transport;
  final PtpSession _session;
  final ProfileConnection _profile;
  final _addedObjects = StreamController<int>.broadcast();
  final _storageChanged = StreamController<void>.broadcast();

  /// Handles are only valid within this PTP session, like this client.
  final _objectInfoCache = <int, PtpObjectInfo>{};

  @override
  final CameraDeviceInfo deviceInfo;

  final PtpDeviceInfo ptpDeviceInfo;

  /// The id of the profile chosen for this camera.
  String get profileId => _profile.profileId;

  static Future<PtpCameraClient> open(
    PtpTransport transport, {
    ProfileRegistry registry = defaultProfileRegistry,
    Duration responseTimeout = ptpDefaultResponseTimeout,
    ProfileOptions options = const ProfileOptions(),
  }) async {
    final (:session, :info, :profile) = await bootstrap(
      transport,
      registry: registry,
      responseTimeout: responseTimeout,
      options: options,
    );
    return PtpCameraClient(transport, session, info, profile);
  }

  /// Opens the session, reads DeviceInfo and attaches the matching profile.
  /// Closes the transport if any step fails.
  static Future<PtpBootstrap> bootstrap(
    PtpTransport transport, {
    ProfileRegistry registry = defaultProfileRegistry,
    Duration responseTimeout = ptpDefaultResponseTimeout,
    ProfileOptions options = const ProfileOptions(),
  }) async {
    final session = PtpSession(transport, responseTimeout: responseTimeout);
    try {
      await session.openSession();
      final info = PtpDeviceInfo.parse(
        (await session.execute(PtpOperation.getDeviceInfo)).data,
      );
      final selected = registry.select(info);
      log(
        'camera connected: profile=${selected.id} '
        'manufacturer=${info.manufacturer} model=${info.model} '
        'vendorExt=0x${info.vendorExtensionId.toRadixString(16)}',
        name: 'shutterlink.camera',
      );
      final profile = await selected.attach(session, info, options);
      return (session: session, info: info, profile: profile);
    } catch (_) {
      transport.close();
      rethrow;
    }
  }

  @override
  Future<void> get disconnected => _transport.disconnected;

  /// Handles of objects the camera reports as new. Transfer requests count as
  /// well: without capture-to-PC the shot still lands on the card.
  @override
  Stream<int> get addedObjects => _addedObjects.stream;

  @override
  Stream<void> get storageChanged => _storageChanged.stream;

  void _closeEvents() {
    if (!_addedObjects.isClosed) {
      _addedObjects.close();
    }
    if (!_storageChanged.isClosed) {
      _storageChanged.close();
    }
  }

  void _onProfileEvent(ProfileEvent event) {
    switch (event) {
      case ObjectAdded(:final handle):
        if (!_addedObjects.isClosed) _addedObjects.add(handle);
      case ObjectRemoved(:final handle):
        _objectInfoCache.remove(handle);
      case StorageChanged():
        if (!_storageChanged.isClosed) _storageChanged.add(null);
    }
  }

  @override
  Future<List<CameraObject>> listPhotos() async {
    final storages = parseU32Array(
      (await _session.execute(PtpOperation.getStorageIds)).data,
    );
    final photos = <CameraObject>[];
    final visited = <int>{};
    for (final storage in storages) {
      await _collect(storage, PtpHandle.root, photos, visited);
    }
    _objectInfoCache.removeWhere((handle, _) => !visited.contains(handle));
    return photos;
  }

  @override
  Future<List<int>> newestFolderHandles() async {
    final storages = parseU32Array(
      (await _session.execute(PtpOperation.getStorageIds)).data,
    );
    final handles = <int>[];
    for (final storage in storages) {
      final dcim = (await _folders(
        storage,
        PtpHandle.root,
      )).firstWhereOrNull((folder) => folder.name == _dcimFolderName);
      if (dcim == null) {
        continue;
      }
      final newest = maxBy([
        for (final folder in await _folders(storage, dcim.handle))
          if (_dcfFolderName.firstMatch(folder.name) case final match?)
            (handle: folder.handle, number: int.parse(match[1]!)),
      ], (folder) => folder.number);
      if (newest != null) {
        handles.addAll(await _handlesIn(storage, newest.handle));
      }
    }
    return handles;
  }

  Future<List<int>> _handlesIn(int storage, int parent) async => parseU32Array(
    (await _session.execute(
      PtpOperation.getObjectHandles,
      params: [storage, PtpHandle.anyFormat, parent],
    )).data,
  );

  Future<List<({int handle, String name})>> _folders(
    int storage,
    int parent,
  ) async {
    final folders = <({int handle, String name})>[];
    for (final handle in await _handlesIn(storage, parent)) {
      final info = PtpObjectInfo.parse(
        (await _session.execute(
          PtpOperation.getObjectInfo,
          params: [handle],
        )).data,
      );
      if (info.objectFormat == PtpObjectFormat.association) {
        folders.add((handle: handle, name: info.filename));
      }
    }
    return folders;
  }

  Future<void> _collect(
    int storage,
    int parent,
    List<CameraObject> photos,
    Set<int> visited,
  ) async {
    for (final handle in await _handlesIn(storage, parent)) {
      if (!visited.add(handle)) {
        continue;
      }
      final info = _objectInfoCache[handle] ?? await _fetchObjectInfo(handle);
      if (info.objectFormat == PtpObjectFormat.association) {
        await _collect(storage, handle, photos, visited);
        continue;
      }
      final kind = _profile.kindOf(info.objectFormat);
      if (kind == null) {
        continue;
      }
      photos.add(_toCameraObject(handle, info, kind));
    }
  }

  /// A file still being written reports size 0, so it is not cached.
  Future<PtpObjectInfo> _fetchObjectInfo(int handle) async {
    final info = PtpObjectInfo.parse(
      (await _session.execute(
        PtpOperation.getObjectInfo,
        params: [handle],
      )).data,
    );
    if (info.compressedSize > 0 ||
        info.objectFormat == PtpObjectFormat.association) {
      _objectInfoCache[handle] = info;
    }
    return info;
  }

  static CameraObject _toCameraObject(
    int handle,
    PtpObjectInfo info,
    CameraObjectKind kind,
  ) => CameraObject(
    handle: handle,
    storageId: info.storageId,
    filename: info.filename,
    size: info.compressedSize,
    captureDate: parsePtpDateTime(info.captureDate),
    kind: kind,
  );

  @override
  Future<CameraObject?> objectInfo(int handle) async {
    final result = await _session.execute(
      PtpOperation.getObjectInfo,
      params: [handle],
      acceptedCodes: const {
        PtpResponseCode.ok,
        PtpResponseCode.invalidObjectHandle,
      },
    );
    if (result.code != PtpResponseCode.ok) {
      return null;
    }
    final info = PtpObjectInfo.parse(result.data);
    final kind = _profile.kindOf(info.objectFormat);
    return kind == null ? null : _toCameraObject(handle, info, kind);
  }

  /// The standard DateTime property, or else the profile's clock.
  @override
  Future<DateTime?> cameraTime() async =>
      await _ptpDateTime() ?? await _profile.fallbackCameraTime();

  Future<DateTime?> _ptpDateTime() async {
    if (!ptpDeviceInfo.operationsSupported.contains(
          PtpOperation.getDevicePropValue,
        ) ||
        !ptpDeviceInfo.devicePropertiesSupported.contains(
          PtpDeviceProperty.dateTime,
        )) {
      return null;
    }
    try {
      final result = await _session.execute(
        PtpOperation.getDevicePropValue,
        params: const [PtpDeviceProperty.dateTime],
      );
      return parsePtpDateTime(PtpDataReader(result.data).string());
    } on PtpResponseException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<Uint8List?> thumbnail(int handle, {CancelToken? cancelToken}) async {
    try {
      final result = await _session.executeLowPriority(
        PtpOperation.getThumb,
        params: [handle],
        cancelToken: cancelToken,
      );
      return result.data.isEmpty ? null : result.data;
    } on PtpResponseException {
      return null;
    }
  }

  @override
  bool get thumbnailsUpright => false;

  @override
  Future<void> download(
    CameraObject object,
    ChunkWriter write, {
    int offset = 0,
    int? length,
    TransferProgress? onProgress,
    CancelToken? cancelToken,
  }) async {
    final release = _session.holdLowPriority();
    try {
      final end = length == null
          ? object.size
          : min(object.size, offset + length);
      var received = offset;
      while (received < end) {
        if (cancelToken?.isCancelled ?? false) {
          throw const TransferCancelledException();
        }
        final chunk = (await _session.execute(
          PtpOperation.getPartialObject,
          params: [
            object.handle,
            received,
            min(ptpDownloadChunkSize, end - received),
          ],
        )).data;
        if (chunk.isEmpty) {
          throw PtpResponseException(
            PtpOperation.getPartialObject,
            PtpResponseCode.generalError,
          );
        }
        await write(chunk);
        received += chunk.length;
        onProgress?.call(received, object.size);
      }
    } finally {
      release();
    }
  }

  @override
  bool get canDelete =>
      ptpDeviceInfo.operationsSupported.contains(PtpOperation.deleteObject);

  @override
  Future<void> delete(int handle) async {
    final retry = _profile.deleteBusyRetry;
    PtpTransactionResult result;
    for (var attempt = 1; ; attempt++) {
      result = await _session.execute(
        PtpOperation.deleteObject,
        params: [handle, PtpHandle.anyFormat],
        acceptedCodes: const {
          PtpResponseCode.ok,
          PtpResponseCode.invalidObjectHandle,
          PtpResponseCode.deviceBusy,
          ..._deleteDeniedCodes,
        },
      );
      if (result.code != PtpResponseCode.deviceBusy) break;
      if (attempt >= retry.attempts) {
        throw PtpResponseException(PtpOperation.deleteObject, result.code);
      }
      await Future<void>.delayed(retry.delay);
    }
    _objectInfoCache.remove(handle);
    if (_deleteDeniedCodes.contains(result.code)) {
      throw DeleteDeniedException(result.code);
    }
  }

  static const _deleteDeniedCodes = {
    PtpResponseCode.objectWriteProtected,
    PtpResponseCode.storeReadOnly,
    PtpResponseCode.accessDenied,
  };

  @override
  Future<void> close() async {
    _closeEvents();
    await _profile.detach();
    _transport.close();
  }
}
