import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'camera_client.dart';
import 'canon_eos.dart';
import 'connection.dart';
import 'dataset.dart';
import 'ptp_session.dart';

const _remoteModeExitTimeout = Duration(seconds: 1);

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
      return client;
    } catch (_) {
      connection.close();
      rethrow;
    }
  }

  @override
  Future<void> get disconnected => _connection.disconnected;

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
    } on PtpResponseException {
      return;
    } on CameraDisconnectedException {
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
    return photos;
  }

  Future<void> _collect(
    int storage,
    int parent,
    List<CameraObject> photos,
    Set<int> visited,
  ) async {
    final handles = parseU32Array(
      (await _session.execute(
        PtpOperation.getObjectHandles,
        params: [storage, PtpHandle.anyFormat, parent],
      )).data,
    );
    for (final handle in handles) {
      if (!visited.add(handle)) {
        continue;
      }
      final info = PtpObjectInfo.parse(
        (await _session.execute(
          PtpOperation.getObjectInfo,
          params: [handle],
        )).data,
      );
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
