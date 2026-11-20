import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'bond_bridge.dart';
import 'canon_ble_protocol.dart';
import 'shutter_remote.dart';

/// A Canon camera paired as its Bluetooth remote. Keeps reconnecting after
/// a drop until [disconnect].
///
/// Connected means the camera takes buttons: the phone is bonded with it,
/// it took the remote's name, and it acknowledged a harmless button byte.
class CanonBleRemote implements ShutterRemote {
  CanonBleRemote(
    this._ble,
    this.camera, {
    required this.remoteName,
    this.firstConnectTimeout = defaultFirstConnectTimeout,
    this._bonds = const NoBondBridge(),
  });

  static const defaultFirstConnectTimeout = Duration(seconds: 20);

  /// A write the camera never answers would hold up every later click.
  static const writeTimeout = Duration(seconds: 5);

  /// How long the user has to confirm Android's pairing request.
  static const pairingTimeout = Duration(seconds: 60);

  /// While waiting for the bond it is also asked for, in case Android's
  /// broadcast does not arrive.
  static const bondPoll = Duration(seconds: 1);

  /// Android passes through "none" on its way to bonded; only a "none" that
  /// lasts is a declined pairing.
  static const declinedAfter = Duration(seconds: 2);

  /// Other remotes keep the button down this long for a click.
  static const clickHold = Duration(milliseconds: 150);

  /// A camera that is off or out of reach lets the attempt run to
  /// [_connectionTimeout]. One that refuses this phone ends it at once: the
  /// link is created, then the camera never answers. Android's private
  /// address changes between connections, and the camera keeps only the one
  /// it paired with. See docs/bluetooth-remote.md.
  static const refusalWindow = Duration(seconds: 2);
  static const refusalsBeforeGivingUp = 3;

  /// Refused, it keeps looking, slowly: pairing again on the camera makes
  /// it answer.
  static const refusedRetry = Duration(seconds: 30);

