import 'package:collection/collection.dart';
import 'package:equatable/equatable.dart';
import 'package:path/path.dart' as p;

import '../../data/settings_repository.dart';
import '../../ptpip/camera_client.dart';

class PhotoGroup extends Equatable {
  const PhotoGroup({required this.key, this.jpeg, this.raw})
    : assert(jpeg != null || raw != null);

  final String key;
  final CameraObject? jpeg;
  final CameraObject? raw;

  String get baseName => p.basenameWithoutExtension((jpeg ?? raw)!.filename);

  DateTime? get captureDate => jpeg?.captureDate ?? raw?.captureDate;

  int get newestHandle => [jpeg?.handle, raw?.handle].nonNulls.max;

  CameraObject get thumbnailSource => (jpeg ?? raw)!;

  List<CameraObject> filesFor(DownloadFormat format) => switch (format) {
    DownloadFormat.jpeg => [?jpeg],
    DownloadFormat.raw => [?raw],
    DownloadFormat.both => [?jpeg, ?raw],
  };

  PhotoGroup _with(CameraObject object) => switch (object.kind) {
    CameraObjectKind.jpeg => PhotoGroup(key: key, jpeg: object, raw: raw),
    CameraObjectKind.raw => PhotoGroup(key: key, jpeg: jpeg, raw: object),
  };

  @override
  List<Object?> get props => [key, jpeg, raw];
}

List<PhotoGroup> groupPhotos(Iterable<CameraObject> objects) {
  final groups = <String, PhotoGroup>{};
  for (final object in objects) {
    final key = _groupKey(object);
    final existing = groups[key];
    final occupied = switch (object.kind) {
      CameraObjectKind.jpeg => existing?.jpeg != null,
      CameraObjectKind.raw => existing?.raw != null,
    };
    final uniqueKey = occupied ? '$key#${object.handle}' : key;
    final current = groups[uniqueKey];
    groups[uniqueKey] = current == null
        ? _empty(uniqueKey, object)
        : current._with(object);
  }
  return groups.values.sorted(_newestFirst);
}

PhotoGroup _empty(String key, CameraObject object) => switch (object.kind) {
  CameraObjectKind.jpeg => PhotoGroup(key: key, jpeg: object),
  CameraObjectKind.raw => PhotoGroup(key: key, raw: object),
};

String _groupKey(CameraObject object) {
  final base = p.basenameWithoutExtension(object.filename).toUpperCase();
  final date = object.captureDate?.toIso8601String() ?? '';
  return '${object.storageId}/$base/$date';
}

int _newestFirst(PhotoGroup a, PhotoGroup b) {
  final aDate = a.captureDate;
  final bDate = b.captureDate;
  if (aDate != null && bDate != null && aDate != bDate) {
    return bDate.compareTo(aDate);
  }
  if (aDate != null && bDate == null) return -1;
  if (aDate == null && bDate != null) return 1;
  return b.newestHandle.compareTo(a.newestHandle);
}
