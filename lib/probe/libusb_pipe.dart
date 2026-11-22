import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../usb/usb_pipe.dart';
import 'probe_args.dart';

const _libraryName = 'libusb-1.0.so.0';
const _usbfsRoot = '/dev/bus/usb';
const _busAddressDigits = 3;
const _hexRadix = 16;

const _stillImageClass = 6;
const _stillImageSubclass = 1;
const _ptpProtocol = 1;
const _endpointDirIn = 0x80;
const _transferTypeMask = 0x03;
const _transferTypeBulk = 2;
const _transferTypeInterrupt = 3;
const _maxPacketSizeMask = 0x7FF;
const _classOut = 0x21;
const _classIn = 0xA1;

const _defaultMaxTransfer = 128 * 1024;
const _controlTimeoutMs = 2000;
const _drainTimeoutMs = 50;

/// Bulk and interrupt waits have no timeout of their own; they wait in
/// slices of this length so that a close can stop them.
const _sliceTimeoutMs = 500;
const _interruptBufferSize = 1024;
const _stringBufferSize = 256;

abstract final class _LibusbError {
  static const success = 0;
  static const access = -3;
  static const noDevice = -4;
  static const busy = -6;
  static const timeout = -7;
}

/// A libusb call failed in the worker. [noDevice] marks an unplugged camera.
class UsbBackendException implements Exception {
  const UsbBackendException(this.message, {this.noDevice = false});

  final String message;
  final bool noDevice;

  @override
  String toString() => 'UsbBackendException: $message';
}

/// A device the backend opened and claimed.
class UsbBackendOpened {
  const UsbBackendOpened({
    required this.maxPacketSize,
    required this.maxTransfer,
    required this.description,
    required this.abort,
  });

  final int maxPacketSize;
  final int maxTransfer;
  final String description;

  /// Called on the pipe's isolate while the worker may be inside a
  /// transfer; makes every wait of the backend end soon.
  final void Function() abort;
}

/// Where a backend reports what arrives outside a request. It can be handed
/// on to further isolates.
final class UsbEventSink {
  const UsbEventSink._(this._port);

  final SendPort _port;

  void interrupt(Uint8List bytes) => _port.send(_Interrupt(bytes));

  void detached() => _port.send(const _Detached());
}

/// The blocking USB calls behind a [LibusbPipe]. It lives in the pipe's
/// worker isolate, which calls it one request at a time.
abstract interface class UsbBackend {
  Future<UsbBackendOpened> open(UsbDeviceId? device, UsbEventSink events);

  void bulkOut(Uint8List bytes);

  ({Uint8List bytes, int? nativeMicros}) bulkIn(
    int maxLength, {
    required bool timing,
  });

  void clearHalt();

  Uint8List classRequest(
    int request, {
    required bool deviceToHost,
    required int value,
    required int length,
    Uint8List? data,
  });

  void drainIn();

  Future<void> close();
}

typedef UsbBackendFactory = UsbBackend Function();

/// A [UsbBulkPipe] whose USB calls run in a worker isolate, so a blocked
/// transfer never stalls this isolate's timers, such as the session
/// watchdog. For the probe only; the app has its platform bridges.
class LibusbPipe implements UsbBulkPipe {
  LibusbPipe._() {
    _worker.future.ignore();
    _port.listen(_onMessage);
  }

  /// Opens [device], or the first still-image device. Throws
  /// [UsbTransferException] when none can be opened and claimed.
  static Future<LibusbPipe> open({
    UsbDeviceId? device,
    UsbBackendFactory backend = LibusbBackend.new,
  }) async {
    final pipe = LibusbPipe._();
    try {
      await Isolate.spawn(
        _serve,
        (pipe._port.sendPort, backend),
        onExit: pipe._port.sendPort,
        debugName: 'libusb',
      );
      final opened =
          await pipe._call((id) => _Open(id, device)) as UsbBackendOpened;
      pipe
        ..maxPacketSize = opened.maxPacketSize
        ..maxTransfer = opened.maxTransfer
        ..description = opened.description
        .._abort = opened.abort;
      return pipe;
    } catch (_) {
      pipe._end();
      pipe._port.close();
      rethrow;
    }
  }

  final _port = ReceivePort();
  final _worker = Completer<SendPort>();
  final _pending = <int, Completer<Object?>>{};
  final _interrupts = StreamController<Uint8List>.broadcast();
  final _detached = Completer<void>();
  var _nextId = 0;
  var _workerGone = false;
  Future<void>? _closing;
  void Function()? _abort;

