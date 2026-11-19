import 'dart:async';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'canon_ble_protocol.dart';
import 'shutter_remote.dart';

/// A Canon camera paired as its Bluetooth remote. Keeps reconnecting after
/// a drop until [disconnect].
class CanonBleRemote implements ShutterRemote {
  CanonBleRemote(
    this._ble,
    this.camera, {
    required this.remoteName,
    this.firstConnectTimeout = defaultFirstConnectTimeout,
  });

  static const defaultFirstConnectTimeout = Duration(seconds: 20);

  /// A write the camera never answers would hold up every later click.
  static const writeTimeout = Duration(seconds: 5);

  /// Other remotes keep the button down this long for a click.
  static const clickHold = Duration(milliseconds: 150);
  static const _connectionTimeout = Duration(seconds: 10);
  static const _retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];

  final FlutterReactiveBle _ble;
  final RemoteCamera camera;

  /// What the camera lists this phone as.
  final String remoteName;
  final Duration firstConnectTimeout;

  final _links = StreamController<RemoteLink>.broadcast();
  RemoteLink _link = RemoteLink.disconnected;
  StreamSubscription<ConnectionStateUpdate>? _connection;
  Timer? _retry;
  int _failures = 0;
  bool _wanted = false;

  /// Bumped per connection attempt, so a late answer to an old one is
  /// ignored.
  int _attempt = 0;
  Completer<void>? _firstConnect;

  /// Clicks go out one after another, so a down never overtakes an up.
  Future<void> _writes = Future.value();

  late final _control = QualifiedCharacteristic(
    serviceId: Uuid.parse(CanonBleProtocol.service),
    characteristicId: Uuid.parse(CanonBleProtocol.control),
    deviceId: camera.id,
  );

  late final _identity = QualifiedCharacteristic(
    serviceId: Uuid.parse(CanonBleProtocol.service),
    characteristicId: Uuid.parse(CanonBleProtocol.identity),
    deviceId: camera.id,
  );

  @override
  String get name => camera.name;

  @override
  RemoteLink get link => _link;

  @override
  Stream<RemoteLink> get links => _links.stream;

  @override
  Future<void> connect() {
    if (_link == RemoteLink.connected) return Future.value();
    final pending = _firstConnect;
    if (pending != null) return pending.future;
    _wanted = true;
    final first = _firstConnect = Completer<void>();
    _open();
    return first.future.timeout(
      firstConnectTimeout,
      onTimeout: () async {
        await disconnect();
        throw const RemoteException('The camera did not answer.');
      },
    );
  }

  void _open() {
    _retry?.cancel();
    unawaited(_connection?.cancel());
    _setLink(RemoteLink.connecting);
    final attempt = ++_attempt;
    _connection = _ble
        .connectToDevice(
          id: camera.id,
          servicesWithCharacteristicsToDiscover: {
            Uuid.parse(CanonBleProtocol.service): [
              Uuid.parse(CanonBleProtocol.identity),
              Uuid.parse(CanonBleProtocol.control),
            ],
          },
          connectionTimeout: _connectionTimeout,
        )
        .listen(
          (update) => _connectionChanged(update, attempt),
          onError: (Object _) {
            if (attempt == _attempt) _dropped();
          },
        );
  }

  Future<void> _connectionChanged(
    ConnectionStateUpdate update,
    int attempt,
  ) async {
    if (attempt != _attempt) return;
    switch (update.connectionState) {
      case DeviceConnectionState.connected:
        try {
          // The camera only takes commands from a remote that names itself
          // on each connect.
          await _ble
              .writeCharacteristicWithResponse(
                _identity,
                value: CanonBleProtocol.identify(remoteName),
              )
              .timeout(writeTimeout);
        } on Exception {
          if (attempt == _attempt) _dropped();
          return;
        }
        if (attempt != _attempt || !_wanted) return;
        _failures = 0;
        _setLink(RemoteLink.connected);
        final first = _firstConnect;
        _firstConnect = null;
        if (first != null && !first.isCompleted) first.complete();
      case DeviceConnectionState.disconnected:
        _dropped();
      case DeviceConnectionState.connecting:
      case DeviceConnectionState.disconnecting:
        break;
    }
  }

  void _dropped() {
    if (!_wanted) return;
    _setLink(RemoteLink.connecting);
    unawaited(_connection?.cancel());
    _connection = null;
    final delay = _retryDelays[_failures.clamp(0, _retryDelays.length - 1)];
    _failures++;
    _retry?.cancel();
    _retry = Timer(delay, () {
      if (_wanted) _open();
    });
  }

  @override
  Future<void> disconnect() async {
    _wanted = false;
    _attempt++;
    _retry?.cancel();
    final first = _firstConnect;
    _firstConnect = null;
    if (first != null && !first.isCompleted) {
      first.completeError(const RemoteException('Cancelled.'));
      // Nobody may be listening any more.
      unawaited(first.future.then((_) {}, onError: (Object _) {}));
    }
    unawaited(_connection?.cancel());
    _connection = null;
    _setLink(RemoteLink.disconnected);
  }

  @override
  Future<void> shoot() =>
      _click(CanonBleProtocol.shutterDown, CanonBleProtocol.shutterUp);

  @override
  Future<void> toggleRecording() =>
      _click(CanonBleProtocol.movieDown, CanonBleProtocol.movieUp);

  @override
  Future<void> wake() => _serial(() => _write(CanonBleProtocol.idle));

  Future<void> _click(List<int> down, List<int> up) => _serial(() async {
    await _write(down);
    await Future<void>.delayed(clickHold);
    await _write(up);
  });

  Future<void> _serial(Future<void> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _write(List<int> value) async {
    if (_link != RemoteLink.connected) {
      throw const RemoteException('The camera is not connected.');
    }
    try {
      await _ble
          .writeCharacteristicWithResponse(_control, value: value)
          .timeout(writeTimeout);
    } on Exception catch (e) {
      throw RemoteException('The camera did not take the command.', e);
    }
  }

  void _setLink(RemoteLink link) {
    if (_link == link) return;
    _link = link;
    _links.add(link);
  }
}
