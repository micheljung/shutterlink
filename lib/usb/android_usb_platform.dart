import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'usb_camera_platform.dart';
import 'usb_pipe.dart';

/// USB cameras through the Kotlin `UsbBridge`, as bulk pipes.
class AndroidUsbPlatform implements UsbCameraPlatform {
  /// [isForeground] decides whether a permission request waits for the
  /// user's answer; it defaults to the app lifecycle being resumed. An
  /// answer that takes longer than [permissionTimeout] counts as
  /// [UsbPermission.userActionNeeded].
  AndroidUsbPlatform({
    bool Function()? isForeground,
    Duration permissionTimeout = const Duration(seconds: 60),
  }) {
    watcher = AndroidUsbCameraWatcher._(
      this,
      isForeground ?? _lifecycleResumed,
      permissionTimeout,
    );
  }

  static const channel = MethodChannel('ch.micheljung.shutterlink/usb');
  static const events = EventChannel('ch.micheljung.shutterlink/usb/events');

  @override
  late final AndroidUsbCameraWatcher watcher;

  @override
  UsbSupport get support => UsbSupport.verified;

  StreamSubscription<Object?>? _events;
  AndroidUsbPipe? _pipe;

  @override
  Future<UsbCameraLink> open(UsbCameraRef device) async {
    _listen();
    // The bridge closes the previous session when it opens the next one.
    _pipe?._end();
    _pipe = null;
    final deviceName =
        watcher._current(device)?.platformId ?? device.platformId;
    final Map<String, Object?>? opened;
    try {
      opened = await channel.invokeMapMethod<String, Object?>('open', {
        'deviceName': deviceName,
      });
    } on PlatformException catch (e) {
      throw UsbTransferException('open failed: ${e.code} ${e.message}');
    }
    final pipe = AndroidUsbPipe._(
      this,
      deviceName,
      sessionId: opened!['sessionId']! as int,
      maxPacketSize: opened['maxPacketSize']! as int,
      maxTransfer: opened['maxTransfer']! as int,
    );
    _pipe = pipe;
    return BulkLink(pipe);
  }

  /// Stops listening to the bridge's events.
  Future<void> dispose() async {
    await _events?.cancel();
    _events = null;
  }

  /// Listens once, when first needed: the bridge holds `attached` events
  /// back until then, e.g. the one that cold-started the app.
  void _listen() {
    _events ??= events.receiveBroadcastStream().listen(_onEvent);
  }

  void _onEvent(Object? event) {
    final map = (event! as Map).cast<String, Object?>();
    switch (map['type']) {
      case 'attached':
        watcher._attach((map['device']! as Map).cast<String, Object?>());
      case 'detached':
        final deviceName = map['deviceName']! as String;
        if (_pipe?.deviceName == deviceName) _pipe?._end();
        watcher._detach(deviceName);
      case 'permission':
        watcher._permission(
          map['deviceName']! as String,
          granted: map['granted']! as bool,
        );
      case 'interrupt':
        _pipe?._interrupt(map['bytes']! as Uint8List);
    }
  }

  static bool _lifecycleResumed() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }
}

class AndroidUsbCameraWatcher implements UsbCameraWatcher {
  AndroidUsbCameraWatcher._(
    this._platform,
    this._isForeground,
    this._permissionTimeout,
  );

  final AndroidUsbPlatform _platform;
  final bool Function() _isForeground;
  final Duration _permissionTimeout;
  late final _attached = StreamController<UsbAttachment>.broadcast(
    onListen: _platform._listen,
  );
  late final _detached = StreamController<UsbCameraRef>.broadcast(
    onListen: _platform._listen,
  );
  final _owners = <String>{};

  /// Plugged-in cameras by platform id.
  final _devices = <String, UsbCameraRef>{};
  final _permitted = <String>{};
  final _pendingPermissions = <String, Completer<UsbPermission>>{};

  @override
  Stream<UsbAttachment> get attached => _attached.stream;

  @override
  Stream<UsbCameraRef> get detached => _detached.stream;

  @override
  void start(String owner) {
    final first = _owners.isEmpty;
    _owners.add(owner);
    if (!first) return;
    _platform._listen();
    unawaited(_enumerate());
  }

  @override
  void stop(String owner) => _owners.remove(owner);

  @override
  bool hasPermission(UsbCameraRef device) {
    final current = _current(device);
    return current != null && _permitted.contains(current.platformId);
  }

  @override
  Future<UsbPermission> requestPermission(UsbCameraRef device) async {
    final deviceName = _current(device)?.platformId ?? device.platformId;
    if (_permitted.contains(deviceName)) return UsbPermission.granted;
    _platform._listen();
    final waitForAnswer = _isForeground();
    final answer = waitForAnswer
        ? (_pendingPermissions[deviceName] ??= Completer<UsbPermission>())
        : null;
    final bool held;
    try {
      held =
          await AndroidUsbPlatform.channel.invokeMethod<bool>(
            'requestPermission',
            {'deviceName': deviceName},
          ) ??
          false;
    } on PlatformException {
      _pendingPermissions.remove(deviceName);
      return UsbPermission.denied;
    }
    if (held) {
      _permitted.add(deviceName);
      _pendingPermissions.remove(deviceName);
      return UsbPermission.granted;
    }
    if (answer == null) return UsbPermission.userActionNeeded;
    return answer.future.timeout(
      _permissionTimeout,
      onTimeout: () {
        if (identical(_pendingPermissions[deviceName], answer)) {
          _pendingPermissions.remove(deviceName);
        }
        return UsbPermission.userActionNeeded;
      },
    );
  }

