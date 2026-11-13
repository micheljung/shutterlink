import 'package:equatable/equatable.dart';

import 'sessions_config.dart';

DateTime parseUtc(Object? value) {
  if (value is! String) throw FormatException('Expected a timestamp', value);
  final parsed = DateTime.parse(value);
  if (!parsed.isUtc) throw FormatException('Expected a UTC timestamp', value);
  return parsed;
}

String formatUtc(DateTime instant) => instant.toUtc().toIso8601String();

class ActivityInterval extends Equatable {
  const ActivityInterval(this.start, [this.end]);

  factory ActivityInterval.fromJson(Map<String, Object?> json) =>
      ActivityInterval(
        parseUtc(json['start']),
        json['end'] == null ? null : parseUtc(json['end']),
      );

  final DateTime start;
  final DateTime? end;

  bool get isOpen => end == null;

  bool contains(DateTime instant, {DateTime? openUntil}) {
    final until = end ?? openUntil;
    return !instant.isBefore(start) &&
        (until == null || instant.isBefore(until));
  }

  Map<String, Object?> toJson() => {
    'start': formatUtc(start),
    if (end case final end?) 'end': formatUtc(end),
  };

  @override
  List<Object?> get props => [start, end];
}

class Session extends Equatable {
  const Session({
    required this.id,
    required this.code,
    required this.createdAt,
    required this.intervals,
    this.expiresAt,
    this.expired = false,
  });

  factory Session.fromJson(Map<String, Object?> json) => Session(
    id: json['id']! as String,
    code: json['code']! as String,
    createdAt: parseUtc(json['createdAt']),
    intervals: [
      for (final interval in json['intervals']! as List<Object?>)
        ActivityInterval.fromJson(interval! as Map<String, Object?>),
    ],
    expiresAt: json['expiresAt'] == null ? null : parseUtc(json['expiresAt']),
    expired: json['expired'] as bool? ?? false,
  );

  final String id;
  final String code;
  final DateTime createdAt;
  final List<ActivityInterval> intervals;
  final DateTime? expiresAt;
  final bool expired;

  bool get isActive => intervals.isNotEmpty && intervals.last.isOpen;

  bool isRetainedAt(DateTime now) {
    if (expired) return false;
    if (expiresAt case final expiresAt?) return now.isBefore(expiresAt);
    final lastEnd = intervals.lastOrNull?.end;
    return lastEnd == null || !now.isAfter(lastEnd.add(retention));
  }

  bool canReactivateAt(DateTime now) =>
      !expired &&
      (expiresAt == null ||
          !now.isAfter(expiresAt!.subtract(reactivationMargin)));

  Session copyWith({
    List<ActivityInterval>? intervals,
    DateTime? expiresAt,
    bool? expired,
  }) => Session(
    id: id,
    code: code,
    createdAt: createdAt,
    intervals: intervals ?? this.intervals,
    expiresAt: expiresAt ?? this.expiresAt,
    expired: expired ?? this.expired,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'code': code,
    'createdAt': formatUtc(createdAt),
    'intervals': [for (final interval in intervals) interval.toJson()],
    if (expiresAt case final expiresAt?) 'expiresAt': formatUtc(expiresAt),
    'expired': expired,
  };

  @override
  List<Object?> get props => [
    id,
    code,
    createdAt,
    intervals,
    expiresAt,
    expired,
  ];
}

enum ClockOffsetSource { standardRead, syncShot, markedPhoto, assumed }

class ClockOffset extends Equatable {
  const ClockOffset({
    required this.offset,
    required this.measuredAt,
    required this.source,
  });

  factory ClockOffset.fromJson(Map<String, Object?> json) => ClockOffset(
    offset: Duration(microseconds: json['offsetMicroseconds']! as int),
    measuredAt: parseUtc(json['measuredAt']),
    source: ClockOffsetSource.values.byName(json['source']! as String),
  );

  final Duration offset;
  final DateTime measuredAt;
  final ClockOffsetSource source;

  Map<String, Object?> toJson() => {
    'offsetMicroseconds': offset.inMicroseconds,
    'measuredAt': formatUtc(measuredAt),
    'source': source.name,
  };

  @override
  List<Object?> get props => [offset, measuredAt, source];
}
