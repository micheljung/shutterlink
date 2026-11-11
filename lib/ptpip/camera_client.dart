import 'dart:typed_data';

import 'package:equatable/equatable.dart';

class CameraIdentity extends Equatable {
  const CameraIdentity({required this.guid, required this.name});

  final Uint8List guid;
  final String name;

  @override
  List<Object?> get props => [guid, name];
}

class CameraDeviceInfo extends Equatable {
  const CameraDeviceInfo({
    required this.manufacturer,
    required this.model,
    required this.deviceVersion,
    required this.serialNumber,
    required this.operationsSupported,
  });

  final String manufacturer;
  final String model;
  final String deviceVersion;
  final String serialNumber;
  final List<int> operationsSupported;

  @override
  List<Object?> get props => [
    manufacturer,
    model,
    deviceVersion,
    serialNumber,
    operationsSupported,
  ];
}

enum CameraObjectKind { jpeg, raw }

class CameraObject extends Equatable {
  const CameraObject({
    required this.handle,
    required this.storageId,
    required this.filename,
    required this.size,
    required this.captureDate,
    required this.kind,
  });

  final int handle;
  final int storageId;
  final String filename;
  final int size;
  final DateTime? captureDate;
  final CameraObjectKind kind;

  @override
  List<Object?> get props => [
    handle,
    storageId,
    filename,
    size,
    captureDate,
    kind,
  ];
}

class PairingRequiredException implements Exception {
  const PairingRequiredException([this.reason]);

  final int? reason;

  @override
  String toString() => 'PairingRequiredException(reason: $reason)';
}

class CameraDisconnectedException implements Exception {
  const CameraDisconnectedException([this.cause]);

  final Object? cause;

  @override
  String toString() => 'CameraDisconnectedException($cause)';
}

class PtpResponseException implements Exception {
  const PtpResponseException(this.operation, this.responseCode);

  final int operation;
  final int responseCode;

  @override
  String toString() =>
      'PtpResponseException(op: 0x${operation.toRadixString(16)}, '
      'code: 0x${responseCode.toRadixString(16)})';
}

class TransferCancelledException implements Exception {
  const TransferCancelledException();
}

class CancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

typedef ChunkWriter = Future<void> Function(Uint8List chunk);
typedef TransferProgress = void Function(int received, int total);

abstract interface class CameraClient {
  CameraDeviceInfo get deviceInfo;

  Future<void> get disconnected;

  Future<List<CameraObject>> listPhotos();

  Future<Uint8List?> thumbnail(int handle);

  Future<void> download(
    CameraObject object,
    ChunkWriter write, {
    int offset = 0,
    TransferProgress? onProgress,
    CancelToken? cancelToken,
  });

  Future<void> close();
}