  @override
  late final int maxPacketSize;

  @override
  late final int maxTransfer;

  /// The opened device, e.g. its vid:pid and bus address.
  late final String description;

  @override
  Stream<Uint8List> get interrupt => _interrupts.stream;

  @override
  Future<void> get detached => _detached.future;

  @override
  Future<void> bulkOut(Uint8List bytes) => _call((id) => _BulkOut(id, bytes));

  @override
  Future<UsbRead> bulkIn(int maxLength, {bool timing = false}) async {
    try {
      final read = await _call(
        (id) => _BulkIn(id, maxLength, timing: timing),
      ) as ({Uint8List bytes, int? nativeMicros});
      return read.bytes.isEmpty
          ? const UsbZeroLength()
          : UsbData(read.bytes, nativeMicros: read.nativeMicros);
    } on UsbTransferException catch (error) {
      return UsbReadError(error);
    }
  }

  @override
  Future<void> clearHalt() => _call(_ClearHalt.new);

  @override
  Future<Uint8List> classRequest(
    int request, {
    required bool deviceToHost,
    int value = 0,
    int length = 0,
    Uint8List? data,
  }) async => await _call(
    (id) => _ClassRequest(
      id,
      request,
      deviceToHost: deviceToHost,
      value: value,
      length: length,
      data: data,
    ),
  ) as Uint8List;

  @override
  Future<void> drainIn() => _call(_DrainIn.new);

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _end();
    if (!_workerGone && _worker.isCompleted) {
      try {
        await _send(_Close.new);
      } on UsbTransferException {
        // The worker died; nothing is left to release.
      }
    }
    _port.close();
  }

  static const _ended = UsbTransferException('USB pipe ended');

  Future<Object?> _call(_Request Function(int id) request) {
    if (_detached.isCompleted) {
      return Future.error(_ended);
    }
    return _send(request);
  }

  Future<Object?> _send(_Request Function(int id) request) async {
    final id = _nextId++;
    final reply = _pending[id] = Completer<Object?>();
    (await _worker.future).send(request(id));
    final value = await reply.future;
    if (value is _Failure) {
      if (value.noDevice) {
        _end();
      }
      throw UsbTransferException(value.message);
    }
    return value;
  }

  void _onMessage(Object? message) {
    switch (message) {
      case final SendPort worker:
        _worker.complete(worker);
      case (final int id, final Object? value):
        _pending.remove(id)?.complete(value);
      case _Interrupt(:final bytes):
        if (!_detached.isCompleted) {
          _interrupts.add(bytes);
        }
      case _Detached():
        _end();
      case null:
        _workerGone = true;
        if (!_worker.isCompleted) {
          _worker.completeError(
            const UsbTransferException('USB worker exited'),
          );
        }
        _end();
        _failPending(const _Failure('USB worker exited'));
    }
  }

  /// Marks the pipe unusable: unplugged, failed or closed. Pending calls
  /// fail at once; the worker finishes its current transfer on its own.
  void _end() {
    if (_detached.isCompleted) {
      return;
    }
    _detached.complete();
    _abort?.call();
    unawaited(_interrupts.close());
    _failPending(_Failure(_ended.message));
  }

  void _failPending(_Failure failure) {
    final pending = [..._pending.values];
    _pending.clear();
    for (final reply in pending) {
      reply.complete(failure);
    }
  }
}

sealed class _Request {
  const _Request(this.id);

  final int id;
}

final class _Open extends _Request {
  const _Open(super.id, this.device);

  final UsbDeviceId? device;
}

final class _BulkOut extends _Request {
  const _BulkOut(super.id, this.bytes);

  final Uint8List bytes;
}

final class _BulkIn extends _Request {
  const _BulkIn(super.id, this.maxLength, {required this.timing});

  final int maxLength;
  final bool timing;
}

final class _ClearHalt extends _Request {
  const _ClearHalt(super.id);
}

final class _ClassRequest extends _Request {
  const _ClassRequest(
    super.id,
    this.request, {
    required this.deviceToHost,
    required this.value,
    required this.length,
    this.data,
  });

  final int request;
  final bool deviceToHost;
  final int value;
  final int length;
  final Uint8List? data;
}

final class _DrainIn extends _Request {
  const _DrainIn(super.id);
}

final class _Close extends _Request {
  const _Close(super.id);
}

