import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/probe/libusb_pipe.dart';
import 'package:shutterlink/probe/probe_args.dart';
import 'package:shutterlink/usb/usb_pipe.dart';

const _packetSize = 512;
const _maxTransfer = 1024;
const _nativeMicros = 7;
const _refused = (vendorId: 1, productId: 1);

const _zeroLength = 0;
const _unplugOnRead = 1;
const _blockingRead = 2;
const _blockFor = Duration(milliseconds: 300);

const _echoInterrupt = 0xF1;
const _detachNow = 0xF2;
const _stall = 0xF3;

void _noAbort() {}

/// Lives in the worker isolate; reports what it saw through its replies.
class _FakeBackend implements UsbBackend {
  late UsbEventSink _events;
  var _lastOut = Uint8List(0);
  var _halts = 0;
  var _drains = 0;

  @override
  Future<UsbBackendOpened> open(
    UsbDeviceId? device,
    UsbEventSink events,
  ) async {
    if (device == _refused) {
      throw const UsbBackendException('no access to the fake');
    }
    _events = events;
    return UsbBackendOpened(
      maxPacketSize: _packetSize,
      maxTransfer: _maxTransfer,
      description: 'fake ${device?.vendorId}',
      abort: _noAbort,
    );
  }

  @override
  void bulkOut(Uint8List bytes) {
    switch (bytes.first) {
      case _echoInterrupt:
        _events.interrupt(bytes);
      case _detachNow:
        _events.detached();
      case _stall:
        throw const UsbBackendException('stalled');
    }
    _lastOut = bytes;
  }

  @override
  ({Uint8List bytes, int? nativeMicros}) bulkIn(
    int maxLength, {
    required bool timing,
  }) {
    switch (maxLength) {
      case _zeroLength:
        return (bytes: Uint8List(0), nativeMicros: null);
      case _unplugOnRead:
        throw const UsbBackendException('gone', noDevice: true);
      case _blockingRead:
        sleep(_blockFor);
    }
    return (bytes: _lastOut, nativeMicros: timing ? _nativeMicros : null);
  }

  @override
  void clearHalt() => _halts++;

  @override
  Uint8List classRequest(
    int request, {
    required bool deviceToHost,
    required int value,
    required int length,
    Uint8List? data,
  }) => Uint8List.fromList([
    request,
    if (deviceToHost) value,
    if (deviceToHost) length,
    if (deviceToHost) _halts,
    if (deviceToHost) _drains,
    ...?data,
  ]);

  @override
  void drainIn() => _drains++;

  @override
  Future<void> close() async {}
}

Future<LibusbPipe> _open({UsbDeviceId? device}) =>
    LibusbPipe.open(device: device, backend: _FakeBackend.new);

void main() {
  late LibusbPipe pipe;

  setUp(() async => pipe = await _open(device: (vendorId: 4, productId: 2)));

  tearDown(() => pipe.close());

  test('open reports what the worker found', () {
    expect(pipe.maxPacketSize, _packetSize);
    expect(pipe.maxTransfer, _maxTransfer);
    expect(pipe.description, 'fake 4');
  });

  test('a refused open throws and leaves no worker behind', () async {
    await expectLater(
      _open(device: _refused),
      throwsA(
        isA<UsbTransferException>().having(
          (e) => e.message,
          'message',
          'no access to the fake',
        ),
      ),
    );
  });

  test('bulk transfers keep their bytes, sizes and timing', () async {
    await pipe.bulkOut(Uint8List.fromList([1, 2, 3]));
    final read = await pipe.bulkIn(_maxTransfer, timing: true);
    expect(read, isA<UsbData>());
    expect((read as UsbData).bytes, [1, 2, 3]);
    expect(read.nativeMicros, _nativeMicros);
    expect((await pipe.bulkIn(_maxTransfer) as UsbData).nativeMicros, isNull);
    expect(await pipe.bulkIn(_zeroLength), isA<UsbZeroLength>());
  });

  test('failures surface as exceptions without ending the pipe', () async {
    await expectLater(
      pipe.bulkOut(Uint8List.fromList([_stall])),
      throwsA(isA<UsbTransferException>()),
    );
    await pipe.bulkOut(Uint8List.fromList([4]));
    expect((await pipe.bulkIn(_maxTransfer) as UsbData).bytes, [4]);
  });

  test('class requests, clearHalt and drainIn reach the backend', () async {
    await pipe.clearHalt();
    await pipe.drainIn();
    await pipe.drainIn();
    expect(
      await pipe.classRequest(0x67, deviceToHost: true, value: 3, length: 4),
      [0x67, 3, 4, 1, 2],
    );
    expect(
      await pipe.classRequest(
        0x64,
        deviceToHost: false,
        data: Uint8List.fromList([9]),
      ),
      [0x64, 9],
    );
  });

  test('interrupts arrive on the stream', () async {
    final first = pipe.interrupt.first;
    await pipe.bulkOut(Uint8List.fromList([_echoInterrupt, 5]));
    expect(await first, [_echoInterrupt, 5]);
  });

  test('a blocked transfer does not stall this isolate', () async {
    await pipe.bulkOut(Uint8List.fromList([6]));
    final read = pipe.bulkIn(_blockingRead);
    final timer = Completer<void>();
    Timer(Duration.zero, timer.complete);
    final first = await Future.any([
      timer.future.then((_) => 'timer'),
      read.then((_) => 'read'),
    ]);
    expect(first, 'timer');
    expect(await read, isA<UsbData>());
  });

  test('an unplug ends the pipe and fails later calls', () async {
    expect(await pipe.bulkIn(_unplugOnRead), isA<UsbReadError>());
    await pipe.detached;
    expect(await pipe.bulkIn(_maxTransfer), isA<UsbReadError>());
    await expectLater(pipe.drainIn(), throwsA(isA<UsbTransferException>()));
  });

  test('a detach event ends the pipe and fails the call in flight', () async {
    await expectLater(
      pipe.bulkOut(Uint8List.fromList([_detachNow])),
      throwsA(isA<UsbTransferException>()),
    );
    await pipe.detached;
    await expectLater(
      pipe.bulkOut(Uint8List.fromList([1])),
      throwsA(isA<UsbTransferException>()),
    );
  });

  test('close ends the pipe; closing twice is harmless', () async {
    await pipe.close();
    await pipe.close();
    await pipe.detached;
    expect(await pipe.bulkIn(_maxTransfer), isA<UsbReadError>());
  });
}
