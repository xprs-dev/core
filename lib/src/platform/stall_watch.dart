/*
 * stall_watch — what held the isolate, by name.
 *
 * Everything an isolate runs after main() returns is run by its zone: a
 * timer, a microtask, the rest of an async function after an await, a
 * stream event, a platform message, a frame. A zone can therefore time each
 * of them, and when one holds the isolate for [thresholdMs] or more, say
 * which function it was:
 *
 *   perf: main isolate held 1900ms by Closure: () => void from Function
 *         'XprsFoo._tick': .
 *
 * Why it exists (2026-11-23, performance.md 8.29): a phone froze for two
 * seconds every twenty, and three fixes in a row went to the wrong place
 * because the evidence was log silences and guesses. A release build has
 * no VM service and no symbols for a profiler, and the phone has no root;
 * this needs neither. The names survive because release builds are not
 * obfuscated.
 *
 * An anonymous closure prints no name in a release (AOT) build, only its
 * type, and most timers are anonymous closures. So a timer also records
 * where it was created (a stack trace, at creation: timers are made rarely
 * enough for that to cost nothing that shows) and a slow timer is named by
 * that place: `timer from MeshService._startSweep (mesh_service.dart:1104)`.
 *
 * Anything else (a `then`, a stream listener, an await) has no creation of
 * its own to record, and recording where every callback is registered would
 * cost a stack trace per await. So it is done for a while only: a slow
 * callback that could not be named turns on [deepFor] of recording, at most
 * once per [deepEvery], and the next slow one is named by the place that
 * registered it: `callback from XprsFoo._onReply (xprs_foo.dart:88)`.
 *
 * Cost: two clock reads per callback, and a line only for a slow one, at
 * most [maxPerMinute] a minute. A callback inside another (a synchronous
 * stream event) is timed too and marked "inside": the innermost slow one is
 * the culprit, the outer ones only contain it. Never a person's words: the
 * line names code, not data.
 */
library;

import 'dart:async';

class StallWatch {
  StallWatch({
    required this.report,
    this.label = 'main isolate',
    this.thresholdMs = 250,
    this.maxPerMinute = 20,
    Duration recordAtStart = const Duration(minutes: 2),
  }) : _deepUntilMs = recordAtStart.inMilliseconds;

  /// Where a line goes (LogService.instance.add).
  final void Function(String line) report;
  final String label;
  final int thresholdMs;
  final int maxPerMinute;

  final Stopwatch _clock = Stopwatch()..start();
  int _depth = 0;

  /// A callback inside the current outermost one has already been named:
  /// the outer one, which only contains it, is not reported again.
  bool _namedInside = false;
  int _minute = -1;
  int _lines = 0;

  /// How long registration sites are recorded after an unnamed slow
  /// callback, and how seldom that may start.
  final Duration deepFor = const Duration(minutes: 5);
  final Duration deepEvery = const Duration(minutes: 30);
  /// Where callbacks come from is also recorded for the first minutes of
  /// the process: a stream listener is registered once, at start, and a
  /// slow one would otherwise never be named (seen on the C61 with beta.9:
  /// `held 820ms by Closure: (dynamic) => Null`, every minute and a half).
  int _deepUntilMs;
  int _deepLastMs = -1 << 40;
  final Expando<StackTrace> _sites = Expando<StackTrace>('stall-watch-site');

  bool get _deep => _clock.elapsedMilliseconds < _deepUntilMs;

  /// Callbacks timed, and how many crossed the threshold (status).
  int timed = 0;
  int slow = 0;

