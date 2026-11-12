import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../ptpip/camera_client.dart';
import '../preview/preview_screen.dart';
import '../spacing.dart';
import 'day_section.dart';
import 'gallery_cubit.dart';
import 'photo_group.dart';
import 'thumbnail_cache.dart';
import 'thumbnail_tile.dart';

class GalleryGrid extends StatefulWidget {
  const GalleryGrid({
    super.key,
    required this.client,
    required this.isDownloaded,
  });

  static const maxTileExtent = 160.0;
  static const tileSpacing = 2.0;
  static const autoScrollEdge = 64.0;
  static const autoScrollStep = 16.0;
  static const autoScrollInterval = Duration(milliseconds: 16);

  final CameraClient client;
  final bool Function(PhotoGroup group) isDownloaded;

  @override
  State<GalleryGrid> createState() => _GalleryGridState();
}

class _RangeDrag {
  _RangeDrag({
    required this.anchorKey,
    required this.base,
    required this.select,
    required this.position,
  });

  final String anchorKey;
  final Set<String> base;
  final bool select;
  Offset position;
}

class _GalleryGridState extends State<GalleryGrid> {
  final _controller = ScrollController();
  _RangeDrag? _drag;
  Timer? _autoScroll;
  double _autoScrollDirection = 0;

  GalleryCubit get _cubit => context.read<GalleryCubit>();

  @override
  void dispose() {
    _autoScroll?.cancel();
    _controller.dispose();
    super.dispose();
  }

  PhotoGroup? _groupAt(Offset globalPosition) {
    final box = context.findRenderObject()! as RenderBox;
    final result = BoxHitTestResult();
    box.hitTest(result, position: box.globalToLocal(globalPosition));
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is PhotoGroup) {
        return target.metaData as PhotoGroup;
      }
    }
    return null;
  }

  void _startDrag(LongPressStartDetails details) {
    final group = _groupAt(details.globalPosition);
    if (group == null) return;
    final base = _cubit.state.selected;
    _drag = _RangeDrag(
      anchorKey: group.key,
      base: base,
      select: !base.contains(group.key),
      position: details.globalPosition,
    );
    _extendDrag();
  }

  void _updateDrag(LongPressMoveUpdateDetails details) {
    final drag = _drag;
    if (drag == null) return;
    drag.position = details.globalPosition;
    _extendDrag();
    _updateAutoScroll();
  }

  void _extendDrag() {
    final drag = _drag;
    if (drag == null) return;
    final group = _groupAt(drag.position);
    if (group == null) return;
    _cubit.selectRange(
      drag.anchorKey,
      group.key,
      base: drag.base,
      select: drag.select,
    );
  }

  void _updateAutoScroll() {
    final box = context.findRenderObject()! as RenderBox;
    final y = box.globalToLocal(_drag!.position).dy;
    if (y < GalleryGrid.autoScrollEdge) {
      _autoScrollDirection = -1;
    } else if (y > box.size.height - GalleryGrid.autoScrollEdge) {
      _autoScrollDirection = 1;
    } else {
      _autoScrollDirection = 0;
    }
    if (_autoScrollDirection == 0) {
      _stopAutoScroll();
    } else {
      _autoScroll ??= Timer.periodic(
        GalleryGrid.autoScrollInterval,
        (_) => _scrollStep(),
      );
    }
  }

  void _scrollStep() {
    final position = _controller.position;
    final offset =
        (position.pixels + _autoScrollDirection * GalleryGrid.autoScrollStep)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (offset == position.pixels) return;
    _controller.jumpTo(offset);
    _extendDrag();
  }

  void _stopAutoScroll() {
    _autoScroll?.cancel();
    _autoScroll = null;
  }

  void _endDrag() {
    _stopAutoScroll();
    _drag = null;
  }

  void _openPreview(PhotoGroup group) => Navigator.of(context).push(
    PreviewScreen.route(
      context,
      client: widget.client,
      index: _cubit.state.groups.indexOf(group),
    ),
  );

  void _onTap(PhotoGroup group) {
    if (_cubit.state.selected.isEmpty) {
      _openPreview(group);
    } else {
      _cubit.toggle(group);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GalleryCubit>().state;
    final cache = context.read<ThumbnailCache>();
    return GestureDetector(
      onLongPressStart: _startDrag,
      onLongPressMoveUpdate: _updateDrag,
      onLongPressEnd: (_) => _endDrag(),
      onLongPressCancel: _endDrag,
      child: CustomScrollView(
        controller: _controller,
        slivers: [
          for (final section in sectionsOf(state.groups))
            SliverMainAxisGroup(
              slivers: [
                SliverToBoxAdapter(
                  child: _DayHeader(
                    section: section,
                    allSelected: section.groups.every(
                      (group) => state.selected.contains(group.key),
                    ),
                  ),
                ),
                SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: GalleryGrid.maxTileExtent,
                    mainAxisSpacing: GalleryGrid.tileSpacing,
                    crossAxisSpacing: GalleryGrid.tileSpacing,
                  ),
                  itemCount: section.groups.length,
                  itemBuilder: (context, index) {
                    final group = section.groups[index];
                    return MetaData(
                      key: ValueKey(group.key),
                      metaData: group,
                      child: ThumbnailTile(
                        group: group,
                        selected: state.selected.contains(group.key),
                        downloaded: widget.isDownloaded(group),
                        cache: cache,
                        client: widget.client,
                        onTap: () => _onTap(group),
                        onPreview: () => _openPreview(group),
                      ),
                    );
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.section, required this.allSelected});

  static const unknownDate = 'Unknown date';

  final DaySection section;
  final bool allSelected;

  @override
  Widget build(BuildContext context) {
    final day = section.day;
    return Padding(
      padding: const EdgeInsets.only(left: Spacing.large),
      child: Row(
        children: [
          Expanded(
            child: Text(
              day == null
                  ? unknownDate
                  : MaterialLocalizations.of(context).formatFullDate(day),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            tooltip: allSelected ? 'Deselect day' : 'Select day',
            icon: Icon(allSelected ? Icons.remove_done : Icons.done_all),
            onPressed: () => context.read<GalleryCubit>().setSelected(
              section.groups,
              !allSelected,
            ),
          ),
        ],
      ),
    );
  }
}
