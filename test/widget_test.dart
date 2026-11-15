import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/feature/connect/connect_screen.dart';
import 'package:shutterlink/feature/mode/reconnecting_overlay.dart';
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

    expect(find.text('Set up the camera'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Pair this phone on the camera'), findsOneWidget);
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
    expect(find.text('Connect'), findsNothing);

    await tester.tap(find.text(ReconnectingOverlay.abortLabel));
    await tester.pumpAndSettle();
    expect(find.text('Connect'), findsOneWidget);
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