final class _Failure {
  const _Failure(this.message, {this.noDevice = false});

  final String message;
  final bool noDevice;
}

final class _Interrupt {
  const _Interrupt(this.bytes);

  final Uint8List bytes;
}

final class _Detached {
  const _Detached();
}

/// The worker isolate: runs each request on the backend and replies with
/// its result or a [_Failure].
void _serve((SendPort, UsbBackendFactory) setup) {
  final (pipe, create) = setup;
  final backend = create();
  final events = UsbEventSink._(pipe);
  final requests = ReceivePort();
  pipe.send(requests.sendPort);
  requests.listen((message) async {
    final request = message as _Request;
    Object? result;
    try {
      result = await _run(backend, request, events);
    } on UsbBackendException catch (error) {
      result = _Failure(error.message, noDevice: error.noDevice);
    } on Object catch (error) {
      result = _Failure('$error');
    }
    pipe.send((request.id, result));
    if (request is _Close || (request is _Open && result is _Failure)) {
      requests.close();
    }
  });
}

Future<Object?> _run(
  UsbBackend backend,
  _Request request,
  UsbEventSink events,
) async {
  switch (request) {
    case _Open(:final device):
      return backend.open(device, events);
    case _BulkOut(:final bytes):
      backend.bulkOut(bytes);
    case _BulkIn(:final maxLength, :final timing):
      return backend.bulkIn(maxLength, timing: timing);
    case _ClearHalt():
      backend.clearHalt();
    case _ClassRequest(
      :final request,
      :final deviceToHost,
      :final value,
      :final length,
      :final data,
    ):
      return backend.classRequest(
        request,
        deviceToHost: deviceToHost,
        value: value,
        length: length,
        data: data,
      );
    case _DrainIn():
      backend.drainIn();
    case _Close():
      await backend.close();
  }
  return null;
}

/// A still-image device as `--list-usb` shows it.
class UsbStillImageDevice {
  const UsbStillImageDevice({
    required this.id,
    required this.bus,
    required this.address,
    this.manufacturer,
    this.product,
    this.openError,
  });

  final UsbDeviceId id;
  final int bus;
  final int address;
  final String? manufacturer;
  final String? product;

  /// Why the device could not be opened to read its strings.
  final String? openError;

  String get node => _deviceNode(bus, address);

  @override
  String toString() => [
    '${formatUsbDeviceId(id)} bus $bus address $address ($node)',
    if (manufacturer != null || product != null)
      [manufacturer, product].nonNulls.join(' '),
    if (openError != null) 'open: $openError',
  ].join(', ');
}

/// Every still-image device libusb sees, without claiming any. Throws
/// [UsbTransferException] when libusb is missing or fails to start.
List<UsbStillImageDevice> listLibusbDevices() {
  final usb = _Libusb.load();
  final context = usb.initContext();
  try {
    return usb.withDevices(context, (devices) {
      final found = <UsbStillImageDevice>[];
      for (final device in devices) {
        final descriptor = usb.deviceDescriptor(device);
        if (descriptor == null || usb.ptpInterface(device) == null) {
          continue;
        }
        final bus = usb.busNumber(device);
        final address = usb.deviceAddress(device);
        String? manufacturer;
        String? product;
        String? openError;
        try {
          final handle = usb.openDevice(device, bus, address);
          try {
            manufacturer = usb.string(handle, descriptor.manufacturerIndex);
            product = usb.string(handle, descriptor.productIndex);
          } finally {
            usb.close(handle);
          }
        } on UsbBackendException catch (error) {
          openError = error.message;
        }
        found.add(
          UsbStillImageDevice(
            id: descriptor.id,
            bus: bus,
            address: address,
            manufacturer: manufacturer,
            product: product,
            openError: openError,
          ),
        );
      }
      return found;
    });
  } finally {
    usb.exit(context);
  }
}

String _deviceNode(int bus, int address) =>
    '$_usbfsRoot/${'$bus'.padLeft(_busAddressDigits, '0')}/'
    '${'$address'.padLeft(_busAddressDigits, '0')}';

/// [UsbBackend] over libusb's synchronous API.
class LibusbBackend implements UsbBackend {
  late final _Libusb _usb;
  Pointer<Void> _context = nullptr;
  Pointer<Void> _handle = nullptr;
  late final _PtpInterface _interface;
  late final int _maxTransfer;
  var _kernelDriverDetached = false;
  var _claimed = false;
  Pointer<Uint8> _buffer = nullptr;
  Pointer<Int> _transferred = nullptr;
  Pointer<Int32> _abortFlag = nullptr;
  ReceivePort? _interruptExit;

