import 'package:equatable/equatable.dart';

import 'photo_group.dart';

enum GalleryStatus { loading, loaded, failed }

class GalleryState extends Equatable {
  const GalleryState({
    this.status = GalleryStatus.loading,
    this.groups = const [],
    this.selected = const {},
    this.deleting = false,
    this.error,
  });

  final GalleryStatus status;
  final List<PhotoGroup> groups;
  final Set<String> selected;
  final bool deleting;
  final String? error;

  List<PhotoGroup> get selectedGroups =>
      groups.where((group) => selected.contains(group.key)).toList();

  bool get allSelected => groups.isNotEmpty && selected.length == groups.length;

  GalleryState copyWith({
    GalleryStatus? status,
    List<PhotoGroup>? groups,
    Set<String>? selected,
    bool? deleting,
    String? error,
  }) => GalleryState(
    status: status ?? this.status,
    groups: groups ?? this.groups,
    selected: selected ?? this.selected,
    deleting: deleting ?? this.deleting,
    error: error,
  );

  @override
  List<Object?> get props => [status, groups, selected, deleting, error];
}
