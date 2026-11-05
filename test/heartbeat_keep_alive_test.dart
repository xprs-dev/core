import 'package:test/test.dart';
import 'package:xprs_core/src/platform/core_host.dart';
import 'package:xprs_core/src/platform/heartbeat_keep_alive.dart';

class _Holds implements KeepAlive {
  final List<String> log = [];
  @override
  bool get ticks => false;
  @override
  Future<void> hold(String reason) async => log.add('hold $reason');
  @override
  Future<void> release(String reason) async => log.add('release $reason');
  @override
  void addTickListener(void Function() listener) {}
  @override
  void removeTickListener(void Function() listener) {}
}

void main() {
  test('ticks while listened to, stops after', () async {
    final k = HeartbeatKeepAlive(every: const Duration(milliseconds: 10));
    expect(k.ticks, isTrue);
    var n = 0;
    void l() => n++;
    k.addTickListener(l);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(n, greaterThan(2));
    k.removeTickListener(l);
    final at = n;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(n, at);
  });

  test('a throwing listener does not stop the others', () async {
    final k = HeartbeatKeepAlive(every: const Duration(milliseconds: 10));
    var n = 0;
    k.addTickListener(() => throw StateError('x'));
    k.addTickListener(() => n++);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(n, greaterThan(0));
  });

  test('hold and release go to the wrapped keep-alive', () async {
    final h = _Holds();
    final k = HeartbeatKeepAlive(every: const Duration(seconds: 1), holds: h);
    await k.hold('mesh');
    await k.release('mesh');
    expect(h.log, ['hold mesh', 'release mesh']);
  });
}
