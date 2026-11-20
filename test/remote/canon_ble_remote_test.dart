import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shutterlink/remote/bond_bridge.dart';
import 'package:shutterlink/remote/canon_ble_protocol.dart';
import 'package:shutterlink/remote/canon_ble_remote.dart';
import 'package:shutterlink/remote/shutter_remote.dart';

class _MockBle extends Mock implements FlutterReactiveBle {}

class _FakeCharacteristic extends Fake implements QualifiedCharacteristic {}

class _FakeBonds implements BondBridge {
  _FakeBonds(this.state);

  BondState state;
  final created = <String>[];
  final _changes = StreamController<BondState>.broadcast(sync: true);

  void change(BondState next) {
    state = next;
    _changes.add(next);
  }

  @override
  Future<BondState> bondState(String address) async => state;

  @override
  Future<void> createBond(String address) async {
    created.add(address);
    change(BondState.bonding);
  }

  @override
  Stream<BondState> bondStates(String address) => _changes.stream;
}

void main() {
  const camera = RemoteCamera(id: 'AA:BB', name: 'EOS R');
  late _MockBle ble;
  late List<StreamController<ConnectionStateUpdate>> connections;
  late List<(String, List<int>)> writes;

  setUpAll(() => registerFallbackValue(_FakeCharacteristic()));

  setUp(() {
    ble = _MockBle();
    connections = [];
    writes = [];
    when(
      () => ble.connectToDevice(
        id: any(named: 'id'),
        servicesWithCharacteristicsToDiscover: any(
          named: 'servicesWithCharacteristicsToDiscover',
        ),
        connectionTimeout: any(named: 'connectionTimeout'),
      ),
    ).thenAnswer((_) {
      final connection = StreamController<ConnectionStateUpdate>();
      connections.add(connection);
      return connection.stream;
    });
    when(
      () => ble.writeCharacteristicWithResponse(
        any(),
        value: any(named: 'value'),
      ),
    ).thenAnswer((invocation) async {
      final characteristic =
          invocation.positionalArguments.single as QualifiedCharacteristic;
      writes.add((
        characteristic.characteristicId.toString(),
        invocation.namedArguments[#value] as List<int>,
      ));
    });
  });

  ConnectionStateUpdate update(DeviceConnectionState state) =>
      ConnectionStateUpdate(
        deviceId: camera.id,
        connectionState: state,
        failure: null,
      );

  String short(String uuid) => Uuid.parse(uuid).toString();

  test('names itself on connect, then clicks the shutter', () {
    fakeAsync((async) {
      final remote = CanonBleRemote(ble, camera, remoteName: 'Shutterlink');
      var connected = false;
      remote.connect().then((_) => connected = true);
      async.flushMicrotasks();
      expect(remote.link, RemoteLink.connecting);
      connections.single.add(update(DeviceConnectionState.connected));
      async.flushMicrotasks();
      expect(connected, isTrue);
      expect(remote.link, RemoteLink.connected);
      expect(writes, hasLength(2));
      expect(writes.first.$1, short(CanonBleProtocol.identity));
      expect(writes.first.$2, CanonBleProtocol.identify('Shutterlink'));
      // A button byte that does nothing proves the camera takes buttons.
      expect(writes.last.$1, short(CanonBleProtocol.control));
      expect(writes.last.$2, CanonBleProtocol.idle);
      remote.shoot();
      async.elapse(CanonBleRemote.clickHold);
      expect(writes.skip(2).map((write) => write.$2), [
        CanonBleProtocol.shutterDown,
        CanonBleProtocol.shutterUp,
      ]);
    });
  });

  test('reconnects after a drop until disconnected', () {
    fakeAsync((async) {
      final remote = CanonBleRemote(ble, camera, remoteName: 'Shutterlink');
      remote.connect();
      async.flushMicrotasks();
      connections.single.add(update(DeviceConnectionState.connected));
      async.flushMicrotasks();
      connections.single.add(update(DeviceConnectionState.disconnected));
      async.flushMicrotasks();
      expect(remote.link, RemoteLink.connecting);
      async.elapse(const Duration(seconds: 1));
      expect(connections, hasLength(2));
      connections.last.add(update(DeviceConnectionState.connected));
      async.flushMicrotasks();
      expect(remote.link, RemoteLink.connected);
      remote.disconnect();
      async.flushMicrotasks();
      expect(remote.link, RemoteLink.disconnected);
      async.elapse(const Duration(minutes: 1));
      expect(connections, hasLength(2));
    });
  });

  test('a camera that never answers fails the first connect', () {
    fakeAsync((async) {
      final remote = CanonBleRemote(ble, camera, remoteName: 'Shutterlink');
      Object? error;
      remote.connect().catchError((Object e) => error = e);
      async.elapse(remote.firstConnectTimeout);
      expect(error, isA<RemoteException>());
      expect(remote.link, RemoteLink.disconnected);
    });
  });

  test('a click while disconnected throws', () async {
    final remote = CanonBleRemote(ble, camera, remoteName: 'Shutterlink');
    await expectLater(remote.shoot(), throwsA(isA<RemoteException>()));
  });

  group('pairing', () {
    test('waits for the bond before it is ready', () {
      fakeAsync((async) {
        final bonds = _FakeBonds(BondState.none);
        final remote = CanonBleRemote(
          ble,
          camera,
          remoteName: 'Shutterlink',
          bonds: bonds,
        );
        var connected = false;
        remote.connect().then((_) => connected = true);
        async.flushMicrotasks();
        connections.single.add(update(DeviceConnectionState.connected));
        async.flushMicrotasks();
        expect(remote.link, RemoteLink.pairing);
        expect(bonds.created, [camera.id]);
        expect(writes, isEmpty);
        // The user takes longer than a plain connect may.
        async.elapse(const Duration(seconds: 30));
        expect(remote.link, RemoteLink.pairing);
        bonds.change(BondState.bonded);
        async.flushMicrotasks();
        expect(remote.link, RemoteLink.connected);
        expect(connected, isTrue);
        expect(writes.map((write) => write.$2), [
          CanonBleProtocol.identify('Shutterlink'),
          CanonBleProtocol.idle,
        ]);
      });
    });

    test('an unconfirmed pairing gives up after the pairing timeout', () {
      fakeAsync((async) {
        final bonds = _FakeBonds(BondState.none);
        final remote = CanonBleRemote(
          ble,
          camera,
          remoteName: 'Shutterlink',
          bonds: bonds,
        );
        Object? error;
        remote.connect().catchError((Object e) => error = e);
        async.flushMicrotasks();
        connections.single.add(update(DeviceConnectionState.connected));
        async.flushMicrotasks();
        async.elapse(
          CanonBleRemote.pairingTimeout - const Duration(seconds: 1),
        );
        expect(error, isNull);
        expect(remote.link, RemoteLink.pairing);
        async.elapse(const Duration(seconds: 1));
        expect(error, isA<RemoteException>());
        expect(remote.link, RemoteLink.disconnected);
        expect(writes, isEmpty);
      });
    });

    test('a bond Android does not announce is found by asking', () {
      fakeAsync((async) {
        final bonds = _FakeBonds(BondState.none);
        final remote = CanonBleRemote(
          ble,
          camera,
          remoteName: 'Shutterlink',
          bonds: bonds,
        );
        remote.connect();
        async.flushMicrotasks();
        connections.single.add(update(DeviceConnectionState.connected));
        async.flushMicrotasks();
        expect(remote.link, RemoteLink.pairing);
        // Bonded without a broadcast.
        bonds.state = BondState.bonded;
        async.elapse(CanonBleRemote.bondPoll);
        expect(remote.link, RemoteLink.connected);
        remote.disconnect();
      });
    });

    test('a passing none on the way to bonded is no decline', () {
      fakeAsync((async) {
        final bonds = _FakeBonds(BondState.none);
        final remote = CanonBleRemote(
          ble,
          camera,
          remoteName: 'Shutterlink',
          bonds: bonds,
        );
        remote.connect();
        async.flushMicrotasks();
        connections.single.add(update(DeviceConnectionState.connected));
        async.flushMicrotasks();
        bonds.change(BondState.none);
        bonds.change(BondState.bonding);
        bonds.change(BondState.bonded);
        async.flushMicrotasks();
        expect(remote.link, RemoteLink.connected);
        expect(connections, hasLength(1));
        remote.disconnect();
      });
    });

    test('a declined pairing is no connection', () {
      fakeAsync((async) {
        final bonds = _FakeBonds(BondState.none);
        final remote = CanonBleRemote(
          ble,
          camera,
          remoteName: 'Shutterlink',
          bonds: bonds,
        );
        remote.connect().ignore();
        async.flushMicrotasks();
        connections.single.add(update(DeviceConnectionState.connected));
        async.flushMicrotasks();
        bonds.change(BondState.none);
        async.flushMicrotasks();
        // Android passes through none on its way to bonded.
        expect(remote.link, RemoteLink.pairing);
        async.elapse(CanonBleRemote.declinedAfter);
        expect(remote.link, RemoteLink.connecting);
        expect(writes, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(connections, hasLength(2));
        remote.disconnect();
      });
    });

    test('Android bonding again while connected shows pairing', () {
      fakeAsync((async) {
        final bonds = _FakeBonds(BondState.bonded);
        final remote = CanonBleRemote(
          ble,
          camera,
          remoteName: 'Shutterlink',
          bonds: bonds,
        );
        remote.connect();
        async.flushMicrotasks();
        connections.single.add(update(DeviceConnectionState.connected));
        async.flushMicrotasks();
        expect(remote.link, RemoteLink.connected);
        bonds.change(BondState.bonding);
        async.flushMicrotasks();
        expect(remote.link, RemoteLink.pairing);

        // Confirmed: the same link carries on, since a new one may be
        // refused.
        writes.clear();
        bonds.change(BondState.bonded);
        async.flushMicrotasks();
        expect(remote.link, RemoteLink.connected);
        expect(connections, hasLength(1));
        expect(writes.map((write) => write.$2), [
          CanonBleProtocol.identify('Shutterlink'),
          CanonBleProtocol.idle,
        ]);
        remote.disconnect();
      });
    });
  });

  group('a camera that refuses the phone', () {
    /// Lets time pass until the next connect attempt starts.
    void untilAttempt(FakeAsync async, int count) {
      while (connections.length < count) {
        async.elapse(const Duration(milliseconds: 100));
      }
    }

    void failAfter(FakeAsync async, Duration after) {
      async.elapse(after);
      connections.last.add(update(DeviceConnectionState.disconnected));
      async.flushMicrotasks();
    }

    const fast = Duration(milliseconds: 200);

    test('fails at once three times in a row: refused', () {
      fakeAsync((async) {
        final remote = CanonBleRemote(ble, camera, remoteName: 'Shutterlink');
        Object? error;
        remote.connect().catchError((Object e) => error = e);
        async.flushMicrotasks();
        failAfter(async, fast);
        untilAttempt(async, 2);
        failAfter(async, fast);
        expect(remote.link, RemoteLink.connecting);
        untilAttempt(async, 3);
        failAfter(async, fast);
        expect(remote.link, RemoteLink.refused);
        expect(error, isA<RemoteException>());

        // It keeps looking, slowly, and stays refused meanwhile.
        async.elapse(
          CanonBleRemote.refusedRetry - const Duration(milliseconds: 100),
        );
        expect(connections, hasLength(3));
        async.elapse(const Duration(milliseconds: 100));
        expect(connections, hasLength(4));
        expect(remote.link, RemoteLink.refused);

        // The camera paired again: it answers.
        connections.last.add(update(DeviceConnectionState.connected));
        async.flushMicrotasks();
        expect(remote.link, RemoteLink.connected);
        remote.disconnect();
      });
    });

    test('a camera that is off is not refusing', () {
      fakeAsync((async) {
        final remote = CanonBleRemote(ble, camera, remoteName: 'Shutterlink');
        remote.connect();
        async.flushMicrotasks();
        connections.single.add(update(DeviceConnectionState.connected));
        async.flushMicrotasks();
        // Switched off: each attempt runs until it times out.
        failAfter(async, const Duration(minutes: 1));
        for (var attempt = 2; attempt <= 6; attempt++) {
          untilAttempt(async, attempt);
          failAfter(async, const Duration(seconds: 10));
          expect(remote.link, isNot(RemoteLink.refused));
        }
        remote.disconnect();
      });
    });

    test('a working connection starts the count again', () {
      fakeAsync((async) {
        final remote = CanonBleRemote(ble, camera, remoteName: 'Shutterlink');
        remote.connect();
        async.flushMicrotasks();
        failAfter(async, fast);
        untilAttempt(async, 2);
        failAfter(async, fast);
        untilAttempt(async, 3);
        connections.last.add(update(DeviceConnectionState.connected));
        async.flushMicrotasks();
        expect(remote.link, RemoteLink.connected);
        failAfter(async, const Duration(minutes: 1));
        untilAttempt(async, 4);
        failAfter(async, fast);
        untilAttempt(async, 5);
        failAfter(async, fast);
        expect(remote.link, RemoteLink.connecting);
        remote.disconnect();
      });
    });
  });
}