  ZoneSpecification get spec => ZoneSpecification(
        createTimer: (Zone self, ZoneDelegate parent, Zone zone, Duration d,
            void Function() f) {
          final site = StackTrace.current;
          return parent.createTimer(zone, d, () {
            // The callback Dart passes here already runs itself through the
            // zone (run, below): hand it the place, and let it report.
            _site = site;
            try {
              f();
            } finally {
              _site = null;
            }
          });
        },
        createPeriodicTimer: (Zone self, ZoneDelegate parent, Zone zone,
            Duration d, void Function(Timer) f) {
          final site = StackTrace.current;
          return parent.createPeriodicTimer(zone, d, (Timer t) {
            _site = site;
            try {
              f(t);
            } finally {
              _site = null;
            }
          });
        },
        registerCallback: <R>(Zone self, ZoneDelegate parent, Zone zone,
            R Function() f) {
          final r = parent.registerCallback<R>(zone, f);
          if (_deep) _sites[r] = StackTrace.current;
          return r;
        },
        registerUnaryCallback: <R, T>(Zone self, ZoneDelegate parent,
            Zone zone, R Function(T) f) {
          final r = parent.registerUnaryCallback<R, T>(zone, f);
          if (_deep) _sites[r] = StackTrace.current;
          return r;
        },
        registerBinaryCallback: <R, T1, T2>(Zone self, ZoneDelegate parent,
            Zone zone, R Function(T1, T2) f) {
          final r = parent.registerBinaryCallback<R, T1, T2>(zone, f);
          if (_deep) _sites[r] = StackTrace.current;
          return r;
        },
        run: <R>(Zone self, ZoneDelegate parent, Zone zone, R Function() f) {
          final site = _takeSite() ?? _sites[f];
          final t0 = _enter();
          try {
            return parent.run<R>(zone, f);
          } finally {
            _leave(t0, f, site: site);
          }
        },
        runUnary: <R, T>(Zone self, ZoneDelegate parent, Zone zone,
            R Function(T) f, T arg) {
          final site = _takeSite() ?? _sites[f];
          final t0 = _enter();
          try {
            return parent.runUnary<R, T>(zone, f, arg);
          } finally {
            _leave(t0, f, site: site);
          }
        },
        runBinary: <R, T1, T2>(Zone self, ZoneDelegate parent, Zone zone,
            R Function(T1, T2) f, T1 a1, T2 a2) {
          final site = _takeSite() ?? _sites[f];
          final t0 = _enter();
          try {
            return parent.runBinary<R, T1, T2>(zone, f, a1, a2);
          } finally {
            _leave(t0, f, site: site);
          }
        },
      );

  /// Where the timer that is firing was made, for the run it starts.
  StackTrace? _site;

  StackTrace? _takeSite() {
    final s = _site;
    _site = null;
    return s;
  }

  int _enter() {
    _depth++;
    return _clock.elapsedMicroseconds;
  }

  void _leave(int t0, Function f, {StackTrace? site}) {
    _depth--;
    timed++;
    final us = _clock.elapsedMicroseconds - t0;
    if (us < thresholdMs * 1000) {
      if (_depth == 0) _namedInside = false;
      return;
    }
    if (_depth == 0 && _namedInside) {
      _namedInside = false;
      return;
    }
    if (_depth > 0) _namedInside = true;
    slow++;
    final minute = _clock.elapsedMilliseconds ~/ 60000;
    if (minute != _minute) {
      _minute = minute;
      _lines = 0;
    }
    // Unnamed: record where callbacks come from for a while, so the next
    // one is named.
    var deepNote = '';
    final nowMs = _clock.elapsedMilliseconds;
    if (site == null && !_deep && nowMs - _deepLastMs >= deepEvery.inMilliseconds) {
      _deepLastMs = nowMs;
      _deepUntilMs = nowMs + deepFor.inMilliseconds;
      deepNote = '; recording where callbacks come from for '
          '${deepFor.inMinutes} min to name the next one';
    }
    if (++_lines > maxPerMinute) return;
    var name = site == null
        ? '$f$deepNote'
        : _isTimerSite(site)
            ? 'timer from ${_siteOf(site)}'
            : 'callback from ${_siteOf(site)}';
    if (name.length > 200) name = '${name.substring(0, 200)}...';
    const where = '';
    try {
      report('perf: $label held ${us ~/ 1000}ms by $name$where');
    } catch (_) {
      // A report that throws must not take the callback's result with it.
    }
  }

  /// A site taken at a timer's creation, not at a callback's registration.
  static bool _isTimerSite(StackTrace st) => '$st'.contains('dart:async/timer.dart');

  static final RegExp _frame = RegExp(r'^#\d+\s+(.+?) \((.+?)\)$');

  /// The first two frames of [st] that are not the SDK's or this file's:
  /// `Owner.method (file.dart:line) < Caller.method (file.dart:line)`.
  static String _siteOf(StackTrace st) {
    final out = <String>[];
    for (final line in '$st'.split('\n')) {
      final m = _frame.firstMatch(line.trim());
      if (m == null) continue;
      final where = m.group(2)!;
      if (where.startsWith('dart:') || where.contains('stall_watch.dart')) continue;
      final file = where.split('/').last;
      out.add('${m.group(1)} ($file)');
      if (out.length == 2) break;
    }
    return out.isEmpty ? 'an unknown place' : out.join(' < ');
  }
}
