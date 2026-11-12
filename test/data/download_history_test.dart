import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/ptpip/camera_client.dart';

import '../fakes/fake_camera_client.dart';

void main() {
  const camera = 'serial';
  late Directory root;
  late File file;

  final jpeg = cameraObject(1, 'IMG_0001.JPG', captureDate: DateTime(2026));
  final raw = cameraObject(2, 'IMG_0001.CR3', captureDate: DateTime(2026));
  final undated = cameraObject(3, 'IMG_0002.JPG');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('history');
    file = File(p.join(root.path, DownloadHistoryRepository.fileName));
  });

  tearDown(() => root.delete(recursive: true));

  test('records files per camera, name, date and kind', () async {
    final history = DownloadHistoryRepository(file);

    await history.record(camera, [jpeg]);

    expect(await history.contains(camera, jpeg), isTrue);
    expect(await history.contains(camera, raw), isFalse);
    expect(await history.contains('other', jpeg), isFalse);
    expect(
      await history.contains(
        camera,
        cameraObject(9, 'IMG_0001.JPG', captureDate: DateTime(2025)),
      ),
      isFalse,
    );
  });

  test('keys an undated file by name and kind', () async {
    final history = DownloadHistoryRepository(file);

    await history.record(camera, [undated]);

    expect(
      DownloadHistoryRepository.entryKey(camera, undated),
      'serial|IMG_0002.JPG||jpeg',
    );
    expect(
      await history.contains(camera, cameraObject(7, 'IMG_0002.JPG')),
      isTrue,
    );
  });

  test('clear forgets everything and notifies', () async {
    final history = DownloadHistoryRepository(file);
    final changes = history.changes.take(2).length;
    await history.record(camera, [jpeg, raw]);

    await history.clear();

    expect(await history.load(), isEmpty);
    expect(await changes, 2);
    expect(await DownloadHistoryRepository(file).load(), isEmpty);
  });

  test('persists across instances', () async {
    final first = DownloadHistoryRepository(file);
    await Future.wait([
      first.record(camera, [jpeg]),
      first.record(camera, [raw]),
    ]);

    final second = DownloadHistoryRepository(file);

    expect(await second.contains(camera, jpeg), isTrue);
    expect(await second.contains(camera, raw), isTrue);
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  for (final (description, content) in [
    ('malformed', '{not json'),
    ('not a list', '{"a": 1}'),
  ]) {
    test('a $description file loads as empty', () async {
      await file.writeAsString(content);
      final history = DownloadHistoryRepository(file);

      expect(await history.load(), isEmpty);

      await history.record(camera, [jpeg]);
      expect(
        await DownloadHistoryRepository(file).contains(camera, jpeg),
        isTrue,
      );
    });
  }

  test('camera key is the serial, else the model', () {
    CameraDeviceInfo info(String serial) => CameraDeviceInfo(
      manufacturer: 'Canon Inc.',
      model: 'Canon EOS R',
      deviceVersion: '1-0',
      serialNumber: serial,
      operationsSupported: const [],
    );

    expect(cameraKeyOf(info('42')), '42');
    expect(cameraKeyOf(info('')), 'Canon EOS R');
  });
}
