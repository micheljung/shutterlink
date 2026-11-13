import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/session_seen_store.dart';
import 'package:shutterlink/feature/sessions/sessions_config.dart';

import '../fakes/fake_camera_client.dart';

void main() {
  const camera = 'serial';
  const otherCamera = 'other';
  final t0 = DateTime.utc(2026, 11, 13, 10);
  const day = Duration(days: 1);
  final photo = SessionSeenStore.keyOf(
    camera,
    cameraObject(1, 'IMG_0001.JPG', captureDate: DateTime(2026, 11, 13)),
  );
  final sync = SessionSeenStore.keyOf(
    camera,
    cameraObject(2, 'IMG_0002.JPG', captureDate: DateTime(2026, 11, 13)),
  );
  late Directory root;
  late File file;
  late DateTime now;

  SessionSeenStore store() => SessionSeenStore(file, clock: Clock(() => now));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('seen');
    file = File(p.join(root.path, SessionSeenStore.fileName));
    now = t0;
  });

  tearDown(() => root.delete(recursive: true));

  test('persists queued and excluded entries', () async {
    final seen = store();
    await seen.markQueued(camera, [photo]);
    await seen.markExcluded(camera, [sync]);

    expect(await store().states(), {
      photo: SeenState.queued,
      sync: SeenState.excluded,
    });
    expect(photo, startsWith('$camera|'));
  });

  test('excluded is never downgraded to queued', () async {
    final seen = store();
    await seen.markExcluded(camera, [sync]);
    await seen.markQueued(camera, [sync]);

    expect(await seen.stateOf(sync), SeenState.excluded);
  });

  test('queued entries are pruned after queueMaxAge', () async {
    final seen = store();
    await seen.markQueued(camera, [photo]);

    now = t0.add(queueMaxAge);
    expect(await seen.stateOf(photo), SeenState.queued);

    now = now.add(day);
    expect(await seen.stateOf(photo), isNull);
    await seen.setBaseline(camera, const []);
    expect(await store().stateOf(photo), isNull);
  });

  test('excluded entries survive past queueMaxAge while listed', () async {
    final seen = store();
    await seen.markExcluded(camera, [sync]);
    await seen.markExcluded(otherCamera, ['$otherCamera|x']);

    now = t0.add(queueMaxAge * 3);
    await seen.pruneExcluded(camera, {sync, photo});
    expect(await store().stateOf(sync), SeenState.excluded);

    await seen.pruneExcluded(camera, {photo});
    expect(await store().stateOf(sync), isNull);
    expect(await store().stateOf('$otherCamera|x'), SeenState.excluded);
  });

  test('keeps one baseline per camera', () async {
    final seen = store();
    expect(await seen.baseline(camera), isNull);

    await seen.setBaseline(camera, [photo, sync]);
    await seen.setBaseline(otherCamera, const []);

    expect(await store().baseline(camera), {photo, sync});
    expect(await store().baseline(otherCamera), isEmpty);
  });

  test('a malformed file loads as empty', () async {
    await file.writeAsString('{"entries": {"x": 1}}');

    expect(await store().states(), isEmpty);
  });
}
