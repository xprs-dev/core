// An ask for a few types is read on the index by type, NAMED in the statement:
// zx's planner otherwise takes the index by addressee for `toc = ''` (most of
// a spool) or the author's own range (a station's beacons), and walks it.
// Measured on the Pi's server, 2026-11-26, a 315,000-row archive: 5 s for its
// forty blog rows, 3.5 s for the seven files of a station with 44,000 rows of
// its own, on every page that opened; 3 ms each on idx_pk_type
// (tool/plan_probe.dart, tool/history_time.dart).
//
// The rows are the same as before; these check that, for each way of asking.
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart';

void main() {
  late Directory dir;
  final a = XprsArchive.instance;

  String ts(int i) =>
      '2026-11-26_${(10 + i ~/ 3600).toString().padLeft(2, '0')}:'
      '${((i ~/ 60) % 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')}';

  void put(String wire, {bool own = false}) =>
      a.admit(XprsPacket.parse(wire)!, bearer: 'lan', own: own);

  String said(Map<String, dynamic> r) => '${r['wire']}'.split(' name:').last;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xprs-rare');
    a
      ..init('${dir.path}/archive.zx')
      ..selfCallsign = 'X3SELF';
    // A station's file: its own beacons by the hundred, others' talk, and a
    // handful of files among them.
    for (var i = 0; i < 600; i++) {
      put('t:observation f:X3SELF ts:${ts(i)} hears:X1N${i % 9} link:lan', own: true);
      if (i % 20 == 0) put('t:message f:X1N${i % 9} ts:${ts(i)} m:talk $i');
    }
    put('t:file f:X3SELF ts:${ts(700)} file:aa.bin size:1 name:one', own: true);
    put('t:file f:X1OTHR ts:${ts(701)} file:bb.bin size:1 name:theirs');
    put('t:file f:X3SELF d:X1BOBB ts:${ts(702)} file:cc.bin size:1 name:forbob', own: true);
    put('t:file f:X3SELF ts:${ts(703)} file:dd.bin size:1 name:two', own: true);
    put('t:file f:X1OTHR d:X3SELF ts:${ts(704)} file:ee.bin size:1 name:forus');
    put('t:observation f:X3FARR ts:${ts(705)} hears:X1BOBB link:lora');
    a.flush();
  });
  tearDown(() {
    a.close();
    dir.deleteSync(recursive: true);
  });

  test('the statement names the index, and zx takes it', () {
    expect(
        a.debugPlan(
            'SELECT id FROM packets INDEXED BY idx_pk_type WHERE 1=1 AND toc IN (?) '
            'AND type = ? ORDER BY pts DESC LIMIT ?',
            ['', 'file', 5]),
        contains('idx_pk_type'));
  });

  test("one author's rows of a type, undirected: newest first, nobody else's", () {
    final rows = a.query(
        types: const ['file'], to: const [''], from: 'X3SELF', limit: 100);
    expect([for (final r in rows) said(r)], ['two', 'one']);
    expect(a.query(types: const ['file'], from: 'X3SELF', limit: 1).length, 1);
    expect(
        a.query(types: const ['file'], from: 'X3SELF', limit: 100).map(said),
        ['two', 'forbob', 'one'],
        reason: 'directed ones too when no addressee is asked');
    expect(a.query(types: const ['file'], from: 'X1NOBODY', limit: 10), isEmpty);
    expect(a.query(types: const ['blog'], from: 'X3SELF', limit: 10), isEmpty);
  });

  test('a window still bounds it', () {
    final since = xprsParseTs(ts(702));
    expect(
        a.query(types: const ['file'], from: 'X3SELF', sinceMs: since, limit: 100)
            .map(said),
        ['two', 'forbob']);
  });

  test('about one callsign: sent by it or addressed to it', () {
    List<String> ask(String c, List<String> types) =>
        [for (final r in a.query(only: c, types: types, limit: 50)) said(r)];
    expect(ask('X3SELF', const ['file']), ['forus', 'two', 'forbob', 'one']);
    expect(ask('X1BOBB', const ['file']), ['forbob']);
    expect(ask('X1NOBODY', const ['file']), isEmpty);
    // An observation ABOUT the callsign names it in hears:.
    final about = a.query(only: 'X1BOBB', types: const ['file', 'observation'], limit: 50);
    expect([for (final r in about) '${r['from']} ${r['type']}'],
        ['X3FARR observation', 'X3SELF file']);
  });

  test("a stranger's ask: this station's own rows only", () {
    final rows = a.query(types: const ['file'], ownOnly: true, limit: 50);
    expect([for (final r in rows) said(r)], ['two', 'forbob', 'one']);
    expect(a.query(types: const ['blog'], ownOnly: true, limit: 50), isEmpty);
  });

  test('the page asks: every readable kind at once, and one kind', () {
    final all = a.query(
        types: const [
          'message', 'reaction', 'status', 'info', 'warning', 'event', 'blog',
          'sos', 'identity', 'file',
        ],
        to: const [''],
        limit: 200);
    expect(all.length, 30 + 3, reason: 'thirty messages and the undirected files');
    expect(said(all.first), 'two');
    expect(all.every((r) => r['to'] == ''), isTrue);
  });
}
