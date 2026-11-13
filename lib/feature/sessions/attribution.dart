import 'session.dart';

Session? attribute(
  DateTime? captureDate,
  List<Session> sessions,
  Duration offset, {
  DateTime? openUntil,
}) {
  if (captureDate == null) return null;
  final corrected = captureDate.toUtc().add(offset);
  for (final session in sessions) {
    for (final interval in session.intervals) {
      if (interval.contains(corrected, openUntil: openUntil)) return session;
    }
  }
  return null;
}
