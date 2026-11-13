import 'package:path/path.dart' as p;

const maxNameCandidates = 1000;

/// The local capture day, matching the gallery's day sections.
String captureDayOf(DateTime date) {
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-'
      '${two(local.month)}-${two(local.day)}';
}

/// Never `.part`, which Nextcloud refuses.
String tempNameFor(String name, String unique) => '.$name.tmp-$unique';

/// `IMG_0001.JPG`, `IMG_0001_1.JPG`, `IMG_0001_2.JPG`, …
String candidateName(String filename, int index) {
  if (index == 0) return filename;
  final stem = p.basenameWithoutExtension(filename);
  return '${stem}_$index${p.extension(filename)}';
}

int candidateIndexOf(String filename, String name) {
  for (var index = 0; index < maxNameCandidates; index++) {
    if (candidateName(filename, index) == name) return index;
  }
  return -1;
}
