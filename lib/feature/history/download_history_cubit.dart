import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/download_history.dart';
import '../../ptpip/camera_client.dart';

class DownloadHistoryCubit extends Cubit<Set<String>> {
  DownloadHistoryCubit(this._repository) : super(const {}) {
    _subscription = _repository.changes.listen((_) => _refresh());
    _refresh();
  }

  final DownloadHistoryRepository _repository;
  late final StreamSubscription<void> _subscription;

  bool isDownloaded(String cameraKey, List<CameraObject> files) =>
      files.isNotEmpty &&
      files.every(
        (file) =>
            state.contains(DownloadHistoryRepository.entryKey(cameraKey, file)),
      );

  Future<void> clear() => _repository.clear();

  Future<void> _refresh() async {
    final keys = await _repository.load();
    if (!isClosed) emit(Set.unmodifiable(keys));
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    return super.close();
  }
}
