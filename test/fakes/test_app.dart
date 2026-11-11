import 'dart:io';

import 'package:eos_transfer/app.dart';
import 'package:eos_transfer/data/camera_host_resolver.dart';
import 'package:eos_transfer/data/identity_repository.dart';
import 'package:eos_transfer/data/network_binder.dart';
import 'package:eos_transfer/data/settings_repository.dart';
import 'package:eos_transfer/feature/connect/connect_cubit.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    downloadDirectory: Directory.systemTemp,
  );
}
