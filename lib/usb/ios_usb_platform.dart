import 'dart:async';

import 'package:flutter/services.dart';

import 'usb_camera_platform.dart';
import 'usb_pipe.dart';

/// USB cameras through the Swift `UsbCameraBridge` (ImageCaptureCore), as
/// whole PTP transactions. Experimental: not verified on hardware.
class IosUsbPlatform implements UsbCameraPlatform {
  IosUsbPlatform() {
    watcher = IosUsbCameraWatcher._(this);
  }

  static const channel = MethodChannel('ch.micheljung.shutterlink/usb');
  static const events = EventChannel('ch.micheljung.shutterlink/usb/events');

  @override
  late final IosUsbCameraWatcher watcher;

  /// Built without a device to try it on.
  @override
  bool get isExperimental => true;

  StreamSubscription<Object?>? _events;
  IosUsbPassthrough? _passthrough;

  @override
  Future<UsbCameraLink> open(UsbCameraRef device) async {
    _listen();
    // The bridge closes the previous session when it opens the next one.
    _passthrough?._end();
    _passthrough = null;
    final deviceName =
        watcher._current(device)?.platformId ?? device.platformId;
    try {
      await channel.invokeMethod<void>('open', {'deviceName': deviceName});
    } on PlatformException catch (e) {
      throw UsbTransferException('open failed: ${e.code} ${e.message}');
    }
    final passthrough = IosUsbPassthrough._(this, deviceName);
    _passthrough = passthrough;
    return PassthroughLink(passthrough);
  }

  /// Stops listening to the bridge's events.
  Future<void> dispose() async {
    await _events?.cancel();
    _events = null;
  }

  void _listen() {
    _events ??= events.receiveBroadcastStream().listen(_onEvent);
  }

  void _onEvent(Object? event) {
    final map = (event! as Map).cast<String, Object?>();
    switch (map['type']) {
      case 'attached':
        watcher._attach(
          (map['device']! as Map).cast<String, Object?>(),
          enumerated: map['enumerated'] == true,
        );
      case 'detached':
        final deviceName = map['deviceName']! as String;
        _endIfOpen(deviceName);
        watcher._detach(deviceName);
      case 'closed':
        _endIfOpen(map['deviceName']! as String);
      case 'interrupt':
        _passthrough?._event(map['bytes']! as Uint8List);
    }
  }

  void _endIfOpen(String deviceName) {
    if (_passthrough?.deviceName == deviceName) _passthrough?._end();
  }
}

/// Browses for cameras while an owner holds it. Control authorization is
/// app-wide on iOS and is asked for once, not per camera.
class IosUsbCameraWatcher implements UsbCameraWatcher {
  IosUsbCameraWatcher._(this._platform);

  final IosUsbPlatform _platform;
  late final _attached = StreamController<UsbAttachment>.broadcast(
    onListen: _platform._listen,
  );
  late final _detached = StreamController<UsbCameraRef>.broadcast(
    onListen: _platform._listen,
  );
  final _owners = <String>{};

  /// Plugged-in cameras by platform id.
  final _devices = <String, UsbCameraRef>{};
  bool _authorized = false;

  @override
  Stream<UsbAttachment> get attached => _attached.stream;

  @override
  Stream<UsbCameraRef> get detached => _detached.stream;

  /// The first owner starts the browser, which reports the cameras already
  /// plugged in as `attached` events marked `enumerated`.
  @override
  void start(String owner) {
    final first = _owners.isEmpty;
    _owners.add(owner);
    if (!first) return;
    _platform._listen();
    unawaited(_invoke('start'));
  }

  /// The last owner stops the browser. Unplugs go unreported while it is
  /// stopped, so every camera except the open one is forgotten, and the next
  /// start reports it again.
  @override
  void stop(String owner) {
    if (!_owners.remove(owner) || _owners.isNotEmpty) return;
    final open = _platform._passthrough?.deviceName;
    _devices.removeWhere((deviceName, _) => deviceName != open);
    unawaited(_invoke('stop'));
  }

  @override
  bool hasPermission(UsbCameraRef device) =>
      _authorized && _current(device) != null;

  /// Waits for the user's answer: iOS asks once per app, and later requests
  /// answer at once.
  @override
  Future<UsbPermission> requestPermission(UsbCameraRef device) async {
    if (_authorized) return UsbPermission.granted;
    try {
      _authorized =
          await IosUsbPlatform.channel.invokeMethod<bool>(
            'requestPermission',
          ) ??
          false;
    } on PlatformException {
      return UsbPermission.denied;
    }
    return _authorized ? UsbPermission.granted : UsbPermission.denied;
  }

  /// The plugged-in camera equal to [device], under its current platform id.
  UsbCameraRef? _current(UsbCameraRef device) =>
      _devices[device.platformId] ??
      _devices.values.where((d) => d == device).firstOrNull;

  Future<void> _invoke(String method) async {
    try {
      await IosUsbPlatform.channel.invokeMethod<void>(method);
    } on PlatformException {
      // Browsing is best effort; no camera is reported.
    }
  }

  void _attach(Map<String, Object?> device, {required bool enumerated}) {
    final deviceName = device['deviceName']! as String;
    if (device['hasPermission'] == true) _authorized = true;
    if (_devices.containsKey(deviceName)) return;
    final ref = UsbCameraRef(
      platformId: deviceName,
      vendorId: device['vendorId']! as int,
      productId: device['productId']! as int,
      name: device['product'] as String? ?? 'USB camera',
    );
    _devices[deviceName] = ref;
    _attached.add(UsbAttachment(ref, enumerated: enumerated));
  }

  void _detach(String deviceName) {
    final ref = _devices.remove(deviceName);
    if (ref != null) _detached.add(ref);
  }
}

/// The open ImageCaptureCore session of one camera.
class IosUsbPassthrough implements UsbPassthrough {
  IosUsbPassthrough._(this._platform, this.deviceName);

  final IosUsbPlatform _platform;
  final String deviceName;
  final _events = StreamController<Uint8List>.broadcast();
  final _detached = Completer<void>();

  @override
  Stream<Uint8List> get events => _events.stream;

  @override
  Future<void> get detached => _detached.future;

  @override
  Future<({Uint8List data, Uint8List response})> send(
    Uint8List commandContainer,
  ) async {
    if (_detached.isCompleted) {
      throw const UsbTransferException('send failed: session closed');
    }
    final Map<String, Object?>? result;
    try {
      result = await IosUsbPlatform.channel.invokeMapMethod<String, Object?>(
        'send',
        {'bytes': commandContainer},
      );
    } on PlatformException catch (e) {
      throw UsbTransferException('send failed: ${e.code} ${e.message}');
    }
    return (
      data: result!['data']! as Uint8List,
      response: result['response']! as Uint8List,
    );
  }

  @override
  Future<void> close() async {
    final current = identical(_platform._passthrough, this);
    _end();
    if (!current) return;
    _platform._passthrough = null;
    try {
      await IosUsbPlatform.channel.invokeMethod<void>('close');
    } on PlatformException {
      // Already gone.
    }
  }

  void _event(Uint8List bytes) {
    if (!_detached.isCompleted) _events.add(bytes);
  }

  /// Marks the session unusable: unplugged, closed, or replaced by another
  /// open.
  void _end() {
    if (_detached.isCompleted) return;
    _detached.complete();
    unawaited(_events.close());
  }
}
