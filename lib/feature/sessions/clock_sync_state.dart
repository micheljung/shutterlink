import 'package:equatable/equatable.dart';

import '../gallery/photo_group.dart';

enum ClockResolution {
  fresh,
  corrected,
  stored,
  syncShot,
  markedPhoto,
  assumed,
}

enum ClockSyncFailure { windowTooLong, timeout, noPhoto }

sealed class ClockState extends Equatable {
  const ClockState();

  @override
  List<Object?> get props => [];
}

class ClockPending extends ClockState {
  const ClockPending();
}

class ClockResolved extends ClockState {
  const ClockResolved(this.kind, this.offset, {this.previous});

  final ClockResolution kind;
  final Duration offset;
  final Duration? previous;

  @override
  List<Object?> get props => [kind, offset, previous];
}

class ClockPrompt extends ClockState {
  const ClockPrompt({this.lastOffset, this.failure});

  final Duration? lastOffset;
  final ClockSyncFailure? failure;

  @override
  List<Object?> get props => [lastOffset, failure];
}

class ClockSyncing extends ClockState {
  const ClockSyncing();
}

class ClockAwaitingMarkedPhoto extends ClockState {
  const ClockAwaitingMarkedPhoto(this.candidate, {required this.index});

  final PhotoGroup candidate;
  final int index;

  @override
  List<Object?> get props => [candidate, index];
}
