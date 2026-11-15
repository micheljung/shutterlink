import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import '../ptp/camera_client.dart';
import '../ptp/ptp_constants.dart';
import '../ptp/ptp_protocol_exception.dart';
import '../ptp/ptp_transport.dart';
import 'usb_container.dart';
import 'usb_pipe.dart';

/// PTP still-image class requests (USB Still Image Capture Device 1.0, 5.2).
abstract final class UsbStillImageRequest {
  static const cancel = 0x64;
  static const deviceReset = 0x66;
  static const getDeviceStatus = 0x67;
}

const _cancellationCode = 0x4001;
const _deviceStatusLength = 20;
const _deviceStatusTimeout = Duration(seconds: 2);
const _deviceStatusPollInterval = Duration(milliseconds: 50);

/// PTP over the bulk endpoints of a claimed USB interface. Reads have no
/// timeout of their own: the session's watchdog aborts, which closes the
/// pipe and fails the blocked read.
class UsbBulkTransport implements PtpTransport {
  UsbBulkTransport._(this._pipe) {
    _reader = UsbContainerReader(maxPacketSize: _pipe.maxPacketSize);
    _interruptReader = _newInterruptReader();
    _interrupts = _pipe.interrupt.listen(_onInterrupt);
    _pipe.detached.then(
      (_) => _shutDown(const UsbTransferException('USB device detached')),
    );
  }

  /// Runs the reset sequence, so no stale state from an earlier session
  /// reaches the first transaction: clear halt, Device Reset (Cancel if it
  /// stalls), GetDeviceStatus until OK, drain. Closes the pipe on failure.
  static Future<UsbBulkTransport> open(UsbBulkPipe pipe) async {
    try {
      await pipe.clearHalt();
      await _reset(pipe);
      await _awaitDeviceReady(pipe);
      await pipe.drainIn();
    } catch (error) {
      unawaited(pipe.close());
      throw error is CameraDisconnectedException
          ? error
          : CameraDisconnectedException(error);
    }
    return UsbBulkTransport._(pipe);
  }

  static Future<void> _reset(UsbBulkPipe pipe) async {
    try {
      await pipe.classRequest(
        UsbStillImageRequest.deviceReset,
        deviceToHost: false,
      );
    } on UsbTransferException {
      final cancel = ByteData(6)
        ..setUint16(0, _cancellationCode, Endian.little)
        ..setUint32(2, 0, Endian.little);
      await pipe.classRequest(
        UsbStillImageRequest.cancel,
        deviceToHost: false,
        length: cancel.lengthInBytes,
        data: cancel.buffer.asUint8List(),
      );
    }
  }

  static Future<void> _awaitDeviceReady(UsbBulkPipe pipe) async {
    final deadline = DateTime.now().add(_deviceStatusTimeout);
    Object? last;
    while (true) {
      try {
        final status = await pipe.classRequest(
          UsbStillImageRequest.getDeviceStatus,
          deviceToHost: true,
          length: _deviceStatusLength,
        );
        if (status.length < 4) {
          last = PtpProtocolException(
            'Device status of ${status.length} bytes',
          );
        } else {
          final code = ByteData.sublistView(status).getUint16(2, Endian.little);
          if (code == PtpResponseCode.ok) {
            return;
          }
          last = 'Device status 0x${code.toRadixString(16)}';
        }
      } on UsbTransferException catch (error) {
        last = error;
      }
      if (!DateTime.now().isBefore(deadline)) {
        throw CameraDisconnectedException(last);
      }
      await Future<void>.delayed(_deviceStatusPollInterval);
    }
  }

  final UsbBulkPipe _pipe;
  late final UsbContainerReader _reader;
  late UsbContainerReader _interruptReader;
  late final StreamSubscription<Uint8List> _interrupts;
  final _events = StreamController<PtpEvent>.broadcast();
  final _disconnected = Completer<void>();
  void Function()? _onActivity;
  Object? _cause;
  Completer<PtpTransactionResult>? _current;

