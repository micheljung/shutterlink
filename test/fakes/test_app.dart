import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
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
}

Future<AppDependencies> testDependencies(CameraConnector connector) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsRepository(prefs);
  return AppDependencies(
    settings: settings,
    identity: IdentityRepository(prefs),
    hostResolver: CameraHostResolver(settings, wifiGateway: () async => null),
    networkBinder: NoopNetworkBinder(),
    photoSaver: RecordingPhotoSaver(),
    connector: connector,
    thumbnailCache: MemoryThumbnailCache(),
    downloadDirectory: Directory(
      p.join(Directory.systemTemp.path, 'shutterlink_test_downloads'),
    ),
  );
}
