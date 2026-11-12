import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../ptpip/camera_client.dart';

String cameraKeyOf(CameraDeviceInfo deviceInfo) =>
    deviceInfo.serialNumber.isEmpty
    ? deviceInfo.model
    : deviceInfo.serialNumber;

class DownloadHistoryRepository {
  DownloadHistoryRepository(this._file);

  static const fileName = 'download_history.json';
  static const _temporarySuffix = '.tmp';

  final File _file;
  final _changes = StreamController<void>.broadcast();
  late final Future<Set<String>> _keys = _read();
  Future<void> _lastWrite = Future.value();

  Stream<void> get changes => _changes.stream;

  static String entryKey(String cameraKey, CameraObject object) => [
    cameraKey,
    object.filename,
    object.captureDate?.toIso8601String() ?? '',
    object.kind.name,
  ].join('|');

  Future<Set<String>> load() => _keys;

  Future<bool> contains(String cameraKey, CameraObject object) async =>
      (await _keys).contains(entryKey(cameraKey, object));

  Future<void> record(String cameraKey, Iterable<CameraObject> objects) =>
      _write(
        (keys) =>
            keys.addAll(objects.map((object) => entryKey(cameraKey, object))),
      );

  Future<void> clear() => _write((keys) => keys.clear());

  Future<void> _write(void Function(Set<String> keys) change) {
    final write = _lastWrite.then((_) async {
      final keys = await _keys;
      change(keys);
      await _file.parent.create(recursive: true);
      final temporary = File('${_file.path}$_temporarySuffix');
      await temporary.writeAsString(jsonEncode(keys.toList()), flush: true);
      await temporary.rename(_file.path);
      _changes.add(null);
    });
    _lastWrite = write.catchError((Object _) {});
    return write;
  }

  Future<Set<String>> _read() async {
    try {
      final decoded = jsonDecode(await _file.readAsString());
      return decoded is List ? decoded.whereType<String>().toSet() : {};
    } on FileSystemException {
      return {};
    } on FormatException {
      return {};
    }
  }
}
