import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/sessions/session.dart';
import 'package:shutterlink/feature/sessions/sessions_config.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 13, 10);
  const hour = Duration(hours: 1);
  final ended = Session(
    id: 'a',
    code: 'a',
    createdAt: t0,
    intervals: [ActivityInterval(t0, t0.add(hour))],
  );

  group('isRetainedAt', () {
    test('without expiresAt uses the client retention', () {
      final open = ended.copyWith(intervals: [ActivityInterval(t0)]);

      expect(ended.isRetainedAt(t0.add(hour).add(retention)), isTrue);
      expect(ended.isRetainedAt(t0.add(hour * 2).add(retention)), isFalse);
      expect(open.isRetainedAt(t0.add(retention * 2)), isTrue);
    });

    test('prefers the server expiresAt', () {
      final expiresAt = t0.add(hour * 2);
      final known = ended.copyWith(expiresAt: expiresAt);

      expect(known.isRetainedAt(expiresAt.subtract(hour)), isTrue);
      expect(known.isRetainedAt(expiresAt), isFalse);
    });

    test('an expired Session is never retained', () {
      expect(ended.copyWith(expired: true).isRetainedAt(t0), isFalse);
    });
  });

  test('canReactivateAt stops reactivationMargin before expiresAt', () {
    final expiresAt = t0.add(retention);
    final known = ended.copyWith(expiresAt: expiresAt);

    expect(ended.canReactivateAt(t0.add(retention * 2)), isTrue);
    expect(
      known.canReactivateAt(expiresAt.subtract(reactivationMargin)),
      isTrue,
    );
    expect(
      known.canReactivateAt(
        expiresAt.subtract(reactivationMargin).add(const Duration(seconds: 1)),
      ),
      isFalse,
    );
    expect(ended.copyWith(expired: true).canReactivateAt(t0), isFalse);
  });

  test('serializes to JSON and back', () {
    final session = ended.copyWith(expiresAt: t0.add(retention), expired: true);

    expect(Session.fromJson(session.toJson()), session);
  });
}
