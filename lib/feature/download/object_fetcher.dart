import 'dart:io';

import '../../ptpip/camera_client.dart';

/// Downloads one camera file into [File], resuming from what is already there.
class ObjectFetcher {
  const ObjectFetcher();

  /// [onResume] reports the starting offset before bytes are requested,
  /// [onReceived] the running total after each chunk.
  Future<File> fetch(
    CameraClient client,
    CameraObject object,
    File file, {
    CancelToken? cancelToken,
    void Function(int received)? onResume,
    void Function(int received)? onReceived,
  }) async {
    await file.parent.create(recursive: true);
    var received = await file.exists() ? await file.length() : 0;
    if (received > object.size) {
      await file.delete();
      received = 0;
    }
    if (received < object.size) {
      onResume?.call(received);
      final sink = await file.open(mode: FileMode.append);
      try {
        await client.download(
          object,
          (chunk) async {
            if (cancelToken?.isCancelled ?? false) {
              throw const TransferCancelledException();
            }
            await sink.writeFrom(chunk);
            received += chunk.length;
            onReceived?.call(received);
          },
          offset: received,
          cancelToken: cancelToken,
        );
      } finally {
        await sink.close();
      }
    }
    if (await file.length() != object.size) {
      throw FileSystemException('Incomplete download', file.path);
    }
    return file;
  }
}
