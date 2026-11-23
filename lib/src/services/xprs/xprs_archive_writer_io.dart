/// See xprs_archive_writer.dart: the writer thread, natively.
///
/// The shape of every worker here (performance.md 8.1): spawned once, its
/// first message is its own port, requests carry an id, a crash fails what
/// was waiting and the archive falls back to writing inline. The queue is
/// bounded by its only caller, which hands over one batch at a time.
///
/// The isolate runs the archive's own write code against the same file:
/// zx lets one isolate write while another reads, and a reader sees each
/// commit on its next statement. Nothing in a batch is a closure: wires,
/// numbers and key bytes go over, plain lists and maps come back.
library;

import 'dart:async';
import 'dart:isolate';

import '../log_service.dart';
import 'xprs_archive.dart';

abstract class XprsArchiveWriterPort {
  bool get alive;

  /// One batch written; the reply, or null when the thread is gone.
  Future<Map<String, Object?>?> write(Map<String, Object?> batch);

  /// Let it finish what it was given, then end.
  void close();
}

/// Spawn the writer for the archive at [path] ([secret]: the store's, which
/// a worker cannot ask the keyring for). Null when it could not start: the
/// archive then writes inline.
Future<XprsArchiveWriterPort?> startArchiveWriter(
    String path, String? secret) async {
  final port = ReceivePort('xprs-archive-writer');
  final exit = ReceivePort();
  final w = _Writer(port, exit);
  try {
    w._isolate = await Isolate.spawn(_entry, [port.sendPort, path, secret],
        debugName: 'xprs-archive-writer', onExit: exit.sendPort);
  } catch (e) {
    port.close();
    exit.close();
    LogService.instance.add('XPRS archive: writer thread did not start: $e');
    return null;
  }
  return await w._ready.future.timeout(const Duration(seconds: 20),
      onTimeout: () {
    w._died('did not answer');
    return null;
  });
}

class _Writer implements XprsArchiveWriterPort {
  _Writer(this._in, this._exit) {
    _in.listen(_onMessage);
    _exit.listen((_) => _died('ended'));
  }

  final ReceivePort _in;
  final ReceivePort _exit;
  final Completer<_Writer?> _ready = Completer();
  final Map<int, Completer<Map<String, Object?>?>> _calls = {};
  Isolate? _isolate;
  SendPort? _to;
  int _next = 0;
  bool _alive = true;

  @override
  bool get alive => _alive && _to != null;

  void _onMessage(Object? m) {
    if (m is SendPort) {
      _to = m;
      if (!_ready.isCompleted) _ready.complete(this);
      return;
    }
    if (m is List && m.length == 2 && m[0] is int) {
      final c = _calls.remove(m[0]);
      final r = m[1];
      c?.complete(r is Map ? r.cast<String, Object?>() : null);
      return;
    }
    if (m is String) {
      // The thread could not open the store.
      LogService.instance.add('XPRS archive: writer thread: $m');
      _died(m);
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
  Future<Map<String, Object?>?> write(Map<String, Object?> batch) {
    final to = _to;
    if (!_alive || to == null) return Future.value(null);
    final id = _next++;
    final c = Completer<Map<String, Object?>?>();
    _calls[id] = c;
    to.send([id, batch]);
    return c.future;
  }

  @override
  void close() {
    // Messages are handled in order: a batch already sent is written first.
    _to?.send('close');
    _alive = false;
    // Its last reply may still come; nobody waits for it after this.
    Future<void>.delayed(const Duration(seconds: 30), () {
      _isolate?.kill(priority: Isolate.beforeNextEvent);
      _in.close();
      _exit.close();
    });
  }
}

void _entry(List<Object?> args) {
  final out = args[0] as SendPort;
  final path = args[1] as String;
  final secret = args[2] as String?;
  final archive = XprsArchive.instance;
  final err = archive.openWriter(path, secret);
  if (err != null) {
    out.send(err);
    return;
  }
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  inbox.listen((m) {
    if (m == 'close') {
      archive.close();
      inbox.close();
      Isolate.exit();
    }
    if (m is List && m.length == 2) {
      Map<String, Object?> reply;
      try {
        reply = archive.writeBatch((m[1] as Map).cast<String, Object?>());
      } catch (e) {
        reply = {'error': '$e'};
      }
      out.send([m[0], reply]);
    }
  });
}
