import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/ptpip/camera_client.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/network_policy.dart';
import 'package:shutterlink/upload/storage_backend.dart';
import 'package:shutterlink/upload/upload_item.dart';
import 'package:shutterlink/upload/upload_queue.dart';

import 'upload_fakes.dart';

const destination = Destination(
  type: DestinationType.webdav,
  endpoint: 'https://a.example.com/dav',
  username: 'me',
);
const otherDestination = Destination(
  type: DestinationType.sftp,
  endpoint: 'b.example.com:22',
  username: 'me',
);

const cameraAp = NetworkInfo(
  transport: NetworkTransport.wifi,
  validated: false,
  metered: false,
);
const cellular = NetworkInfo(
  transport: NetworkTransport.cellular,
  validated: true,
  metered: true,
);
const infraWifi = NetworkInfo(
  transport: NetworkTransport.wifi,
  validated: true,
  metered: false,
);

void main() {
  final captureDate = DateTime(2026, 11, 13, 10, 30);
  late Directory root;
  late Directory staging;
  late Map<String, FakeStorageServer> servers;
  late FakeMediaSaver media;
  late FakeTimers timers;
  late DateTime now;
  late List<UploadQueue> queues;

  FakeStorageServer server([Destination target = destination]) =>
      servers.putIfAbsent(target.fingerprint, FakeStorageServer.new);

  UploadQueueRepository repository() => UploadQueueRepository.inDirectory(root);

  UploadQueue newQueue({
    Destination? target = destination,
    Stream<NetworkStatus>? network,
    NetworkStatus initialNetwork = const NetworkStatus.unrestricted(),
  }) {
    final queue = UploadQueue(
      repository: repository(),
      stagingDirectory: staging,
      mediaSaver: media,
      backendFactory: (target, {required allowMetered}) async =>
          server(target).backend(allowMetered: allowMetered),
      destination: target,
      networkStatus: network,
      initialNetwork: initialNetwork,
      clock: () => now,
      timerFactory: timers.create,
      random: MidRandom(),
      uniqueId: () => 'u1',
    );
    queues.add(queue);
    return queue;
  }

  Future<UploadQueue> started({
    Destination? target = destination,
    Stream<NetworkStatus>? network,
    NetworkStatus initialNetwork = const NetworkStatus.unrestricted(),
  }) async {
    final queue = newQueue(
      target: target,
      network: network,
      initialNetwork: initialNetwork,
    );
    await queue.start();
    await queue.idle;
    return queue;
  }

  Uint8List bytesOf(String name) => Uint8List.fromList(utf8.encode(name));

  Future<File> photo(String name) async {
    final file = File(p.join(root.path, 'work', name));
    await file.parent.create(recursive: true);
    return file..writeAsBytesSync(bytesOf(name));
  }

  String idOf(String name) => '1|$name|2026-11-13T10:30:00.000|jpeg';

  Future<UploadItem> add(
    UploadQueue queue,
    String name, {
    CameraObjectKind kind = CameraObjectKind.jpeg,
  }) async => queue.add(
    id: idOf(name),
    file: await photo(name),
    filename: name,
    kind: kind,
    captureDate: captureDate,
  );

  /// Persists [item] as if a previous run crashed in its state.
  Future<UploadItem> persisted(
    String name, {
    UploadState state = UploadState.staged,
    String? pendingRef,
    String? mediaRef,
    String? remoteName,
    String? tempName,
    Destination target = destination,
  }) async {
    final file = File(
      newQueue(target: target).stagingFileFor(idOf(name), name).path,
    );
    await file.parent.create(recursive: true);
    file.writeAsBytesSync(bytesOf(name));
    final item = UploadItem(
      id: idOf(name),
      filename: name,
      kind: CameraObjectKind.jpeg,
      captureDay: '2026-11-13',
      size: bytesOf(name).length,
      sha256: sha256.convert(bytesOf(name)).toString(),
      localPath: file.path,
      destinationFingerprint: target.fingerprint,
      state: state,
      pendingRef: pendingRef,
      mediaRef: mediaRef,
      remoteName: remoteName,
      tempName: tempName,
    );
    final store = repository();
    await store.load();
    await store.put(item);
    return item;
  }

  Future<Map<String, UploadItem>> stored() async {
    final store = repository();
    await store.load();
    return store.items;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('queue');
    staging = Directory(p.join(root.path, UploadQueue.stagingDirectoryName));
    servers = {};
    media = FakeMediaSaver();
    timers = FakeTimers();
    now = DateTime.utc(2026, 11, 13, 9);
    queues = [];
  });

  tearDown(() async {
    for (final queue in queues) {
      await queue.close();
    }
    await root.delete(recursive: true);
  });

  test('saves to the gallery, uploads by capture day and forgets', () async {
    final queue = await started();

    final item = await add(queue, 'IMG_0001.JPG');
    expect(item.state, UploadState.savedToGallery);
    expect(media.published.single.path, item.localPath);
    await queue.idle;

    expect(server().files.keys, ['2026-11-13/IMG_0001.JPG']);
    expect(server().files.values.single, bytesOf('IMG_0001.JPG'));
    expect(server().hasTempFiles, isFalse);
    expect(media.published, hasLength(1), reason: 'local copy kept');
    expect(staging.listSync(), isEmpty);
    expect(await stored(), isEmpty);
    expect(queue.snapshot.completed, 1);
    expect(await queue.contains(idOf('IMG_0001.JPG')), isTrue);
  });

  test('persists items across restarts', () async {
    final offline = await started(initialNetwork: NetworkStatus.offline);
    await add(offline, 'IMG_0001.JPG');
    await offline.idle;
    expect(offline.snapshot.waiting.values, [WaitReason.network]);
    await offline.close();

    expect((await stored()).values.single.state, UploadState.savedToGallery);
    final online = await started();

    expect(server().files.keys, ['2026-11-13/IMG_0001.JPG']);
    expect(await online.contains(idOf('IMG_0001.JPG')), isTrue);
  });

  test('a corrupt queue file starts empty', () async {
    File(p.join(root.path, UploadQueueRepository.queueFileName))
        .writeAsStringSync('{');
    final queue = await started();
    expect(queue.snapshot.items, isEmpty);
  });

  group('crash recovery', () {
    test('staged → saves to the gallery, then uploads', () async {
      await persisted('IMG_0001.JPG');

      await started();

      expect(media.calls.first, 'begin IMG_0001.JPG');
      expect(media.published, hasLength(1));
      expect(server().files.keys, ['2026-11-13/IMG_0001.JPG']);
    });

    test('saving with a pending row → deletes it and saves again', () async {
      final pending = await media.beginSave(
        filename: 'IMG_0001.JPG',
        kind: CameraObjectKind.jpeg,
      );
      await persisted(
        'IMG_0001.JPG',
        state: UploadState.saving,
        pendingRef: pending,
      );
      media.calls.clear();

      await started();

      expect(media.calls.take(3), [
        'query $pending',
        'delete $pending',
        'begin IMG_0001.JPG',
      ]);
      expect(media.rows.keys, isNot(contains(pending)));
      expect(media.published, hasLength(1));
      expect(server().files, hasLength(1));
    });

    test('saving with a published row → no second insert', () async {
      final ref = await media.beginSave(
        filename: 'IMG_0001.JPG',
        kind: CameraObjectKind.jpeg,
      );
      await media.finishSave(ref, path: '/x', kind: CameraObjectKind.jpeg);
      await persisted(
        'IMG_0001.JPG',
        state: UploadState.saving,
        pendingRef: ref,
      );
      media.calls.clear();
      final queue = newQueue(initialNetwork: NetworkStatus.offline);
      await queue.start();
      await queue.idle;

      expect(media.calls, ['query $ref']);
      final item = queue.snapshot.items.single;
      expect(item.state, UploadState.savedToGallery);
      expect(item.mediaRef, ref);
      expect(item.pendingRef, isNull);
    });

    test('saving with a reclaimed row → saves again', () async {
      await persisted(
        'IMG_0001.JPG',
        state: UploadState.saving,
        pendingRef: 'content://media/gone',
      );

      await started();

      expect(media.calls.take(2), [
        'query content://media/gone',
        'begin IMG_0001.JPG',
      ]);
      expect(media.published, hasLength(1));
    });

    test('savedToGallery → uploads', () async {
      await persisted(
        'IMG_0001.JPG',
        state: UploadState.savedToGallery,
        mediaRef: 'content://media/1',
      );

      await started();

      expect(media.calls, isEmpty);
      expect(server().files.keys, ['2026-11-13/IMG_0001.JPG']);
    });

    test('uploading → resumes with the persisted names', () async {
      await persisted(
        'IMG_0001.JPG',
        state: UploadState.uploading,
        mediaRef: 'content://media/1',
        remoteName: 'IMG_0001_3.JPG',
        tempName: '.IMG_0001_3.JPG.tmp-old',
      );

      await started();

      expect(server().tempWrites, ['2026-11-13/.IMG_0001_3.JPG.tmp-old']);
      expect(server().files.keys, ['2026-11-13/IMG_0001_3.JPG']);
    });

    test('uploaded without keeping the local copy → deletes it', () async {
      const removing = Destination(
        type: DestinationType.webdav,
        endpoint: 'https://a.example.com/dav',
        username: 'me',
        keepLocalCopy: false,
      );
      media.rows['content://media/1'] = MediaRow(
        'IMG_0001.JPG',
        pending: false,
      );
      await persisted(
        'IMG_0001.JPG',
        state: UploadState.uploaded,
        mediaRef: 'content://media/1',
        target: removing,
      );

      await started(target: removing);

      expect(media.calls, ['delete content://media/1']);
      expect(media.rows, isEmpty);
      expect(await stored(), isEmpty);
      expect(server(removing).connections, isEmpty);
    });

    test('N3: a restart mid-upload reuses the temp name', () async {
      final crashed = Completer<void>();
      server().beforeCommit = (_) => crashed.future;
      final first = await started();
      await add(first, 'IMG_0001.JPG');
      await until(() => server().tempWrites.isNotEmpty);
      final persistedItem = (await stored()).values.single;
      expect(persistedItem.state, UploadState.uploading);
      expect(persistedItem.tempName, '.IMG_0001.JPG.tmp-u1');

      queues.remove(first);
      server().beforeCommit = null;
      final restarted = newQueue();
      await restarted.start();
      await restarted.idle;

      expect(server().tempWrites.toSet(), {'2026-11-13/.IMG_0001.JPG.tmp-u1'});
      expect(server().tempWrites, hasLength(2));
      expect(server().hasTempFiles, isFalse);
      expect(server().files.keys, ['2026-11-13/IMG_0001.JPG']);
      expect(await stored(), isEmpty);
    });

    test('drops staging folders no item refers to', () async {
      final orphan = File(p.join(staging.path, 'abc', 'IMG_9.JPG'));
      await orphan.parent.create(recursive: true);
      orphan.writeAsBytesSync([1]);
      final kept = await persisted(
        'IMG_0001.JPG',
        state: UploadState.savedToGallery,
      );

      await started(initialNetwork: NetworkStatus.offline);

      expect(orphan.parent.existsSync(), isFalse);
      expect(File(kept.localPath).existsSync(), isTrue);
    });
  });

  group('dedup', () {
    test('adding a queued id again changes nothing', () async {
      final queue = await started(initialNetwork: NetworkStatus.offline);
      final first = await add(queue, 'IMG_0001.JPG');
      final duplicate = await photo('IMG_0001.JPG');

      final second = await queue.add(
        id: first.id,
        file: duplicate,
        filename: 'IMG_0001.JPG',
        kind: CameraObjectKind.jpeg,
        captureDate: captureDate,
      );

      expect(second, first);
      expect(duplicate.existsSync(), isFalse);
      expect(media.published, hasLength(1));
    });

    test('an id uploaded before is saved locally but not sent', () async {
      final queue = await started();
      await add(queue, 'IMG_0001.JPG');
      await queue.idle;
      final connections = server().connections.length;

      await add(queue, 'IMG_0001.JPG');
      await queue.idle;

      expect(server().connections, hasLength(connections));
      expect(media.published, hasLength(2));
      expect(await stored(), isEmpty);
    });

    test('an identical remote file counts as uploaded', () async {
      server().files['2026-11-13/IMG_0001.JPG'] = bytesOf('IMG_0001.JPG');
      final queue = await started();

      await add(queue, 'IMG_0001.JPG');
      await queue.idle;

      expect(server().tempWrites, isEmpty);
      expect(server().files, hasLength(1));
    });
  });

  group('collisions', () {
    test('a different remote file moves the upload to _1', () async {
      server().files['2026-11-13/IMG_0001.JPG'] = Uint8List.fromList([9]);
      final queue = await started();

      await add(queue, 'IMG_0001.JPG');
      await queue.idle;

      expect(server().files['2026-11-13/IMG_0001.JPG'], [9]);
      expect(
        server().files['2026-11-13/IMG_0001_1.JPG'],
        bytesOf('IMG_0001.JPG'),
      );
    });

    test('a name taken during the upload moves on to the next', () async {
      server().beforeCommit = (request) async {
        server().beforeCommit = null;
        server().files['${request.target}'] = Uint8List.fromList([9]);
      };
      final queue = await started();

      await add(queue, 'IMG_0001.JPG');
      await queue.idle;

      expect(server().files.keys.toSet(), {
        '2026-11-13/IMG_0001.JPG',
        '2026-11-13/IMG_0001_1.JPG',
      });
      expect(server().tempWrites.toSet(), {'2026-11-13/.IMG_0001.JPG.tmp-u1'});
    });

    test('an identical file appearing during the upload is accepted', () async {
      server().beforeCommit = (request) async {
        server().beforeCommit = null;
        server().files['${request.target}'] = bytesOf('IMG_0001.JPG');
      };
      final queue = await started();

      await add(queue, 'IMG_0001.JPG');
      await queue.idle;

      expect(server().files.keys, ['2026-11-13/IMG_0001.JPG']);
      expect(await stored(), isEmpty);
    });

    test('a name taken and the next one identical is accepted', () async {
      server().beforeCommit = (request) async {
        server().beforeCommit = null;
        server().files['${request.target}'] = Uint8List.fromList([9]);
        server().files['2026-11-13/IMG_0001_1.JPG'] = bytesOf('IMG_0001.JPG');
      };
      final queue = await started();

      await add(queue, 'IMG_0001.JPG');
      await queue.idle;

      expect(server().files, hasLength(2));
      expect(await stored(), isEmpty);
    });
  });

  group('backoff', () {
    test('delays grow from 5 s, cap at 15 min and jitter ±20 %', () {
      expect(backoffDelay(1, 0.5), const Duration(seconds: 5));
      expect(backoffDelay(2, 0.5), const Duration(seconds: 10));
      expect(backoffDelay(8, 0.5), const Duration(seconds: 640));
      expect(backoffDelay(9, 0.5), maxBackoff);
      expect(backoffDelay(500, 0.5), maxBackoff);
      expect(backoffDelay(1, 0), const Duration(seconds: 4));
      expect(backoffDelay(1, 1), const Duration(seconds: 6));
    });

    test('retries on the fake clock until the upload succeeds', () async {
      server().failUploads = 2;
      final queue = await started();
      await add(queue, 'IMG_0001.JPG');
      await queue.idle;

      var item = queue.snapshot.items.single;
      expect(item.attempts, 1);
      expect(item.lastError, 'Connection reset');
      expect(item.nextAttemptAt, now.add(const Duration(seconds: 5)));
      expect(queue.snapshot.waiting.values, [WaitReason.backoff]);
      expect(timers.active!.delay, const Duration(seconds: 5));

      now = now.add(const Duration(seconds: 5));
      timers.active!.fire();
      await queue.idle;
      item = queue.snapshot.items.single;
      expect(item.attempts, 2);
      expect(timers.active!.delay, const Duration(seconds: 10));

      now = now.add(const Duration(seconds: 10));
      timers.active!.fire();
      await queue.idle;
      expect(queue.snapshot.items, isEmpty);
      expect(server().files, hasLength(1));
    });

    test('an early timer does not retry before the deadline', () async {
      server().failUploads = 1;
      final queue = await started();
      await add(queue, 'IMG_0001.JPG');
      await queue.idle;

      timers.active!.fire();
      await queue.idle;

      expect(queue.snapshot.items.single.attempts, 1);
      expect(timers.active!.delay, const Duration(seconds: 5));
    });

    test('no usable network waits without counting an attempt', () async {
      server()
        ..failUploads = 1
        ..failure = const NoNetworkException();
      final queue = await started();
      await add(queue, 'IMG_0001.JPG');
      await queue.idle;

      final item = queue.snapshot.items.single;
      expect(item.attempts, 0);
      expect(item.state, UploadState.savedToGallery);
      expect(item.nextAttemptAt, now.add(noNetworkRecheck));
      expect(queue.snapshot.waiting.values, [WaitReason.network]);

      now = now.add(noNetworkRecheck);
      timers.active!.fire();
      await queue.idle;
      expect(server().files, hasLength(1));
    });

    test('permanent errors wait for the user', () async {
      server()
        ..failUploads = 1
        ..failure = const StorageException('Wrong password', retryable: false);
      final queue = await started();
      await add(queue, 'IMG_0001.JPG');
      await queue.idle;

      expect(queue.snapshot.waiting.values, [WaitReason.attention]);
      expect(timers.active, isNull);

      await queue.retryNow();
      await queue.idle;
      expect(server().files, hasLength(1));
    });

    test('gaining a network retries without waiting', () async {
      final network = StreamController<NetworkStatus>();
      server().failUploads = 1;
      final queue = await started(
        network: network.stream,
        initialNetwork: const NetworkStatus([cameraAp, cellular]),
      );
      await queue.setDestination(
        const Destination(
          type: DestinationType.webdav,
          endpoint: 'https://a.example.com/dav',
          username: 'me',
          policy: MobileDataPolicy.all,
        ),
      );
      await add(queue, 'IMG_0001.JPG');
      await queue.idle;
      expect(queue.snapshot.waiting.values, [WaitReason.backoff]);

      final uploaded = queue.snapshots.firstWhere((s) => s.completed == 1);
      network.add(const NetworkStatus([infraWifi]));
      await uploaded;

      expect(server().files, hasLength(1));
      await network.close();
    });

    test('a failed gallery save is retried with backoff', () async {
      await persisted('IMG_0001.JPG');
      media.failFinish = 1;
      final queue = await started();

      expect(queue.snapshot.items.single.state, UploadState.saving);
      expect(queue.snapshot.waiting.values, [WaitReason.backoff]);

      now = now.add(const Duration(seconds: 5));
      timers.active!.fire();
      await queue.idle;
      expect(media.published, hasLength(1));
      expect(server().files, hasLength(1));
    });
  });

  test('policy jpeg over mobile data holds RAW until Wi-Fi', () async {
    const jpegOnly = Destination(
      type: DestinationType.webdav,
      endpoint: 'https://a.example.com/dav',
      username: 'me',
      policy: MobileDataPolicy.jpeg,
    );
    final network = StreamController<NetworkStatus>();
    final queue = await started(
      target: jpegOnly,
      network: network.stream,
      initialNetwork: const NetworkStatus([cameraAp]),
    );
    await add(queue, 'IMG_0001.JPG');
    await add(queue, 'IMG_0001.CR3', kind: CameraObjectKind.raw);
    await queue.idle;
    expect(queue.snapshot.waiting.values.toSet(), {WaitReason.network});

    network.add(const NetworkStatus([cameraAp, cellular]));
    await pumpEventQueue();
    await queue.idle;
    expect(server(jpegOnly).files.keys, ['2026-11-13/IMG_0001.JPG']);
    expect(server(jpegOnly).connections, [true]);
    expect(queue.snapshot.waiting.values, [WaitReason.unmeteredNetwork]);

    network.add(const NetworkStatus([infraWifi]));
    await pumpEventQueue();
    await queue.idle;
    expect(server(jpegOnly).files, hasLength(2));
    expect(server(jpegOnly).connections, [true, false]);
    await network.close();
  });

  group('destination', () {
    test('without one, nothing can be added and items wait', () async {
      await persisted('IMG_0001.JPG', state: UploadState.savedToGallery);
      final queue = await started(target: null);

      expect(queue.snapshot.waiting.values, [WaitReason.noDestination]);
      expect(await queue.contains('x'), isFalse);
      await expectLater(add(queue, 'IMG_0002.JPG'), throwsStateError);
    });

    test('replacing it re-targets pending items', () async {
      await persisted(
        'IMG_0001.JPG',
        state: UploadState.uploading,
        remoteName: 'IMG_0001_1.JPG',
        tempName: '.IMG_0001_1.JPG.tmp-old',
      );
      final queue = await started(initialNetwork: NetworkStatus.offline);

      await queue.setDestination(otherDestination);

      final item = queue.snapshot.items.single;
      expect(item.destinationFingerprint, otherDestination.fingerprint);
      expect(item.remoteName, isNull);
      expect(item.tempName, isNull);
      expect(item.state, UploadState.savedToGallery);
    });

    test('replacing it mid-upload sends the photo to the new one', () async {
      final release = Completer<void>();
      server().beforeCommit = (_) => release.future;
      final queue = await started();
      await add(queue, 'IMG_0001.JPG');
      await until(() => server().tempWrites.isNotEmpty);

      await queue.setDestination(otherDestination);
      release.complete();
      await pumpEventQueue();
      await queue.idle;

      expect(server(otherDestination).files.keys, ['2026-11-13/IMG_0001.JPG']);
      expect(await queue.contains(idOf('IMG_0001.JPG')), isTrue);
      final history = jsonDecode(
        File(p.join(root.path, UploadQueueRepository.historyFileName))
            .readAsStringSync(),
      );
      expect(history, [
        UploadQueueRepository.uploadedKey(
          otherDestination.fingerprint,
          idOf('IMG_0001.JPG'),
        ),
      ]);
    });

    test('a restart with a new destination re-targets too', () async {
      await persisted('IMG_0001.JPG', state: UploadState.savedToGallery);

      await started(target: otherDestination);

      expect(server(otherDestination).files, hasLength(1));
      expect(server().connections, isEmpty);
    });
  });

  group('local copy', () {
    const removing = Destination(
      type: DestinationType.webdav,
      endpoint: 'https://a.example.com/dav',
      username: 'me',
      keepLocalCopy: false,
    );

    test('is deleted only after the upload is confirmed', () async {
      final release = Completer<void>();
      server(removing).beforeCommit = (_) => release.future;
      final queue = await started(target: removing);
      await add(queue, 'IMG_0001.JPG');
      await until(() => server(removing).tempWrites.isNotEmpty);

      expect(media.published, hasLength(1));
      expect(media.calls.where((call) => call.startsWith('delete')), isEmpty);

      release.complete();
      await pumpEventQueue();
      await queue.idle;
      expect(server(removing).files, hasLength(1));
      expect(media.rows, isEmpty);
      expect(await stored(), isEmpty);
    });

    test('lost ownership keeps the copy until the user agrees', () async {
      media.ownershipLost.add('content://media/1');
      final queue = await started(target: removing);
      await add(queue, 'IMG_0001.JPG');
      await queue.idle;

      final kept = queue.snapshot.items.single;
      expect(kept.state, UploadState.localKept);
      expect(kept.deleteDenied, isTrue);
      expect(queue.snapshot.hasPendingUploads, isFalse);
      expect(media.published, hasLength(1));

      media.approveDelete = false;
      expect(await queue.removeKeptCopies(), 0);
      media.approveDelete = true;
      expect(await queue.removeKeptCopies(), 1);
      expect(media.rows, isEmpty);
      expect(queue.snapshot.items, isEmpty);
      expect(await queue.removeKeptCopies(), 0);
    });
  });

  test('a failed gallery save drops the item and its staging', () async {
    media.failFinish = 1;
    final queue = await started();

    await expectLater(
      add(queue, 'IMG_0001.JPG'),
      throwsA(isA<FileSystemException>()),
    );

    expect(await stored(), isEmpty);
    expect(staging.listSync(), isEmpty);
    expect(await queue.contains(idOf('IMG_0001.JPG')), isFalse);
  });

  test('files already in staging are not moved', () async {
    final queue = await started(initialNetwork: NetworkStatus.offline);
    final file = queue.stagingFileFor(idOf('IMG_0001.JPG'), 'IMG_0001.JPG');
    await file.parent.create(recursive: true);
    file.writeAsBytesSync(bytesOf('IMG_0001.JPG'));

    final item = await queue.add(
      id: idOf('IMG_0001.JPG'),
      file: file,
      filename: 'IMG_0001.JPG',
      kind: CameraObjectKind.jpeg,
      captureDate: null,
    );

    expect(item.localPath, file.path);
    expect(item.captureDay, '2026-11-13');
    expect(item.sha256, sha256.convert(bytesOf('IMG_0001.JPG')).toString());
  });

  test('reports upload progress', () async {
    final release = Completer<void>();
    server().beforeCommit = (_) => release.future;
    final queue = await started();
    final snapshots = <UploadQueueSnapshot>[];
    final subscription = queue.snapshots.listen(snapshots.add);

    await add(queue, 'IMG_0001.JPG');
    await until(() => server().tempWrites.isNotEmpty);
    expect(queue.snapshot.activeId, idOf('IMG_0001.JPG'));
    expect(queue.snapshot.sentBytes, bytesOf('IMG_0001.JPG').length);
    expect(queue.snapshot.hasPendingUploads, isTrue);

    release.complete();
    await pumpEventQueue();
    await queue.idle;
    expect(queue.snapshot.activeId, isNull);
    expect(snapshots, isNotEmpty);
    await subscription.cancel();
  });
}
