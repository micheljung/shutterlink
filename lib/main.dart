import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/camera_host_resolver.dart';
import 'data/destination_repository.dart';
import 'data/download_history.dart';
import 'data/identity_repository.dart';
import 'data/live_service.dart';
import 'data/network_binder.dart';
import 'data/network_status_feed.dart';
import 'data/photo_saver.dart';
import 'data/session_repository.dart';
import 'data/session_seen_store.dart';
import 'data/sessions_credentials.dart';
import 'data/sessions_prefetch.dart';
import 'data/sessions_upload_queue.dart';
import 'data/settings_repository.dart';
import 'data/upload_transport.dart';
import 'data/upload_tunnel.dart';
import 'feature/gallery/thumbnail_cache.dart';
import 'feature/live/ingest_coordinator.dart';
import 'feature/sessions/sessions_dependencies.dart';
import 'ptpip/ptpip_camera_client.dart';
import 'upload/backend_factory.dart';
import 'upload/media_saver.dart';
import 'upload/network_policy.dart';
import 'upload/platform_tcp_connector.dart';
import 'upload/upload_queue.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSize =
      ThumbnailCache.defaultMaxMemoryEntries;

  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsRepository(prefs);
  final cacheDirectory = await getApplicationCacheDirectory();
  final temporaryDirectory = await getTemporaryDirectory();
  final supportDirectory = await getApplicationSupportDirectory();
  final photoSaver = PlatformPhotoSaver();
  final destinations = DestinationRepository(prefs);
  final tcpConnector = platformTcpConnector();
  final networkStatus = NetworkStatusFeed(
    Platform.isAndroid
        ? const UploadTunnel().networkStatus()
        : const Stream.empty(),
    initial: Platform.isAndroid
        ? NetworkStatus.offline
        : const NetworkStatus.unrestricted(),
  );
  final uploadQueue = UploadQueue(
    repository: UploadQueueRepository.inDirectory(supportDirectory),
    stagingDirectory: Directory(
      p.join(supportDirectory.path, UploadQueue.stagingDirectoryName),
    ),
    mediaSaver: Platform.isAndroid
        ? const ChannelMediaSaver()
        : PhotoSaverMediaSaver(photoSaver),
    backendFactory: destinationBackendFactory(
      destinations.readSecrets,
      connector: tcpConnector,
    ),
    destination: destinations.destination,
    networkStatus: Platform.isAndroid ? networkStatus.statuses : null,
    initialNetwork: networkStatus.value,
  );
  await uploadQueue.start();
  destinations.changes.listen(uploadQueue.setDestination);
  AppLifecycleListener(onResume: () => unawaited(uploadQueue.resume()));
  final ingestCoordinator = IngestCoordinator();
  File supportFile(String name) => File(p.join(supportDirectory.path, name));
  final sessionsUploadDirectory = Directory(
    p.join(supportDirectory.path, SessionsDependencies.uploadDirectoryName),
  );
  final sessions = SessionsDependencies(
    repository: SessionRepository(supportFile(SessionRepository.fileName)),
    seen: SessionSeenStore(supportFile(SessionSeenStore.fileName)),
    queue: SessionsUploadQueue(
      supportFile(SessionsUploadQueue.fileName),
      uploadDirectory: sessionsUploadDirectory,
    ),
    credentials: SecureSessionsCredentials(settings),
    transport: TunnelTransport(networkStatus, connector: tcpConnector),
    settings: settings,
    ingestCoordinator: ingestCoordinator,
    prefetch: SessionsPrefetch(
      Directory(p.join(supportDirectory.path, SessionsPrefetch.directoryName)),
    ),
    stagedFileOf: uploadQueue.stagingFileFor,
    uploadDirectory: sessionsUploadDirectory,
  );
  unawaited(sessions.sweepPrefetch());

  runApp(
    ShutterlinkApp(
      dependencies: AppDependencies(
        settings: settings,
        identity: IdentityRepository(prefs),
        hostResolver: CameraHostResolver(settings),
        networkBinder: PlatformNetworkBinder(),
        photoSaver: photoSaver,
        connector: (host, identity) =>
            PtpIpCameraClient.connect(host: host, identity: identity),
        thumbnailCache: ThumbnailCache(
          directory: Directory(p.join(cacheDirectory.path, 'thumbnails')),
        ),
        downloadDirectory: Directory(
          p.join(temporaryDirectory.path, 'downloads'),
        ),
        downloadHistory: DownloadHistoryRepository(
          supportFile(DownloadHistoryRepository.fileName),
        ),
        sessions: sessions,
        destinations: destinations,
        uploadQueue: uploadQueue,
        ingestCoordinator: ingestCoordinator,
        liveService: PlatformLiveService(),
        connectionTester: (destination, secrets) =>
            testDestination(destination, secrets, connector: tcpConnector),
      ),
    ),
  );
}
