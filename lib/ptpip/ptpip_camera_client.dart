import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import 'camera_client.dart';
import 'canon_eos.dart';
import 'canon_events.dart';
import 'connection.dart';
import 'dataset.dart';
import 'ptp_session.dart';

const _remoteModeExitTimeout = Duration(seconds: 1);
const _dcimFolderName = 'DCIM';
final _dcfFolderName = RegExp(r'^(\d{3})[0-9A-Z_]{5}$');

class PtpIpCameraClient implements CameraClient {
  PtpIpCameraClient._(
    this._connection,
    this._session,
    this.deviceInfo,
    this.ptpDeviceInfo,
    this._onEventData,
  );

  static const defaultEventPollInterval = Duration(seconds: 1);
  static const downloadChunkSize = 1024 * 1024;

  final PtpIpConnection _connection;
  final PtpSession _session;
  final void Function(Uint8List data)? _onEventData;
  Timer? _pollTimer;
  bool _pollInFlight = false;
  final _addedObjects = StreamController<int>.broadcast();

  /// Handles are only valid within this PTP session, like this client.
  final _objectInfoCache = <int, PtpObjectInfo>{};

  @override
  final CameraDeviceInfo deviceInfo;

  final PtpDeviceInfo ptpDeviceInfo;

  static Future<PtpIpCameraClient> connect({
    required String host,
    int port = ptpIpDefaultPort,
    required CameraIdentity identity,
    Duration timeout = ptpIpDefaultConnectTimeout,
    Duration pairingTimeout = ptpIpDefaultPairingTimeout,
    Duration responseTimeout = ptpDefaultResponseTimeout,
    Duration eventPollInterval = defaultEventPollInterval,
    PacketTap? packetTap,
    void Function(Uint8List data)? onEventData,
  }) async {
    final connection = await PtpIpConnection.open(
      host: host,
      port: port,
      identity: identity,
      timeout: timeout,
      pairingTimeout: pairingTimeout,
      tap: packetTap,
    );
    final session = PtpSession(connection, responseTimeout: responseTimeout);
    try {
      await session.openSession();
      final info = PtpDeviceInfo.parse(
        (await session.execute(PtpOperation.getDeviceInfo)).data,
      );
      final supported = info.operationsSupported.toSet();
      Future<void> runIfSupported(int opcode, [List<int> params = const []]) =>
          supported.contains(opcode)
          ? session.execute(opcode, params: params)
          : Future.value();
      await runIfSupported(CanonEosOperation.setRemoteMode, const [
        CanonEosMode.remoteModeOn,
      ]);
      await runIfSupported(CanonEosOperation.setEventMode, const [
        CanonEosMode.eventModeOn,
      ]);
      if (supported.contains(CanonEosOperation.getEvent)) {
        final initial = await session.execute(CanonEosOperation.getEvent);
        onEventData?.call(initial.data);
      }
      final client = PtpIpCameraClient._(
        connection,
        session,
        CameraDeviceInfo(
          manufacturer: info.manufacturer,
          model: info.model,
          deviceVersion: info.deviceVersion,
          serialNumber: info.serialNumber,
          operationsSupported: info.operationsSupported,
        ),
        info,
        onEventData,
      );
      if (supported.contains(CanonEosOperation.getEvent)) {
        client._startPolling(eventPollInterval);
      }
      connection.disconnected.then((_) => client._closeAddedObjects());
      return client;
    } catch (_) {
      connection.close();
      rethrow;
    }
  }

  @override
  Future<void> get disconnected => _connection.disconnected;

  /// Handles of objects the camera reports as new. Transfer requests count as
  /// well: without capture-to-PC the shot still lands on the card.
  @override
  Stream<int> get addedObjects => _addedObjects.stream;

  void _closeAddedObjects() {
    if (!_addedObjects.isClosed) {
      _addedObjects.close();
    }
  }

  void _startPolling(Duration interval) {
    _pollTimer = Timer.periodic(interval, (_) => _poll());
    _connection.disconnected.then((_) => _pollTimer?.cancel());
  }

  Future<void> _poll() async {
    if (_pollInFlight) {
      return;
    }
    _pollInFlight = true;
    try {
      final result = await _session.execute(CanonEosOperation.getEvent);
      _onEventData?.call(result.data);
      for (final event in parseCanonEvents(result.data)) {
        switch (event) {
          case CanonObjectAdded(:final format)
              when format == PtpObjectFormat.association:
            break;
          case CanonObjectAdded(:final handle) ||
              CanonTransferRequested(:final handle):
            if (!_addedObjects.isClosed) _addedObjects.add(handle);
          case CanonObjectRemoved(:final handle):
            _objectInfoCache.remove(handle);
        }
      }
    } on PtpResponseException {
      return;
    } on CameraDisconnectedException {
      return;
    } on PtpIpProtocolException {
      return;
    } finally {
      _pollInFlight = false;
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
      final kind = _kindOf(info.objectFormat);
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
    final kind = _kindOf(info.objectFormat);
    return kind == null ? null : _toCameraObject(handle, info, kind);
  }

  @override
  Future<DateTime?> cameraTime() async {
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

  static CameraObjectKind? _kindOf(int format) => switch (format) {
    PtpObjectFormat.exifJpeg || PtpObjectFormat.jfif => CameraObjectKind.jpeg,
    PtpObjectFormat.canonCr3 => CameraObjectKind.raw,
    _ => null,
  };

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
  Future<void> download(
    CameraObject object,
    ChunkWriter write, {
    int offset = 0,
    TransferProgress? onProgress,
    CancelToken? cancelToken,
  }) async {
    final release = _session.holdLowPriority();
    try {
      var received = offset;
      while (received < object.size) {
        if (cancelToken?.isCancelled ?? false) {
          throw const TransferCancelledException();
        }
        final length = min(downloadChunkSize, object.size - received);
        final chunk = (await _session.execute(
          PtpOperation.getPartialObject,
          params: [object.handle, received, length],
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
  Future<void> close() async {
    _pollTimer?.cancel();
    _closeAddedObjects();
    if (!_connection.isConnected) {
      return;
    }
    if (ptpDeviceInfo.operationsSupported.contains(
      CanonEosOperation.setRemoteMode,
    )) {
      await _session
          .execute(
            CanonEosOperation.setRemoteMode,
            params: const [CanonEosMode.remoteModeOn],
          )
          .timeout(_remoteModeExitTimeout)
          .then<void>((_) {}, onError: (_) {});
    }
    _connection.close();
  }
}
