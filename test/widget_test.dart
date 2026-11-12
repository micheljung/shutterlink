import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import 'fakes/fake_camera_client.dart';
import 'fakes/test_app.dart';

void main() {
  testWidgets('starts on the connect screen and shows pairing help', (
    tester,
  ) async {
    final dependencies = await testDependencies(
      (_, _) => throw const PairingRequiredException(),
    );
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));

    expect(find.text('Set up the camera'), findsOneWidget);

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Pair this phone on the camera'), findsOneWidget);
  });

  testWidgets('returns to the connect screen when the camera drops', (
    tester,
  ) async {
    final client = FakeCameraClient([cameraObject(1, 'IMG_0001.JPG')]);
    final dependencies = await testDependencies((_, _) async => client);
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Photos (1)'), findsOneWidget);

    client.simulateDisconnect();
    await tester.pumpAndSettle();

    expect(find.text('The camera disconnected.'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}
