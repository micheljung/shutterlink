import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/connect/connect_screen.dart';
import 'package:shutterlink/feature/connect/connect_state.dart';
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

  testWidgets('reconnects when the camera drops, until aborted', (
    tester,
  ) async {
    final client = FakeCameraClient([cameraObject(1, 'IMG_0001.JPG')]);
    final dependencies = await testDependencies((_) async => client);
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Photos (1)'), findsOneWidget);
    final connect = tester
        .element(find.text('Photos (1)'))
        .read<ConnectCubit>();

    client.simulateDisconnect();
    await tester.pump();
    expect(connect.state, const ConnectReconnecting());

    await connect.abortReconnect();
    await tester.pumpAndSettle();
    expect(find.text('Connect'), findsOneWidget);
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
