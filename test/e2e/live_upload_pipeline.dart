import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/live/ingest_coordinator.dart';
import 'package:shutterlink/feature/live/live_ingestor.dart';
import 'package:shutterlink/ptpip/ptpip.dart';
import 'package:shutterlink/upload/backend_factory.dart';
import 'package:shutterlink/upload/destination.dart';
import 'package:shutterlink/upload/upload_queue.dart';

import '../ptpip/fake_camera.dart';
import '../upload/support/dropping_proxy.dart';
import '../upload/support/immich_test_server.dart';
import '../upload/support/s3_test_server.dart';
import '../upload/support/sshd_fixture.dart';
import '../upload/support/webdav_test_server.dart';
import '../upload/upload_fakes.dart';

const _shotHandle = 0x30;
const _shotName = 'IMG_0100.JPG';
const _shotDay = '2026-11-13';
const _shotSize = 200000;
const _dropAfterBytes = 20000;
const _maxUploadLatency = Duration(seconds: 5);
const _waitTimeout = Duration(seconds: 30);
const _waitStep = Duration(milliseconds: 20);

/// Long enough for several production event polls and a folder rescan.
const _quietPeriod = Duration(seconds: 6);

/// A storage server as the pipeline sees it: files by [pathOf] relative to
/// the destination's base path.
abstract class Remote {
  Destination get destination;

  /// Where a file named [name] captured on [day] lands.
  String pathOf(String day, String name);

  DestinationSecrets get secrets;

  int get port;

  Map<String, Uint8List> files();

  void put(String path, Uint8List bytes);

  Future<void> close();
}

class WebDavRemote implements Remote {
  WebDavRemote(this._server);

  static const _root = 'dav/Photos';

  static Future<WebDavRemote> start() async =>
      WebDavRemote(await WebDavTestServer.start(collections: [_root]));

  final WebDavTestServer _server;

  @override
  Destination get destination => Destination(
    type: DestinationType.webdav,
    endpoint: 'http://dav.test:${_server.port}/dav/',
    basePath: 'Photos',
    username: 'alice',
  );

  @override
  String pathOf(String day, String name) => '$day/$name';

  @override
  DestinationSecrets get secrets =>
      const DestinationSecrets(password: 'secret');

  @override
  int get port => _server.port;

  @override
  Map<String, Uint8List> files() => {
    for (final MapEntry(:key, :value) in _server.files.entries)
      p.posix.relative(key, from: _root): value,
  };

  @override
  void put(String path, Uint8List bytes) {
    _server.collections.add(p.posix.dirname('$_root/$path'));
    _server.files['$_root/$path'] = bytes;
  }

  @override
  Future<void> close() => _server.close();
}

class S3Remote implements Remote {
  S3Remote(this._server);

  static const _bucket = 'photos';
  static const _prefix = 'camera';

  static Future<S3Remote> start() async => S3Remote(await S3TestServer.start());

  final S3TestServer _server;

  @override
  Destination get destination => Destination(
    type: DestinationType.s3,
    endpoint: 'http://s3.test:${_server.port}',
    region: 'eu-central-1',
    bucket: _bucket,
    basePath: _prefix,
    username: 'AKIDTEST',
    pathStyle: true,
  );

  @override
  String pathOf(String day, String name) => '$day/$name';

  @override
  DestinationSecrets get secrets =>
      const DestinationSecrets(password: 'test-secret');

  @override
  int get port => _server.port;

  @override
  Map<String, Uint8List> files() => {
    for (final MapEntry(:key, :value) in _server.buckets[_bucket]!.entries)
      p.posix.relative(key, from: _prefix): value.bytes,
  };

  @override
  void put(String path, Uint8List bytes) =>
      _server.buckets[_bucket]!['$_prefix/$path'] = S3Object(bytes, {});

  @override
  Future<void> close() => _server.close();
}

class SftpRemote implements Remote {
  SftpRemote(this._sshd, this._fingerprint);

  static Future<SftpRemote> start() async {
    final sshd = await SshdFixture.start();
    return SftpRemote(sshd, await sshd.hostKeyFingerprint());
  }

