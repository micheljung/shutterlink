import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shutterlink/data/download_history.dart';
import 'package:shutterlink/data/settings_repository.dart';
import 'package:shutterlink/feature/download/download_cubit.dart';
import 'package:shutterlink/feature/download/download_state.dart';
import 'package:shutterlink/feature/gallery/photo_group.dart';
import 'package:shutterlink/ptpip/ptpip.dart';

import '../../fakes/fake_camera_client.dart';
import '../../ptpip/fake_camera.dart';

void main() {
  late Directory root;
  late FakeCamera camera;
  late PtpIpCameraClient client;
  late RecordingPhotoSaver saver;
  late DownloadCubit cubit;

  int partialRequests() => camera.receivedOpcodes
      .where((opcode) => opcode == PtpOperation.getPartialObject)
      .length;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('history_camera');
    camera = FakeCamera(pairedGuids: [pairedGuid]);
    await camera.start();
    client = await connectTo(camera);
    saver = RecordingPhotoSaver();
    cubit = DownloadCubit(
      saver: saver,
      workDirectory: Directory(p.join(root.path, 'work')),
      history: DownloadHistoryRepository(
        File(p.join(root.path, DownloadHistoryRepository.fileName)),
      ),
    );
  });

  tearDown(() async {
    await cubit.close();
    await client.close();
    await camera.stop();
    await root.delete(recursive: true);
  });

  test('a second download fetches nothing already downloaded', () async {
    final groups = groupPhotos(await client.listPhotos());
    await cubit.start(client, groups, DownloadFormat.jpeg);
    final firstRequests = partialRequests();
    final firstSaved = saver.saved.length;
    expect(firstSaved, greaterThan(0));
    cubit.dismiss();

    await cubit.start(client, groups, DownloadFormat.jpeg);

    expect(cubit.state.status, DownloadStatus.completed);
    expect(partialRequests(), firstRequests);
    expect(saver.saved, hasLength(firstSaved));
    expect(cubit.state.alreadyDownloaded, hasLength(firstSaved));
  });
}
