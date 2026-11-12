import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/feature/gallery/gallery_grid.dart';
import 'package:shutterlink/feature/gallery/thumbnail_tile.dart';
import 'package:shutterlink/feature/preview/preview_screen.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/test_app.dart';

const _tallSurface = Size(800, 1200);
const _longPressHold = Duration(milliseconds: 600);
const _autoScrollTicks = 60;

void main() {
  final firstDay = DateTime(2026, 6, 14, 18);
  final secondDay = DateTime(2026, 6, 13, 18);
  final objects = [
    for (var i = 0; i < 7; i++)
      cameraObject(
        i + 1,
        'IMG_${i.toString().padLeft(4, '0')}.JPG',
        captureDate: firstDay.subtract(Duration(minutes: i)),
      ),
    for (var i = 7; i < 10; i++)
      cameraObject(
        i + 1,
        'IMG_${i.toString().padLeft(4, '0')}.JPG',
        captureDate: secondDay.subtract(Duration(minutes: i)),
      ),
    cameraObject(11, 'IMG_0010.JPG'),
  ];

  Future<void> pumpGallery(WidgetTester tester, {bool tall = true}) async {
    if (tall) {
      tester.view
        ..physicalSize = _tallSurface
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    final client = FakeCameraClient(objects);
    final dependencies = await testDependencies((_, _) async => client);
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
  }

  Finder tile(int index) => find.byWidgetPredicate(
    (widget) =>
        widget is ThumbnailTile &&
        widget.group.baseName == 'IMG_${index.toString().padLeft(4, '0')}',
  );

  List<int> selectedTiles(WidgetTester tester) => [
    for (var i = 0; i < objects.length; i++)
      if (tile(i).evaluate().isNotEmpty &&
          tester.widget<ThumbnailTile>(tile(i)).selected)
        i,
  ];

  Future<TestGesture> longPressAt(WidgetTester tester, Finder finder) async {
    final gesture = await tester.startGesture(tester.getCenter(finder));
    await tester.pump(_longPressHold);
    return gesture;
  }

  testWidgets('shows day headers newest first with unknown dates last', (
    tester,
  ) async {
    await pumpGallery(tester);

    final headers = [
      find.text('Sunday, June 14, 2026'),
      find.text('Saturday, June 13, 2026'),
      find.text('Unknown date'),
    ];
    for (final header in headers) {
      expect(header, findsOneWidget);
    }
    final tops = headers.map((header) => tester.getTopLeft(header).dy);
    expect(tops, orderedEquals([...tops]..sort()));
    expect(
      tester.getTopLeft(headers[1]).dy,
      greaterThan(tester.getBottomLeft(tile(6)).dy),
    );
  });

  testWidgets('selects and deselects a whole day', (tester) async {
    await pumpGallery(tester);

    await tester.tap(find.byTooltip('Select day').at(1));
    await tester.pump();
    expect(selectedTiles(tester), [7, 8, 9]);
    expect(find.text('3 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Select day').first);
    await tester.pump();
    expect(selectedTiles(tester), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);

    await tester.tap(find.byTooltip('Deselect day').at(1));
    await tester.pump();
    expect(selectedTiles(tester), [0, 1, 2, 3, 4, 5, 6]);
  });

  testWidgets('long-press and drag select a range across rows and days', (
    tester,
  ) async {
    await pumpGallery(tester);

    final gesture = await longPressAt(tester, tile(1));
    expect(selectedTiles(tester), [1]);

    await gesture.moveTo(tester.getCenter(tile(6)));
    await tester.pump();
    expect(selectedTiles(tester), [1, 2, 3, 4, 5, 6]);

    await gesture.moveTo(tester.getCenter(tile(8)));
    await tester.pump();
    expect(selectedTiles(tester), [1, 2, 3, 4, 5, 6, 7, 8]);

    await gesture.moveTo(tester.getCenter(tile(3)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(selectedTiles(tester), [1, 2, 3]);
    expect(find.text('3 selected'), findsOneWidget);
  });

  testWidgets('long-press on the preview button starts a range', (
    tester,
  ) async {
    await pumpGallery(tester);
    final preview = find.descendant(
      of: tile(1),
      matching: find.bySemanticsLabel('Preview'),
    );

    final gesture = await longPressAt(tester, preview);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(selectedTiles(tester), [1]);
    expect(find.byType(PreviewScreen), findsNothing);
  });

  testWidgets('long-press and drag on a selected shot deselect the range', (
    tester,
  ) async {
    await pumpGallery(tester);
    await tester.tap(find.byTooltip('Select day').first);
    await tester.pump();

    final gesture = await longPressAt(tester, tile(2));
    await gesture.moveTo(tester.getCenter(tile(4)));
    await gesture.up();
    await tester.pump();

    expect(selectedTiles(tester), [0, 1, 5, 6]);
  });

  testWidgets('dragging at the edge scrolls and keeps selecting', (
    tester,
  ) async {
    await pumpGallery(tester, tall: false);
    final grid = find.byType(GalleryGrid);

    final gesture = await longPressAt(tester, tile(0));
    await gesture.moveTo(
      Offset(tester.getCenter(tile(0)).dx, tester.getBottomLeft(grid).dy - 1),
    );
    for (var i = 0; i < _autoScrollTicks; i++) {
      await tester.pump(GalleryGrid.autoScrollInterval);
    }
    await gesture.up();
    await tester.pump();

    expect(find.text('${objects.length} selected'), findsOneWidget);
  });

  testWidgets('a tap opens the preview while nothing is selected', (
    tester,
  ) async {
    await pumpGallery(tester);

    await tester.tap(tile(2));
    await tester.pumpAndSettle();

    expect(find.byType(PreviewScreen), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('IMG_0002')),
      findsOneWidget,
    );
  });

  testWidgets('a tap toggles while photos are selected', (tester) async {
    await pumpGallery(tester);

    await tester.longPress(tile(0));
    await tester.pump();
    await tester.tap(tile(2));
    await tester.pump();
    expect(selectedTiles(tester), [0, 2]);

    await tester.tap(tile(0));
    await tester.pump();
    expect(selectedTiles(tester), [2]);
    expect(find.byType(PreviewScreen), findsNothing);
  });
}
