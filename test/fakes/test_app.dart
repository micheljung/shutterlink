import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/destination_repository.dart';
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/live_service.dart';
import 'package:shutterlink/data/network_binder.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';
import 'package:shutterlink/feature/live/ingest_coordinator.dart';
import 'package:shutterlink/upload/backend_factory.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/media_saver.dart';
import 'package:shutterlink/upload/upload_queue.dart';

import 'fake_camera_client.dart';

class NoopNetworkBinder implements NetworkBinder {
  @override
  Future<String?> acquireBinding(
    String owner, {
    bool holdNetwork = false,
  }) async => null;

  @override
  Future<void> releaseBinding(String owner) async {}

  @override
  void transferBinding(String from, String to) {}

  @override
  Stream<void> get bindingLost => const Stream.empty();

  @override
  Future<void> acquireMulticastLock() async {}

  @override
  Future<void> releaseMulticastLock() async {}
}

/// The upload half of [AppDependencies]. The queue is not started, so it
/// reports an empty snapshot and touches no files.
({
  DestinationRepository destinations,
  UploadQueue uploadQueue,
  IngestCoordinator ingestCoordinator,
  LiveService liveService,
})
testUploadDependencies(SharedPreferences prefs, Directory root) {
  FlutterSecureStorage.setMockInitialValues({});
  final destinations = DestinationRepository(prefs);
  return (
    destinations: destinations,
    uploadQueue: UploadQueue(
      repository: UploadQueueRepository.inDirectory(root),
      stagingDirectory: Directory(
        p.join(root.path, UploadQueue.stagingDirectoryName),
      ),
      mediaSaver: PhotoSaverMediaSaver(RecordingPhotoSaver()),
      backendFactory: destinationBackendFactory(destinations.readSecrets),
      destination: destinations.destination,
    ),
    ingestCoordinator: IngestCoordinator(),
    liveService: PlatformLiveService(isAndroid: false),
  );
}

Future<void> noConnectionTest(
  Destination destination,
  DestinationSecrets secrets,
) async {}

Future<AppDependencies> testDependencies(CameraConnector connector) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsRepository(prefs);
  final historyDirectory = Directory.systemTemp.createTempSync(
    'shutterlink_test_history',
  );
  addTearDown(() => historyDirectory.deleteSync(recursive: true));
  final downloadDirectory = Directory.systemTemp.createTempSync(
    'shutterlink_test_downloads',
  );
  addTearDown(() {
    if (downloadDirectory.existsSync()) {
      downloadDirectory.deleteSync(recursive: true);
    }
  });
  final upload = testUploadDependencies(prefs, historyDirectory);
  return AppDependencies(
    settings: settings,
    identity: IdentityRepository(prefs),
    hostResolver: CameraHostResolver(settings, wifiGateway: () async => null),
    networkBinder: NoopNetworkBinder(),
    photoSaver: RecordingPhotoSaver(),
    connector: connector,
    thumbnailCache: MemoryThumbnailCache(),
    downloadDirectory: downloadDirectory,
    downloadHistory: DownloadHistoryRepository(
      File(p.join(historyDirectory.path, DownloadHistoryRepository.fileName)),
    ),
    destinations: upload.destinations,
    uploadQueue: upload.uploadQueue,
    ingestCoordinator: upload.ingestCoordinator,
    liveService: upload.liveService,
    connectionTester: noConnectionTest,
  );
}
