import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/session_repository.dart';
import 'package:shutterlink/data/session_seen_store.dart';
import 'package:shutterlink/data/sessions_prefetch.dart';
import 'package:shutterlink/data/sessions_upload_queue.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/data/upload_worker.dart';
import 'package:shutterlink/feature/live/ingest_coordinator.dart';
import 'package:shutterlink/feature/sessions/clock_sync_cubit.dart';
import 'package:shutterlink/feature/sessions/session_collector.dart';
import 'package:shutterlink/feature/sessions/sessions_dependencies.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import 'fake_sessions_credentials.dart';
import 'test_app.dart';

class SpySessionsDependencies extends SessionsDependencies {
  SpySessionsDependencies(
    SettingsRepository settings,
    Directory directory, {
    IngestCoordinator? coordinator,
    String? token,
  }) : this._(
         settings,
         directory,
         coordinator ?? IngestCoordinator(),
         FakeSessionsCredentials(token),
         [],
       );

  SpySessionsDependencies._(
    SettingsRepository settings,
    Directory directory,
    IngestCoordinator coordinator,
    this.fakeCredentials,
    this.requests,
  ) : super(
        repository: SessionRepository(
          File(p.join(directory.path, SessionRepository.fileName)),
        ),
        seen: SessionSeenStore(
          File(p.join(directory.path, SessionSeenStore.fileName)),
        ),
        queue: SessionsUploadQueue(
          File(p.join(directory.path, SessionsUploadQueue.fileName)),
        ),
        credentials: fakeCredentials,
        transport: testTransport(
          () => MockClient((request) async {
            requests.add(request);
            return http.Response('', HttpStatus.notFound);
          }),
        ),
        settings: settings,
        uploadDirectory: Directory(
          p.join(directory.path, SessionsDependencies.uploadDirectoryName),
        ),
        ingestCoordinator: coordinator,
        prefetch: SessionsPrefetch(
          Directory(p.join(directory.path, SessionsPrefetch.directoryName)),
        ),
      );

  final FakeSessionsCredentials fakeCredentials;
  final List<http.BaseRequest> requests;
  int workers = 0;
  int collectors = 0;
  int clockSyncs = 0;

  @override
  UploadWorker createWorker() {
    workers++;
    return super.createWorker();
  }

  @override
  ClockSyncCubit createClockSync(CameraClient client) {
    clockSyncs++;
    return super.createClockSync(client);
  }

  @override
  SessionCollector createCollector(
    CameraClient client,
    ClockSyncCubit clockSync, {
    required bool Function() isBusy,
  }) {
    collectors++;
    return super.createCollector(client, clockSync, isBusy: isBusy);
  }
}
