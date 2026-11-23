/// See store_worker.dart: the worker, natively.
library;

import 'dart:async';
import 'dart:isolate';

import '../services/log_service.dart';

/// The store, as the worker sees it.
abstract class StoreWorkerTarget {
  /// One operation; what it returns goes back to a [StoreWorker.call].
  Object? handle(String op, Object? arg);
  void close();
}

/// Makes the target in the worker: top-level or static.
typedef StoreWorkerFactory = StoreWorkerTarget? Function(
    String path, String? secret);

abstract class StoreWorker {
  bool get alive;

  /// Send [op] and do not wait. Done in order with everything else sent.
  void post(String op, Object? arg);

  /// Send [op] and have its answer; null when the worker is gone.
  Future<Object?> call(String op, Object? arg);

  /// Finish what was sent, then end.
  void close();
}

/// Spawn a worker for the store at [path]. Null when it could not start:
/// the caller then works inline.
Future<StoreWorker?> startStoreWorker(
    String path, String? secret, StoreWorkerFactory factory,
    {String name = 'store-worker'}) async {
  final port = ReceivePort(name);
  final exit = ReceivePort();
  final w = _Worker(name, port, exit);
  try {
    w._isolate = await Isolate.spawn(_entry, [port.sendPort, path, secret, factory],
        debugName: name, onExit: exit.sendPort);
  } catch (e) {
    port.close();
    exit.close();
    LogService.instance.add('$name: did not start: $e');
    return null;
  }
  return w._ready.future.timeout(const Duration(seconds: 20), onTimeout: () {
    w._died('did not answer');
    return null;
  });
}

class _Worker implements StoreWorker {
  _Worker(this.name, this._in, this._exit) {
    _in.listen(_onMessage);
    _exit.listen((_) => _died('ended'));
  }

  final String name;
  final ReceivePort _in;
  final ReceivePort _exit;
  final Completer<_Worker?> _ready = Completer();
  final Map<int, Completer<Object?>> _calls = {};
  Isolate? _isolate;
  SendPort? _to;
  int _next = 1;
  bool _alive = true;

  @override
  bool get alive => _alive && _to != null;

  void _onMessage(Object? m) {
    if (m is SendPort) {
      _to = m;
      if (!_ready.isCompleted) _ready.complete(this);
    } else if (m is List && m.length == 2 && m[0] == 'log') {
      LogService.instance.add('${m[1]}');
    } else if (m is List && m.length == 2 && m[0] is int) {
      _calls.remove(m[0])?.complete(m[1]);
    } else if (m is String) {
      // Only a failure to start is sent bare.
      LogService.instance.add('$name: $m');
      if (!_ready.isCompleted) _died(m);
    }
  }

  void _died(String why) {
    if (!_alive) return;
    _alive = false;
    for (final c in _calls.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _calls.clear();
    if (!_ready.isCompleted) _ready.complete(null);
    _in.close();
    _exit.close();
  }

  @override
  void post(String op, Object? arg) {
    if (alive) _to!.send([0, op, arg]);
  }

  @override
  Future<Object?> call(String op, Object? arg) {
    if (!alive) return Future.value(null);
    final id = _next++;
    final c = Completer<Object?>();
    _calls[id] = c;
    _to!.send([id, op, arg]);
    return c.future;
  }

  @override
  void close() {
    _to?.send('close');
    _alive = false;
    Future<void>.delayed(const Duration(seconds: 30), () {
      _isolate?.kill(priority: Isolate.beforeNextEvent);
      _in.close();
      _exit.close();
    });
  }
}

void _entry(List<Object?> args) {
  final out = args[0] as SendPort;
  final factory = args[3] as StoreWorkerFactory;
  final logs = LogService.instance;
  // The worker's log lines go to the main isolate's log.
  logs.onLine = (l) => out.send(['log', l]);
  StoreWorkerTarget? target;
  try {
    target = factory(args[1] as String, args[2] as String?);
  } catch (e) {
    out.send('open failed: $e');
    return;
  }
  if (target == null) {
    out.send('open failed');
    return;
  }
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  inbox.listen((m) {
    if (m == 'close') {
      target!.close();
      inbox.close();
      Isolate.exit();
    }
    if (m is List && m.length == 3) {
      Object? r;
      try {
        r = target!.handle(m[1] as String, m[2]);
      } catch (e) {
        logs.add('${m[1]} failed: $e');
      }
      if (m[0] != 0) out.send([m[0], r]);
    }
  });
}