  @override
  Future<UsbBackendOpened> open(
    UsbDeviceId? device,
    UsbEventSink events,
  ) async {
    try {
      _usb = _Libusb.load();
      _context = _usb.initContext();
      final description = _usb.withDevices(_context, (devices) {
        final (selected, ptp) = _select(devices, device);
        final bus = _usb.busNumber(selected);
        final address = _usb.deviceAddress(selected);
        _handle = _usb.openDevice(selected, bus, address);
        _interface = ptp;
        final id = _usb.deviceDescriptor(selected)!.id;
        return '${formatUsbDeviceId(id)} on bus $bus address $address';
      });
      _claim();
      _maxTransfer =
          _defaultMaxTransfer - _defaultMaxTransfer % _interface.maxPacketSize;
      _buffer = calloc<Uint8>(_maxTransfer);
      _transferred = calloc<Int>();
      _abortFlag = calloc<Int32>();
      final interrupt = _interface.interrupt;
      if (interrupt != null) {
        final exit = _interruptExit = ReceivePort();
        await Isolate.spawn(
          _readInterrupts,
          (
            handle: _handle.address,
            endpoint: interrupt,
            abortFlag: _abortFlag.address,
            events: events,
          ),
          onExit: exit.sendPort,
          debugName: 'libusb interrupt',
        );
      }
      return UsbBackendOpened(
        maxPacketSize: _interface.maxPacketSize,
        maxTransfer: _maxTransfer,
        description: description,
        abort: _aborter(_abortFlag.address),
      );
    } catch (_) {
      await close();
      rethrow;
    }
  }

  /// Built outside any instance scope, so the closure captures nothing but
  /// the address and can be sent to the pipe's isolate.
  static void Function() _aborter(int flag) =>
      () => Pointer<Int32>.fromAddress(flag).value = 1;

  (Pointer<Void>, _PtpInterface) _select(
    List<Pointer<Void>> devices,
    UsbDeviceId? wanted,
  ) {
    for (final device in devices) {
      final id = _usb.deviceDescriptor(device)?.id;
      if (id == null || (wanted != null && id != wanted)) {
        continue;
      }
      final ptp = _usb.ptpInterface(device);
      if (ptp != null) {
        return (device, ptp);
      }
      if (wanted != null) {
        throw UsbBackendException(
          '${formatUsbDeviceId(wanted)} has no still-image interface',
        );
      }
    }
    throw UsbBackendException(
      wanted == null
          ? 'no USB still-image device found'
          : 'no USB device ${formatUsbDeviceId(wanted)} found',
    );
  }

  void _claim() {
    final number = _interface.number;
    if (_usb.kernelDriverActive(_handle, number) == 1) {
      _check(
        'detach the kernel driver',
        _usb.detachKernelDriver(_handle, number),
      );
      _kernelDriverDetached = true;
    }
    final code = _usb.claimInterface(_handle, number);
    if (code == _LibusbError.busy) {
      throw UsbBackendException(
        'interface $number is busy: another program (gphoto2, '
        'gvfs-gphoto2-volume-monitor) holds the camera',
      );
    }
    _check('claim interface $number', code);
    _claimed = true;
  }

  @override
  void bulkOut(Uint8List bytes) {
    var offset = 0;
    while (offset < bytes.length) {
      final length = min(_maxTransfer, bytes.length - offset);
      _buffer.asTypedList(length).setRange(0, length, bytes, offset);
      _bulk(_interface.bulkOut, length, null);
      offset += length;
    }
    // A transfer of whole packets ends with a zero-length packet.
    if (bytes.isNotEmpty && bytes.length % _interface.bulkOutPacketSize == 0) {
      _bulk(_interface.bulkOut, 0, null);
    }
  }

  @override
  ({Uint8List bytes, int? nativeMicros}) bulkIn(
    int maxLength, {
    required bool timing,
  }) {
    final packet = _interface.maxPacketSize;
    final limit = max(packet, maxLength - maxLength % packet);
    final result = Uint8List(limit);
    final clock = timing ? Stopwatch() : null;
    var offset = 0;
    while (offset < limit) {
      final requested = min(_maxTransfer, limit - offset);
      final read = _bulk(_interface.bulkIn, requested, clock);
      result.setRange(offset, offset + read, _buffer.asTypedList(read));
      offset += read;
      if (read < requested) {
        break;
      }
    }
    return (
      bytes: result.sublist(0, offset),
      nativeMicros: clock?.elapsedMicroseconds,
    );
  }

