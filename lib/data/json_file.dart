import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';

class JsonFile {
  JsonFile(this.file, {this._clock = const Clock()});

  static const _temporarySuffix = '.tmp';
  static const _corruptSuffix = '.corrupt';

  final File file;
  final Clock _clock;
  Future<void> _lastWrite = Future.value();

  /// Returns [empty] without a file. An unreadable file is moved aside to
  /// [corruptFileAt] first, so starting fresh never overwrites it.
  Future<T> read<T>(
    T Function(Map<String, Object?> json) parse,
    T Function() empty,
  ) async {
    final String text;
    try {
      text = await file.readAsString();
    } on PathNotFoundException {
      return empty();
    }
    try {
      return parse(jsonDecode(text) as Map<String, Object?>);
    } on Object {
      await file.rename(corruptFileAt(_clock.now()).path);
      return empty();
    }
  }

  File corruptFileAt(DateTime time) => File(
    '${file.path}.${time.toUtc().toIso8601String().replaceAll(':', '')}'
    '$_corruptSuffix',
  );

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
