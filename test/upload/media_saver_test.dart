import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/media_saver.dart';

import '../fakes/fake_camera_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall call) handler;

  setUp(() {
    calls = [];
    handler = (_) async => null;
    messenger.setMockMethodCallHandler(ChannelMediaSaver.channel, (call) {
      calls.add(call);
      return handler(call);
    });
  });

  tearDown(
    () => messenger.setMockMethodCallHandler(ChannelMediaSaver.channel, null),
  );

  group('ChannelMediaSaver', () {
    const saver = ChannelMediaSaver();

    test('saves in two calls', () async {
      handler = (call) async => 'content://media/1';

      final pending = await saver.beginSave(
        filename: 'IMG_0001.CR3',
        kind: CameraObjectKind.raw,
      );
      final published = await saver.finishSave(
        pending,
        path: '/staging/IMG_0001.CR3',
        kind: CameraObjectKind.raw,
      );

      expect(published, 'content://media/1');
      expect(calls.map((call) => call.method), ['beginSave', 'finishSave']);
      expect(calls.first.arguments, {'name': 'IMG_0001.CR3', 'kind': 'raw'});
      expect(calls.last.arguments, {
        'uri': 'content://media/1',
        'path': '/staging/IMG_0001.CR3',
        'kind': 'raw',
      });
    });

    test('maps row states', () async {
      for (final state in MediaRowState.values) {
        handler = (_) async => state.name;
        expect(await saver.query('content://media/1'), state);
      }
      expect(calls.last.arguments, {'uri': 'content://media/1'});
    });

    test('a missing result is an error', () async {
      await expectLater(
        saver.beginSave(filename: 'a.JPG', kind: CameraObjectKind.jpeg),
        throwsA(isA<PlatformException>()),
      );
    });

    test('lost ownership surfaces as its own exception', () async {
      handler = (_) async =>
          throw PlatformException(code: ChannelMediaSaver.ownershipLostCode);
      await expectLater(
        saver.delete('content://media/1'),
        throwsA(isA<MediaOwnershipLostException>()),
      );

      handler = (_) async => throw PlatformException(code: 'io');
      await expectLater(
        saver.delete('content://media/1'),
        throwsA(isA<PlatformException>()),
      );
    });

    test('deletes and batch-requests consent', () async {
      await saver.delete('content://media/1');
      handler = (_) async => true;
      expect(await saver.requestDelete(['content://media/1']), isTrue);
      handler = (_) async => null;
      expect(await saver.requestDelete(['content://media/2']), isFalse);

      expect(calls.map((call) => call.method), [
        'deleteMedia',
        'requestDelete',
        'requestDelete',
      ]);
      expect(calls[1].arguments, {
        'uris': ['content://media/1'],
      });
    });

    test('times out', () async {
      handler = (_) => Completer<Object?>().future;
      await expectLater(
        const ChannelMediaSaver(timeout: Duration(milliseconds: 10))
            .query('content://media/1'),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('PhotoSaverMediaSaver', () {
    late Directory root;

    setUp(() async => root = await Directory.systemTemp.createTemp('media'));
    tearDown(() => root.delete(recursive: true));

    test('saves through PhotoSaver and keeps the staged file', () async {
      final photos = RecordingPhotoSaver();
      final saver = PhotoSaverMediaSaver(photos);
      final file = File('${root.path}/IMG_0001.CR3')..writeAsBytesSync([1, 2]);

      final pending = await saver.beginSave(
        filename: 'IMG_0001.CR3',
        kind: CameraObjectKind.raw,
      );
      final ref = await saver.finishSave(
        pending,
        path: file.path,
        kind: CameraObjectKind.raw,
      );

      expect(ref, 'content://media/IMG_0001.CR3');
      expect(photos.saved.single, (jpeg: null, raw: 'IMG_0001.CR3'));
      expect(file.existsSync(), isTrue);
      expect(await saver.query(pending), MediaRowState.missing);
      await expectLater(
        saver.delete(ref),
        throwsA(isA<MediaOwnershipLostException>()),
      );
      expect(await saver.requestDelete([ref]), isFalse);
      expect(const MediaOwnershipLostException('x').toString(), contains('x'));
    });
  });
}