  /// One whole transfer through [_buffer]: [length] bytes or up to a short
  /// packet. A slice that times out has moved whole packets only, so the
  /// next slice carries on behind them.
  int _bulk(int endpoint, int length, Stopwatch? clock) {
    var done = 0;
    while (true) {
      _checkOpen();
      clock?.start();
      final code = _usb.bulkTransfer(
        _handle,
        endpoint,
        _buffer + done,
        length - done,
        _transferred,
        _sliceTimeoutMs,
      );
      clock?.stop();
      done += _transferred.value;
      if (code == _LibusbError.success) {
        return done;
      }
      if (code != _LibusbError.timeout) {
        throw _usb.failure('bulk transfer on ${_hex(endpoint)}', code);
      }
    }
  }

  @override
  void clearHalt() {
    for (final endpoint in [_interface.bulkIn, _interface.bulkOut]) {
      _checkOpen();
      _check(
        'clear halt on ${_hex(endpoint)}',
        _usb.clearHalt(_handle, endpoint),
      );
    }
  }

  @override
  Uint8List classRequest(
    int request, {
    required bool deviceToHost,
    required int value,
    required int length,
    Uint8List? data,
  }) {
    _checkOpen();
    final size = deviceToHost ? length : data?.length ?? 0;
    return using((arena) {
      final buffer = arena<Uint8>(max(size, 1));
      if (!deviceToHost && data != null) {
        buffer.asTypedList(size).setAll(0, data);
      }
      final transferred = _usb.controlTransfer(
        _handle,
        deviceToHost ? _classIn : _classOut,
        request,
        value,
        _interface.number,
        buffer,
        size,
        _controlTimeoutMs,
      );
      if (transferred < 0) {
        throw _usb.failure('class request ${_hex(request)}', transferred);
      }
      return deviceToHost
          ? Uint8List.fromList(buffer.asTypedList(transferred))
          : Uint8List(0);
    });
  }

  @override
  void drainIn() {
    while (true) {
      _checkOpen();
      final code = _usb.bulkTransfer(
        _handle,
        _interface.bulkIn,
        _buffer,
        _maxTransfer,
        _transferred,
        _drainTimeoutMs,
      );
      if (code == _LibusbError.noDevice) {
        throw _usb.failure('drain', code);
      }
      if (_transferred.value <= 0 ||
          (code != _LibusbError.success && code != _LibusbError.timeout)) {
        return;
      }
    }
  }

  @override
  Future<void> close() async {
    if (_abortFlag != nullptr) {
      _abortFlag.value = 1;
    }
    final interruptExit = _interruptExit;
    _interruptExit = null;
    if (interruptExit != null) {
      await interruptExit.first;
      interruptExit.close();
    }
    if (_handle != nullptr) {
      if (_claimed) {
        _usb.releaseInterface(_handle, _interface.number);
      }
      if (_kernelDriverDetached) {
        _usb.attachKernelDriver(_handle, _interface.number);
      }
      _usb.close(_handle);
      _handle = nullptr;
    }
    if (_context != nullptr) {
      _usb.exit(_context);
      _context = nullptr;
    }
    for (final pointer in [_buffer, _transferred, _abortFlag]) {
      if (pointer != nullptr) {
        calloc.free(pointer);
      }
    }
    _buffer = nullptr;
    _transferred = nullptr;
    _abortFlag = nullptr;
  }

  void _checkOpen() {
    if (_abortFlag.value != 0) {
      throw const UsbBackendException('USB pipe closed');
    }
  }

  void _check(String what, int code) {
    if (code < 0) {
      throw _usb.failure(what, code);
    }
  }
}

String _hex(int value) => '0x${value.toRadixString(_hexRadix)}';

typedef _InterruptSetup = ({
  int handle,
  ({int address, int packetSize}) endpoint,
  int abortFlag,
  UsbEventSink events,
});

