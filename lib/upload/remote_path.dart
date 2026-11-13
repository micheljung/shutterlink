import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../feature/gallery/day_section.dart';
import 'storage_backend.dart';

/// Gives up suffixing after this many taken names; a camera never produces
/// that many same-named files on one day.
const maxNameCandidates = 1000;

/// `YYYY-MM-DD` of [captureDate] in local time, matching the gallery days.
String remoteDirectoryFor(DateTime captureDate) {
  final day = dayOf(captureDate)!;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-'
      '${two(day.day)}';
}

/// [filename] for [index] 0, otherwise `<stem>_<index>.<ext>`.
String candidateName(String filename, int index) {
  if (index == 0) return filename;
  final ext = p.extension(filename);
  final stem = filename.substring(0, filename.length - ext.length);
  return '${stem}_$index$ext';
}

String tempNameFor(String name) => '.$name.tmp-${const Uuid().v4()}';

/// Splits a user-entered base path into non-empty segments.
List<String> pathSegments(String path) =>
    path.split('/').where((s) => s.isNotEmpty && s != '.').toList();

typedef ResolvedName = ({RemoteTarget target, bool alreadyPresent});

/// Picks the first candidate name in [directory] that is free or already
/// holds an identical file. Never selects a name with different content.
Future<ResolvedName> resolveRemoteName(
  StorageBackend backend, {
  required String directory,
  required String filename,
  required int size,
  required String sha256,
  int startIndex = 0,
}) async {
  for (var i = startIndex; i < maxNameCandidates; i++) {
    final target = RemoteTarget(
      directory: directory,
      name: candidateName(filename, i),
    );
    switch (await backend.probe(target, size: size, sha256: sha256)) {
      case ProbeResult.absent:
        return (target: target, alreadyPresent: false);
      case ProbeResult.identical:
        return (target: target, alreadyPresent: true);
      case ProbeResult.different:
        continue;
    }
  }
  throw StorageException(
    'No free name for $filename in $directory.',
    retryable: false,
  );
}
