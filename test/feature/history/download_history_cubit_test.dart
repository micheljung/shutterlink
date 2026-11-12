import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/feature/history/download_history_cubit.dart';

import '../../fakes/fake_camera_client.dart';

void main() {
  const camera = 'serial';
  late Directory root;
  late DownloadHistoryRepository history;
  late DownloadHistoryCubit cubit;

  final jpeg = cameraObject(1, 'IMG_0001.JPG');
  final raw = cameraObject(2, 'IMG_0001.CR3');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('history_cubit');
    history = DownloadHistoryRepository(
      File(p.join(root.path, DownloadHistoryRepository.fileName)),
    );
    cubit = DownloadHistoryCubit(history);
  });

  tearDown(() async {
    await cubit.close();
    await root.delete(recursive: true);
  });

  test('a shot is downloaded only when all its files are recorded', () async {
    final recorded = cubit.stream.firstWhere((keys) => keys.isNotEmpty);
    await history.record(camera, [jpeg]);
    await recorded;

    expect(cubit.isDownloaded(camera, [jpeg]), isTrue);
    expect(cubit.isDownloaded(camera, [jpeg, raw]), isFalse);
    expect(cubit.isDownloaded(camera, []), isFalse);
    expect(cubit.isDownloaded('other', [jpeg]), isFalse);
  });

  test('clear forgets recorded shots', () async {
    await history.record(camera, [jpeg]);
    await cubit.stream.firstWhere((keys) => keys.isNotEmpty);

    final cleared = cubit.stream.firstWhere((keys) => keys.isEmpty);
    await cubit.clear();
    await cleared;

    expect(cubit.isDownloaded(camera, [jpeg]), isFalse);
  });
}
