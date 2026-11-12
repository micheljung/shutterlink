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
}
