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
  const DownloadPlan({required this.tasks, required this.skipped});

  final List<DownloadTask> tasks;
  final List<PhotoGroup> skipped;

  @override
  List<Object?> get props => [tasks, skipped];
}

DownloadPlan planDownload(List<PhotoGroup> groups, DownloadFormat format) {
  final tasks = <DownloadTask>[];
  final skipped = <PhotoGroup>[];
  for (final group in groups) {
    final files = group.filesFor(format);
    if (files.isEmpty) {
      skipped.add(group);
    } else {
      tasks.add(DownloadTask(group: group, files: files));
    }
  }
  return DownloadPlan(tasks: tasks, skipped: skipped);
}
