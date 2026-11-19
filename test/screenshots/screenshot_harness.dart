import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shutterlink/app.dart';
import 'package:shutterlink/brand/brand_theme.dart';
import 'package:shutterlink/data/camera_host_resolver.dart';
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/identity_repository.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/connect/connect_screen.dart';
import 'package:shutterlink/feature/gallery/thumbnail_cache.dart';
import 'package:shutterlink/feature/mode/mode_back_button.dart';
import 'package:shutterlink/feature/mode/mode_picker_screen.dart';
import 'package:shutterlink/feature/mode/operating_mode.dart';
import 'package:shutterlink/feature/sessions/session_code.dart';
import 'package:shutterlink/feature/settings/settings_cards.dart';
import 'package:shutterlink/feature/settings/settings_screen.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/backend_factory.dart';
import 'package:shutterlink/upload/network_policy.dart';
import 'package:shutterlink/upload/provider_preset.dart';

import '../fakes/fake_camera_client.dart';
import '../fakes/fake_sessions_credentials.dart';
import '../fakes/test_app.dart';

const outputDirectory = String.fromEnvironment(
  'SCREENSHOTS_DIR',
  defaultValue: 'docs/screenshots',
);
const brightness = bool.fromEnvironment('SCREENSHOTS_LIGHT')
    ? Brightness.light
    : Brightness.dark;
const _profile = String.fromEnvironment('SCREENSHOTS_PROFILE');
const _playProfile = 'play';
const logicalSize = _profile == _playProfile ? Size(360, 640) : Size(390, 844);
const pixelRatio = 3.0;
const thumbnailSize = 320;
const downloadPollInterval = Duration(milliseconds: 5);
const maxDownloadPolls = 2000;
// Material's Roboto lacks "→"; only Linux typography falls back to DejaVu.
const arrowFallbackFont = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf';
const brandFonts = 'assets/fonts';
final platform = TargetPlatformVariant.only(TargetPlatform.linux);
const settleDuration = Duration(seconds: 1);
const settingsScrollStep = 200.0;

const newShotCount = 3;

const modePollInterval = Duration(milliseconds: 5);
const maxModePolls = 4000;

Future<void> enterMode(WidgetTester tester, OperatingMode mode) async {
  await tester.tap(find.text(ConnectScreen.connectLabel));
  await pumpUntilFound(tester, find.text(mode.label));
  await tester.ensureVisible(find.text(mode.label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(mode.label));
}

Future<void> leaveMode(WidgetTester tester) async {
  await tester.tap(find.byTooltip(ModeBackButton.tooltip));
  await pumpUntilFound(tester, find.text(ModePickerScreen.title));
}

Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < maxModePolls && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(modePollInterval));
    await tester.pump();
  }
  expect(finder, findsWidgets);
  await tester.pump(settleDuration);
}

const sessionCodeSeed = 7;
const sessionsServerUrl = 'https://photos.example.com';
final screenshotDay = DateTime(2026, 6, 14);

