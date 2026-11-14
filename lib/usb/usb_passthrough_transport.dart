import 'dart:async';
import 'dart:typed_data';

import '../ptp/camera_client.dart';
import '../ptp/ptp_constants.dart';
import '../ptp/ptp_protocol_exception.dart';
import '../ptp/ptp_transport.dart';
import 'usb_container.dart';
import 'usb_pipe.dart';

/// The platform reports no progress while a transaction runs, so a large
/// GetPartialObject must not trip the session's default timeout.
const usbPassthroughMinimumResponseTimeout = Duration(seconds: 30);

/// PTP through a platform that runs whole transactions (iOS
/// ImageCaptureCore). The platform owns the PTP session, so OpenSession and
/// CloseSession are answered here. Buffers are accepted with or without
/// their container header, and the response is recognised by its container
/// type rather than by which buffer it came in.
class UsbPassthroughTransport implements PtpTransport {
  UsbPassthroughTransport(this._passthrough) {
    _eventSubscription = _passthrough.events.listen(_onEvent);
    _passthrough.detached.then(
      (_) => _shutDown(const UsbTransferException('USB device detached')),
    );
  }

  final UsbPassthrough _passthrough;
  late final StreamSubscription<Uint8List> _eventSubscription;
  final _events = StreamController<PtpEvent>.broadcast();
  final _disconnected = Completer<void>();
  Completer<PtpTransactionResult>? _current;
  Object? _cause;

  @override
  Stream<PtpEvent> get events => _events.stream;

  @override
  Future<void> get disconnected => _disconnected.future;

  @override
  bool get isConnected => !_disconnected.isCompleted;

  @override
  Object? get disconnectCause => _cause;

  /// No progress is reported; [minimumResponseTimeout] covers slow
  /// transfers instead.
  @override
  set onActivity(void Function()? callback) {}

  @override
  Duration? get minimumResponseTimeout => usbPassthroughMinimumResponseTimeout;

  @override
  Future<PtpTransactionResult> transact(
    int opcode,
    List<int> params,
    int transactionId,
  ) {
    if (!isConnected) {
      return Future.error(CameraDisconnectedException(_cause));
    }
    if (opcode == PtpOperation.openSession ||
        opcode == PtpOperation.closeSession) {
      return Future.value(
        PtpTransactionResult(
          code: PtpResponseCode.ok,
          params: const [],
          data: Uint8List(0),
        ),
      );
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
      final command = UsbContainer.withParams(
        UsbContainerType.command,
        opcode,
        transactionId,
        params,
      ).encode();
      final (:data, :response) = await _passthrough.send(command);
      if (!isConnected) {
        throw CameraDisconnectedException(_cause);
      }
      // Transactions are strictly serial, so a transaction ID the platform
      // rewrote is not checked.
      final inOrder = _container(response, UsbContainerType.response);
      final responseContainer =
          inOrder ?? _container(data, UsbContainerType.response);
      if (responseContainer == null) {
        throw PtpProtocolException(
          'No response container for opcode 0x${opcode.toRadixString(16)}',
        );
      }
      final dataIn = inOrder != null ? data : response;
      return PtpTransactionResult(
        code: responseContainer.code,
        params: responseContainer.params,
        data: _stripDataHeader(dataIn, opcode),
      );
    } on CameraDisconnectedException {
      rethrow;
    } on Object catch (error) {
      _shutDown(error);
      throw CameraDisconnectedException(_cause);
    }
  }

  void _onEvent(Uint8List bytes) {
    final event = _container(bytes, UsbContainerType.event);
    if (event != null) {
      _events.add(
        PtpEvent(
          code: event.code,
          transactionId: event.transactionId,
          params: event.params,
        ),
      );
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
    unawaited(_eventSubscription.cancel());
    unawaited(_events.close());
    unawaited(_passthrough.close());
  }

  /// [bytes] as one whole container of [type], or null if its header does
  /// not say so.
  static UsbContainer? _container(Uint8List bytes, UsbContainerType type) {
    if (bytes.length < usbContainerHeaderSize) {
      return null;
    }
    final header = ByteData.sublistView(bytes);
    if (header.getUint32(0, Endian.little) != bytes.length ||
        header.getUint16(4, Endian.little) != type.code) {
      return null;
    }
    return UsbContainer(
      type: type,
      code: header.getUint16(6, Endian.little),
      transactionId: header.getUint32(8, Endian.little),
      payload: Uint8List.sublistView(bytes, usbContainerHeaderSize),
    );
  }

  /// The data-in phase without its container header, if it carries one.
  static Uint8List _stripDataHeader(Uint8List data, int opcode) {
    final container = _container(data, UsbContainerType.data);
    return container != null && container.code == opcode
        ? container.payload
        : data;
  }
}
