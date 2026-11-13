import 'dart:async';
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
  TestWidgetsFlutterBinding.ensureInitialized();
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

  group('releases the binding', () {
    void verifyReleased() =>
        verify(() => binder.releaseBinding(ConnectCubit.bindingOwner))
            .called(1);

    blocTest<ConnectCubit, ConnectState>(
      'when the connection fails on the platform side',
      build: () => build((_, _) => throw PlatformException(code: 'socket')),
      act: (cubit) => cubit.connect(),
      expect: () => [const ConnectConnecting(), const ConnectFailed('null')],
      verify: (_) => verifyReleased(),
    );

    test('when resolving the gateway fails', () async {
      final cubit = ConnectCubit(
        connector: (_, _) async => client,
        identity: IdentityRepository(prefs),
        hostResolver: CameraHostResolver(
          SettingsRepository(prefs),
          wifiGateway: () => throw PlatformException(code: 'wifi'),
        ),
        networkBinder: binder,
      );
      addTearDown(cubit.close);
      when(() => binder.acquireBinding(any())).thenAnswer((_) async => null);

      await cubit.connect();

      expect(cubit.state, isA<ConnectFailed>());
      verifyReleased();
    });

    test('when the cubit closes while connecting', () async {
      final connected = Completer<CameraClient>();
      final cubit = build((_, _) => connected.future);
      final connecting = cubit.connect();
      await pumpEventQueue();
      await cubit.close();

      connected.complete(client);
      await connecting;

      expect(client.closed, isTrue);
      verifyReleased();
    });
  });

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

  group('Live ownership', () {
    const live = 'live';

    blocTest<ConnectCubit, ConnectState>(
      'a client drop and disconnect() leave the binding to Live',
      build: () => build((_, _) async => client),
      act: (cubit) async {
        await cubit.connect();
        expect(cubit.handOver(live), client);
        client.simulateDisconnect();
        await Future<void>.delayed(Duration.zero);
        await cubit.disconnect();
      },
      expect: () => [
        const ConnectConnecting(),
        ConnectConnected(client),
        const ConnectLiveOwned(),
      ],
      verify: (_) {
        verify(() => binder.transferBinding(ConnectCubit.bindingOwner, live))
            .called(1);
        verifyNever(() => binder.releaseBinding(any()));
        expect(client.closed, isFalse);
      },
    );

    blocTest<ConnectCubit, ConnectState>(
      'a live client comes back with the binding',
      build: () => build((_, _) async => client),
      act: (cubit) async {
        await cubit.connect();
        cubit.handOver(live);
        expect(cubit.takeBack(client, owner: live), isTrue);
      },
      skip: 2,
      expect: () => [const ConnectLiveOwned(), ConnectConnected(client)],
      verify: (_) =>
          verify(() => binder.transferBinding(live, ConnectCubit.bindingOwner))
              .called(1),
    );

    blocTest<ConnectCubit, ConnectState>(
      'a reconnected client is watched for drops',
      build: () => build((_, _) async => client),
      act: (cubit) async {
        await cubit.connect();
        cubit.handOver(live);
        final other = FakeCameraClient([]);
        cubit.takeBack(other, owner: live);
        other.simulateDisconnect();
        await Future<void>.delayed(Duration.zero);
      },
      skip: 3,
      expect: () => [
        isA<ConnectConnected>(),
        const ConnectFailed(ConnectCubit.disconnectedMessage),
      ],
    );

    blocTest<ConnectCubit, ConnectState>(
      'without a client it goes idle',
      build: () => build((_, _) async => client),
      act: (cubit) async {
        await cubit.connect();
        cubit.handOver(live);
        expect(cubit.takeBack(null, owner: live), isFalse);
      },
      skip: 3,
      expect: () => [const ConnectIdle()],
    );

    blocTest<ConnectCubit, ConnectState>(
      'nothing to hand over or take back while idle',
      build: () => build((_, _) async => client),
      act: (cubit) {
        expect(cubit.handOver(live), isNull);
        expect(cubit.takeBack(client, owner: live), isFalse);
      },
      expect: () => const <ConnectState>[],
    );

    group('with the platform binder', () {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      late List<String> nativeCalls;
      late PlatformNetworkBinder platformBinder;

      setUp(() {
        nativeCalls = [];
        platformBinder = PlatformNetworkBinder(isAndroid: true);
        messenger.setMockMethodCallHandler(PlatformNetworkBinder.channel, (
          call,
        ) async {
          nativeCalls.add(call.method);
          return call.method == 'bindToWifi' ? gateway : null;
        });
      });

      tearDown(
        () => messenger.setMockMethodCallHandler(
          PlatformNetworkBinder.channel,
          null,
        ),
      );

      ConnectCubit platformCubit() => ConnectCubit(
        connector: (_, _) async => client,
        identity: IdentityRepository(prefs),
        hostResolver: CameraHostResolver(
          SettingsRepository(prefs),
          wifiGateway: () async => null,
        ),
        networkBinder: platformBinder,
      );

      test('repeated Live acquires need a single release', () async {
        final cubit = platformCubit();
        await cubit.connect();
        cubit.handOver(live);
        await platformBinder.acquireBinding(live, holdNetwork: true);
        await platformBinder.acquireBinding(live, holdNetwork: true);

        await platformBinder.releaseBinding(live);

        expect(nativeCalls.where((call) => call == 'unbind'), hasLength(1));
        await cubit.close();
      });

      test('stop with the client alive keeps the Wi-Fi bound', () async {
        final cubit = platformCubit();
        await cubit.connect();
        cubit.handOver(live);
        await platformBinder.acquireBinding(live, holdNetwork: true);

        cubit.takeBack(client, owner: live);
        await platformBinder.releaseBinding(live);

        expect(nativeCalls, isNot(contains('unbind')));
        await cubit.disconnect();
        expect(nativeCalls.where((call) => call == 'unbind'), hasLength(1));
      });
    });
  });
}
