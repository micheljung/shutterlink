import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/session_repository.dart';
import 'package:shutterlink/data/session_seen_store.dart';
import 'package:shutterlink/feature/sessions/clock_sync_banner.dart';
import 'package:shutterlink/feature/sessions/clock_sync_cubit.dart';
import 'package:shutterlink/feature/sessions/clock_sync_state.dart';

import '../../fakes/fake_camera_client.dart';

const _pollInterval = Duration(milliseconds: 5);
const _maxPolls = 400;

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < _maxPolls && !condition(); i++) {
    await tester.runAsync(() => Future<void>.delayed(_pollInterval));
    await tester.pump();
  }
  await tester.pump();
  expect(condition(), isTrue);
}

void main() {
  final t0 = DateTime.utc(2026, 11, 13, 10);
  late Directory root;
  late FakeCameraClient client;
  late SessionRepository sessions;
  late DateTime now;

  setUp(() {
    now = t0;
    root = Directory.systemTemp.createTempSync('clock_banner');
    client = FakeCameraClient([]);
    sessions = SessionRepository(
      File(p.join(root.path, SessionRepository.fileName)),
      clock: Clock(() => t0),
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<ClockSyncCubit> pumpBanner(WidgetTester tester) async {
    final cubit = ClockSyncCubit(
      client: client,
      cameraKey: cameraKeyOf(client.deviceInfo),
      sessions: sessions,
      seen: SessionSeenStore(
        File(p.join(root.path, SessionSeenStore.fileName)),
        clock: Clock(() => t0),
      ),
      clock: Clock(() => now),
      delay: (duration) async => now = now.add(duration),
    );
    addTearDown(cubit.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: ClockSyncBanner(client: client),
          ),
        ),
      ),
    );
    return cubit;
  }

  test('describes the offset direction', () {
    expect(describeOffset(const Duration(seconds: 90)), '90 s behind');
    expect(describeOffset(const Duration(seconds: -3)), '3 s ahead');
    expect(describeOffset(Duration.zero), 'in sync');
  });

  testWidgets('prompts and confirms an assumed offset', (tester) async {
    final cubit = await pumpBanner(tester);
    expect(find.text('Checking the camera clock…'), findsOneWidget);

    cubit.start();
    await pumpUntil(tester, () => cubit.state is ClockPrompt);
    expect(find.text('Sync clock'), findsOneWidget);

    await tester.tap(find.text('Skip'));
    await pumpUntil(tester, () => cubit.state is ClockResolved);
    expect(find.text('Camera clock in sync.'), findsOneWidget);
  });

  testWidgets('a sync shot shows progress and a retry', (tester) async {
    final cubit = await pumpBanner(tester);
    cubit.start();
    await pumpUntil(tester, () => cubit.state is ClockPrompt);

    await tester.tap(find.text('Sync clock'));
    await pumpUntil(
      tester,
      () => cubit.state == const ClockPrompt(failure: ClockSyncFailure.timeout),
    );
    expect(find.text('No sync photo found. Try again.'), findsOneWidget);
  });

  testWidgets('a marked photo is proposed with its thumbnail', (tester) async {
    final photo = cameraObject(
      7,
      'IMG_0007.JPG',
      captureDate: t0.subtract(const Duration(minutes: 1)),
    );
    client.objects.add(photo);
    await tester.runAsync(() => sessions.setMarkedAt(t0));
    final cubit = await pumpBanner(tester);
    cubit.start();
    await pumpUntil(tester, () => cubit.state is ClockAwaitingMarkedPhoto);
    await pumpUntil(tester, () => client.thumbnailRequests.contains(7));

    await tester.tap(find.text('Use this photo'));
    await pumpUntil(tester, () => cubit.state is ClockResolved);
    expect(find.text('Camera clock 60 s behind, corrected.'), findsOneWidget);
    expect(find.textContaining('60 s behind'), findsWidgets);
  });
}
