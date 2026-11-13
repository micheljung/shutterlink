import 'dart:convert';
import 'dart:io';

class JsonFile {
  JsonFile(this.file);

  static const _temporarySuffix = '.tmp';

  final File file;
  Future<void> _lastWrite = Future.value();

  Future<Object?> read() async {
    try {
      return jsonDecode(await file.readAsString());
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<T> serialized<T>(Future<T> Function() action) {
    final result = _lastWrite.then((_) => action());
    _lastWrite = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> save(Object? json) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}$_temporarySuffix');
    await temporary.writeAsString(jsonEncode(json), flush: true);
    await temporary.rename(file.path);
  }
}
