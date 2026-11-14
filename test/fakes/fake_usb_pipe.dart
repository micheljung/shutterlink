import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:shutterlink/ptp/ptp_constants.dart';
import 'package:shutterlink/usb/usb_bulk_transport.dart';
import 'package:shutterlink/usb/usb_container.dart';
import 'package:shutterlink/usb/usb_pipe.dart';

import 'fake_ptp_device.dart';

/// A [FakePtpDevice] behind USB bulk endpoints. Each reply is one IN
/// transfer with the response container packed right behind the data, and
/// [bulkIn] returns as much of it as fits, so a read can end inside a
/// container and the next one can start inside a read.
class FakeUsbPipe implements UsbBulkPipe {
  FakeUsbPipe(
    this.device, {
    this.maxPacketSize = 512,
    this.maxTransfer = 128 * 1024,
    this.zlpOnExactMultiple = true,
    this.unplugAfterBytes,
    this.stallAfterBytes,
    Uint8List? staleInData,
    this.resetStalls = false,
    this.deviceStatusBusyPolls = 0,
    List<Uint8List> interruptEvents = const [],
    this.readDelay = Duration.zero,
    this.onlyZeroLengthReads = false,
  }) {
    if (staleInData != null) {
      _transfers.add(_Transfer(staleInData));
    }
    _interrupt = StreamController<Uint8List>(
      onListen: () => interruptEvents.forEach(_interrupt.add),
    );
  }

  final FakePtpDevice device;

  @override
  final int maxPacketSize;

  @override
  final int maxTransfer;

  /// Send a zero-length packet after a transfer whose last read ended
  /// exactly at the requested length on a packet boundary.
  final bool zlpOnExactMultiple;

  /// Unplug once this many IN bytes were delivered.
  final int? unplugAfterBytes;

  /// After this many IN bytes, [bulkIn] never completes until [close].
  final int? stallAfterBytes;

  /// Device Reset (0x66) stalls, so the host must Cancel (0x64) instead.
  final bool resetStalls;

  /// GetDeviceStatus answers Device Busy this many times before OK.
  int deviceStatusBusyPolls;

  /// Each [bulkIn] waits this long before answering.
  final Duration readDelay;

  /// Every [bulkIn] answers a zero-length packet and never the reply.
  final bool onlyZeroLengthReads;

  /// Pipe calls in order: 'clearHalt', 'class 0x66', 'drain', 'close'...
  final calls = <String>[];

  /// IN bytes delivered by [bulkIn] so far.
  int bytesDelivered = 0;

  final _transfers = Queue<_Transfer>();
  late final StreamController<Uint8List> _interrupt;
  final _detached = Completer<void>();
  Completer<void>? _dataArrived;
  bool _zeroLengthPending = false;
  bool _closed = false;

  bool get isClosed => _closed;

  /// Pushes one raw transfer on the interrupt endpoint.
  void sendInterrupt(Uint8List bytes) => _interrupt.add(bytes);

  /// Pulls the cable.
  void unplug() {
    if (!_detached.isCompleted) {
      _detached.complete();
    }
    _wake();
  }

  void _wake() {
    final arrived = _dataArrived;
    _dataArrived = null;
    if (arrived != null && !arrived.isCompleted) {
      arrived.complete();
    }
  }

  @override
  Stream<Uint8List> get interrupt => _interrupt.stream;

  @override
  Future<void> get detached => _detached.future;

  bool get _gone => _closed || _detached.isCompleted;

  @override
  Future<void> bulkOut(Uint8List bytes) async {
    if (_gone) {
      throw const UsbTransferException('bulk-out on a gone pipe');
    }
    final command = UsbContainerReader().add(bytes).single;
    device.receivedOpcodes.add(command.code);
    final reply = device.handle(command.code, command.params);
    final transfer = BytesBuilder(copy: false);
    final data = reply.data;
    final drop = reply.dropAfterBytes;
    if (data != null) {
      final container = UsbContainer(
        type: UsbContainerType.data,
        code: command.code,
        transactionId: command.transactionId,
        payload: data,
      ).encode();
      transfer.add(
        drop == null
            ? container
            : Uint8List.sublistView(
                container,
                0,
                usbContainerHeaderSize + min(drop, data.length),
              ),
      );
    }
    if (drop == null) {
      transfer.add(
        UsbContainer.withParams(
          UsbContainerType.response,
          reply.code,
          command.transactionId,
          reply.params,
        ).encode(),
      );
    }
    _transfers.add(_Transfer(transfer.takeBytes(), unplugAfter: drop != null));
    _wake();
  }

  @override
  Future<UsbRead> bulkIn(int maxLength) async {
    await Future<void>.delayed(readDelay);
    while (true) {
      if (_gone) {
        return const UsbReadError('pipe gone');
      }
      if (onlyZeroLengthReads) {
        return const UsbZeroLength();
      }
      if (_zeroLengthPending) {
        _zeroLengthPending = false;
        return const UsbZeroLength();
      }
      final unplugAt = unplugAfterBytes;
      if (unplugAt != null && bytesDelivered >= unplugAt) {
        unplug();
        continue;
      }
      final stall = stallAfterBytes;
      if (_transfers.isEmpty || stall != null && bytesDelivered >= stall) {
        await (_dataArrived = Completer<void>()).future;
        continue;
      }
      return _take(maxLength);
    }
  }

  UsbRead _take(int maxLength) {
    final transfer = _transfers.first;
    var length = min(maxLength, transfer.remaining);
    for (final limit in [stallAfterBytes, unplugAfterBytes]) {
      if (limit != null) {
        length = min(length, limit - bytesDelivered);
      }
    }
    final bytes = Uint8List.sublistView(
      transfer.bytes,
      transfer.offset,
      transfer.offset + length,
    );
    transfer.offset += length;
    bytesDelivered += length;
    if (transfer.remaining == 0) {
      _transfers.removeFirst();
      _zeroLengthPending =
          zlpOnExactMultiple &&
          length == maxLength &&
          transfer.bytes.length % maxPacketSize == 0;
      if (transfer.unplugAfter) {
        unplug();
      }
    }
    return UsbData(bytes);
  }

  @override
  Future<void> clearHalt() async {
    calls.add('clearHalt');
  }

  @override
  Future<Uint8List> classRequest(
    int request, {
    required bool deviceToHost,
    int value = 0,
    int length = 0,
    Uint8List? data,
  }) async {
    calls.add('class 0x${request.toRadixString(16)}');
    if (_gone) {
      throw const UsbTransferException('control request on a gone pipe');
    }
    switch (request) {
      case UsbStillImageRequest.deviceReset when resetStalls:
        throw const UsbTransferException('stall');
      case UsbStillImageRequest.getDeviceStatus:
        final busy = deviceStatusBusyPolls > 0;
        if (busy) {
          deviceStatusBusyPolls--;
        }
        return (ByteData(4)
              ..setUint16(0, 4, Endian.little)
              ..setUint16(
                2,
                busy ? PtpResponseCode.deviceBusy : PtpResponseCode.ok,
                Endian.little,
              ))
            .buffer
            .asUint8List();
      default:
        return Uint8List(0);
    }
  }

  @override
  Future<void> drainIn() async {
    calls.add('drain');
    _transfers.clear();
    _zeroLengthPending = false;
  }

  @override
  Future<void> close() async {
    calls.add('close');
    _closed = true;
    unplug();
    unawaited(_interrupt.close());
  }
}

class _Transfer {
  _Transfer(this.bytes, {this.unplugAfter = false});

  final Uint8List bytes;
  final bool unplugAfter;
  int offset = 0;

  int get remaining => bytes.length - offset;
}
