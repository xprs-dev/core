// The zone that names what held the isolate (performance.md 8.29): a slow
// timer, a slow await continuation and a slow stream event are each named;
// quick ones are not; the line names the function, never data.
import 'dart:async';

import 'package:test/test.dart';
import 'package:xprs_core/src/platform/stall_watch.dart';

void _busy(int ms) {
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < ms) {}
}

void slowTimerBody() => _busy(60);

Future<void> slowAfterAwait() async {
  await Future<void>.delayed(Duration.zero);
  _busy(60);
}

void main() {
  test('slow callbacks are named, quick ones are not', () async {
    final lines = <String>[];
    final w = StallWatch(report: lines.add, thresholdMs: 40);
    await runZoned(() async {
      final done = Completer<void>();
      Timer(Duration.zero, () {
        slowTimerBody();
        done.complete();
      });
      await done.future;
      await slowAfterAwait();
      final c = StreamController<int>();
      final got = Completer<void>();
      c.stream.listen((_) {
        _busy(60);
        got.complete();
      });
      c.add(1);
      await got.future;
      Timer(Duration.zero, () {}); // quick
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await c.close();
    }, zoneSpecification: w.spec);
    expect(w.slow, greaterThanOrEqualTo(3));
    expect(lines.every((l) => l.startsWith('perf: main isolate held ')), isTrue);
    expect(lines.length, w.slow.clamp(0, 20));
    expect(w.timed, greaterThan(w.slow), reason: 'quick callbacks are timed, not reported');
  });

  test('at most maxPerMinute lines', () async {
    final lines = <String>[];
    final w = StallWatch(report: lines.add, thresholdMs: 1, maxPerMinute: 2);
    await runZoned(() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>(() => _busy(3));
      }
    }, zoneSpecification: w.spec);
    expect(lines.length, 2);
    expect(w.slow, greaterThanOrEqualTo(3), reason: "five slow tasks, an outer run never counted twice");
  });

  test('a slow timer is named by where it was created', () async {
    final lines = <String>[];
    final w = StallWatch(report: lines.add, thresholdMs: 40);
    await runZoned(() async {
      final done = Completer<void>();
      Timer(Duration.zero, () {
        slowTimerBody();
        done.complete();
      });
      await done.future;
    }, zoneSpecification: w.spec);
    expect(lines, hasLength(1), reason: 'named once, not again by the run that contains it: $lines');
    expect(lines.single, contains('timer from '));
    expect(lines.single, contains('stall_watch_test.dart'));
  });

  test('an unnamed slow callback turns on recording, and the next is named', () async {
    final lines = <String>[];
    final w = StallWatch(
        report: lines.add, thresholdMs: 40, recordAtStart: Duration.zero);
    await runZoned(() async {
      final c = StreamController<int>();
      final sub = c.stream.listen((_) => _busy(60)); // anonymous: no name
      c.add(1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(lines.join(' | '), contains('recording where callbacks come from'));
      // Registered while recording: named by the place that registered it.
      await Future<void>.value(1).then((_) => _busy(60));
      await sub.cancel();
      await c.close();
    }, zoneSpecification: w.spec);
    expect(lines.last, contains('callback from '), reason: lines.join(' | '));
    expect(lines.last, contains('stall_watch_test.dart'));
  });

  test('a listener registered at start is named when it is slow later', () async {
    final lines = <String>[];
    final w = StallWatch(report: lines.add, thresholdMs: 40);
    await runZoned(() async {
      final c = StreamController<int>();
      final sub = c.stream.listen((_) => _busy(60)); // registered at start
      c.add(1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      await c.close();
    }, zoneSpecification: w.spec);
    expect(lines.join(' | '), contains('callback from '));
    expect(lines.join(' | '), contains('stall_watch_test.dart'));
  });
}
