import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/network_binder.dart';
import 'package:shutterlink/data/settings_repository.dart';
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    binder = _MockNetworkBinder();
    when(binder.bindToWifi).thenAnswer((_) async => gateway);
    when(binder.unbind).thenAnswer((_) async {});
    client = FakeCameraClient([]);
    hosts = [];
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
    verify: (_) => verify(binder.unbind).called(1),
  );

  blocTest<ConnectCubit, ConnectState>(
    'maps CameraBusyException to a busy message',
    build: () => build((_, _) => throw const CameraBusyException(2)),
    act: (cubit) => cubit.connect(),
    expect: () => [
      const ConnectConnecting(),
      const ConnectFailed(ConnectCubit.busyMessage),
    ],
    verify: (_) => verify(binder.unbind).called(1),
  );

  blocTest<ConnectCubit, ConnectState>(
    'reports missing Wi-Fi',
    setUp: () =>
        when(binder.bindToWifi)
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
}
