// The archive's index by type (idx_pk_type) is built ONCE in the file's life,
// by the writer thread, and kept in the file: a later start only looks it up.
// Type-filtered asks then read one index range per type. Measured on the
// Pi's server, 2026-11-23: an inline history request for talk types walked a
// spool of observations, 2.5 s each.
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/log_service.dart';
import 'package:xprs_core/src/storage/store_db.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

String _ts(int s) =>
    '2026-11-23_10:${(s ~/ 60 % 60).toString().padLeft(2, '0')}:'
    '${(s % 60).toString().padLeft(2, '0')}';

void main() {
  late Directory dir;
  final a = XprsArchive.instance;
  final t0 = DateTime.utc(2026, 11, 23, 10).millisecondsSinceEpoch;

  void fill() {
    for (var i = 0; i < 400; i++) {
      final at = t0 + i * 1000;
      final p = i % 10 == 3
          ? 't:message f:X1N${i % 7} ts:${_ts(i)} m:talk $i'
          : i % 10 == 7
              ? 't:message f:X1N${i % 7} d:X1DEST ts:${_ts(i)} m:mail $i'
              : 't:observation f:X1N${i % 7} ts:${_ts(i)} hears:X1N${i % 5}';
      a.admit(XprsPacket.parse(p)!, bearer: 'lan', nowMs: at);
    }
  }

  Future<void> waitFor(bool Function() ok) async {
    final until = DateTime.now().add(const Duration(seconds: 20));
    while (!ok() && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  setUp(() => dir = Directory.systemTemp.createTempSync('xprs-type-index'));
  tearDown(() {
    a
      ..close()
      ..offThreadWrites = false;
    dir.deleteSync(recursive: true);
  });

  test('without a writer thread it is made at once, and asks give the same rows',
      () async {
    a.init('${dir.path}/a.zx');
    expect(a.typeIndexReady, isTrue);
    fill();
    a.flush();
    final talk = a.query(types: const ['message'], to: const [''], limit: 5);
    expect([for (final r in talk) r['wire']], [
      for (final i in [393, 383, 373, 363, 353]) contains('m:talk $i'),
    ], reason: 'newest first, undirected only');
    final mixed = a.query(
        types: const ['message', 'observation'],
        sinceMs: t0 + 390 * 1000,
        limit: 50);
    expect(mixed.length, 10, reason: 'both types inside the window');
    expect(a.query(types: const ['reaction'], limit: 5), isEmpty);
    expect(a.debugPlan(
        "SELECT id FROM packets WHERE 1=1 AND type = ? ORDER BY pts DESC LIMIT 5",
        ['message']), contains('idx_pk_type'));
  });

  test('with the thread: built there once, used here, never again', () async {
    final logs = <String>[];
    final before = LogService.instance.onLine;
    LogService.instance.onLine = (l) {
      logs.add(l);
      before?.call(l);
    };
    addTearDown(() => LogService.instance.onLine = before);
    final path = '${dir.path}/b.zx';
    // An archive from before the index: rows, no idx_pk_type.
    a.init(path);
    fill();
    a.flush();
    a.close();
    final old = openStoreDb(path, autoCompact: false);
    old.execute('DROP INDEX idx_pk_type');
    old.dispose();
    a
      ..offThreadWrites = true
      ..init(path);
    expect(a.typeIndexReady, isFalse, reason: 'the main isolate does not build it');
    await waitFor(() => a.typeIndexReady);
    expect(a.typeIndexReady, isTrue, reason: 'the thread built it');
    expect(logs.where((l) => l.contains('index by type built once')), hasLength(1));
    expect(a.debugPlan(
        'SELECT id FROM packets WHERE 1=1 AND type = ? ORDER BY pts DESC LIMIT 5',
        ['message']), contains('idx_pk_type'),
        reason: 'this connection sees the index the thread made');
    expect(a.query(types: const ['message'], to: const [''], limit: 3).length, 3);
    // A later start: found in the file, nothing built.
    a.init(path);
    expect(a.typeIndexReady, isTrue);
    await waitFor(() => a.writesOffThread);
    await a.flushNow();
    expect(logs.where((l) => l.contains('index by type built once')), hasLength(1));
  });
}
