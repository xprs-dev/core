/*
 * Browser half of store_db_host.dart: the zx store files (held in memory by
 * package:zx, ZxWebFs) persisted in IndexedDB database `xprs-zx`.
 *
 *   files   one record per file id: {id, path, length, mtime}. A rename is
 *           the same id with a new path.
 *   chunks  key [id, n]: the n-th 64 KiB piece of file id.
 *
 * After any change a flush is scheduled (300 ms later); a flush writes
 * ZxWebFs.changes() in one readwrite transaction. When a transaction fails,
 * every file is marked changed again (ZxWebFs.markAllDirty) so the next
 * flush rewrites everything. Page hide and hidden visibility flush at once.
 */
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;
import 'package:zx/zxdb_web.dart';

import '../services/log_service.dart';

const String _dbName = 'xprs-zx';
const String _files = 'files';
const String _chunks = 'chunks';
const Duration _debounce = Duration(milliseconds: 300);

web.IDBDatabase? _db;
Timer? _timer;
Future<void>? _inFlight;

Future<T> _await<T extends JSAny?>(web.IDBRequest req) {
  final c = Completer<T>();
  req.onsuccess = ((web.Event _) => c.complete(req.result as T)).toJS;
  req.onerror = ((web.Event _) => c.completeError(
      StateError('IndexedDB request failed: ${req.error?.message}'))).toJS;
  return c.future;
}

Future<web.IDBDatabase> _open() {
  final c = Completer<web.IDBDatabase>();
  final req = web.window.indexedDB.open(_dbName, 1);
  req.onupgradeneeded = ((web.Event _) {
    final db = req.result as web.IDBDatabase;
    if (!db.objectStoreNames.contains(_files)) {
      db.createObjectStore(_files, web.IDBObjectStoreParameters(keyPath: 'id'.toJS));
    }
    if (!db.objectStoreNames.contains(_chunks)) {
      db.createObjectStore(_chunks);
    }
  }).toJS;
  req.onsuccess = ((web.Event _) => c.complete(req.result as web.IDBDatabase)).toJS;
  req.onerror = ((web.Event _) => c.completeError(
      StateError('IndexedDB open of $_dbName failed: ${req.error?.message}'))).toJS;
  return c.future;
}

JSArray<JSAny?> _key(int id, int n) => [id.toJS, n.toJS].toJS;

web.IDBKeyRange _range(int id, int from) =>
    web.IDBKeyRange.bound(_key(id, from), _key(id, 1 << 30));

/// Loads the stores' files from IndexedDB into memory and starts writing
/// their changes back. Idempotent.
Future<void> initStoreDb() async {
  if (_db != null) return;
  final db = await _open();
  _db = db;
  final fs = ZxWebFs.instance;
  final tx = db.transaction([_files.toJS, _chunks.toJS].toJS, 'readonly');
  final recs = await _await<JSArray<JSObject>>(tx.objectStore(_files).getAll());
  for (final r in recs.toDart) {
    final m = r.dartify();
    if (m is! Map) continue;
    final id = (m['id'] as num).toInt();
    final length = (m['length'] as num).toInt();
    final bytes = Uint8List(length);
    final parts = await _await<JSArray<JSAny?>>(
        tx.objectStore(_chunks).getAll(_range(id, 0)));
    final list = parts.toDart;
    for (var n = 0; n < list.length; n++) {
      final b = (list[n] as JSUint8Array).toDart;
      final at = n * zxWebChunk;
      if (at >= length) break;
      final end = at + b.length > length ? length : at + b.length;
      bytes.setRange(at, end, b);
    }
    fs.restore(m['path'] as String, id, bytes,
        DateTime.fromMillisecondsSinceEpoch((m['mtime'] as num).toInt()));
  }
  fs.onChange = () {
    _timer?.cancel();
    _timer = Timer(_debounce, () => unawaited(flushStoreDb()));
  };
  void now(web.Event _) => unawaited(flushStoreDb());
  web.window.addEventListener('pagehide', now.toJS);
  web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        if (web.document.visibilityState == 'hidden') unawaited(flushStoreDb());
      }).toJS);
}

/// Tests: closes IndexedDB and empties the memory, as a page reload would.
void resetStoreDbHostForTest() {
  _timer?.cancel();
  _db?.close();
  _db = null;
  ZxWebFs.instance
    ..onChange = null
    ..reset();
}

/// Writes every change of the stores' files to IndexedDB and waits for it.
Future<void> flushStoreDb() {
  final f = _inFlight;
  if (f != null) return f.then((_) => _write());
  return _write();
}

Future<void> _write() {
  final db = _db;
  if (db == null) return Future.value();
  final fs = ZxWebFs.instance;
  final changes = fs.changes();
  if (changes.isEmpty) return Future.value();
  final c = Completer<void>();
  _inFlight = c.future;
  void done() {
    if (c.isCompleted) return;
    _inFlight = null;
    c.complete();
  }

  try {
    final tx = db.transaction([_files.toJS, _chunks.toJS].toJS, 'readwrite');
    final files = tx.objectStore(_files);
    final chunkStore = tx.objectStore(_chunks);
    for (final ch in changes) {
      switch (ch) {
        case ZxWebFsDelete(:final id):
          files.delete(id.toJS);
          chunkStore.delete(_range(id, 0));
        case ZxWebFsFile(
            :final path,
            :final id,
            :final length,
            :final modified,
            chunks: final parts
          ):
          files.put({
            'id': id,
            'path': path,
            'length': length,
            'mtime': modified.millisecondsSinceEpoch,
          }.jsify());
          parts.forEach((n, bytes) => chunkStore.put(bytes.toJS, _key(id, n)));
          // pieces past the end are gone (a truncation)
          chunkStore.delete(_range(id, (length + zxWebChunk - 1) ~/ zxWebChunk));
        case ZxWebFsDir():
          break; // folders come back with their files
      }
    }
    tx.oncomplete = ((web.Event _) => done()).toJS;
    tx.onerror = ((web.Event _) {
      LogService.instance.add('stores(web): write of ${changes.length} changes '
          'failed: ${tx.error?.name} ${tx.error?.message}; all rewritten next');
      fs.markAllDirty();
      done();
    }).toJS;
    tx.onabort = ((web.Event _) {
      fs.markAllDirty();
      done();
    }).toJS;
  } catch (e) {
    LogService.instance.add('stores(web): write threw: $e');
    fs.markAllDirty();
    done();
  }
  return c.future;
}