  final SshdFixture _sshd;
  final String _fingerprint;

  String get _base => p.join(_sshd.dataDir, 'photos');

  @override
  Destination get destination => Destination(
    type: DestinationType.sftp,
    endpoint: '127.0.0.1:${_sshd.port}',
    basePath: _base,
    username: _sshd.username,
  );

  @override
  String pathOf(String day, String name) => '$day/$name';

  @override
  DestinationSecrets get secrets => DestinationSecrets(
    privateKey: _sshd.clientPrivateKey,
    hostKeyPin: _fingerprint,
  );

  @override
  int get port => _sshd.port;

  @override
  Map<String, Uint8List> files() {
    final base = Directory(_base);
    if (!base.existsSync()) return {};
    return {
      for (final file in base.listSync(recursive: true).whereType<File>())
        p.relative(file.path, from: _base): file.readAsBytesSync(),
    };
  }

  @override
  void put(String path, Uint8List bytes) => (File(
    p.join(_base, path),
  )..parent.createSync(recursive: true)).writeAsBytesSync(bytes);

  @override
  Future<void> close() => _sshd.stop();
}

/// Immich has no folders, so files are keyed by their name alone.
class ImmichRemote implements Remote {
  ImmichRemote(this._server);

  static Future<ImmichRemote> start() async =>
      ImmichRemote(await ImmichTestServer.start());

  final ImmichTestServer _server;

  @override
  Destination get destination => Destination(
    type: DestinationType.immich,
    endpoint: 'http://immich.test:${_server.port}',
  );

  @override
  String pathOf(String day, String name) => name;

  @override
  DestinationSecrets get secrets =>
      DestinationSecrets(password: _server.apiKey);

  @override
  int get port => _server.port;

  @override
  Map<String, Uint8List> files() => {
    for (final asset in _server.assets.values)
      asset.fields['filename']!: asset.bytes,
  };

  @override
  void put(String path, Uint8List bytes) {
    final id = 'existing-${_server.assets.length}';
    _server.assets[sha1.convert(bytes).toString()] = ImmichAsset(id, bytes, {
      'filename': p.posix.basename(path),
    }, p.posix.basename(path));
  }

  @override
  Future<void> close() => _server.close();
}

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(_waitTimeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting');
    await Future<void>.delayed(_waitStep);
  }
}

