/*
 * A heartbeat for a host with no native one (the server, the desktop app).
 *
 * Android's foreground service ticks the core every 2 s from its own thread;
 * work driven only by that heartbeat (the catch-up poll, XPRS.md 12.10.1)
 * never ran anywhere else. This gives any other host the same tick from a
 * Dart timer, which nothing throttles on a machine that is never suspended.
 *
 * The period is the HOST's choice and has no default here: the core does not
 * poll (performance.md §8, `no-sub-minute-interval-constant`). Each listener
 * gates itself on top of the tick. The timer runs only while somebody listens.
 *
 * hold/release go to [holds] (the app's foreground service, which is a no-op
 * off Android; nothing on a server).
 */
import 'dart:async';

import 'core_host.dart';

class HeartbeatKeepAlive implements KeepAlive {
  HeartbeatKeepAlive({required this.every, KeepAlive? holds})
      : _holds = holds;

  final Duration every;
  final KeepAlive? _holds;
  final List<void Function()> _listeners = [];
  Timer? _timer;

  @override
  bool get ticks => true;

  @override
  Future<void> hold(String reason) async => _holds?.hold(reason);
  @override
  Future<void> release(String reason) async => _holds?.release(reason);

  @override
  void addTickListener(void Function() listener) {
    _listeners.add(listener);
    _timer ??= Timer.periodic(every, (_) {
      for (final l in List.of(_listeners)) {
        try {
          l();
        } catch (_) {
          // One listener's fault must not stop the others' heartbeat.
        }
      }
    });
  }

  @override
  void removeTickListener(void Function() listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }
}