  /// The plugged-in camera equal to [device], under its current platform id.
  UsbCameraRef? _current(UsbCameraRef device) =>
      _devices[device.platformId] ??
      _devices.values.where((d) => d == device).firstOrNull;

  Future<void> _enumerate() async {
    final List<Object?>? devices;
    try {
      devices = await AndroidUsbPlatform.channel.invokeListMethod<Object?>(
        'list',
      );
    } on PlatformException {
      return;
    }
    for (final device in devices ?? const <Object?>[]) {
      _attach((device! as Map).cast<String, Object?>(), enumerated: true);
    }
  }

  void _attach(Map<String, Object?> device, {bool enumerated = false}) {
    final deviceName = device['deviceName']! as String;
    if (device['hasPermission'] == true) _permitted.add(deviceName);
    if (_devices.containsKey(deviceName)) return;
    final vendorId = device['vendorId']! as int;
    final productId = device['productId']! as int;
    final ref = UsbCameraRef(
      platformId: deviceName,
      vendorId: vendorId,
      productId: productId,
      name: device['product'] as String? ?? 'USB camera',
      serial: device['serial'] as String?,
    );
    _devices[deviceName] = ref;
    _attached.add(UsbAttachment(ref, enumerated: enumerated));
  }

  void _detach(String deviceName) {
    _permitted.remove(deviceName);
    _pendingPermissions.remove(deviceName)?.complete(UsbPermission.denied);
    final ref = _devices.remove(deviceName);
    if (ref != null) _detached.add(ref);
  }

  void _permission(String deviceName, {required bool granted}) {
    if (granted) {
      _permitted.add(deviceName);
    } else {
      _permitted.remove(deviceName);
    }
    _pendingPermissions
        .remove(deviceName)
        ?.complete(granted ? UsbPermission.granted : UsbPermission.denied);
  }
}

/// The claimed PTP interface of the one open device. Once ended, it never
/// calls the bridge again, and the bridge refuses calls carrying an older
/// [sessionId], so a replaced pipe cannot reach the next session's device.
class AndroidUsbPipe implements UsbBulkPipe {
  AndroidUsbPipe._(
    this._platform,
    this.deviceName, {
    required this.sessionId,
    required this.maxPacketSize,
    required this.maxTransfer,
  });

  final AndroidUsbPlatform _platform;
  final String deviceName;
  final int sessionId;

  @override
  final int maxPacketSize;

  @override
  final int maxTransfer;

  final _interrupts = StreamController<Uint8List>.broadcast();
  final _detached = Completer<void>();

  MethodChannel get _channel => AndroidUsbPlatform.channel;

  @override
  Stream<Uint8List> get interrupt => _interrupts.stream;

  @override
  Future<void> get detached => _detached.future;

  @override
  Future<void> bulkOut(Uint8List bytes) =>
      _transfer('bulkOut', {'bytes': bytes});

  @override
  Future<UsbRead> bulkIn(int maxLength) async {
    if (_detached.isCompleted) return const UsbReadError(_ended);
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('bulkIn', {
        'sessionId': sessionId,
        'maxLength': maxLength,
      });
      final bytes = result!['bytes']! as Uint8List;
      return bytes.isEmpty ? const UsbZeroLength() : UsbData(bytes);
    } on PlatformException catch (e) {
      return UsbReadError(e);
    }
  }

  @override
  Future<void> clearHalt() => _transfer('clearHalt');

  @override
  Future<Uint8List> classRequest(
    int request, {
    required bool deviceToHost,
    int value = 0,
    int length = 0,
    Uint8List? data,
  }) async {
    final result = await _transfer('classRequest', {
      'request': request,
      'deviceToHost': deviceToHost,
      'value': value,
      'length': length,
      'data': data,
    });
    return (result! as Map)['bytes']! as Uint8List;
  }

  @override
  Future<void> drainIn() => _transfer('drainIn');

  @override
  Future<void> close() async {
    final current = identical(_platform._pipe, this);
    _end();
    if (!current) return;
    _platform._pipe = null;
    try {
      await _channel.invokeMethod<void>('close', {'sessionId': sessionId});
    } on PlatformException {
      // Already gone.
    }
  }

  static const _ended = UsbTransferException('USB pipe ended');

  Future<Object?> _transfer(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    if (_detached.isCompleted) throw _ended;
    try {
      return await _channel.invokeMethod<Object?>(method, {
        'sessionId': sessionId,
        ...arguments,
      });
    } on PlatformException catch (e) {
      throw UsbTransferException('$method failed: ${e.code} ${e.message}');
    }
  }

  void _interrupt(Uint8List bytes) {
    if (!_detached.isCompleted) _interrupts.add(bytes);
  }

  /// Marks the pipe unusable: unplugged, closed, or replaced by another open.
  void _end() {
    if (_detached.isCompleted) return;
    _detached.complete();
    unawaited(_interrupts.close());
  }
}