  @override
  Stream<PtpEvent> get events => _events.stream;

  @override
  Future<void> get disconnected => _disconnected.future;

  @override
  bool get isConnected => !_disconnected.isCompleted;

  @override
  Object? get disconnectCause => _cause;

  @override
  set onActivity(void Function()? callback) => _onActivity = callback;

  @override
  Duration? get minimumResponseTimeout => null;

  @override
  Future<PtpTransactionResult> transact(
    int opcode,
    List<int> params,
    int transactionId,
  ) {
    if (!isConnected) {
      return Future.error(CameraDisconnectedException(_cause));
    }
    final completer = _current = Completer<PtpTransactionResult>();
    _exchange(opcode, params, transactionId).then(
      (result) {
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
    );
    return completer.future.whenComplete(() {
      if (identical(_current, completer)) {
        _current = null;
      }
    });
  }

  Future<PtpTransactionResult> _exchange(
    int opcode,
    List<int> params,
    int transactionId,
  ) async {
    try {
      await _pipe.bulkOut(
        UsbContainer.withParams(
          UsbContainerType.command,
          opcode,
          transactionId,
          params,
        ).encode(),
      );
      Uint8List? data;
      while (true) {
        final read = await _pipe.bulkIn(_pipe.maxTransfer);
        if (!isConnected) {
          throw CameraDisconnectedException(_cause);
        }
        final Uint8List bytes;
        switch (read) {
          case UsbData(bytes: final received):
            _onActivity?.call();
            bytes = received;
          case UsbZeroLength():
            bytes = Uint8List(0);
          case UsbReadError(:final cause):
            _shutDown(cause);
            throw CameraDisconnectedException(_cause);
        }
        for (final container in _reader.add(bytes)) {
          if (container.transactionId != transactionId) {
            log(
              'skipped ${container.type.name} container '
              '0x${container.code.toRadixString(16)} of transaction '
              '${container.transactionId} while waiting for $transactionId',
              name: 'shutterlink.camera',
            );
            continue;
          }
          switch (container.type) {
            case UsbContainerType.data:
              data = container.payload;
            case UsbContainerType.response:
              return PtpTransactionResult(
                code: container.code,
                params: container.params,
                data: data ?? Uint8List(0),
              );
            case UsbContainerType.command || UsbContainerType.event:
              throw PtpProtocolException(
                'Unexpected ${container.type.name} container',
              );
          }
        }
      }
    } on CameraDisconnectedException {
      rethrow;
    } on Object catch (error) {
      _shutDown(error);
      throw CameraDisconnectedException(_cause);
    }
  }

  /// The interrupt endpoint has its own, smaller packet size, so its
  /// transfers are not judged against the bulk one.
  static UsbContainerReader _newInterruptReader() =>
      UsbContainerReader(rejectShortTransfers: false);

  void _onInterrupt(Uint8List bytes) {
    try {
      for (final container in _interruptReader.add(bytes)) {
        if (container.type == UsbContainerType.event) {
          _events.add(
            PtpEvent(
              code: container.code,
              transactionId: container.transactionId,
              params: container.params,
            ),
          );
        }
      }
    } on PtpProtocolException {
      // A garbled event is dropped; the camera keeps its session.
      _interruptReader = _newInterruptReader();
    }
  }

  @override
  void abort(Object cause) => _shutDown(cause);

  @override
  void close() => _shutDown(null);

  void _shutDown(Object? cause) {
    if (_disconnected.isCompleted) {
      return;
    }
    _cause = cause;
    _disconnected.complete();
    final current = _current;
    if (current != null && !current.isCompleted) {
      current.completeError(CameraDisconnectedException(cause));
    }
    unawaited(_interrupts.cancel());
    unawaited(_events.close());
    unawaited(_pipe.close());
  }
}
