import 'dart:async';
import 'dart:io';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shutterlink/brand/brand_theme.dart';
import 'package:shutterlink/brand/shutterlink_logo.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/data/ssdp_discovery.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_screen.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/feature/download/download_cubit.dart';
import 'package:shutterlink/feature/download/download_state.dart';
import 'package:shutterlink/feature/onboarding/setup_steps.dart';
import 'package:shutterlink/feature/sessions/active_session_indicator.dart';
import 'package:shutterlink/feature/sessions/session.dart';
import 'package:shutterlink/feature/sessions/sessions_cubit.dart';
import 'package:shutterlink/feature/sessions/sessions_state.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_usb_camera_watcher.dart';
import '../../fakes/test_app.dart';

class _MockConnectCubit extends MockCubit<ConnectState>
    implements ConnectCubit {}

class _MockSettingsCubit extends MockCubit<SettingsState>
    implements SettingsCubit {}

class _MockSessionsCubit extends MockCubit<SessionsState>
    implements SessionsCubit {}

class _MockDownloadCubit extends MockCubit<DownloadState>
    implements DownloadCubit {}

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
    await tester.tap(find.text(ConnectScreen.connectLabel));
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
    expect(find.text(ConnectScreen.connectLabel), findsOneWidget);
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

  testWidgets('the demo connects to an empty demo camera', (tester) async {
    final targets = <ConnectTarget>[];
    final dependencies = await testDependencies(
      (_) async => FakeCameraClient([]),
    );
    final connect = ConnectCubit(
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
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.ensureVisible(find.text(ConnectScreen.demoLabel));
    await tester.tap(find.text(ConnectScreen.demoLabel));
    await tester.pump();

    expect(connect.state, isA<ConnectConnected>());
    expect(targets.single, isA<DemoTarget>());
  });

  group('every state keeps a home', () {
    const sessionCode = 'brave-otter';
    const pairingTitle = 'Pair this phone on the camera';
    const pausedText = 'Download paused. Reconnect to resume it.';
    final connectButton = find.text(ConnectScreen.connectLabel);
    late _MockConnectCubit connect;
    Future<void> pumpState(
      WidgetTester tester,
      ConnectState state, {
      bool usbExperimental = false,
      bool downloadPaused = false,
      bool sessionActive = false,
    }) async {
      connect = _MockConnectCubit();
      when(() => connect.state).thenReturn(state);
      when(() => connect.usbWatcher).thenReturn(FakeUsbCameraWatcher());
      when(connect.connect).thenAnswer((_) async {});
      when(connect.cancelChoice).thenAnswer((_) async {});
      when(connect.connectDemo).thenAnswer((_) async {});
      final settings = _MockSettingsCubit();
      when(() => settings.state).thenReturn(
        SettingsState(
          format: SettingsRepository.defaultFormat,
          sessionsConfigured: sessionActive,
        ),
      );
      final sessions = _MockSessionsCubit();
      when(() => sessions.state).thenReturn(
        SessionsState(
          loaded: true,
          sessions: [
            if (sessionActive)
              Session(
                id: sessionCode,
                code: sessionCode,
                createdAt: DateTime.utc(2026),
                intervals: [ActivityInterval(DateTime.utc(2026))],
              ),
          ],
        ),
      );
      final download = _MockDownloadCubit();
      when(() => download.state).thenReturn(
        DownloadState(
          status: downloadPaused ? DownloadStatus.paused : DownloadStatus.idle,
        ),
      );
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<ConnectCubit>.value(value: connect),
            BlocProvider<SettingsCubit>.value(value: settings),
            BlocProvider<SessionsCubit>.value(value: sessions),
            BlocProvider<DownloadCubit>.value(value: download),
          ],
          child: MaterialApp(
            theme: BrandTheme.light(),
            home: ConnectScreen(usbExperimental: usbExperimental),
          ),
        ),
      );
    }

    Future<void> expectConnectTappable(WidgetTester tester) async {
      expect(connectButton, findsOneWidget);
      await tester.tap(connectButton);
      await tester.pump();
      verify(connect.connect).called(1);
    }

    void expectHome() {
      expect(find.byType(ShutterlinkLogo), findsOneWidget);
      expect(find.byTooltip('Settings').hitTestable(), findsOneWidget);
      expect(
        find.text(ConnectScreen.setupGuideLabel).hitTestable(),
        findsOneWidget,
      );
    }

    testWidgets('idle shows the logo and Connect', (tester) async {
      await pumpState(tester, const ConnectIdle());

      expectHome();
      await expectConnectTappable(tester);
    });

    testWidgets('pairing shows the pairing help', (tester) async {
      await pumpState(tester, const ConnectPairingRequired());

      expect(find.text(pairingTitle), findsOneWidget);
      expectHome();
      await expectConnectTappable(tester);
    });

    testWidgets('a failure shows its message', (tester) async {
      await pumpState(tester, const ConnectFailed('Camera not found'));

      expect(find.text('Camera not found'), findsOneWidget);
      expectHome();
      await expectConnectTappable(tester);
    });

    testWidgets('a paused download says so', (tester) async {
      await pumpState(tester, const ConnectIdle(), downloadPaused: true);

      expect(find.text(pausedText), findsOneWidget);
      await expectConnectTappable(tester);
    });

    testWidgets('a running Session stays visible', (tester) async {
      await pumpState(tester, const ConnectIdle(), sessionActive: true);

      expect(find.text(ActiveSessionIndicator.text(sessionCode)), findsOne);
      await expectConnectTappable(tester);
    });

    testWidgets('labels USB as experimental', (tester) async {
      await pumpState(tester, const ConnectIdle(), usbExperimental: true);

      expect(find.text(ConnectScreen.usbExperimentalLabel), findsOneWidget);
      await expectConnectTappable(tester);
    });

    testWidgets('Connect stays tappable with every notice shown', (
      tester,
    ) async {
      await pumpState(
        tester,
        const ConnectPairingRequired(),
        usbExperimental: true,
        downloadPaused: true,
        sessionActive: true,
      );

      expect(find.text(pairingTitle), findsOneWidget);
      expect(find.text(pausedText), findsOneWidget);
      expect(find.text(ActiveSessionIndicator.text(sessionCode)), findsOne);
      expectHome();
      await expectConnectTappable(tester);
    });

    testWidgets('offers the demo', (tester) async {
      await pumpState(tester, const ConnectIdle());

      await tester.tap(find.text(ConnectScreen.demoLabel));
      await tester.pump();

      verify(connect.connectDemo).called(1);
    });

    testWidgets('the chooser lists the cameras and cancels', (tester) async {
      await pumpState(tester, const ConnectChooseCamera(cameras));

      expect(find.text('EOS R'), findsOneWidget);
      expect(find.text('EOS R6'), findsOneWidget);
      expect(connectButton, findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      verify(connect.cancelChoice).called(1);
      expectHome();
    });

    testWidgets('connecting over Wi-Fi names the camera', (tester) async {
      await pumpState(tester, const ConnectConnecting(cameraName: 'EOS R'));

      expect(find.textContaining('Connecting to EOS R…'), findsOneWidget);
      expect(connectButton, findsNothing);
      expectHome();
    });

    testWidgets('connecting over USB says so', (tester) async {
      await pumpState(tester, const ConnectConnecting(usb: true));

      expect(
        find.text(ConnectScreen.usbConnectingText).hitTestable(),
        findsOneWidget,
      );
      expect(connectButton, findsNothing);
    });

    testWidgets('the setup guide lists every step', (tester) async {
      await pumpState(tester, const ConnectIdle());

      await tester.tap(find.text(ConnectScreen.setupGuideLabel));
      await tester.pumpAndSettle();

      expect(find.text(SetupSteps.title), findsOneWidget);
      expect(find.byType(SetupStepList), findsOneWidget);
      for (final step in SetupSteps.all) {
        expect(find.text(step, findRichText: true), findsOneWidget);
      }
    });
  });
}
