import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shutterlink/remote/canon_ble_protocol.dart';
import 'package:shutterlink/remote/canon_ble_remote.dart';
import 'package:shutterlink/remote/shutter_remote.dart';

class _MockBle extends Mock implements FlutterReactiveBle {}

class _FakeCharacteristic extends Fake implements QualifiedCharacteristic {}

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
      expect(writes.single.$1, short(CanonBleProtocol.identity));
      expect(writes.single.$2, CanonBleProtocol.identify('Shutterlink'));
      remote.shoot();
      async.elapse(CanonBleRemote.clickHold);
      expect(writes.skip(1).map((write) => write.$2), [
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
}
