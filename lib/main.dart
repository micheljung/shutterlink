import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/camera_host_resolver.dart';
import 'data/download_history.dart';
import 'data/identity_repository.dart';
import 'data/network_binder.dart';
import 'data/photo_saver.dart';
import 'data/settings_repository.dart';
import 'feature/gallery/thumbnail_cache.dart';
import 'ptpip/ptpip_camera_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSize =
      ThumbnailCache.defaultMaxMemoryEntries;

  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsRepository(prefs);
  final cacheDirectory = await getApplicationCacheDirectory();
  final temporaryDirectory = await getTemporaryDirectory();
  final supportDirectory = await getApplicationSupportDirectory();

  runApp(
    ShutterlinkApp(
      dependencies: AppDependencies(
        settings: settings,
        identity: IdentityRepository(prefs),
        hostResolver: CameraHostResolver(settings),
        networkBinder: PlatformNetworkBinder(),
        photoSaver: PlatformPhotoSaver(),
        connector: (host, identity) =>
            PtpIpCameraClient.connect(host: host, identity: identity),
        thumbnailCache: ThumbnailCache(
          directory: Directory(p.join(cacheDirectory.path, 'thumbnails')),
        ),
        downloadDirectory: Directory(
          p.join(temporaryDirectory.path, 'downloads'),
        ),
        downloadHistory: DownloadHistoryRepository(
          File(
            p.join(supportDirectory.path, DownloadHistoryRepository.fileName),
          ),
        ),
      ),
    ),
  );
}
