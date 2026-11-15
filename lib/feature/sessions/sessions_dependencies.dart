import 'dart:io';

import 'package:clock/clock.dart';

import '../../data/download_history.dart';
import '../../data/session_repository.dart';
import '../../data/session_seen_store.dart';
import '../../data/sessions_credentials.dart';
import '../../data/sessions_upload_queue.dart';
import '../../data/settings_repository.dart';
import '../../data/upload_transport.dart';
import '../../data/upload_worker.dart';
import '../../ptpip/camera_client.dart';
import '../live/ingest_coordinator.dart';
import 'clock_sync_cubit.dart';
import 'session_collector.dart';

class SessionsDependencies {
  SessionsDependencies({
    required this.repository,
    required this.seen,
    required this.queue,
    required this.credentials,
    required this.transport,
    required this.settings,
    required this.uploadDirectory,
    required this.ingestCoordinator,
    this.stagedFileOf,
    this.clock = const Clock(),
  });

  static const uploadDirectoryName = 'sessions_upload';

  final SessionRepository repository;
  final SessionSeenStore seen;
  final SessionsUploadQueue queue;
  final SessionsCredentials credentials;
  final UploadTransport transport;
  final SettingsRepository settings;
  final Directory uploadDirectory;

  /// Shared with auto-upload so a file is never taken off the camera by
  /// both at once.
  final IngestCoordinator ingestCoordinator;
  final StagedFileOf? stagedFileOf;
  final Clock clock;

  UploadWorker createWorker() => UploadWorker(
    queue: queue,
    transport: transport,
    sessions: repository,
    settings: settings,
    credentials: credentials,
    clock: clock,
  );

  ClockSyncCubit createClockSync(CameraClient client) => ClockSyncCubit(
    client: client,
    cameraKey: cameraKeyOf(client.deviceInfo),
    sessions: repository,
    seen: seen,
    clock: clock,
  );

  /// [baseline] is the newest folder's handles at attach; new shots are
  /// looked for among the others.
  SessionCollector createCollector(
    CameraClient client,
    ClockSyncCubit clockSync, {
    required Set<int> baseline,
  }) => SessionCollector(
    client: client,
    cameraKey: cameraKeyOf(client.deviceInfo),
    clockSync: clockSync,
    sessions: repository,
    seen: seen,
    queue: queue,
    uploadDirectory: uploadDirectory,
    baseline: baseline,
    coordinator: ingestCoordinator,
    stagedFileOf: stagedFileOf,
    clock: clock,
  );
}
