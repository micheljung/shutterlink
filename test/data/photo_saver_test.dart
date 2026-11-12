import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/data/photo_saver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const galChannel = MethodChannel('gal');
  const shortTimeout = Duration(milliseconds: 50);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory root;
  late Directory documents;
  late List<MethodCall> galCalls;
  late List<MethodCall> rawCalls;
  late bool galHasAccess;
  late Future<Object?> Function(MethodCall call) rawHandler;

  Future<File> tempFile(String name) async {
    final file = File('${root.path}/$name');
    await file.writeAsBytes([1, 2, 3]);
    return file;
  }

  PlatformPhotoSaver saver(SaverPlatform platform) => PlatformPhotoSaver(
    platform: platform,
    documentsDirectory: () async => documents,
    timeout: shortTimeout,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('saver');
    documents = await Directory('${root.path}/documents').create();
    galCalls = [];
    rawCalls = [];
    galHasAccess = true;
    rawHandler = (_) async => null;
    messenger.setMockMethodCallHandler(galChannel, (call) async {
      galCalls.add(call);
      return switch (call.method) {
        'hasAccess' => galHasAccess,
        'requestAccess' => true,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(PlatformPhotoSaver.channel, (call) {
      rawCalls.add(call);
      return rawHandler(call);
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(galChannel, null);
    messenger.setMockMethodCallHandler(PlatformPhotoSaver.channel, null);
    await root.delete(recursive: true);
  });

  test('Android JPEG goes to the Shutterlink album through gal', () async {
    final jpeg = await tempFile('IMG_0001.JPG');

    await saver(SaverPlatform.android).save(jpeg: jpeg);

    final put = galCalls.singleWhere((call) => call.method == 'putImage');
    expect(put.arguments, {
      'path': jpeg.path,
      'album': PlatformPhotoSaver.album,
    });
    expect(rawCalls, isEmpty);
    expect(jpeg.existsSync(), isFalse);
  });

  test('Android RAW requests storage access, then saves natively', () async {
    galHasAccess = false;
    final raw = await tempFile('IMG_0001.CR3');

    await saver(SaverPlatform.android).save(raw: raw);

    expect(galCalls.map((call) => call.method), ['hasAccess', 'requestAccess']);
    expect(rawCalls.single.method, PlatformPhotoSaver.saveRawMethod);
    expect(rawCalls.single.arguments, {'raw': raw.path});
    expect(raw.existsSync(), isFalse);
  });

  test('a hanging native save times out and cleans up', () async {
    rawHandler = (_) => Completer<Object?>().future;
    final raw = await tempFile('IMG_0001.CR3');

    await expectLater(
      saver(SaverPlatform.android).save(raw: raw),
      throwsA(isA<TimeoutException>()),
    );
    expect(raw.existsSync(), isFalse);
  });

  test('iOS pairs JPEG and RAW in one native call', () async {
    final jpeg = await tempFile('IMG_0001.JPG');
    final raw = await tempFile('IMG_0001.CR3');

    await saver(SaverPlatform.ios).save(jpeg: jpeg, raw: raw);

    expect(rawCalls.single.arguments, {'raw': raw.path, 'jpeg': jpeg.path});
    expect(galCalls, isEmpty);
  });

  test('iOS native failure falls back without overwriting', () async {
    rawHandler = (_) async => throw PlatformException(code: 'save_failed');
    final existing = File('${documents.path}/IMG_0001.CR3');
    await existing.writeAsBytes([9]);
    await File('${documents.path}/IMG_0001-1.CR3').writeAsBytes([8]);
    final jpeg = await tempFile('IMG_0001.JPG');
    final raw = await tempFile('IMG_0001.CR3');

    await saver(SaverPlatform.ios).save(jpeg: jpeg, raw: raw);

    expect(existing.readAsBytesSync(), [9]);
    expect(File('${documents.path}/IMG_0001-2.CR3').readAsBytesSync(), [
      1,
      2,
      3,
    ]);
    final put = galCalls.singleWhere((call) => call.method == 'putImage');
    expect(put.arguments, {'path': jpeg.path, 'album': null});
    expect(jpeg.existsSync() || raw.existsSync(), isFalse);
  });
}