  static const _connectionTimeout = Duration(seconds: 10);
  static const _retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];

  final FlutterReactiveBle _ble;
  final BondBridge _bonds;
  final RemoteCamera camera;

  /// What the camera lists this phone as.
  final String remoteName;
  final Duration firstConnectTimeout;

  final _links = StreamController<RemoteLink>.broadcast();
  RemoteLink _link = RemoteLink.disconnected;
  StreamSubscription<ConnectionStateUpdate>? _connection;
  StreamSubscription<BondState>? _bondWatch;
  Timer? _retry;
  Timer? _firstTimeout;
  int _failures = 0;
  int _refusals = 0;
  bool _wanted = false;

  /// [_ensureBonded] is waiting on the bond itself.
  bool _bonding = false;

  /// Bumped per connection attempt, so a late answer to an old one is
  /// ignored.
  int _attempt = 0;
  DateTime? _attemptStarted;

  /// The link of this attempt came up, so its end is no refusal.
  bool _linked = false;
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
    _armFirstTimeout(firstConnectTimeout);
    _watchBond();
    _open();
    return first.future;
  }

  void _armFirstTimeout(Duration timeout) {
    _firstTimeout?.cancel();
    if (_firstConnect == null) return;
    _firstTimeout = Timer(timeout, () {
      _log('first connect timed out after $timeout');
      _failFirst(const RemoteException('The camera did not answer.'));
      unawaited(disconnect());
    });
  }

  /// One line per step, for `adb logcat | grep CanonBle` on real hardware.
  void _log(String message) =>
      debugPrint('[CanonBle ${camera.id} #$_attempt] $message');

  void _failFirst(RemoteException error) {
    if (_firstConnect != null) _log('first connect fails: ${error.message}');
    _firstTimeout?.cancel();
    final first = _firstConnect;
    _firstConnect = null;
    if (first == null || first.isCompleted) return;
    first.completeError(error);
    // Nobody may be listening any more.
    unawaited(first.future.then((_) {}, onError: (Object _) {}));
  }

  /// Android may start bonding by itself, e.g. when the camera lost the
  /// keys; buttons do nothing until the user confirms.
  void _watchBond() {
    unawaited(_bondWatch?.cancel());
    _bondWatch = _bonds.bondStates(camera.id).listen((state) {
      _log('bond event $state (link $_link, waiting $_bonding)');
      // [_ensureBonded] handles the bond it waits for.
      if (!_wanted || _bonding) return;
      switch (state) {
        case BondState.bonding:
          if (_link == RemoteLink.connected) _setLink(RemoteLink.pairing);
        case BondState.bonded:
          if (_link == RemoteLink.pairing && _connection != null && _linked) {
            // The bond came back on a live link. Keep it: this phone may
            // not get back in on a new one.
            unawaited(_takeButtons(_attempt));
          }
        case BondState.none:
          if (_link == RemoteLink.pairing) _dropped();
      }
    });
  }

  void _open() {
    _retry?.cancel();
    unawaited(_connection?.cancel());
    // Refused stays shown while it keeps looking.
    if (_link != RemoteLink.refused) _setLink(RemoteLink.connecting);
    final attempt = ++_attempt;
    _log('connecting');
    _attemptStarted = clock.now();
    _linked = false;
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
          onError: (Object error) {
            _log('attempt #$attempt failed: $error');
            if (attempt == _attempt) _dropped();
          },
        );
  }

  Future<void> _connectionChanged(
    ConnectionStateUpdate update,
    int attempt,
  ) async {
    _log(
      'attempt #$attempt: ${update.connectionState} ${update.failure ?? ''}',
    );
    if (attempt != _attempt) return;
    switch (update.connectionState) {
      case DeviceConnectionState.connected:
        _linked = true;
        try {
          await _ensureBonded(attempt);
        } on Exception {
          if (attempt == _attempt) _dropped();
          return;
        }
        await _takeButtons(attempt);
      case DeviceConnectionState.disconnected:
        _dropped();
      case DeviceConnectionState.connecting:
      case DeviceConnectionState.disconnecting:
        break;
    }
  }

  /// Names the remote and checks the camera takes buttons, then calls the
  /// link connected.
  Future<void> _takeButtons(int attempt) async {
    try {
      // The camera only takes commands from a remote that names itself on
      // each connect.
      await _writeTo(_identity, CanonBleProtocol.identify(remoteName));
      if (attempt != _attempt) return;
      // Buttons need the encrypted link; one that does nothing proves the
      // camera takes them.
      await _writeTo(_control, CanonBleProtocol.idle);
    } on Exception catch (e) {
      _log('attempt #$attempt: camera did not take the name or probe: $e');
      if (attempt == _attempt) _dropped();
      return;
    }
    if (attempt != _attempt || !_wanted) {
      _log('attempt #$attempt ready but outdated (wanted $_wanted)');
      return;
    }
    _failures = 0;
    _refusals = 0;
    _setLink(RemoteLink.connected);
    _firstTimeout?.cancel();
    final first = _firstConnect;
    _firstConnect = null;
    if (first != null && !first.isCompleted) first.complete();
  }

  /// Bonds with the camera unless already bonded, waiting for the user.
  Future<void> _ensureBonded(int attempt) async {
    final state = await _bonds.bondState(camera.id);
    _log('attempt #$attempt: bond $state');
    if (state == BondState.bonded || attempt != _attempt) return;
    _setLink(RemoteLink.pairing);
    _armFirstTimeout(pairingTimeout);
    _bonding = true;
    final (settled, abandon) = _awaitBond();
    try {
      if (state == BondState.none) await _bonds.createBond(camera.id);
      final result = await settled;
      _log('attempt #$attempt: pairing ended $result');
      if (result != BondState.bonded) {
        throw const RemoteException('The pairing was not confirmed.');
      }
    } on TimeoutException {
      throw const RemoteException('The pairing was not confirmed.');
    } on Exception {
      // createBond failed: nobody waits for the bond any more.
      abandon();
      rethrow;
    } finally {
      _bonding = false;
    }
  }

  /// Completes with bonded, or none once it lasted [declinedAfter]; fails
  /// after [pairingTimeout]. Listens to Android's broadcasts and also asks
  /// every [bondPoll].
  (Future<BondState>, void Function()) _awaitBond() {
    final done = Completer<BondState>();
    DateTime? noneSince;
    void seen(BondState state) {
      if (done.isCompleted) return;
      switch (state) {
        case BondState.bonded:
          done.complete(state);
        case BondState.bonding:
          noneSince = null;
        case BondState.none:
          final since = noneSince ??= clock.now();
          if (clock.now().difference(since) >= declinedAfter) {
            done.complete(state);
          }
      }
    }

    final events = _bonds.bondStates(camera.id).listen(seen);
    final poll = Timer.periodic(bondPoll, (_) async {
      seen(await _bonds.bondState(camera.id));
    });
    final timeout = Timer(pairingTimeout, () {
      if (!done.isCompleted) {
        done.completeError(TimeoutException('No pairing', pairingTimeout));
      }
    });
    void stop() {
      unawaited(events.cancel());
      poll.cancel();
      timeout.cancel();
    }

    final settled = done.future.whenComplete(stop);
    return (
      settled,
      () {
        stop();
        settled.ignore();
      },
    );
  }

  Future<void> _writeTo(QualifiedCharacteristic target, List<int> value) => _ble
      .writeCharacteristicWithResponse(target, value: value)
      .timeout(writeTimeout);

  void _dropped() {
    if (!_wanted) return;
    final started = _attemptStarted;
    final refused =
        !_linked &&
        started != null &&
        clock.now().difference(started) < refusalWindow;
    _refusals = refused ? _refusals + 1 : 0;
    _log('dropped (linked $_linked, refusals $_refusals)');
    unawaited(_connection?.cancel());
    _connection = null;
    _retry?.cancel();
    final Duration delay;
    if (_refusals >= refusalsBeforeGivingUp) {
      _setLink(RemoteLink.refused);
      _failFirst(
        const RemoteException('The camera no longer accepts this phone.'),
      );
      delay = refusedRetry;
    } else {
      if (_link != RemoteLink.refused) _setLink(RemoteLink.connecting);
      delay = _retryDelays[_failures.clamp(0, _retryDelays.length - 1)];
    }
    _failures++;
    _retry = Timer(delay, () {
      if (_wanted) _open();
    });
  }

  @override
  Future<void> disconnect() async {
    _log('disconnect');
    _wanted = false;
    _attempt++;
    _retry?.cancel();
    _failFirst(const RemoteException('Cancelled.'));
    unawaited(_bondWatch?.cancel());
    _bondWatch = null;
    unawaited(_connection?.cancel());
    _connection = null;
    _refusals = 0;
    _failures = 0;
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
      await _writeTo(_control, value);
    } on Exception catch (e) {
      throw RemoteException('The camera did not take the command.', e);
    }
  }

  void _setLink(RemoteLink link) {
    if (_link == link) return;
    _log('link $link');
    _link = link;
    _links.add(link);
  }
}
