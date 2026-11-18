import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:shutterlink/feature/sessions/session_qr_sheet.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _OfflineHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw const SocketException('offline');
}

class _RecordingLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  _RecordingLauncher({this.opens = true});

  final bool opens;
  final launched = <(String, PreferredLaunchMode)>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add((url, options.mode));
    return opens;
  }
}

List<bool> modulesOf(QrImage image) => [
  for (var row = 0; row < image.moduleCount; row++)
    for (var column = 0; column < image.moduleCount; column++)
      image.isDark(row, column),
];

void main() {
  const code = 'apple-banana-cherry-delta';

  test('the page URL keeps a server path prefix', () {
    expect(
      sessionPageUrl('https://example.com/photos/', code).toString(),
      'https://example.com/photos/s/$code',
    );
  });

  testWidgets('shows the QR and the code without network access', (
    tester,
  ) async {
    await HttpOverrides.runZoned(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SessionQrSheet(
              serverUrl: 'https://photos.example.com',
              code: code,
            ),
          ),
        ),
      );
    }, createHttpClient: _OfflineHttpOverrides().createHttpClient);

    final shown = tester.widget<PrettyQrView>(find.byType(PrettyQrView));
    expect(
      // ignore: invalid_use_of_protected_member
      modulesOf(shown.qrImage),
      modulesOf(
        QrImage(
          QrCode.fromData(
            data: 'https://photos.example.com/s/$code',
            errorCorrectLevel: QrErrorCorrectLevel.L,
          ),
        ),
      ),
    );
    expect(find.text(code), findsOneWidget);
    expect(find.text('https://photos.example.com/s/$code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('the page address', () {
    const url = 'https://photos.example.com/s/$code';

    Future<void> pumpCode(WidgetTester tester) => tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SessionQrCode(
              serverUrl: 'https://photos.example.com',
              code: code,
            ),
          ),
        ),
      ),
    );

    testWidgets('is one line that is copied when tapped', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpCode(tester);

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.maxLines, 1);
      expect(field.readOnly, isTrue);

      await tester.tap(find.text(url));
      await tester.pump();
      expect(copied, [url]);
      expect(find.byIcon(Icons.check), findsOneWidget);

      await tester.pump(SessionUrlField.copiedFor);
      expect(find.byIcon(Icons.copy), findsOneWidget);

      await tester.tap(find.byIcon(Icons.copy));
      await tester.pump();
      expect(copied, [url, url]);
      await tester.pump(SessionUrlField.copiedFor);
    });

    testWidgets('opens in the browser with the only button', (tester) async {
      final previous = UrlLauncherPlatform.instance;
      final launcher = UrlLauncherPlatform.instance = _RecordingLauncher();
      addTearDown(() => UrlLauncherPlatform.instance = previous);
      await pumpCode(tester);

      expect(
        find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
        findsOneWidget,
      );
      await tester.tap(find.text(SessionQrCode.openLabel));
      await tester.pump();

      expect(launcher.launched, [
        (url, PreferredLaunchMode.externalApplication),
      ]);
    });

    testWidgets('says so when no browser opens it', (tester) async {
      final previous = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = _RecordingLauncher(opens: false);
      addTearDown(() => UrlLauncherPlatform.instance = previous);
      await pumpCode(tester);

      await tester.tap(find.text(SessionQrCode.openLabel));
      await tester.pump();

      expect(find.text(SessionQrCode.openFailedText), findsOneWidget);
    });
  });
}
