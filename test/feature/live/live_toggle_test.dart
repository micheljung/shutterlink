import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/feature/gallery/gallery_screen.dart';
import 'package:shutterlink/feature/live/live_screen.dart';
import 'package:shutterlink/feature/live/live_transfer_cubit.dart';
import 'package:shutterlink/feature/upload/upload_status_cubit.dart';
import 'package:shutterlink/upload/backend_factory.dart';
import 'package:shutterlink/upload/destination.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/test_app.dart';

class _MockLiveTransferCubit extends MockCubit<LiveTransferState>
    implements LiveTransferCubit {}

class _MockUploadStatusCubit extends MockCubit<UploadStatusState>
    implements UploadStatusCubit {}

/// Stopping closes the ingestor, which settles outside the fake clock.
const _stopDelay = Duration(milliseconds: 50);

void main() {
  final liveToggle = find.byTooltip('Start Live transfer');

  Future<void> pumpGallery(
    WidgetTester tester, {
    required bool destination,
  }) async {
    final client = FakeCameraClient([cameraObject(1, 'IMG_0001.JPG')]);
    final dependencies = await testDependencies((_, _) async => client);
    if (destination) {
      await dependencies.destinations.save(
        const Destination(
          type: DestinationType.webdav,
          endpoint: 'https://dav.example.com',
        ),
        const DestinationSecrets(password: 'secret'),
      );
    }
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
  }

  testWidgets('Live is hidden without an upload destination', (tester) async {
    await pumpGallery(tester, destination: false);

    expect(find.byType(GalleryScreen), findsOneWidget);
    expect(liveToggle, findsNothing);
    expect(find.byTooltip('Uploads'), findsNothing);
  });

  testWidgets('Live starts from the gallery and stops back to it', (
    tester,
  ) async {
    await pumpGallery(tester, destination: true);
    expect(find.byTooltip('Uploads'), findsOneWidget);

    await tester.tap(liveToggle);
    await tester.pumpAndSettle();
    expect(find.byType(LiveScreen), findsOneWidget);
    expect(find.text('Waiting for new photos'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.runAsync(() => Future<void>.delayed(_stopDelay));
    await tester.pumpAndSettle();
    expect(find.byType(GalleryScreen), findsOneWidget);
  });

  group('Live screen', () {
    late _MockLiveTransferCubit live;
    late _MockUploadStatusCubit uploads;

    setUp(() {
      live = _MockLiveTransferCubit();
      uploads = _MockUploadStatusCubit();
      when(() => uploads.state)
          .thenReturn(const UploadStatusState(pending: 2, completed: 3));
      when(live.stop).thenAnswer((_) async {});
    });

    Future<void> pump(WidgetTester tester, LiveTransferState state) async {
      when(() => live.state).thenReturn(state);
      await tester.pumpWidget(
        MaterialApp(
          home: MultiBlocProvider(
            providers: [
              BlocProvider<LiveTransferCubit>.value(value: live),
              BlocProvider<UploadStatusCubit>.value(value: uploads),
            ],
            child: const LiveScreen(),
          ),
        ),
      );
    }

    testWidgets('explains hidden notifications', (tester) async {
      await pump(
        tester,
        const LiveTransferring(ingested: 4, notificationsDenied: true),
      );

      expect(find.text(LiveScreen.notificationsHint), findsOneWidget);
      expect(find.text('4 new photos'), findsOneWidget);
      expect(find.text('2 waiting · 3 uploaded'), findsOneWidget);
    });

    testWidgets('shows an unreachable camera and stops', (tester) async {
      await pump(tester, const LiveReconnecting(unreachable: true));

      expect(find.text(LiveTransferCubit.unreachableText), findsOneWidget);
      expect(find.text(LiveScreen.notificationsHint), findsNothing);

      await tester.tap(find.text('Stop'));
      verify(live.stop).called(1);
    });
  });
}
