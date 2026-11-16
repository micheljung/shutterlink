import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_screen.dart';
import 'package:shutterlink/feature/mode/reconnecting_overlay.dart';
import 'package:shutterlink/feature/onboarding/onboarding_screen.dart';
import 'package:shutterlink/feature/onboarding/setup_steps.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/usb/ios_usb_platform.dart';

import 'fakes/fake_camera_client.dart';
import 'fakes/test_app.dart';

void main() {
  testWidgets('starts on the connect screen and shows pairing help', (
    tester,
  ) async {
    final dependencies = await testDependencies(
      (_) => throw const PairingRequiredException(),
    );
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));

    await tester.tap(find.text(ConnectScreen.setupGuideLabel));
    await tester.pumpAndSettle();
    expect(find.text(SetupSteps.title), findsOneWidget);
    Navigator.of(tester.element(find.text(SetupSteps.title))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text(ConnectScreen.connectLabel));
    await tester.pumpAndSettle();

    expect(find.text('Pair this phone on the camera'), findsOneWidget);
  });

  testWidgets('the first run shows the onboarding once, then Connect', (
    tester,
  ) async {
    final dependencies = await testDependencies(
      (_) => throw const PairingRequiredException(),
      prefs: {SettingsRepository.onboardingSeenKey: false},
    );
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text(ConnectScreen.connectLabel), findsNothing);
    expect(find.text(OnboardingScreen.progressText(0)), findsOneWidget);

    await tester.tap(find.text(OnboardingScreen.nextLabel));
    await tester.pumpAndSettle();
    expect(find.text(SetupSteps.title), findsOneWidget);

    await tester.tap(find.text(OnboardingScreen.nextLabel));
    await tester.pumpAndSettle();
    expect(find.text(OnboardingScreen.phoneTitle), findsOneWidget);
    expect(find.text(OnboardingScreen.skipLabel), findsNothing);

    await tester.tap(find.text(OnboardingScreen.doneLabel));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.text(ConnectScreen.connectLabel), findsOneWidget);
    expect(dependencies.settings.onboardingSeen, isTrue);
  });

  testWidgets('skipping the onboarding lands on Connect', (tester) async {
    final dependencies = await testDependencies(
      (_) => throw const PairingRequiredException(),
      prefs: {SettingsRepository.onboardingSeenKey: false},
    );
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));

    await tester.tap(find.text(OnboardingScreen.skipLabel));
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.text(ConnectScreen.connectLabel), findsOneWidget);
    expect(dependencies.settings.onboardingSeen, isTrue);
  });

  testWidgets('a camera drop shows the overlay over the mode; Abort ends it', (
    tester,
  ) async {
    final client = FakeCameraClient([cameraObject(1, 'IMG_0001.JPG')]);
    final dependencies = await testDependencies((_) async => client);
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await connectAndBrowse(tester);
    expect(find.text('Photos (1)'), findsOneWidget);

    client.simulateDisconnect();
    await tester.pumpAndSettle();

    expect(find.text(ReconnectingOverlay.reconnectingText), findsOneWidget);
    expect(find.text('Photos (1)'), findsOneWidget);
    expect(find.text(ConnectScreen.connectLabel), findsNothing);

    await tester.tap(find.text(ReconnectingOverlay.abortLabel));
    await tester.pumpAndSettle();
    expect(find.text(ConnectScreen.connectLabel), findsOneWidget);
    expect(find.text(ReconnectingOverlay.reconnectingText), findsNothing);
  });

  testWidgets('labels USB as experimental on iOS (U7)', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(IosUsbPlatform.channel, (_) async {
      return null;
    });
    messenger.setMockStreamHandler(
      IosUsbPlatform.events,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(IosUsbPlatform.channel, null);
      messenger.setMockStreamHandler(IosUsbPlatform.events, null);
    });
    final usb = IosUsbPlatform();
    addTearDown(usb.dispose);
    final dependencies = await testDependencies(
      (_) => throw const PairingRequiredException(),
      usb: usb,
    );
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.ensureVisible(find.text(ConnectScreen.usbExperimentalLabel));

    expect(find.text(ConnectScreen.usbExperimentalLabel), findsOneWidget);
  });
}
