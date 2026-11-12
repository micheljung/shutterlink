import 'package:equatable/equatable.dart';

import '../gallery/photo_group.dart';
import 'download_plan.dart';

enum DownloadStatus { idle, running, paused, cancelled, completed }

enum DownloadFailureReason { saveFailed, photoChanged }

class DownloadFailure extends Equatable {
  const DownloadFailure(this.group, this.reason);

  final PhotoGroup group;
  final DownloadFailureReason reason;

  @override
  List<Object?> get props => [group, reason];
}

class DownloadState extends Equatable {
  const DownloadState({
    this.status = DownloadStatus.idle,
    this.tasks = const [],
    this.skipped = const [],
    this.alreadyDownloaded = const [],
    this.nextTask = 0,
    this.currentFile,
    this.fileReceived = 0,
    this.fileTotal = 0,
    this.completedBytes = 0,
    this.saved = const [],
    this.failed = const [],
    this.error,
  });

  final DownloadStatus status;
  final List<DownloadTask> tasks;
  final List<PhotoGroup> skipped;
  final List<PhotoGroup> alreadyDownloaded;
  final int nextTask;
  final String? currentFile;
  final int fileReceived;
  final int fileTotal;
  final int completedBytes;
  final List<PhotoGroup> saved;
  final List<DownloadFailure> failed;
  final String? error;

  int get totalBytes => tasks.fold(0, (sum, task) => sum + task.totalBytes);

  double get fileProgress => fileTotal == 0 ? 0 : fileReceived / fileTotal;

  double get overallProgress {
    final total = totalBytes;
    return total == 0 ? 0 : (completedBytes + fileReceived) / total;
  }

  bool get isActive =>
      status == DownloadStatus.running || status == DownloadStatus.paused;

  DownloadState copyWith({
    DownloadStatus? status,
    int? nextTask,
    String? Function()? currentFile,
    int? fileReceived,
    int? fileTotal,
    int? completedBytes,
    List<PhotoGroup>? saved,
    List<DownloadFailure>? failed,
    String? Function()? error,
  }) => DownloadState(
    status: status ?? this.status,
    tasks: tasks,
    skipped: skipped,
    alreadyDownloaded: alreadyDownloaded,
    nextTask: nextTask ?? this.nextTask,
    currentFile: currentFile != null ? currentFile() : this.currentFile,
    fileReceived: fileReceived ?? this.fileReceived,
    fileTotal: fileTotal ?? this.fileTotal,
    completedBytes: completedBytes ?? this.completedBytes,
    saved: saved ?? this.saved,
    failed: failed ?? this.failed,
    error: error != null ? error() : this.error,
  );

  @override
  List<Object?> get props => [
    status,
    tasks,
    skipped,
    alreadyDownloaded,
    nextTask,
    currentFile,
    fileReceived,
    fileTotal,
    completedBytes,
    saved,
    failed,
    error,
  ];
}