/// The interrupt endpoint's own isolate, so event reads never wait behind a
/// bulk transfer. libusb allows transfers on one handle from many threads.
void _readInterrupts(_InterruptSetup setup) {
  final usb = _Libusb.load();
  final handle = Pointer<Void>.fromAddress(setup.handle);
  final abort = Pointer<Int32>.fromAddress(setup.abortFlag);
  final size = max(setup.endpoint.packetSize, _interruptBufferSize);
  final buffer = calloc<Uint8>(size);
  final transferred = calloc<Int>();
  try {
    while (abort.value == 0) {
      final code = usb.interruptTransfer(
        handle,
        setup.endpoint.address,
        buffer,
        size,
        transferred,
        _sliceTimeoutMs,
      );
      final count = transferred.value;
      if (count > 0 && abort.value == 0) {
        setup.events.interrupt(Uint8List.fromList(buffer.asTypedList(count)));
      }
      if (code == _LibusbError.noDevice) {
        setup.events.detached();
        return;
      }
      if (code != _LibusbError.success && code != _LibusbError.timeout) {
        return;
      }
    }
  } finally {
    calloc
      ..free(buffer)
      ..free(transferred);
  }
}

typedef _PtpInterface = ({
  int number,
  int bulkIn,
  int bulkOut,
  int maxPacketSize,
  int bulkOutPacketSize,
  ({int address, int packetSize})? interrupt,
});

typedef _DeviceSummary = ({
  UsbDeviceId id,
  int manufacturerIndex,
  int productIndex,
});

final class _DeviceDescriptor extends Struct {
  @Uint8()
  external int length;
  @Uint8()
  external int descriptorType;
  @Uint16()
  external int bcdUsb;
  @Uint8()
  external int deviceClass;
  @Uint8()
  external int deviceSubclass;
  @Uint8()
  external int deviceProtocol;
  @Uint8()
  external int maxPacketSize0;
  @Uint16()
  external int vendorId;
  @Uint16()
  external int productId;
  @Uint16()
  external int bcdDevice;
  @Uint8()
  external int manufacturerIndex;
  @Uint8()
  external int productIndex;
  @Uint8()
  external int serialNumberIndex;
  @Uint8()
  external int numConfigurations;
}

final class _ConfigDescriptor extends Struct {
  @Uint8()
  external int length;
  @Uint8()
  external int descriptorType;
  @Uint16()
  external int totalLength;
  @Uint8()
  external int numInterfaces;
  @Uint8()
  external int configurationValue;
  @Uint8()
  external int configurationIndex;
  @Uint8()
  external int attributes;
  @Uint8()
  external int maxPower;
  external Pointer<_Interface> interfaces;
  external Pointer<Uint8> extra;
  @Int()
  external int extraLength;
}

final class _Interface extends Struct {
  external Pointer<_InterfaceDescriptor> altsettings;
  @Int()
  external int numAltsettings;
}

final class _InterfaceDescriptor extends Struct {
  @Uint8()
  external int length;
  @Uint8()
  external int descriptorType;
  @Uint8()
  external int interfaceNumber;
  @Uint8()
  external int alternateSetting;
  @Uint8()
  external int numEndpoints;
  @Uint8()
  external int interfaceClass;
  @Uint8()
  external int interfaceSubclass;
  @Uint8()
  external int interfaceProtocol;
  @Uint8()
  external int interfaceIndex;
  external Pointer<_EndpointDescriptor> endpoints;
  external Pointer<Uint8> extra;
  @Int()
  external int extraLength;
}

final class _EndpointDescriptor extends Struct {
  @Uint8()
  external int length;
  @Uint8()
  external int descriptorType;
  @Uint8()
  external int address;
  @Uint8()
  external int attributes;
  @Uint16()
  external int maxPacketSize;
  @Uint8()
  external int interval;
  @Uint8()
  external int refresh;
  @Uint8()
  external int synchAddress;
  external Pointer<Uint8> extra;
  @Int()
  external int extraLength;
}

typedef _TransferNative = Int Function(
  Pointer<Void>,
  Uint8,
  Pointer<Uint8>,
  Int,
  Pointer<Int>,
  UnsignedInt,
);
typedef _Transfer = int Function(
  Pointer<Void>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Int>,
  int,
);

/// The libusb-1.0 calls the probe needs.
final class _Libusb {
  _Libusb._(this._library);

  /// Throws [UsbTransferException] when libusb-1.0 is not installed.
  factory _Libusb.load() {
    try {
      return _Libusb._(DynamicLibrary.open(_libraryName));
    } on ArgumentError catch (error) {
      throw UsbTransferException('$_libraryName is not available: $error');
    }
  }

  final DynamicLibrary _library;

