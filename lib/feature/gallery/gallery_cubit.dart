import 'dart:math';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../ptpip/camera_client.dart';
import 'gallery_state.dart';
import 'photo_group.dart';

class GalleryCubit extends Cubit<GalleryState> {
  GalleryCubit(this._client) : super(const GalleryState());

  final CameraClient _client;

  Future<void> load() async {
    emit(state.copyWith(status: GalleryStatus.loading));
    try {
      final groups = groupPhotos(await _client.listPhotos());
      if (isClosed) return;
      final keys = groups.map((group) => group.key).toSet();
      emit(
        state.copyWith(
          status: GalleryStatus.loaded,
          groups: groups,
          selected: state.selected.intersection(keys),
        ),
      );
    } on Exception catch (error) {
      if (isClosed) return;
      emit(state.copyWith(status: GalleryStatus.failed, error: '$error'));
    }
  }

  void toggle(PhotoGroup group) {
    final selected = {...state.selected};
    if (!selected.remove(group.key)) selected.add(group.key);
    emit(state.copyWith(selected: selected));
  }

  void selectAll() => emit(
    state.copyWith(selected: state.groups.map((group) => group.key).toSet()),
  );

  void selectWhere(bool Function(PhotoGroup group) test) => emit(
    state.copyWith(
      selected: state.groups.where(test).map((group) => group.key).toSet(),
    ),
  );

  void setSelected(Iterable<PhotoGroup> groups, bool selected) {
    final keys = groups.map((group) => group.key);
    emit(
      state.copyWith(
        selected: selected
            ? {...state.selected, ...keys}
            : state.selected.difference(keys.toSet()),
      ),
    );
  }

  void selectRange(
    String anchorKey,
    String toKey, {
    required Set<String> base,
    required bool select,
  }) {
    final keys = state.groups.map((group) => group.key).toList();
    final anchor = keys.indexOf(anchorKey);
    final to = keys.indexOf(toKey);
    if (anchor < 0 || to < 0) return;
    final range = keys.sublist(min(anchor, to), max(anchor, to) + 1);
    emit(
      state.copyWith(
        selected: select ? {...base, ...range} : base.difference(range.toSet()),
      ),
    );
  }

  void clearSelection() => emit(state.copyWith(selected: const {}));

  /// Groups that keep a file stay in the grid and in the selection.
  Future<DeleteOutcome> delete(List<PhotoGroup> groups) async {
    emit(state.copyWith(deleting: true));
    final deleted = <int>{};
    var denied = 0;
    var failed = 0;
    var disconnected = false;
    try {
      for (final (index, group) in groups.indexed) {
        try {
          for (final file in [?group.jpeg, ?group.raw]) {
            await _client.delete(file.handle);
            deleted.add(file.handle);
          }
        } on CameraDisconnectedException {
          failed += groups.length - index;
          disconnected = true;
          break;
        } on DeleteDeniedException {
          denied++;
        } on Exception {
          failed++;
        }
      }
    } finally {
      if (!isClosed) _dropFiles(deleted);
    }
    return (denied: denied, failed: failed, disconnected: disconnected);
  }

  void _dropFiles(Set<int> handles) {
    bool kept(CameraObject? file) =>
        file != null && !handles.contains(file.handle);
    final remaining = [
      for (final group in state.groups)
        if (kept(group.jpeg) || kept(group.raw))
          PhotoGroup(
            key: group.key,
            jpeg: kept(group.jpeg) ? group.jpeg : null,
            raw: kept(group.raw) ? group.raw : null,
          ),
    ];
    final keys = remaining.map((group) => group.key).toSet();
    emit(
      state.copyWith(
        groups: remaining,
        selected: state.selected.intersection(keys),
        deleting: false,
      ),
    );
  }
}

typedef DeleteOutcome = ({int denied, int failed, bool disconnected});
