import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/ssdp_discovery.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_screen.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/feature/download/download_cubit.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_usb_camera_watcher.dart';
import '../../fakes/test_app.dart';

void main() {
  const gateway = CameraHostResolver.fallbackHost;
  const cameras = [
    DiscoveredCamera(host: '192.168.178.20', name: 'EOS R'),
    DiscoveredCamera(host: '192.168.178.21', name: 'EOS R6'),
  ];
  late List<String> hosts;

  Future<void> showChooser(WidgetTester tester) async {
    hosts = [];
    final client = FakeCameraClient([]);
    final dependencies = await testDependencies((_) async => client);
    final connect = ConnectCubit(
      claimsUsbVendor: (_) => false,
      connector: (target) async {
        final host = (target as WifiTarget).host;
        hosts.add(host);
        if (host == gateway) {
          throw const CameraDisconnectedException(
            SocketException('Connection refused'),
          );
        }
        return client;
      },
      identity: dependencies.identity,
      hostResolver: dependencies.hostResolver,
      networkBinder: dependencies.networkBinder,
      discovery: () async => cameras,
    );
    addTearDown(connect.close);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider.value(value: connect),
          BlocProvider(create: (_) => SettingsCubit(dependencies.settings)),
          BlocProvider(
            create: (_) => DownloadCubit(
              saver: dependencies.photoSaver,
              workDirectory: dependencies.downloadDirectory,
              history: dependencies.downloadHistory,
            ),
          ),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Cancel'));
    await tester.pumpAndSettle();
  }

  testWidgets('connects to the chosen camera', (tester) async {
    await showChooser(tester);

    expect(find.text('EOS R'), findsOneWidget);
    expect(find.text('EOS R6'), findsOneWidget);

    await tester.tap(find.text('EOS R6'));
    await tester.pump();

    expect(hosts, [gateway, cameras.last.host]);
  });

  testWidgets('cancelling the choice shows Connect again', (tester) async {
    await showChooser(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('EOS R'), findsNothing);
    expect(find.text('Connect'), findsOneWidget);
  });

  group('USB', () {
    late FakeUsbCameraWatcher watcher;
    late Completer<CameraClient> opened;

    Future<void> showScreen(
      WidgetTester tester, {
      bool usbExperimental = false,
    }) async {
      watcher = FakeUsbCameraWatcher()..permitted.add(usbCamera());
      opened = Completer<CameraClient>();
      final dependencies = await testDependencies((_) => opened.future);
      final connect = ConnectCubit(
        connector: (_) => opened.future,
        identity: dependencies.identity,
        hostResolver: dependencies.hostResolver,
        networkBinder: dependencies.networkBinder,
        claimsUsbVendor: claimsCanonOnly,
        usbWatcher: watcher,
      );
      addTearDown(connect.close);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider.value(value: connect),
            BlocProvider(create: (_) => SettingsCubit(dependencies.settings)),
            BlocProvider(
              create: (_) => DownloadCubit(
                saver: dependencies.photoSaver,
                workDirectory: dependencies.downloadDirectory,
                history: dependencies.downloadHistory,
              ),
            ),
          ],
          child: MaterialApp(
            home: ConnectScreen(usbExperimental: usbExperimental),
          ),
        ),
      );
    }

    testWidgets('watches the cable while shown', (tester) async {
      await showScreen(tester);
      expect(watcher.calls, ['start connection', 'start connect']);

      await tester.pumpWidget(const SizedBox());

      expect(watcher.calls, [
        'start connection',
        'start connect',
        'stop connect',
      ]);
    });

    testWidgets('stops watching in the background and resumes after', (
      tester,
    ) async {
      await showScreen(tester);
      watcher.calls.clear();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(watcher.calls, ['stop connect']);

      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      expect(watcher.calls, ['stop connect', 'start connect']);
    });

    testWidgets('says when it connects over USB', (tester) async {
      await showScreen(tester);

      watcher.attach(usbCamera());
      await tester.pump();
      await tester.ensureVisible(find.text(ConnectScreen.usbConnectingText));

      expect(find.text(ConnectScreen.usbConnectingText), findsOneWidget);
      opened.complete(FakeCameraClient([]));
    });

    testWidgets('labels USB as experimental only when asked', (tester) async {
      await showScreen(tester);
      expect(find.text(ConnectScreen.usbExperimentalLabel), findsNothing);

      await showScreen(tester, usbExperimental: true);
      await tester.ensureVisible(find.text(ConnectScreen.usbExperimentalLabel));
      expect(find.text(ConnectScreen.usbExperimentalLabel), findsOneWidget);
    });
  });

  group('demo', () {
    late ConnectCubit connect;
    late List<ConnectTarget> targets;
    late int picks;

    Future<void> tapDemo(
      WidgetTester tester,
      List<XFile> picked, {
      PhotoPicker? pickPhotos,
    }) async {
      targets = [];
      picks = 0;
      final dependencies = await testDependencies(
        (_) async => FakeCameraClient([]),
      );
      connect = ConnectCubit(
        connector: (target) async {
          targets.add(target);
          return FakeCameraClient([]);
        },
        identity: dependencies.identity,
        hostResolver: dependencies.hostResolver,
        networkBinder: dependencies.networkBinder,
        claimsUsbVendor: (_) => false,
      );
      addTearDown(connect.close);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider.value(value: connect),
            BlocProvider(create: (_) => SettingsCubit(dependencies.settings)),
            BlocProvider(
              create: (_) => DownloadCubit(
                saver: dependencies.photoSaver,
                workDirectory: dependencies.downloadDirectory,
                history: dependencies.downloadHistory,
              ),
            ),
          ],
          child: MaterialApp(
            home: ConnectScreen(
              pickPhotos: () {
                picks++;
                return pickPhotos?.call() ?? Future.value(picked);
              },
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text(ConnectScreen.demoLabel));
      await tester.tap(find.text(ConnectScreen.demoLabel));
      await tester.pump();
    }

    testWidgets('opens the picked JPEGs as a demo camera', (tester) async {
      await tapDemo(tester, [
        XFile('/picked/IMG_0001.JPG'),
        XFile('/picked/b.jpeg'),
      ]);

      expect(picks, 1);
      expect(connect.state, isA<ConnectConnected>());
      expect((targets.single as DemoTarget).photos.map((file) => file.path), [
        '/picked/IMG_0001.JPG',
        '/picked/b.jpeg',
      ]);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('skips photos that are no JPEG and says so', (tester) async {
      await tapDemo(tester, [XFile('/picked/a.jpg'), XFile('/picked/b.heic')]);

      expect((targets.single as DemoTarget).photos.map((file) => file.path), [
        '/picked/a.jpg',
      ]);
      expect(find.text(ConnectScreen.skippedText(1)), findsOneWidget);
    });

    testWidgets('stays without a camera when no JPEG was picked', (
      tester,
    ) async {
      await tapDemo(tester, [XFile('/picked/a.png')]);

      expect(connect.state, const ConnectIdle());
      expect(targets, isEmpty);
      expect(find.text(ConnectScreen.skippedText(1)), findsOneWidget);
    });

    testWidgets('a cancelled picker changes nothing', (tester) async {
      await tapDemo(tester, []);

      expect(picks, 1);
      expect(connect.state, const ConnectIdle());
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('says when the picker fails', (tester) async {
      await tapDemo(
        tester,
        [],
        pickPhotos: () async => throw PlatformException(code: 'already_active'),
      );

      expect(connect.state, const ConnectIdle());
      expect(find.text(ConnectScreen.pickFailedText), findsOneWidget);
    });

    testWidgets('opens one picker at a time', (tester) async {
      final picker = Completer<List<XFile>>();
      await tapDemo(tester, [], pickPhotos: () => picker.future);

      await tester.tap(find.text(ConnectScreen.demoLabel));
      expect(picks, 1);

      picker.complete([XFile('/picked/a.jpg')]);
      await tester.pump();

      expect(targets.single, isA<DemoTarget>());
    });
  });
}
