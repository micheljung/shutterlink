import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/json_file.dart';
import 'package:shutterlink/data/sessions_upload_queue.dart';
import 'package:shutterlink/feature/sessions/sessions_config.dart';

void main() {
  const code = 'apple-bread-cider-dough';
  const otherCode = 'eagle-fable-giant-house';
  final t0 = DateTime.utc(2026, 11, 13, 10);
  const minute = Duration(minutes: 1);
  late Directory root;
  late File manifest;
  late DateTime now;
  var fileCount = 0;

  SessionsUploadQueue queue() =>
      SessionsUploadQueue(manifest, clock: Clock(() => now));

  Future<File> photo(String content) async {
    final file = File(p.join(root.path, 'upload', '${fileCount++}.jpg'));
    await file.parent.create(recursive: true);
    return file..writeAsStringSync(content);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('queue');
    manifest = File(p.join(root.path, SessionsUploadQueue.fileName));
    now = t0;
  });

  tearDown(() => root.delete(recursive: true));

  test('keys items by the SHA-256 of the file', () async {
    final item = await queue().enqueue(
      sessionCode: code,
      file: await photo('a'),
    );

    expect(item!.photoKey, sha256.convert(utf8.encode('a')).toString());
    expect(item.attempts, 0);
    expect(item.enqueuedAt, t0);
    expect(item.nextAttemptAt, t0);
  });

  test('survives a restart', () async {
    final first = queue();
    final a = await first.enqueue(sessionCode: code, file: await photo('a'));
    now = t0.add(minute);
    await first.reschedule(
      a!.copyWith(attempts: 2, nextAttemptAt: now, lastStatus: '503'),
    );
    final b = await first.enqueue(sessionCode: code, file: await photo('b'));

    final reloaded = await queue().items();

    expect(reloaded, [
      a.copyWith(attempts: 2, nextAttemptAt: now, lastStatus: '503'),
      b,
    ]);
    expect(File('${manifest.path}.tmp').existsSync(), isFalse);
  });

  test('deduplicates by photo key and Session Code', () async {
    final uploads = queue();
    final original = await photo('a');
    final duplicate = await photo('a');
    final enqueued = uploads.enqueued.take(2).length;

    expect(await uploads.enqueue(sessionCode: code, file: original), isNotNull);
    expect(await uploads.enqueue(sessionCode: code, file: duplicate), isNull);
    expect(await uploads.enqueue(sessionCode: code, file: original), isNull);
    expect(
      await uploads.enqueue(sessionCode: otherCode, file: await photo('a')),
      isNotNull,
    );

    expect(await uploads.items(), hasLength(2));
    expect(original.existsSync(), isTrue);
    expect(duplicate.existsSync(), isFalse);
    expect(await enqueued, 2);
  });

  test('drops items older than queueMaxAge on load and counts them', () async {
    final first = queue();
    final stale = await photo('stale');
    await first.enqueue(sessionCode: code, file: stale);
    now = t0.add(queueMaxAge);
    final fresh = await photo('fresh');
    await first.enqueue(sessionCode: code, file: fresh);

    now = now.add(minute);
    final reloaded = queue();

    expect((await reloaded.items()).single.filePath, fresh.path);
    expect(await reloaded.droppedCount(), 1);
    expect(stale.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(await queue().droppedCount(), 1);
  });

  test('nextDue returns the earliest due item', () async {
    final uploads = queue();
    final a = await uploads.enqueue(sessionCode: code, file: await photo('a'));
    final b = await uploads.enqueue(sessionCode: code, file: await photo('b'));
    await uploads.reschedule(a!.copyWith(nextAttemptAt: t0.add(minute)));

    expect(await uploads.nextDue(), b);
    await uploads.complete(b!);
    expect(await uploads.nextDue(), isNull);
    expect(await uploads.nextAttemptAt(), t0.add(minute));

    now = t0.add(minute);
    expect((await uploads.nextDue())?.photoKey, a.photoKey);
  });

  test('complete and drop delete the file and count', () async {
    final uploads = queue();
    final done = await photo('done');
    final expired = await photo('expired');
    final dropped = await photo('dropped');
    final a = await uploads.enqueue(sessionCode: code, file: done);
    final b = await uploads.enqueue(sessionCode: code, file: expired);
    final c = await uploads.enqueue(sessionCode: code, file: dropped);

    await uploads.complete(a!);
    await uploads.complete(b!, expired: true);
    await uploads.drop(c!);

    expect(await uploads.items(), isEmpty);
    expect([done, expired, dropped].any((file) => file.existsSync()), isFalse);
    final reloaded = queue();
    expect(await reloaded.expiredCount(), 1);
    expect(await reloaded.droppedCount(), 1);
  });

  test('a corrupt manifest is moved aside before starting fresh', () async {
    await manifest.writeAsString('[1, 2');

    expect(await queue().items(), isEmpty);
    expect(await JsonFile(manifest).corruptFileAt(now).readAsString(), '[1, 2');
    expect(await manifest.exists(), isFalse);
  });

  test('sweeps old upload files the queue does not reference', () async {
    final kept = await photo('kept');
    await queue().enqueue(sessionCode: code, file: kept);
    final orphan = await photo('orphan');
    final downloading = await photo('downloading');
    final old = DateTime.now().subtract(SessionsUploadQueue.orphanAge * 2);
    await orphan.setLastModified(old);
    await kept.setLastModified(old);
    now = DateTime.now().toUtc();

    final reloaded = SessionsUploadQueue(
      manifest,
      uploadDirectory: orphan.parent,
      clock: Clock(() => now),
    );
    expect(await reloaded.items(), hasLength(1));

    expect(await orphan.exists(), isFalse);
    expect(await kept.exists(), isTrue);
    expect(await downloading.exists(), isTrue);
  });
}
