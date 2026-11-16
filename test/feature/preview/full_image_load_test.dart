import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/gallery/photo_group.dart';
import 'package:shutterlink/feature/preview/full_image_load.dart';

import '../../fakes/exif_jpeg.dart';
import '../../fakes/fake_camera_client.dart';

void main() {
  final jpeg = Uint8List.fromList([
    ...exifJpeg(orientation: 6),
    ...List.filled(headReadLength, 0),
  ]);
  final object = cameraObject(1, 'IMG_0001.JPG', size: jpeg.length);
  final group = groupPhotos([object]).single;

  FakeCameraClient camera() => FakeCameraClient([object])
    ..contentOverrides[1] = jpeg
    ..chunkSize = headReadLength;

  test('a full start during a head read goes on to the full image', () async {
    final client = camera();
    final gate = client.chunkGate = Completer<void>();
    final load = FullImageLoad(client, group);
    addTearDown(load.dispose);

    final head = load.start(orientationOnly: true);
    await pumpEventQueue();
    expect(load.loading, isFalse);
    expect(load.quarterTurns, 1);

    unawaited(load.start());
    expect(load.loading, isTrue);
    client.chunkGate = null;
    gate.complete();
    await head;

    expect(load.full, jpeg);
    expect(client.requestedOffsets[1], [0, headReadLength]);
  });

  test('a head read alone stops after the head', () async {
    final client = camera();
    final load = FullImageLoad(client, group);
    addTearDown(load.dispose);

    await load.start(orientationOnly: true);

    expect(load.quarterTurns, 1);
    expect(load.full, isNull);
    expect(client.downloadLengths[1], [headReadLength]);
  });

  test('a held load starts only once released', () async {
    final client = camera();
    final load = FullImageLoad(client, group);
    addTearDown(load.dispose);

    expect(load.handOver(), isEmpty);
    await load.start();
    await load.start(orientationOnly: true);
    expect(client.requestedOffsets, isEmpty);

    load.release();
    await load.start();
    expect(load.full, jpeg);
  });
}
