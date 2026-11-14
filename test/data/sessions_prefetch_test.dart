import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/sessions_prefetch.dart';
import 'package:shutterlink/feature/sessions/sessions_config.dart';

void main() {
  const key = 'Canon EOS R|IMG_0001.JPG|2026-11-13T10:00:00.000|jpeg';
  const otherKey = 'Canon EOS R|IMG_0002.JPG|2026-11-13T10:00:01.000|jpeg';
  const bytes = [1, 2, 3, 4];
  const settleMargin = Duration(minutes: 1);
  late Directory root;
  late Directory directory;
  late SessionsPrefetch prefetch;
  late DateTime now;
  late File source;

  File target() => File(p.join(root.path, 'target.jpg'));

  setUp(() async {
    root = await Directory.systemTemp.createTemp('prefetch');
    directory = Directory(p.join(root.path, SessionsPrefetch.directoryName));
    now = DateTime.now();
    prefetch = SessionsPrefetch(directory, clock: Clock(() => now));
    source = File(p.join(root.path, 'staged.jpg'));
    await source.writeAsBytes(bytes);
  });

  tearDown(() => root.delete(recursive: true));

  test('keeps a copy that a complete take moves to the target', () async {
    await prefetch.keep(key, source);

    expect(await source.readAsBytes(), bytes);
    expect(await prefetch.keys(), {key});
    expect(await prefetch.take(key, bytes.length, target()), isTrue);
    expect(await target().readAsBytes(), bytes);
    expect(await prefetch.keys(), isEmpty);
  });

  test('an incomplete copy is deleted instead of taken', () async {
    await prefetch.keep(key, source);

    expect(await prefetch.take(key, bytes.length + 1, target()), isFalse);
    expect(await target().exists(), isFalse);
    expect(await prefetch.keys(), isEmpty);
  });

  test('take without a copy finds nothing', () async {
    expect(await prefetch.take(key, bytes.length, target()), isFalse);
    expect(await prefetch.keys(), isEmpty);
  });

  test('a failed keep is ignored', () async {
    await prefetch.keep(key, File(p.join(root.path, 'missing.jpg')));

    expect(await prefetch.keys(), isEmpty);
  });

  test('discards only the given keys', () async {
    await prefetch.keep(key, source);
    await prefetch.keep(otherKey, source);

    await prefetch.discard([key, 'never kept']);

    expect(await prefetch.keys(), {otherKey});
  });

  test('ignores files that are not copies', () async {
    await prefetch.keep(key, source);
    await File(p.join(directory.path, 'stray.tmp')).writeAsString('');
    await File(p.join(directory.path, '%E0%A4%A.jpg')).writeAsString('');

    expect(await prefetch.keys(), {key});
  });

  test('sweeps copies of settled photos and those past queueMaxAge', () async {
    await prefetch.keep(key, source);
    await prefetch.keep(otherKey, source);
    final fresh = prefetch.fileFor('fresh');
    await prefetch.keep('fresh', source);
    await prefetch
        .fileFor(otherKey)
        .setLastModified(now.subtract(queueMaxAge + settleMargin));

    await prefetch.sweep({key});

    expect(await prefetch.keys(), {'fresh'});
    expect(await fresh.exists(), isTrue);
  });

  test('sweeping a missing directory does nothing', () async {
    await prefetch.sweep({key});

    expect(await directory.exists(), isFalse);
  });
}
