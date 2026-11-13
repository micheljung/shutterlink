import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/gallery/gallery_screen.dart';
import 'package:shutterlink/feature/live/live_screen.dart';
import 'package:shutterlink/feature/sessions/clock_sync_banner.dart';

import '../../fakes/fake_camera_client.dart';
import '../../fakes/spy_sessions_dependencies.dart';
import '../../fakes/test_app.dart';
import 'sessions_app_test.dart' show pumpUntil;

const _cameraLag = Duration(seconds: 90);
const _liveOwner = 'live';
const _idleWhileLive = Duration(milliseconds: 200);
const _pollInterval = Duration(milliseconds: 5);
const _maxPolls = 400;

void main() {
  testWidgets('the collector idles while Live owns the camera and catches '
      'up once it is handed back', (tester) async {
    late SpySessionsDependencies sessions;
    final client = FakeCameraClient([])..cameraLag = _cameraLag;
    final dependencies = await testDependencies(
      (_, _) async => client,
      prefs: {
        SettingsRepository.sessionsEnabledKey: true,
        SettingsRepository.sessionsServerUrlKey: 'https://photos.example.com',
      },
      sessions: (settings, directory, coordinator) =>
          sessions = SpySessionsDependencies(
            settings,
            directory,
            coordinator: coordinator,
            token: 'token',
          ),
    );
    await tester.runAsync(() => sessions.repository.start());
    await tester.pumpWidget(ShutterlinkApp(dependencies: dependencies));
    await tester.pump();
    await pumpUntil(tester, () => find.text('Connect').evaluate().isNotEmpty);

    await tester.tap(find.text('Connect'));
    await pumpUntil(
      tester,
      () => find.textContaining('90 s behind').evaluate().isNotEmpty,
    );
    expect(sessions.collectors, 1);
    final connect = tester
        .element(find.byType(GalleryScreen))
        .read<ConnectCubit>();

    expect(connect.handOver(_liveOwner), client);
    await pumpUntil(
      tester,
      () => find.byType(LiveScreen).evaluate().isNotEmpty,
    );
    expect(find.byType(ClockSyncBanner), findsNothing);
    client.objects.add(
      cameraObject(
        1,
        'IMG_0001.JPG',
        captureDate: DateTime.now().subtract(_cameraLag),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(_idleWhileLive));
    await tester.pump();
    expect(client.requestedOffsets, isEmpty);
    expect(await tester.runAsync(sessions.queue.items), isEmpty);

    expect(connect.takeBack(client, owner: _liveOwner), isTrue);
    await pumpUntil(tester, () => sessions.collectors == 2);
    await pumpUntil(tester, () => client.requestedOffsets.isNotEmpty);
    var queued = await tester.runAsync(sessions.queue.items);
    for (var i = 0; i < _maxPolls && queued!.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(_pollInterval));
      await tester.pump();
      queued = await tester.runAsync(sessions.queue.items);
    }
    expect(queued, hasLength(1));
    expect(client.requestedOffsets.keys, [1]);
  });
}
