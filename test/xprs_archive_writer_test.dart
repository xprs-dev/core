// The archive is written on its own thread (performance.md 8.28). Measured
// on a phone, 2026-11-23: the write ran on the isolate that draws, in
// slices, and a slice still took 1.9 s. These check that the rows really
// go through the thread, and that what the main isolate keeps in memory
// (counters, a room's count, the hooks) stays true with two isolates
// writing the same file.
import 'dart:io';
import 'dart:math';

import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_id.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

BigInt _key(int seed) {
  final r = Random(seed);
  var d = BigInt.zero;
  for (var i = 0; i < 31; i++) {
    d = (d << 8) | BigInt.from(r.nextInt(256));
  }
  return d + BigInt.one;
}

void main() {
  late Directory dir;
  final a = XprsArchive.instance;
  final alice = _key(1), mallory = _key(2);
  final alicePub = XprsCrypto.publicKeyXOnly(alice);
  var n = 0;

  XprsPacket signed(String rest, BigInt d) => xprsSign(
      XprsPacket.parse('t:message f:X1ALIC ts:2026-11-23_10:00:${(n++ % 60).toString().padLeft(2, '0')} $rest')!,
      d);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('xprs-writer');
    XprsArchive.drainWriterStats();
    a
      ..offThreadWrites = true
      ..keyResolver = ((c) => c == 'X1ALIC' ? alicePub : null)
      ..init('${dir.path}/archive.zx');
    final until = DateTime.now().add(const Duration(seconds: 20));
    while (!a.writesOffThread && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(a.writesOffThread, isTrue, reason: 'the writer thread did not start');
  });
  tearDown(() {
    a
      ..close()
      ..offThreadWrites = false
      ..keyResolver = null
      ..onStored = null
      ..onVerdict = null;
    dir.deleteSync(recursive: true);
  });

  test('rows are written by the thread, checked, and readable here', () async {
    final stored = <String>[];
    final verdicts = <String, XprsSigState>{};
    a
      ..onStored = ((f, _) => stored.add(f))
      ..onVerdict = ((c, s) => verdicts['$c ${s.name}'] = s);
    final good = signed('m:hello', alice);
    final forged = signed('m:not alice', mallory);
    a
      ..admit(good, bearer: 'lan')
      ..admit(forged, bearer: 'lan')
      ..admit(XprsPacket.parse('t:message f:X1BOBB ts:2026-11-23_10:01:00 m:plain')!,
          bearer: 'lan');
    expect(a.pendingWire(xprsIdentifier(good)), good.encode(),
        reason: 'what waits is findable before it is written');
    await a.flushNow();
    expect(a.wireById(xprsIdentifier(good)), isNotNull);
    expect(a.wireById(xprsIdentifier(forged)), isNull, reason: 'forged: dropped');
    expect(verdicts.keys, contains('X1ALIC forged'));
    expect(stored, containsAll(['X1ALIC', 'X1BOBB']));
    expect(a.countOf(types: const ['message']), 2);
    expect(a.forged, greaterThanOrEqualTo(1));
    expect(XprsArchive.drainWriterStats()['rows'], 3,
        reason: 'written by the thread, not inline');
  });

  test('counters stay true when both isolates change the rows', () async {
    for (var i = 0; i < 5; i++) {
      a.admit(signed('d:X5GRUP m:in the group $i', alice), bearer: 'lan');
    }
    a.admit(signed('m:elsewhere', alice), bearer: 'lan');
    await a.flushNow();
    expect(a.countOf(), a.debugCount());
    expect(a.messagesTo('X5GRUP'), 5);
    // This isolate removes rows itself (a group forgotten)...
    a.forgetGroup('X5GRUP');
    await a.flushNow();
    expect(a.countOf(), a.debugCount());
    // ...and the thread then adds more: the table must carry both.
    a.admit(signed('d:X5GRUP m:after', alice), bearer: 'lan');
    a.admit(signed('m:after too', alice), bearer: 'lan');
    await a.flushNow();
    expect(a.countOf(), a.debugCount());
    expect(a.messagesTo('X5GRUP'), 1);
  });

  test("a room's kept count follows what the thread writes", () async {
    a.admit(signed('d:X5ROOM m:one', alice), bearer: 'lan');
    await a.flushNow();
    expect(a.messagesTo('X5ROOM'), 1); // now kept in memory
    a.admit(signed('d:X5ROOM m:two', alice), bearer: 'lan');
    a.admit(signed('d:X5ROOM m:three', alice), bearer: 'lan');
    await a.flushNow();
    expect(a.messagesTo('X5ROOM'), 3);
  });

  test('declarations and visitors are written by the thread, not here', () async {
    a.selfCallsign = 'X3SELF';
    final decl = xprsSign(
        XprsPacket.parse('t:mailbox f:X1ALIC ts:2026-11-23_11:00:00 hold:X3SELF')!,
        alice);
    final fake = xprsSign(
        XprsPacket.parse('t:mailbox f:X1ALIC ts:2026-11-23_11:00:01 hold:X3SELF,X3MALL')!,
        mallory);
    expect(a.recordMailboxDecl(decl), isTrue, reason: 'it names us');
    a.recordMailboxDecl(fake);
    a.noteServed('X1VISI');
    expect(a.servesVisitor('X1VISI'), isTrue, reason: 'known here at once');
    await a.flushNow();
    expect(a.hasActiveDecl('X1ALIC'), isTrue);
    expect(a.holdersFor('X1ALIC'), isNot(contains('X3MALL')),
        reason: 'the forged declaration was refused by the thread');
    expect(a.servedVisitors().map((v) => v.call), contains('X1VISI'));
    a.selfCallsign = '';
  });
}