  late final _init = _library
      .lookupFunction<
        Int Function(Pointer<Pointer<Void>>),
        int Function(Pointer<Pointer<Void>>)
      >('libusb_init');
  late final exit = _library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('libusb_exit');
  late final _getDeviceList = _library
      .lookupFunction<
        IntPtr Function(Pointer<Void>, Pointer<Pointer<Pointer<Void>>>),
        int Function(Pointer<Void>, Pointer<Pointer<Pointer<Void>>>)
      >('libusb_get_device_list');
  late final _freeDeviceList = _library
      .lookupFunction<
        Void Function(Pointer<Pointer<Void>>, Int),
        void Function(Pointer<Pointer<Void>>, int)
      >('libusb_free_device_list');
  late final _getDeviceDescriptor = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Pointer<_DeviceDescriptor>),
        int Function(Pointer<Void>, Pointer<_DeviceDescriptor>)
      >('libusb_get_device_descriptor');
  late final _getActiveConfigDescriptor = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Pointer<Pointer<_ConfigDescriptor>>),
        int Function(Pointer<Void>, Pointer<Pointer<_ConfigDescriptor>>)
      >('libusb_get_active_config_descriptor');
  late final _getConfigDescriptor = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Uint8, Pointer<Pointer<_ConfigDescriptor>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<_ConfigDescriptor>>)
      >('libusb_get_config_descriptor');
  late final _freeConfigDescriptor = _library
      .lookupFunction<
        Void Function(Pointer<_ConfigDescriptor>),
        void Function(Pointer<_ConfigDescriptor>)
      >('libusb_free_config_descriptor');
  late final busNumber = _library
      .lookupFunction<
        Uint8 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('libusb_get_bus_number');
  late final deviceAddress = _library
      .lookupFunction<
        Uint8 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('libusb_get_device_address');
  late final _open = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, Pointer<Pointer<Void>>)
      >('libusb_open');
  late final close = _library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('libusb_close');
  late final kernelDriverActive = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('libusb_kernel_driver_active');
  late final detachKernelDriver = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('libusb_detach_kernel_driver');
  late final attachKernelDriver = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('libusb_attach_kernel_driver');
  late final claimInterface = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('libusb_claim_interface');
  late final releaseInterface = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Int),
        int Function(Pointer<Void>, int)
      >('libusb_release_interface');
  late final bulkTransfer = _library.lookupFunction<_TransferNative, _Transfer>(
    'libusb_bulk_transfer',
  );
  late final interruptTransfer = _library
      .lookupFunction<_TransferNative, _Transfer>('libusb_interrupt_transfer');
  late final controlTransfer = _library
      .lookupFunction<
        Int Function(
          Pointer<Void>,
          Uint8,
          Uint8,
          Uint16,
          Uint16,
          Pointer<Uint8>,
          Uint16,
          UnsignedInt,
        ),
        int Function(
          Pointer<Void>,
          int,
          int,
          int,
          int,
          Pointer<Uint8>,
          int,
          int,
        )
      >('libusb_control_transfer');
  late final clearHalt = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Uint8),
        int Function(Pointer<Void>, int)
      >('libusb_clear_halt');
  late final _getStringDescriptorAscii = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Uint8, Pointer<Uint8>, Int),
        int Function(Pointer<Void>, int, Pointer<Uint8>, int)
      >('libusb_get_string_descriptor_ascii');
  late final _errorName = _library
      .lookupFunction<Pointer<Utf8> Function(Int), Pointer<Utf8> Function(int)>(
        'libusb_error_name',
      );
  late final _strerror = _library
      .lookupFunction<Pointer<Utf8> Function(Int), Pointer<Utf8> Function(int)>(
        'libusb_strerror',
      );

  String describe(int code) =>
      '${_errorName(code).toDartString()}: ${_strerror(code).toDartString()}';

  UsbBackendException failure(String what, int code) => UsbBackendException(
    '$what failed (${describe(code)})',
    noDevice: code == _LibusbError.noDevice,
  );

  Pointer<Void> initContext() {
    final context = calloc<Pointer<Void>>();
    try {
      final code = _init(context);
      if (code < 0) {
        throw UsbTransferException('libusb_init failed (${describe(code)})');
      }
      return context.value;
    } finally {
      calloc.free(context);
    }
  }

  T withDevices<T>(Pointer<Void> context, T Function(List<Pointer<Void>>) use) {
    final list = calloc<Pointer<Pointer<Void>>>();
    try {
      final count = _getDeviceList(context, list);
      if (count < 0) {
        throw UsbTransferException(
          'libusb_get_device_list failed (${describe(count)})',
        );
      }
      try {
        return use([for (var i = 0; i < count; i++) list.value[i]]);
      } finally {
        _freeDeviceList(list.value, 1);
      }
    } finally {
      calloc.free(list);
    }
  }

  _DeviceSummary? deviceDescriptor(Pointer<Void> device) {
    final descriptor = calloc<_DeviceDescriptor>();
    try {
      if (_getDeviceDescriptor(device, descriptor) < 0) {
        return null;
      }
      final ref = descriptor.ref;
      return (
        id: (vendorId: ref.vendorId, productId: ref.productId),
        manufacturerIndex: ref.manufacturerIndex,
        productIndex: ref.productIndex,
      );
    } finally {
      calloc.free(descriptor);
    }
  }

  /// The first still-image interface with a bulk-in and a bulk-out
  /// endpoint, read from sysfs without opening the device.
  _PtpInterface? ptpInterface(Pointer<Void> device) {
    final config = calloc<Pointer<_ConfigDescriptor>>();
    try {
      if (_getActiveConfigDescriptor(device, config) < 0 &&
          _getConfigDescriptor(device, 0, config) < 0) {
        return null;
      }
      try {
        return _findPtp(config.value.ref);
      } finally {
        _freeConfigDescriptor(config.value);
      }
    } finally {
      calloc.free(config);
    }
  }

  static _PtpInterface? _findPtp(_ConfigDescriptor config) {
    for (var i = 0; i < config.numInterfaces; i++) {
      final usbInterface = config.interfaces[i];
      if (usbInterface.numAltsettings == 0) {
        continue;
      }
      final setting = usbInterface.altsettings.ref;
      if (setting.interfaceClass != _stillImageClass ||
          setting.interfaceSubclass != _stillImageSubclass ||
          setting.interfaceProtocol != _ptpProtocol) {
        continue;
      }
      ({int address, int packetSize})? bulkIn;
      ({int address, int packetSize})? bulkOut;
      ({int address, int packetSize})? interrupt;
      for (var e = 0; e < setting.numEndpoints; e++) {
        final endpoint = setting.endpoints[e];
        final found = (
          address: endpoint.address,
          packetSize: endpoint.maxPacketSize & _maxPacketSizeMask,
        );
        final isIn = endpoint.address & _endpointDirIn != 0;
        switch (endpoint.attributes & _transferTypeMask) {
          case _transferTypeBulk when isIn:
            bulkIn ??= found;
          case _transferTypeBulk:
            bulkOut ??= found;
          case _transferTypeInterrupt when isIn:
            interrupt ??= found;
        }
      }
      if (bulkIn != null && bulkOut != null) {
        return (
          number: setting.interfaceNumber,
          bulkIn: bulkIn.address,
          bulkOut: bulkOut.address,
          maxPacketSize: bulkIn.packetSize,
          bulkOutPacketSize: bulkOut.packetSize,
          interrupt: interrupt,
        );
      }
    }
    return null;
  }

  /// Throws [UsbBackendException] naming the device node when it cannot be
  /// opened.
  Pointer<Void> openDevice(Pointer<Void> device, int bus, int address) {
    final handle = calloc<Pointer<Void>>();
    try {
      final code = _open(device, handle);
      if (code == _LibusbError.success) {
        return handle.value;
      }
      final node = _deviceNode(bus, address);
      final present = File(node).existsSync();
      if (code == _LibusbError.access ||
          (code == _LibusbError.noDevice && !present)) {
        final reason = present
            ? 'permission denied; add a udev rule or join the group '
                  'owning the node'
            : 'the device node is missing; mount /dev/bus/usb into this '
                  'machine';
        throw UsbBackendException(
          'no access to $node: $reason (${describe(code)})',
        );
      }
      throw failure('open $node', code);
    } finally {
      calloc.free(handle);
    }
  }

  String? string(Pointer<Void> handle, int index) {
    if (index == 0) {
      return null;
    }
    final buffer = calloc<Uint8>(_stringBufferSize);
    try {
      final length = _getStringDescriptorAscii(
        handle,
        index,
        buffer,
        _stringBufferSize,
      );
      return length < 0
          ? null
          : String.fromCharCodes(buffer.asTypedList(length));
    } finally {
      calloc.free(buffer);
    }
  }
}
