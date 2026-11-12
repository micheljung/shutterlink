import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/network_binder.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_cubit.dart';

import 'fake_camera_client.dart';

class NoopNetworkBinder implements NetworkBinder {
  @override
  Future<String?> bindToWifi() async => null;

  @override
  Future<void> unbind() async {}

  @override
  Future<void> acquireMulticastLock() async {}

  @override
  Future<void> releaseMulticastLock() async {}
}

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
  );
}
