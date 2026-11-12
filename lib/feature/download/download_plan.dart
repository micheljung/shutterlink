import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';

import '../../data/settings_repository.dart';
import '../../ptpip/camera_client.dart';
import '../gallery/photo_group.dart';

class DownloadTask extends Equatable {
  const DownloadTask({required this.group, required this.files});

  final PhotoGroup group;
  final List<CameraObject> files;

  int get totalBytes => files.fold(0, (sum, file) => sum + file.size);

  @override
  List<Object?> get props => [group, files];
}

class DownloadPlan extends Equatable {
  const DownloadPlan({
    required this.tasks,
    required this.skipped,
    required this.alreadyDownloaded,
  });

  final List<DownloadTask> tasks;
  final List<PhotoGroup> skipped;
  final List<PhotoGroup> alreadyDownloaded;

  @override
  List<Object?> get props => [tasks, skipped, alreadyDownloaded];
}

DownloadPlan planDownload(
  List<PhotoGroup> groups,
  DownloadFormat format, {
  required bool Function(CameraObject object) isDownloaded,
}) {
  final tasks = <DownloadTask>[];
  final skipped = <PhotoGroup>[];
  final alreadyDownloaded = <PhotoGroup>[];
  for (final group in groups) {
    final files = group.filesFor(format);
    final missing = files.whereNot(isDownloaded).toList();
    if (files.isEmpty) {
      skipped.add(group);
    } else if (missing.isEmpty) {
      alreadyDownloaded.add(group);
    } else {
      tasks.add(DownloadTask(group: group, files: missing));
    }
  }
  return DownloadPlan(
    tasks: tasks,
    skipped: skipped,
    alreadyDownloaded: alreadyDownloaded,
  );
}
