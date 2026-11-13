import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shutterlink/feature/live/ingest_coordinator.dart';

void main() {
  late IngestCoordinator coordinator;
  late List<String> log;

  setUp(() {
    coordinator = IngestCoordinator();
    log = [];
  });

  Future<String> step(String name, Future<void> gate) async {
    log.add('start $name');
    await gate;
    log.add('end $name');
    return name;
  }

  test('the same key runs one requester at a time', () async {
    final gate = Completer<void>();
    final first = coordinator.run(['a'], () => step('first', gate.future));
    final second = coordinator.run(['a'], () => step('second', Future.value()));
    await pumpEventQueue();

    expect(log, ['start first']);
    expect(coordinator.isInFlight('a'), isTrue);
    gate.complete();

    expect(await first, 'first');
    expect(await second, 'second');
    expect(log, ['start first', 'end first', 'start second', 'end second']);
    expect(coordinator.isInFlight('a'), isFalse);
  });

  test('different keys run concurrently; overlapping sets wait', () async {
    final gate = Completer<void>();
    final a = coordinator.run(['a'], () => step('a', gate.future));
    final b = coordinator.run(['b'], () => step('b', Future.value()));
    final ab = coordinator.run(['a', 'b'], () => step('ab', Future.value()));
    await b;
    await pumpEventQueue();

    expect(log, ['start a', 'start b', 'end b']);
    gate.complete();
    await Future.wait([a, ab]);
    expect(log.last, 'end ab');
  });

  test('a failing requester releases its keys', () async {
    await expectLater(
      coordinator.run(['a'], () async => throw StateError('boom')),
      throwsStateError,
    );
    expect(coordinator.isInFlight('a'), isFalse);
    expect(await coordinator.run(['a'], () async => 1), 1);
  });
}