/// Live pipeline: FakeCamera → production 1 s event poll → LiveIngestor →
/// UploadQueue → dropping proxy → [startRemote]'s server. [namedFiles] is
/// false for servers that key files by content rather than name.
void pipelineTests(
  Future<Remote> Function() startRemote, {
  bool namedFiles = true,
}) {
  final shot = FakeObject(
    handle: _shotHandle,
    format: PtpObjectFormat.exifJpeg,
    filename: _shotName,
    parent: FakeCamera.folderHandle,
    captureDate: '20261113T101010',
    content: patternBytes(_shotSize, seed: _shotHandle),
  );
  late Remote remote;
  String shotPath() => remote.pathOf(_shotDay, _shotName);
  late Directory root;
  late FakeCamera camera;
  late PtpIpCameraClient client;
  late DownloadHistoryRepository history;
  late IngestCoordinator coordinator;
  late Duration skipped;
  late List<UploadQueue> queues;
  late List<LiveIngestor> ingestors;
  DroppingProxy? proxy;

  setUp(() async {
    remote = await startRemote();
    root = await Directory.systemTemp.createTemp('live_e2e');
    camera = FakeCamera(pairedGuids: [pairedGuid]);
    await camera.start();
    client = await connectTo(
      camera,
      eventPollInterval: PtpIpCameraClient.defaultEventPollInterval,
    );
    history = DownloadHistoryRepository(
      File(p.join(root.path, DownloadHistoryRepository.fileName)),
    );
    coordinator = IngestCoordinator();
    skipped = Duration.zero;
    queues = [];
    ingestors = [];
    proxy = null;
  });

  tearDown(() async {
    for (final ingestor in ingestors) {
      await ingestor.close();
    }
    for (final queue in queues) {
      await queue.close();
    }
    await client.close();
    await camera.stop();
    await proxy?.close();
    await remote.close();
    await root.delete(recursive: true);
  });

  /// Backoff delays pass at once on the queue's clock, unless [holdRetries].
  Future<UploadQueue> startQueue({
    int drops = 0,
    bool holdRetries = false,
  }) async {
    final dropping = proxy ??= await DroppingProxy.start(
      remote.port,
      dropAfterBytes: _dropAfterBytes,
      dropFirst: drops,
    );
    final queue = UploadQueue(
      repository: UploadQueueRepository.inDirectory(root),
      stagingDirectory: Directory(
        p.join(root.path, UploadQueue.stagingDirectoryName),
      ),
      mediaSaver: FakeMediaSaver(),
      backendFactory: (destination, {required allowMetered}) async =>
          createBackend(
            destination,
            remote.secrets,
            connector: dropping.connect,
          ),
      destination: remote.destination,
      clock: () => DateTime.now().add(skipped),
      timerFactory: (delay, wake) {
        if (holdRetries) return Timer(delay, wake);
        skipped += delay;
        return Timer(Duration.zero, wake);
      },
    );
    queues.add(queue);
    await queue.start();
    return queue;
  }

  Future<LiveIngestor> startLive(UploadQueue queue) async {
    final ingestor = LiveIngestor(
      client: client,
      format: DownloadFormat.jpeg,
      baseline: await LiveIngestor.baselineOf(client),
      history: history,
      queue: queue,
      coordinator: coordinator,
    );
    ingestors.add(ingestor);
    return ingestor..start();
  }

  bool hasTempFiles() =>
      remote.files().keys.any((path) => p.basename(path).contains('.tmp-'));

  test('AC2/AC3/AC7: a new shot is uploaded within 5 s, once', () async {
    await startLive(await startQueue());

    final stopwatch = Stopwatch()..start();
    camera.addObject(shot);
    await _eventually(() => remote.files().containsKey(shotPath()));
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThanOrEqualTo(_maxUploadLatency));
    expect(remote.files()[shotPath()], shot.content);

    final connections = proxy!.connections;
    camera.queueEventRecord(objectAddedRecord(shot));
    await Future<void>.delayed(_quietPeriod);

    expect(proxy!.connections, connections);
    expect(remote.files().keys, [shotPath()]);
  });

  test('AC6: a cut upload is retried without leaving a temp file', () async {
    final queue = await startQueue(drops: 1);
    await startLive(queue);

    camera.addObject(shot);
    await _eventually(() => remote.files().containsKey(shotPath()));
    await queue.idle;

    expect(proxy!.drops, 1);
    expect(remote.files()[shotPath()], shot.content);
    expect(hasTempFiles(), isFalse);
  });

  test('AC5: a restart after a cut upload still completes it', () async {
    final first = await startQueue(drops: 1, holdRetries: true);
    final live = await startLive(first);
    camera.addObject(shot);
    await _eventually(
      () => first.snapshot.items.any((item) => item.attempts == 1),
    );
    expect(remote.files().containsKey(shotPath()), isFalse);
    await live.close();
    await first.close();

    final restarted = await startQueue();
    await _eventually(() => remote.files().containsKey(shotPath()));
    await restarted.idle;

    expect(remote.files()[shotPath()], shot.content);
    expect(hasTempFiles(), isFalse);
  });

  if (namedFiles) {
    test('C3: a different file under the same name moves to _1', () async {
      final other = Uint8List.fromList([1, 2, 3]);
      remote.put(shotPath(), other);
      await startLive(await startQueue());

      camera.addObject(shot);
      await _eventually(
        () => remote.files().containsKey('$_shotDay/IMG_0100_1.JPG'),
      );

      expect(remote.files()['$_shotDay/IMG_0100_1.JPG'], shot.content);
      expect(remote.files()[shotPath()], other);
    });
  } else {
    test('a file the server already has is not stored twice', () async {
      remote.put(shotPath(), shot.content);
      final queue = await startQueue();
      await startLive(queue);

      camera.addObject(shot);
      await _eventually(() => queue.snapshot.completed == 1);

      expect(remote.files(), {shotPath(): shot.content});
    });
  }
}
