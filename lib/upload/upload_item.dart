import 'package:equatable/equatable.dart';

import '../ptpip/camera_client.dart';

/// `staged → saving → savedToGallery → uploading → uploaded →
/// localDeleted | localKept`. Each state is persisted before the side effect
/// that leads out of it.
enum UploadState {
  staged,

  /// A pending gallery entry exists at [UploadItem.pendingRef].
  saving,
  savedToGallery,

  /// Bytes may have reached [UploadItem.tempName].
  uploading,
  uploaded,
  localDeleted,
  localKept;

  bool get isTerminal => this == localDeleted || this == localKept;

  bool get isUploaded => this == uploaded || isTerminal;
}

const _transitions = {
  UploadState.staged: {UploadState.saving},
  UploadState.saving: {UploadState.saving, UploadState.savedToGallery},
  UploadState.savedToGallery: {UploadState.uploading, UploadState.uploaded},
  UploadState.uploading: {UploadState.savedToGallery, UploadState.uploaded},
  UploadState.uploaded: {UploadState.localDeleted, UploadState.localKept},
  UploadState.localDeleted: <UploadState>{},
  UploadState.localKept: {UploadState.localDeleted},
};

class UploadItem extends Equatable {
  const UploadItem({
    required this.id,
    required this.filename,
    required this.kind,
    required this.captureDay,
    required this.size,
    required this.sha256,
    required this.localPath,
    required this.destinationFingerprint,
    this.state = UploadState.staged,
    this.pendingRef,
    this.mediaRef,
    this.remoteName,
    this.tempName,
    this.attempts = 0,
    this.nextAttemptAt,
    this.lastError,
    this.needsAttention = false,
    this.deleteDenied = false,
  });

  /// The download history entry key of the camera file.
  final String id;
  final String filename;
  final CameraObjectKind kind;

  /// `YYYY-MM-DD`, the remote directory.
  final String captureDay;
  final int size;
  final String sha256;

  /// The staged file; the source of truth until the upload is confirmed.
  final String localPath;
  final String destinationFingerprint;
  final UploadState state;
  final String? pendingRef;
  final String? mediaRef;

  /// Chosen once and kept across retries, so a retry never picks a new name.
  final String? remoteName;
  final String? tempName;

  /// Failed attempts since the last success or reset.
  final int attempts;
  final DateTime? nextAttemptAt;
  final String? lastError;
  final bool needsAttention;

  /// The gallery copy could not be removed and awaits the user's consent.
  final bool deleteDenied;

  UploadItem moveTo(
    UploadState next, {
    String? Function()? pendingRef,
    String? Function()? mediaRef,
    bool? deleteDenied,
  }) {
    if (!_transitions[state]!.contains(next)) {
      throw StateError('Invalid upload transition $state → $next');
    }
    return copyWith(
      state: next,
      pendingRef: pendingRef,
      mediaRef: mediaRef,
      deleteDenied: deleteDenied,
    );
  }

  UploadItem copyWith({
    UploadState? state,
    String? Function()? pendingRef,
    String? Function()? mediaRef,
    String? Function()? remoteName,
    String? Function()? tempName,
    String? destinationFingerprint,
    int? attempts,
    DateTime? Function()? nextAttemptAt,
    String? Function()? lastError,
    bool? needsAttention,
    bool? deleteDenied,
  }) => UploadItem(
    id: id,
    filename: filename,
    kind: kind,
    captureDay: captureDay,
    size: size,
    sha256: sha256,
    localPath: localPath,
    destinationFingerprint:
        destinationFingerprint ?? this.destinationFingerprint,
    state: state ?? this.state,
    pendingRef: pendingRef == null ? this.pendingRef : pendingRef(),
    mediaRef: mediaRef == null ? this.mediaRef : mediaRef(),
    remoteName: remoteName == null ? this.remoteName : remoteName(),
    tempName: tempName == null ? this.tempName : tempName(),
    attempts: attempts ?? this.attempts,
    nextAttemptAt: nextAttemptAt == null ? this.nextAttemptAt : nextAttemptAt(),
    lastError: lastError == null ? this.lastError : lastError(),
    needsAttention: needsAttention ?? this.needsAttention,
    deleteDenied: deleteDenied ?? this.deleteDenied,
  );

  /// Clears every trace of the previous destination.
  UploadItem retarget(String fingerprint) => copyWith(
    destinationFingerprint: fingerprint,
    state: state == UploadState.uploading ? UploadState.savedToGallery : null,
    remoteName: () => null,
    tempName: () => null,
    attempts: 0,
    nextAttemptAt: () => null,
    lastError: () => null,
    needsAttention: false,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'filename': filename,
    'kind': kind.name,
    'captureDay': captureDay,
    'size': size,
    'sha256': sha256,
    'localPath': localPath,
    'destinationFingerprint': destinationFingerprint,
    'state': state.name,
    'pendingRef': pendingRef,
    'mediaRef': mediaRef,
    'remoteName': remoteName,
    'tempName': tempName,
    'attempts': attempts,
    'nextAttemptAt': nextAttemptAt?.toUtc().toIso8601String(),
    'lastError': lastError,
    'needsAttention': needsAttention,
    'deleteDenied': deleteDenied,
  };

  /// Returns null for entries this version cannot interpret.
  static UploadItem? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    try {
      final next = json['nextAttemptAt'] as String?;
      return UploadItem(
        id: json['id']! as String,
        filename: json['filename']! as String,
        kind: CameraObjectKind.values.byName(json['kind']! as String),
        captureDay: json['captureDay']! as String,
        size: json['size']! as int,
        sha256: json['sha256']! as String,
        localPath: json['localPath']! as String,
        destinationFingerprint: json['destinationFingerprint']! as String,
        state: UploadState.values.byName(json['state']! as String),
        pendingRef: json['pendingRef'] as String?,
        mediaRef: json['mediaRef'] as String?,
        remoteName: json['remoteName'] as String?,
        tempName: json['tempName'] as String?,
        attempts: json['attempts'] as int? ?? 0,
        nextAttemptAt: next == null ? null : DateTime.parse(next),
        lastError: json['lastError'] as String?,
        needsAttention: json['needsAttention'] as bool? ?? false,
        deleteDenied: json['deleteDenied'] as bool? ?? false,
      );
    } on Object {
      return null;
    }
  }

  @override
  List<Object?> get props => [
    id,
    filename,
    kind,
    captureDay,
    size,
    sha256,
    localPath,
    destinationFingerprint,
    state,
    pendingRef,
    mediaRef,
    remoteName,
    tempName,
    attempts,
    nextAttemptAt,
    lastError,
    needsAttention,
    deleteDenied,
  ];
}