/// Opens Settings scrolled so the [header] section starts at the top.
Future<void> openSettingsAt(WidgetTester tester, String header) async {
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  final section = find.widgetWithText(SettingsSectionHeader, header);
  await tester.scrollUntilVisible(
    section,
    settingsScrollStep,
    scrollable: find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.ensureVisible(section);
  await tester.pumpAndSettle();
}

Future<void> tapAndSettle(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

/// Hides the cursor and keyboard focus so captures are stable.
Future<void> settleWithoutFocus(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

final boundaryKey = GlobalKey();

Future<void> loadFonts() async {
  final flutterRoot =
      Platform.environment['FLUTTER_ROOT'] ??
      p.normalize(
        p.join(p.dirname(Platform.resolvedExecutable), '../../../..'),
      );
  final materialFonts = p.join(
    flutterRoot,
    'bin/cache/artifacts/material_fonts',
  );
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      if (File(path).existsSync()) {
        loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
      }
    }
    await loader.load();
  }

  await load('Roboto', [
    for (final weight in ['Light', 'Regular', 'Medium', 'Bold'])
      p.join(materialFonts, 'Roboto-$weight.ttf'),
  ]);
  await load('MaterialIcons', [
    p.join(materialFonts, 'MaterialIcons-Regular.otf'),
  ]);
  await load('DejaVu Sans', [arrowFallbackFont]);
  await load(BrandTheme.fontFamily, [
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold'])
      p.join(brandFonts, '${BrandTheme.fontFamily}-$weight.ttf'),
  ]);
}

Future<void> pumpApp(
  WidgetTester tester,
  FakeCameraClient client, {
  Iterable<String> downloaded = const [],
  bool configured = false,
  bool startUploadQueue = false,
}) async {
  tester.view
    ..physicalSize = logicalSize * pixelRatio
    ..devicePixelRatio = pixelRatio;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  final thumbnails = await tester.runAsync(renderThumbnails);
  if (client is ScreenshotCameraClient) client.serveJpegs(thumbnails!);
  SharedPreferences.setMockInitialValues({
    SettingsRepository.onboardingSeenKey: true,
    if (configured) ...{
      SettingsRepository.sessionsServerUrlKey: sessionsServerUrl,
    },
  });
  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsRepository(prefs);
  final workDirectory = Directory.systemTemp.createTempSync('shutterlink_');
  addTearDown(() => workDirectory.deleteSync(recursive: true));
  final history = DownloadHistoryRepository(
    File(p.join(workDirectory.path, DownloadHistoryRepository.fileName)),
  );
  final downloadedNames = downloaded.toSet();
  final binder = NoopNetworkBinder();
  await tester.runAsync(
    () => history.record(
      cameraKeyOf(client.deviceInfo),
      client.objects.where(
        (object) => downloadedNames.contains(
          p.basenameWithoutExtension(object.filename),
        ),
      ),
    ),
  );
  final upload = testUploadDependencies(prefs, workDirectory);
  if (configured) {
    await tester.runAsync(
      () => upload.destinations.save(
        ProviderPreset.nextcloud
            .build(
              const PresetInput(
                server: 'cloud.example.com',
                basePath: 'Photos',
                username: 'alice',
              ),
            )
            .withPolicy(MobileDataPolicy.jpeg, keepLocalCopy: true),
        const DestinationSecrets(password: 'app-password'),
        preset: ProviderPreset.nextcloud,
      ),
    );
  }
  if (startUploadQueue) {
    await tester.runAsync(upload.uploadQueue.start);
    addTearDown(() => tester.runAsync(upload.uploadQueue.close));
  }
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: ShutterlinkApp(
        dependencies: AppDependencies(
          claimsUsbVendor: (_) => false,
          settings: settings,
          identity: IdentityRepository(prefs),
          hostResolver: CameraHostResolver(
            settings,
            wifiGateway: () async => null,
          ),
          networkBinder: binder,
          photoSaver: RecordingPhotoSaver(),
          connector: (_) async => client,
          thumbnailCache: PrerenderedThumbnails(thumbnails!),
          downloadDirectory: workDirectory,
          downloadHistory: history,
          destinations: upload.destinations,
          uploadQueue: upload.uploadQueue,
          ingestCoordinator: upload.ingestCoordinator,
          liveService: upload.liveService,
          connectionTester: noConnectionTest,
          sessions: testSessionsDependencies(
            settings,
            workDirectory,
            upload.ingestCoordinator,
            credentials: FakeSessionsCredentials(configured ? 'token' : null),
            codes: SessionCodeGenerator(random: Random(sessionCodeSeed)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> connect(WidgetTester tester) async {
  await connectAndBrowse(tester);
  await precacheImages(tester);
}

Future<void> precacheImages(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      await precacheImage((element.widget as Image).image, element);
    }
  });
  await tester.pumpAndSettle();
}

Future<void> capture(WidgetTester tester, String name) async {
  debugDisableShadows = false;
  try {
    await tester.pump();
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final png = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    final file = File(p.join(outputDirectory, '$name.png'));
    await tester.runAsync(() async {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!);
    });
  } finally {
    debugDisableShadows = true;
  }
}

const newestDayCount = 5;

final photos = [
  ('IMG_4821', {CameraObjectKind.jpeg, CameraObjectKind.raw}),
  ('IMG_4820', {CameraObjectKind.jpeg}),
  ('IMG_4819', {CameraObjectKind.jpeg, CameraObjectKind.raw}),
  ('IMG_4818', {CameraObjectKind.raw}),
  ('IMG_4817', {CameraObjectKind.jpeg}),
  ('IMG_4816', {CameraObjectKind.jpeg, CameraObjectKind.raw}),
  ('IMG_4815', {CameraObjectKind.jpeg}),
  ('IMG_4814', {CameraObjectKind.jpeg, CameraObjectKind.raw}),
  ('IMG_4813', {CameraObjectKind.jpeg}),
  ('IMG_4812', {CameraObjectKind.raw}),
  ('IMG_4811', {CameraObjectKind.jpeg, CameraObjectKind.raw}),
  ('IMG_4810', {CameraObjectKind.jpeg}),
];

class ScreenshotCameraClient extends FakeCameraClient {
  ScreenshotCameraClient({this.stall = false}) : super(_objects());

  static const _fileSize = 8;
  static const _stalledFileSize = 20;
  static const _stalledFraction = 0.6;

  final bool stall;
  final stalled = Completer<void>();

  static List<CameraObject> _objects() {
    final start = DateTime(2026, 6, 14, 19, 42);
    var handle = 0;
    return [
      for (final (index, (name, kinds)) in photos.indexed)
        for (final kind in kinds)
          cameraObject(
            ++handle,
            '$name.${kind == CameraObjectKind.jpeg ? 'JPG' : 'CR3'}',
            size: '$name.JPG' == _stallName ? _stalledFileSize : _fileSize,
            captureDate: start.subtract(
              Duration(
                days: index < newestDayCount ? 0 : 1,
                minutes: index * 3,
              ),
            ),
          ),
    ];
  }

  static const _stallName = 'IMG_4819.JPG';

  /// Makes each JPEG the rendered picture, so the preview's full-size load
  /// shows it. A stalling client keeps its tiny files.
  void serveJpegs(Map<String, Uint8List> pictures) {
    if (stall) return;
    for (final (index, object) in objects.indexed) {
      final picture = pictures[p.basenameWithoutExtension(object.filename)];
      if (object.kind != CameraObjectKind.jpeg || picture == null) continue;
      objects[index] = CameraObject(
        handle: object.handle,
        storageId: object.storageId,
        filename: object.filename,
        size: picture.length,
        captureDate: object.captureDate,
        kind: object.kind,
      );
      contentOverrides[object.handle] = picture;
    }
  }

  @override
  Future<void> download(
    CameraObject object,
    ChunkWriter write, {
    int offset = 0,
    int? length,
    TransferProgress? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (!stall || object.filename != _stallName) {
      return super.download(
        object,
        write,
        offset: offset,
        length: length,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    }
    final content = contentFor(object);
    final end = (content.length * _stalledFraction).round();
    await write(Uint8List.sublistView(content, offset, end));
    onProgress?.call(end, content.length);
    stalled.complete();
    await Completer<void>().future;
  }
}

class PrerenderedThumbnails with MemoryTurns implements ThumbnailCache {
  PrerenderedThumbnails(this._bytes);

  final Map<String, Uint8List> _bytes;

  @override
  Directory get directory => Directory.systemTemp;

  @override
  int get maxMemoryEntries => _bytes.length;

  @override
  int get memoryEntryCount => _bytes.length;

  @override
  Uint8List? peek(CameraObject object) =>
      _bytes[p.basenameWithoutExtension(object.filename)];

  @override
  Future<Uint8List?> get(CameraObject object, ThumbnailFetcher fetch) async =>
      peek(object);
}

typedef Scene = ({
  List<Color> sky,
  Color sun,
  double sunX,
  double sunY,
  List<Color> ridges,
  Color? water,
});

const scenes = <Scene>[
  (
    sky: [Color(0xFFFF9A62), Color(0xFFFFD9A0)],
    sun: Color(0xFFFFF4D6),
    sunX: 0.7,
    sunY: 0.55,
    ridges: [Color(0xFFB0587A), Color(0xFF6E3263), Color(0xFF3A1C47)],
    water: null,
  ),
  (
    sky: [Color(0xFF6FB6F0), Color(0xFFD4ECFF)],
    sun: Color(0xFFFFFFFF),
    sunX: 0.25,
    sunY: 0.25,
    ridges: [Color(0xFF9DB7CF), Color(0xFF5E7F9E), Color(0xFF2F4A63)],
    water: Color(0xFF4A86B8),
  ),
  (
    sky: [Color(0xFF1B2A4E), Color(0xFF5B4C8A)],
    sun: Color(0xFFF4F1E1),
    sunX: 0.75,
    sunY: 0.22,
    ridges: [Color(0xFF3D3A6B), Color(0xFF272650), Color(0xFF14142E)],
    water: null,
  ),
  (
    sky: [Color(0xFF8FD3C8), Color(0xFFF1F7D6)],
    sun: Color(0xFFFFFBE8),
    sunX: 0.5,
    sunY: 0.3,
    ridges: [Color(0xFF7FB77E), Color(0xFF3F8F5A), Color(0xFF1F5B3C)],
    water: null,
  ),
  (
    sky: [Color(0xFFF6B26B), Color(0xFFFCE6C2)],
    sun: Color(0xFFFFF0C8),
    sunX: 0.3,
    sunY: 0.5,
    ridges: [Color(0xFFD98E5B), Color(0xFFB4643B), Color(0xFF7C3F22)],
    water: null,
  ),
  (
    sky: [Color(0xFFE96D7E), Color(0xFFF9C38E)],
    sun: Color(0xFFFFE9B0),
    sunX: 0.5,
    sunY: 0.48,
    ridges: [Color(0xFF8E4A6E), Color(0xFF55305A)],
    water: Color(0xFFB05A6E),
  ),
  (
    sky: [Color(0xFFB9D7EA), Color(0xFFF2F6F8)],
    sun: Color(0xFFFFFFFF),
    sunX: 0.8,
    sunY: 0.2,
    ridges: [Color(0xFFE6EEF3), Color(0xFFA9BFCF), Color(0xFF5C7A90)],
    water: null,
  ),
  (
    sky: [Color(0xFF2E4057), Color(0xFFD1785C)],
    sun: Color(0xFFFFD2A1),
    sunX: 0.62,
    sunY: 0.6,
    ridges: [Color(0xFF4D4A63), Color(0xFF2A2B3F)],
    water: Color(0xFF3B4660),
  ),
];

Future<Map<String, Uint8List>> renderThumbnails() async => {
  for (final (index, (name, _)) in photos.indexed)
    name: await landscape(scenes[index % scenes.length], seed: index),
};

Future<Uint8List> landscape(Scene scene, {required int seed}) async {
  const size = thumbnailSize * 1.0;
  final random = Random(seed);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const bounds = Rect.fromLTWH(0, 0, size, size);
  canvas.drawRect(
    bounds,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(0, size),
        scene.sky,
      ),
  );
  final sun = Offset(scene.sunX * size, scene.sunY * size);
  canvas
    ..drawCircle(
      sun,
      size * 0.3,
      Paint()
        ..shader = ui.Gradient.radial(sun, size * 0.3, [
          scene.sun.withValues(alpha: 0.5),
          scene.sun.withValues(alpha: 0),
        ]),
    )
    ..drawCircle(sun, size * 0.07, Paint()..color = scene.sun);
  final horizon = scene.water == null ? size : size * 0.78;
  final layers = scene.ridges.length;
  for (final (layer, color) in scene.ridges.indexed) {
    final base = horizon - (layers - layer - 1) * size * 0.1 - size * 0.08;
    final amplitude = size * (0.16 - layer * 0.03);
    final frequency = 1.5 + random.nextDouble() * 2;
    final phase = random.nextDouble() * pi * 2;
    final path = Path()..moveTo(0, horizon);
    for (var x = 0.0; x <= size; x += 4) {
      final t = x / size;
      final y =
          base -
          amplitude *
              (0.6 * sin(t * frequency * pi + phase).abs() +
                  0.4 * sin(t * frequency * 3.1 * pi + phase * 2).abs());
      path.lineTo(x, y);
    }
    path
      ..lineTo(size, horizon)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }
  final water = scene.water;
  if (water != null) {
    canvas
      ..drawRect(
        Rect.fromLTRB(0, horizon, size, size),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, horizon),
            const Offset(0, size),
            [water, Color.lerp(water, Colors.black, 0.35)!],
          ),
      )
      ..drawRect(
        Rect.fromCenter(
          center: Offset(sun.dx, horizon + size * 0.08),
          width: size * 0.12,
          height: size * 0.14,
        ),
        Paint()..color = scene.sun.withValues(alpha: 0.35),
      );
  }
  final image = await recorder.endRecording().toImage(
    thumbnailSize,
    thumbnailSize,
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
