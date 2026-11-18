import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shutterlink/brand/brand_theme.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
import 'package:shutterlink/feature/mode/mode_cubit.dart';
import 'package:shutterlink/feature/mode/mode_picker_screen.dart';
import 'package:shutterlink/feature/mode/operating_mode.dart';
import 'package:shutterlink/feature/mode/usb_waves_indicator.dart';
import 'package:shutterlink/feature/sessions/sessions_upload_cubit.dart';
import 'package:shutterlink/feature/settings/settings_cubit.dart';
import 'package:shutterlink/feature/settings/upload_settings_cubit.dart';
import 'package:shutterlink/feature/upload/upload_status_cubit.dart';
import 'package:shutterlink/feature/upload/upload_status_indicator.dart';
import 'package:shutterlink/upload/destination.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/fake_usb_camera_watcher.dart';

class _MockConnectCubit extends MockCubit<ConnectState>
    implements ConnectCubit {}

class _MockSettingsCubit extends MockCubit<SettingsState>
    implements SettingsCubit {}

class _MockUploadSettingsCubit extends MockCubit<UploadSettingsState>
    implements UploadSettingsCubit {}

class _MockUploadStatusCubit extends MockCubit<UploadStatusState>
    implements UploadStatusCubit {}

class _MockSessionsUploadCubit extends MockCubit<SessionsUploadState>
    implements SessionsUploadCubit {}

const _destination = Destination(
  type: DestinationType.webdav,
  endpoint: 'https://dav.example.com',
);
const _phoneSize = Size(390, 844);
const _scrollStep = 100.0;

void main() {
  late _MockConnectCubit connect;
  late ModeCubit modes;

  setUp(() {
    connect = _MockConnectCubit();
    modes = ModeCubit();
    addTearDown(modes.close);
    when(() => connect.state)
        .thenReturn(ConnectConnected(FakeCameraClient([])));
    when(() => connect.disconnect()).thenAnswer((_) async {});
  });

  Future<void> pumpPicker(
    WidgetTester tester, {
    bool reduceMotion = false,
    Brightness brightness = Brightness.light,
  }) async {
    final settings = _MockSettingsCubit();
    when(() => settings.state).thenReturn(
      const SettingsState(
        format: DownloadFormat.jpeg,
        sessionsConfigured: true,
      ),
    );
    final uploadSettings = _MockUploadSettingsCubit();
    when(() => uploadSettings.state)
        .thenReturn(const UploadSettingsState(destination: _destination));
    final uploads = _MockUploadStatusCubit();
    when(() => uploads.state).thenReturn(const UploadStatusState());
    final sessions = _MockSessionsUploadCubit();
    when(() => sessions.state).thenReturn(const SessionsUploadState());
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<ConnectCubit>.value(value: connect),
          BlocProvider<ModeCubit>.value(value: modes),
          BlocProvider<SettingsCubit>.value(value: settings),
          BlocProvider<UploadSettingsCubit>.value(value: uploadSettings),
          BlocProvider<UploadStatusCubit>.value(value: uploads),
          BlocProvider<SessionsUploadCubit>.value(value: sessions),
        ],
        child: MaterialApp(
          theme: brightness == Brightness.dark
              ? BrandTheme.dark()
              : BrandTheme.light(),
          home: const ModePickerScreen(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
        ),
      ),
    );
  }

  testWidgets('shows the title and every mode with its description', (
    tester,
  ) async {
    await pumpPicker(tester);

    expect(find.text(ModePickerScreen.title), findsOneWidget);
    for (final mode in OperatingMode.values) {
      expect(find.text(mode.label), findsOneWidget);
      expect(find.text(mode.description), findsOneWidget);
    }
  });

  for (final mode in OperatingMode.values) {
    testWidgets('tapping ${mode.label} enters it', (tester) async {
      await pumpPicker(tester);

      await tester.tap(find.text(mode.label));
      await tester.pumpAndSettle();

      expect(modes.state, mode);
    });
  }

  testWidgets('on a phone every mode is reachable by scrolling', (
    tester,
  ) async {
    tester.view
      ..physicalSize = _phoneSize
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpPicker(tester);

    final mode = OperatingMode.values.last;
    await tester.scrollUntilVisible(find.text(mode.description), _scrollStep);
    await tester.tap(find.text(mode.label));
    await tester.pumpAndSettle();

    expect(modes.state, mode);
  });

  testWidgets('has the upload indicator, Settings and Disconnect', (
    tester,
  ) async {
    await pumpPicker(tester);

    expect(find.byTooltip(UploadStatusIndicator.tooltip), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    await tester.tap(find.byTooltip('Disconnect'));
    verify(() => connect.disconnect()).called(1);
  });

  testWidgets('says how the camera is connected', (tester) async {
    when(() => connect.state).thenReturn(
      ConnectConnected(FakeCameraClient([]), target: const DemoTarget()),
    );
    await pumpPicker(tester);

    expect(
      find.text(ModePickerScreen.statusText(const DemoTarget())),
      findsOneWidget,
    );
  });

  group('USB connection', () {
    setUp(() {
      when(() => connect.state).thenReturn(
        ConnectConnected(FakeCameraClient([]), target: UsbTarget(usbCamera())),
      );
    });

    testWidgets('ripples waves from the plug', (tester) async {
      await pumpPicker(tester);
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(UsbWavesIndicator), findsOneWidget);
      expect(
        find.text(ModePickerScreen.statusText(UsbTarget(usbCamera()))),
        findsOneWidget,
      );
      final state = tester.state<UsbWavesIndicatorState>(
        find.byType(UsbWavesIndicator),
      );
      expect(state.controller.duration, UsbWavesIndicator.period);
      expect(tester.hasRunningAnimations, isTrue);
    });

    for (final brightness in Brightness.values) {
      testWidgets('paints in the online colour ($brightness)', (tester) async {
        await pumpPicker(tester, brightness: brightness);

        final paint = tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(UsbWavesIndicator),
            matching: find.byType(CustomPaint),
          ),
        );
        expect(
          (paint.painter! as UsbWavesPainter).color,
          BrandColors.online(brightness),
        );
      });
    }

    testWidgets('holds still with reduced motion', (tester) async {
      await pumpPicker(tester, reduceMotion: true);

      expect(find.byType(UsbWavesIndicator), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('follows a reduced-motion change while shown', (tester) async {
      await pumpPicker(tester);
      expect(tester.hasRunningAnimations, isTrue);

      await pumpPicker(tester, reduceMotion: true);
      expect(tester.hasRunningAnimations, isFalse);

      await pumpPicker(tester);
      expect(tester.hasRunningAnimations, isTrue);
    });

    testWidgets('stops when the picker goes away', (tester) async {
      await pumpPicker(tester);
      await tester.pumpWidget(const SizedBox());

      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  testWidgets('keeps the dot over Wi-Fi', (tester) async {
    await pumpPicker(tester);

    expect(find.byType(UsbWavesIndicator), findsNothing);
  });
}
