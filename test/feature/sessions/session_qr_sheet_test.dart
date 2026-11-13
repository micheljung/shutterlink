import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:shutterlink/feature/sessions/session_qr_sheet.dart';

class _OfflineHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw const SocketException('offline');
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
}
