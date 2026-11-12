import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/feature/gallery/thumbnail_tile.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/test_app.dart';

void main() {
  final objects = [
    cameraObject(1, 'IMG_0001.JPG'),
    cameraObject(2, 'IMG_0001.CR3'),
    cameraObject(3, 'IMG_0002.JPG'),
    cameraObject(4, 'IMG_0003.CR3'),
  ];

  Future<FakeCameraClient> pumpGallery(WidgetTester tester) async {
    final client = FakeCameraClient(objects);
    final dependencies = await testDependencies((_, _) async => client);
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    return client;
  }

  testWidgets('shows one tile per photo group with format badges', (
    tester,
  ) async {
    await pumpGallery(tester);

    expect(find.byType(ThumbnailTile), findsNWidgets(3));
    expect(find.text('Photos (3)'), findsOneWidget);
    expect(find.text('RAW+JPEG'), findsOneWidget);
    expect(find.text('JPEG'), findsOneWidget);
    expect(find.text('RAW'), findsOneWidget);
  });

  testWidgets('tapping tiles and select all update the selection', (
    tester,
  ) async {
    await pumpGallery(tester);

    await tester.tap(find.byType(ThumbnailTile).first);
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('Download (1)'), findsOneWidget);

    await tester.tap(find.byTooltip('Select all'));
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(3));

    await tester.tap(find.byTooltip('Select none'));
    await tester.pump();
    expect(find.text('Photos (3)'), findsOneWidget);
  });

  testWidgets('leaving the gallery cancels thumbnail requests', (tester) async {
    final client = await pumpGallery(tester);
    expect(client.thumbnailTokens, hasLength(3));
    expect(client.thumbnailTokens.any((token) => token!.isCancelled), isFalse);

    await tester.tap(find.byTooltip('Disconnect'));
    await tester.pumpAndSettle();

    expect(client.thumbnailTokens.every((token) => token!.isCancelled), isTrue);
  });
}
