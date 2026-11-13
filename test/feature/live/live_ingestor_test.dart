import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/download/download_cubit.dart';
import 'package:shutterlink/feature/download/download_state.dart';
import 'package:shutterlink/feature/gallery/photo_group.dart';
import 'package:shutterlink/feature/live/ingest_coordinator.dart';
import 'package:shutterlink/feature/live/live_ingestor.dart';
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/upload_queue.dart';

import '../../fakes/fake_camera_client.dart';
import '../../upload/upload_fakes.dart';

class _Source implements AddedObjectSource {
  final controller = StreamController<AddedObject>();

  @override
  Stream<AddedObject> get addedObjects => controller.stream;
}

/// Answers objectInfo from a script before falling back to the real objects.
class _ScriptedClient extends FakeCameraClient {
  _ScriptedClient(super.objects);

  final script = <Object?>[];
  int infoCalls = 0;

  @override
  Future<CameraObject?> objectInfo(int handle) async {
    infoCalls++;
    if (script.isEmpty) return super.objectInfo(handle);
    final next = script.removeAt(0);
    if (next is Exception) throw next;
    return next as CameraObject?;
  }
}

void main() {
  const destination = Destination(
    type: DestinationType.webdav,
    endpoint: 'https://a.example.com/dav',
  );
  final date = DateTime(2026, 11, 13, 10);
  final jpeg = cameraObject(1, 'IMG_0001.JPG', captureDate: date);
  final raw = cameraObject(2, 'IMG_0001.CR3', captureDate: date);
  final old = cameraObject(3, 'IMG_0000.JPG', captureDate: date);

  late Directory root;
  late FakeStorageServer server;
  late FakeMediaSaver media;
  late DownloadHistoryRepository history;
  late IngestCoordinator coordinator;
  late UploadQueue queue;
  late _Source source;
  late _ScriptedClient client;
  late List<LiveIngestor> ingestors;

  final cameraKey = cameraKeyOf(FakeCameraClient(const []).deviceInfo);
  String keyOf(CameraObject object) =>
      DownloadHistoryRepository.entryKey(cameraKey, object);

  LiveIngestor ingestor({
    DownloadFormat format = DownloadFormat.both,
    Set<String> baseline = const {},
  }) {
    final created = LiveIngestor(
      client: client,
      source: source,
      format: format,
      baseline: baseline,
      history: history,
      queue: queue,
      coordinator: coordinator,
      infoRetryDelay: Duration.zero,
    );
    ingestors.add(created);
    return created..start();
  }

  Future<void> settle() async {
    await pumpEventQueue();
    await queue.idle;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('live');
    server = FakeStorageServer();
    media = FakeMediaSaver();
    history = DownloadHistoryRepository(
      File(p.join(root.path, DownloadHistoryRepository.fileName)),
    );
    coordinator = IngestCoordinator();
    queue = UploadQueue(
      repository: UploadQueueRepository.inDirectory(root),
      stagingDirectory: Directory(p.join(root.path, 'staging')),
      mediaSaver: media,
      backendFactory: (_, {required allowMetered}) async => server.backend(),
      destination: destination,
    );
    await queue.start();
    source = _Source();
    client = _ScriptedClient([old, jpeg, raw]);
    ingestors = [];
  });

  tearDown(() async {
    for (final ingestor in ingestors) {
      await ingestor.close();
    }
    await settle();
    await queue.close();
    await root.delete(recursive: true);
  });

  test('a new shot is downloaded, saved, recorded and uploaded', () async {
    final live = ingestor();
    final ingested = live.ingested.first;

    source.controller.add(const AddedObject(1));

    expect(await ingested, jpeg);
    await settle();
    expect(server.files.keys, ['2026-11-13/IMG_0001.JPG']);
    expect(server.files.values.single, contentFor(jpeg));
    expect(media.published, hasLength(1));
    expect(await history.contains(cameraKey, jpeg), isTrue);
  });

  test('skips folders, the baseline, history, filtered kinds', () async {
    await history.record(cameraKey, [raw]);
    client.objects.add(cameraObject(4, 'IMG_0002.CR3'));
    ingestor(format: DownloadFormat.raw, baseline: {keyOf(old)});

    source.controller
      ..add(const AddedObject(9, format: AddedObject.associationFormat))
      ..add(const AddedObject(3))
      ..add(const AddedObject(1))
      ..add(const AddedObject(2))
      ..add(const AddedObject(99));
    await settle();

    expect(server.files, isEmpty);
    expect(client.requestedOffsets, isEmpty);
    expect(client.infoCalls, 4);
  });

  test('waits while the camera is still writing the file', () async {
    client.script.addAll([
      cameraObject(1, 'IMG_0001.JPG', size: 0, captureDate: date),
      const PtpResponseException(0x1008, 0x2019),
    ]);
    ingestor();

    source.controller.add(const AddedObject(1));
    await until(() => server.files.isNotEmpty);

    expect(client.infoCalls, 3);
  });

  test('gives up on unreadable objects until the catch-up', () async {
    client.script.addAll(
      List.filled(LiveIngestor.infoRetries + 1, Exception('busy')),
    );
    final live = ingestor(baseline: {keyOf(old)});

    source.controller.add(const AddedObject(1));
    await settle();
    expect(server.files, isEmpty);
    expect(client.infoCalls, LiveIngestor.infoRetries + 1);

    await live.catchUp();
    await until(() => server.files.length == 2);
    expect(server.files.keys.toSet(), {
      '2026-11-13/IMG_0001.JPG',
      '2026-11-13/IMG_0001.CR3',
    });
  });

  test('a disconnect while asking for the object stops retrying', () async {
    client.script.add(const CameraDisconnectedException());
    final live = ingestor(baseline: {keyOf(old), keyOf(raw)});

    source.controller.add(const AddedObject(1));
    await settle();
    expect(client.infoCalls, 1);

    await live.catchUp();
    await until(() => server.files.isNotEmpty);
    expect(server.files.keys, ['2026-11-13/IMG_0001.JPG']);
  });

  test('an interrupted download resumes in the catch-up', () async {
    LiveIngestor direct(CameraClient camera) {
      final created = LiveIngestor(
        client: camera,
        source: source,
        format: DownloadFormat.both,
        baseline: const {},
        history: history,
        queue: queue,
        coordinator: coordinator,
      );
      ingestors.add(created);
      return created;
    }

    final dropping = FakeCameraClient([jpeg], disconnectAfterChunks: 1);
    await direct(dropping).catchUp();
    expect(server.files, isEmpty);
    expect(await history.contains(cameraKey, jpeg), isFalse);

    final reconnected = FakeCameraClient([jpeg]);
    await direct(reconnected).catchUp();
    await settle();

    expect(reconnected.requestedOffsets[1], [fakeChunkSize]);
    expect(server.files.values.single, contentFor(jpeg));
  });

  test('baseline holds the entry keys on the card', () async {
    expect(await LiveIngestor.baselineOf(client), {
      keyOf(old),
      keyOf(jpeg),
      keyOf(raw),
    });
  });

  test('manual download and Live of the same shot run once', () async {
    client.chunkGate = Completer<void>();
    final saver = RecordingPhotoSaver();
    final cubit = DownloadCubit(
      saver: saver,
      workDirectory: Directory(p.join(root.path, 'work')),
      history: history,
      coordinator: coordinator,
      uploadQueue: queue,
    );
    ingestor(format: DownloadFormat.jpeg);
    source.controller.add(const AddedObject(1));
    await until(() => coordinator.isInFlight(keyOf(jpeg)));

    final manual = cubit.start(
      client,
      groupPhotos([jpeg]),
      DownloadFormat.jpeg,
    );
    await pumpEventQueue();
    client.chunkGate!.complete();
    client.chunkGate = null;
    await manual;
    await settle();

    expect(cubit.state.status, DownloadStatus.completed);
    expect(cubit.state.saved, hasLength(1));
    expect(client.requestedOffsets[1], [0]);
    expect(saver.saved, isEmpty);
    expect(media.published, hasLength(1));
    expect(server.files, hasLength(1));
    expect(server.tempWrites, hasLength(1));
    await cubit.close();
  });
}
