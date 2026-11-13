import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/network_binder.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/data/ssdp_discovery.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../../fakes/fake_camera_client.dart';

class _MockNetworkBinder extends Mock implements NetworkBinder {}

void main() {
  const gateway = '192.168.1.2';
  late SharedPreferences prefs;
  late _MockNetworkBinder binder;
  late FakeCameraClient client;
  late List<String> hosts;
  late List<DiscoveredCamera> discovered;
  late int discoveries;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    binder = _MockNetworkBinder();
    when(() => binder.acquireBinding(any())).thenAnswer((_) async => gateway);
    when(() => binder.releaseBinding(any())).thenAnswer((_) async {});
    when(binder.acquireMulticastLock).thenAnswer((_) async {});
    when(binder.releaseMulticastLock).thenAnswer((_) async {});
    client = FakeCameraClient([]);
    hosts = [];
    discovered = [];
    discoveries = 0;
  });

  ConnectCubit build(CameraConnector connector) => ConnectCubit(
    connector: (host, identity) {
      hosts.add(host);
      return connector(host, identity);
    },
    identity: IdentityRepository(prefs),
    hostResolver: CameraHostResolver(
      SettingsRepository(prefs),
      wifiGateway: () async => null,
    ),
    networkBinder: binder,
    discovery: () async {
      discoveries++;
      return discovered;
    },
  );

  blocTest<ConnectCubit, ConnectState>(
    'connects to the bound Wi-Fi gateway',
    build: () => build((_, _) async => client),
    act: (cubit) => cubit.connect(),
    expect: () => [const ConnectConnecting(), ConnectConnected(client)],
    verify: (_) => expect(hosts, [gateway]),
  );

  blocTest<ConnectCubit, ConnectState>(
    'maps PairingRequiredException to pairing instructions',
    build: () => build((_, _) => throw const PairingRequiredException(1)),
    act: (cubit) => cubit.connect(),
    expect: () => [const ConnectConnecting(), const ConnectPairingRequired()],
    verify: (_) =>
        verify(() => binder.releaseBinding(ConnectCubit.bindingOwner))
            .called(1),
  );

  blocTest<ConnectCubit, ConnectState>(
    'maps CameraBusyException to a busy message',
    build: () => build((_, _) => throw const CameraBusyException(2)),
    act: (cubit) => cubit.connect(),
    expect: () => [
      const ConnectConnecting(),
      const ConnectFailed(ConnectCubit.busyMessage),
    ],
    verify: (_) =>
        verify(() => binder.releaseBinding(ConnectCubit.bindingOwner))
            .called(1),
  );

  blocTest<ConnectCubit, ConnectState>(
    'reports missing Wi-Fi',
    setUp: () =>
        when(() => binder.acquireBinding(any()))
            .thenThrow(PlatformException(code: ConnectCubit.noWifiCode)),
    build: () => build((_, _) async => client),
    act: (cubit) => cubit.connect(),
    expect: () => [
      const ConnectConnecting(),
      const ConnectFailed(ConnectCubit.noWifiMessage),
    ],
  );

  blocTest<ConnectCubit, ConnectState>(
    'reports a camera drop',
    build: () => build((_, _) async => client),
    act: (cubit) async {
      await cubit.connect();
      client.simulateDisconnect();
      await Future<void>.delayed(Duration.zero);
    },
    expect: () => [
      const ConnectConnecting(),
      ConnectConnected(client),
      const ConnectFailed(ConnectCubit.disconnectedMessage),
    ],
  );

  blocTest<ConnectCubit, ConnectState>(
    'disconnect closes the client',
    build: () => build((_, _) async => client),
    act: (cubit) async {
      await cubit.connect();
      await cubit.disconnect();
    },
    expect: () => [
      const ConnectConnecting(),
      ConnectConnected(client),
      const ConnectIdle(),
    ],
    verify: (_) => expect(client.closed, isTrue),
  );

  group('discovery', () {
    const refused = CameraDisconnectedException(
      SocketException('Connection refused'),
    );
    const first = DiscoveredCamera(host: '192.168.178.20', name: 'EOS R');
    const second = DiscoveredCamera(host: '192.168.178.21', name: 'EOS R6');

    CameraConnector refusingGateway() =>
        (host, _) async => host == gateway ? throw refused : client;

    void verifyLockReleased() {
      verifyInOrder([binder.acquireMulticastLock, binder.releaseMulticastLock]);
    }

    blocTest<ConnectCubit, ConnectState>(
      'does not run while the gateway answers',
      setUp: () => discovered = [first],
      build: () => build((_, _) async => client),
      act: (cubit) => cubit.connect(),
      expect: () => [const ConnectConnecting(), ConnectConnected(client)],
      verify: (_) {
        expect(discoveries, 0);
        verifyNever(binder.acquireMulticastLock);
      },
    );

    blocTest<ConnectCubit, ConnectState>(
      'connects to the only camera found',
      setUp: () => discovered = [first],
      build: () => build(refusingGateway()),
      act: (cubit) => cubit.connect(),
      expect: () => [
        const ConnectConnecting(),
        const ConnectConnecting(cameraName: 'EOS R'),
        ConnectConnected(client),
      ],
      verify: (_) {
        expect(hosts, [gateway, first.host]);
        verifyLockReleased();
      },
    );

    blocTest<ConnectCubit, ConnectState>(
      'reports the gateway error when no camera is found',
      build: () => build(refusingGateway()),
      act: (cubit) => cubit.connect(),
      expect: () => [
        const ConnectConnecting(),
        ConnectFailed('Could not reach the camera at $gateway ($refused).'),
      ],
      verify: (_) {
        verifyLockReleased();
        verify(() => binder.releaseBinding(ConnectCubit.bindingOwner))
            .called(1);
      },
    );

    blocTest<ConnectCubit, ConnectState>(
      'releases the lock when discovery fails',
      build: () => ConnectCubit(
        connector: refusingGateway(),
        identity: IdentityRepository(prefs),
        hostResolver: CameraHostResolver(
          SettingsRepository(prefs),
          wifiGateway: () async => null,
        ),
        networkBinder: binder,
        discovery: () async => throw const SocketException('no multicast'),
      ),
      act: (cubit) => cubit.connect(),
      expect: () => [
        const ConnectConnecting(),
        ConnectFailed('Could not reach the camera at $gateway ($refused).'),
      ],
      verify: (_) => verifyLockReleased(),
    );

    blocTest<ConnectCubit, ConnectState>(
      'does not run when pairing is required',
      setUp: () => discovered = [first],
      build: () => build((_, _) => throw const PairingRequiredException(1)),
      act: (cubit) => cubit.connect(),
      expect: () => [const ConnectConnecting(), const ConnectPairingRequired()],
      verify: (_) => expect(discoveries, 0),
    );

    blocTest<ConnectCubit, ConnectState>(
      'offers a choice when several cameras are found',
      setUp: () => discovered = [first, second],
      build: () => build(refusingGateway()),
      act: (cubit) => cubit.connect(),
      expect: () => [
        const ConnectConnecting(),
        const ConnectChooseCamera([first, second]),
      ],
      verify: (_) {
        verifyLockReleased();
        verifyNever(() => binder.releaseBinding(any()));
      },
    );

    blocTest<ConnectCubit, ConnectState>(
      'connects to the chosen camera',
      setUp: () => discovered = [first, second],
      build: () => build(refusingGateway()),
      act: (cubit) async {
        await cubit.connect();
        await cubit.chooseCamera(second);
      },
      skip: 2,
      expect: () => [
        const ConnectConnecting(cameraName: 'EOS R6'),
        ConnectConnected(client),
      ],
      verify: (_) => expect(hosts, [gateway, second.host]),
    );

    blocTest<ConnectCubit, ConnectState>(
      'cancelling the choice unbinds and returns to idle',
      setUp: () => discovered = [first, second],
      build: () => build(refusingGateway()),
      act: (cubit) async {
        await cubit.connect();
        await cubit.cancelChoice();
      },
      skip: 2,
      expect: () => [const ConnectIdle()],
      verify: (_) =>
          verify(() => binder.releaseBinding(ConnectCubit.bindingOwner))
              .called(1),
    );

    blocTest<ConnectCubit, ConnectState>(
      'is skipped for a host override',
      setUp: () async {
        await SettingsRepository(prefs).setHostOverride('10.0.0.9');
        discovered = [first];
      },
      build: () => build((_, _) => throw refused),
      act: (cubit) => cubit.connect(),
      expect: () => [
        const ConnectConnecting(),
        ConnectFailed('Could not reach the camera at 10.0.0.9 ($refused).'),
      ],
      verify: (_) {
        expect(hosts, ['10.0.0.9']);
        expect(discoveries, 0);
        verifyNever(binder.acquireMulticastLock);
      },
    );
  });
}
