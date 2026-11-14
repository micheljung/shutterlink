import 'dart:typed_data';

/// One bulk-in transfer, as the platform bridge reports it.
sealed class UsbRead {
  const UsbRead();
}

/// A non-empty transfer: packets up to a short one, or up to the requested
/// length.
final class UsbData extends UsbRead {
  const UsbData(this.bytes);

  final Uint8List bytes;
}

/// A real zero-length packet, ending a transfer that filled whole packets.
final class UsbZeroLength extends UsbRead {
  const UsbZeroLength();
}

/// The pipe is closed, detached or failed; no more reads will succeed.
final class UsbReadError extends UsbRead {
  const UsbReadError(this.cause);

  final Object cause;
}

/// A bulk-out, control or drain request failed. A stalled control request
/// fails this way too, since the platform does not tell a stall apart.
class UsbTransferException implements Exception {
  const UsbTransferException(this.message);

  final String message;

  @override
  String toString() => 'UsbTransferException: $message';
}

/// The bulk and interrupt endpoints of one claimed PTP interface. The bridge
/// moves bytes and keeps no timeout of its own, except in [drainIn].
abstract interface class UsbBulkPipe {
  int get maxPacketSize;

  /// The most [bulkIn] is asked for: a multiple of [maxPacketSize] in
  /// 64-256 KiB, 16 KiB below Android API 28.
  int get maxTransfer;

  /// Throws [UsbTransferException] when the write fails.
  Future<void> bulkOut(Uint8List bytes);

  /// One whole transfer: reads packets until a short one arrives or
  /// [maxLength] is reached. Never times out and never throws; a closed,
  /// detached or failed pipe completes with [UsbReadError].
  Future<UsbRead> bulkIn(int maxLength);

  /// Raw interrupt-endpoint transfers.
  Stream<Uint8List> get interrupt;

  /// Completes when the device is unplugged or the pipe closes.
  Future<void> get detached;

  /// Clears a halt on both bulk endpoints.
  Future<void> clearHalt();

  /// A PTP still-image class request to the interface. Returns the bytes the
  /// device sent for a [deviceToHost] request, otherwise an empty list.
  /// Throws [UsbTransferException] when the request fails or stalls.
  Future<Uint8List> classRequest(
    int request, {
    required bool deviceToHost,
    int value = 0,
    int length = 0,
    Uint8List? data,
  });

  /// Reads with a short internal timeout until nothing arrives, and discards
  /// what it read. The only bounded read.
  Future<void> drainIn();

  /// Releases the interface; a pending [bulkIn] completes with
  /// [UsbReadError].
  Future<void> close();
}

/// A platform that runs whole PTP transactions itself (iOS ImageCaptureCore).
abstract interface class UsbPassthrough {
  /// Runs one transaction from a USB command container. [data] is the
  /// data-in phase and [response] the response; either may come with or
  /// without its 12-byte container header.
  Future<({Uint8List data, Uint8List response})> send(
    Uint8List commandContainer,
  );

  /// Raw event payloads the camera pushes.
  Stream<Uint8List> get events;

  Future<void> get detached;

  /// Closes the platform's session with the camera.
  Future<void> close();
}

/// An opened USB camera, as the platform can drive it.
sealed class UsbCameraLink {
  const UsbCameraLink();
}

final class BulkLink extends UsbCameraLink {
  const BulkLink(this.pipe);

  final UsbBulkPipe pipe;
}

final class PassthroughLink extends UsbCameraLink {
  const PassthroughLink(this.passthrough);

  final UsbPassthrough passthrough;
}
