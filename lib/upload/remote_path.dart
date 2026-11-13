import 'package:path/path.dart' as p;

import '../feature/gallery/day_section.dart';
import 'storage_backend.dart';

/// Gives up suffixing after this many taken names; a camera never produces
/// that many same-named files on one day.
const maxNameCandidates = 1000;

/// `YYYY-MM-DD` of [captureDate] in local time, matching the gallery days.
String captureDayOf(DateTime captureDate) {
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

/// The index [name] was generated from, or 0 if it matches no candidate.
int candidateIndexOf(String filename, String name) {
  for (var index = 0; index < maxNameCandidates; index++) {
    if (candidateName(filename, index) == name) return index;
  }
  return 0;
}

/// Never `.part`, which Nextcloud refuses.
String tempNameFor(String name, String unique) => '.$name.tmp-$unique';

/// Splits a user-entered base path into non-empty segments.
List<String> pathSegments(String path) =>
    path.split('/').where((s) => s.isNotEmpty && s != '.').toList();

/// The first candidate index at or after [from] whose name in [directory] is
/// free, or null if an identical file already exists under one of them.
/// Never selects a name with different content.
Future<int?> freeNameIndex(
  StorageBackend backend, {
  required String directory,
  required String filename,
  required int size,
  required String sha256,
  int from = 0,
}) async {
  for (var i = from; i < maxNameCandidates; i++) {
    final target = RemoteTarget(
      directory: directory,
      name: candidateName(filename, i),
    );
    switch (await backend.probe(target, size: size, sha256: sha256)) {
      case ProbeResult.absent:
        return i;
      case ProbeResult.identical:
        return null;
      case ProbeResult.different:
        continue;
    }
  }
  throw StorageException(
    'No free name for $filename in $directory.',
    retryable: false,
  );
}
