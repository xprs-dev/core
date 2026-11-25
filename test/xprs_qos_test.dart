/*
 * QoS.md, rule by rule (../spec/QoS.md). Each group names the section it
 * checks; the replay harness (xprs_qos_replay_test.dart) checks the same
 * rules against recorded bench traffic.
 */
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_qos.dart';

const t0 = 1795620000000; // 2026-11-25 ~15:20 UTC, in ms
const t0s = t0 ~/ 1000;

String ts(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}_${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

XprsPacket pk(String w) => XprsPacket.parse(w)!;

XprsQosContext ctx(int ms,
        {bool own = false,
        bool fromOwner = false,
        Set<String> first = const {},
        bool Function(String)? reachedCheaper,
        bool Function(String)? heardHere,
        int stations = 0,
        double util = 0,
        bool clock = true}) =>
    XprsQosContext(
        nowMs: ms,
        heardOn: own || fromOwner ? null : 'ble',
        own: own,
        fromOwner: fromOwner,
        first: first,
        reachedCheaper: reachedCheaper,
        heardHere: heardHere,
        clockEpochS: clock ? ms ~/ 1000 : null,
        stationsHeard: stations,
        utilisation: util);

String msg(String from, int ms, {String extra = '', String text = 'hello'}) =>
    't:message f:$from ts:${ts(ms)} scope:regional$extra m:$text';

void main() {
  group('4.4 admission classes', () {
    test('types land in their classes', () {
      final c = ctx(t0);
      expect(xprsQosClassify(pk('t:sos f:X1AAAA m:help'), c), XprsQosClass.life);
      expect(xprsQosClassify(pk('t:warning f:X3AAAA kind:fire'), c), XprsQosClass.life);
      expect(xprsQosClassify(pk(msg('X1AAAA', t0)), c), XprsQosClass.conversation);
      expect(xprsQosClassify(pk('t:status f:X1AAAA m:on the quay'), c),
          XprsQosClass.conversation, reason: 'a status is a person\'s words, not a beacon');
      expect(xprsQosClassify(pk('t:command f:X3AAAA d:X3BBBB cmd:history'), c),
          XprsQosClass.transaction);
      expect(xprsQosClassify(pk('t:identity f:X1AAAA k:npub1x'), c), XprsQosClass.keys);
      expect(xprsQosClassify(pk('t:observation f:X3AAAA link:ble'), c), XprsQosClass.presence);
      expect(xprsQosClassify(pk('t:mailbox f:X3AAAA d:X1BBBB'), c), XprsQosClass.bulk);
      expect(xprsQosClassify(pk(msg('X1AAAA', t0)), ctx(t0, own: true)), XprsQosClass.owner);
    });

    test('scope:local never goes on a radio, even a call for help', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      final d = g.admit(pk('t:sos f:X1AAAA scope:local m:help'), ctx(t0));
      expect(d.shed, XprsQosShed.scope);
      final b = XprsQosGate(const XprsQosProfile.unmetered('ble5'));
      expect(b.admit(pk('t:sos f:X1AAAA scope:local m:help'), ctx(t0)).admitted, isTrue);
    });

    test('a packet for somebody reached on a cheaper bearer is not admitted', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      final d = g.admit(pk(msg('X1AAAA', t0, extra: ' d:X1BBBB')),
          ctx(t0, reachedCheaper: (c) => c == 'X1BBBB'));
      expect(d.shed, XprsQosShed.reached);
    });

    test('a transaction goes on LoRa only for somebody heard there', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      final w = pk('t:command f:X3AAAA d:X3BBBB ts:${ts(t0)} cmd:history');
      expect(g.admit(w, ctx(t0)).shed, XprsQosShed.notHere);
      expect(g.admit(w, ctx(t0, heardHere: (c) => c == 'X3BBBB')).admitted, isTrue);
      // On an unmetered bearer the rule does not apply.
      final b = XprsQosGate(const XprsQosProfile.unmetered('ble5'));
      expect(b.admit(w, ctx(t0)).admitted, isTrue);
    });

    test('not twice in half an hour', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      final p = pk(msg('X1AAAA', t0));
      expect(g.admit(p, ctx(t0)).admitted, isTrue);
      g.aired(p, XprsQosClass.conversation, 120, t0);
      expect(g.admit(p, ctx(t0 + 60000)).shed, XprsQosShed.aired);
      expect(g.admit(p, ctx(t0 + 31 * 60000)).admitted, isTrue);
    });

    test('old news is bulk, carried only on spare capacity', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      final old = pk(msg('X1AAAA', t0 - 2 * 3600000));
      final d = g.admit(old, ctx(t0));
      expect(d.cls, XprsQosClass.bulk);
      expect(d.admitted, isTrue, reason: 'the hour is unspent');
      // Spend half the budget: bulk waits for more than 60% free.
      _spend(g, t0, 180000);
      expect(g.admit(old, ctx(t0)).shed, XprsQosShed.oldNews);
      // Crowded: never.
      final g2 = XprsQosGate(XprsQosProfile.loraLongFast);
      expect(g2.admit(old, ctx(t0, stations: 8)).shed, XprsQosShed.oldNews);
      // A 1% band carries no bulk at all.
      final g3 = XprsQosGate(XprsQosProfile.lora1pct);
      expect(g3.admit(old, ctx(t0)).shed, XprsQosShed.oldNews);
    });

    test('with no clock, now is the newest ts: heard', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      _spend(g, t0, 180000); // no spare capacity: old news is shed
      g.admit(pk(msg('X1CCCC', t0)), ctx(t0, clock: false));
      final old = pk(msg('X1AAAA', t0 - 2 * 3600000));
      expect(g.admit(old, ctx(t0 + 1000, clock: false)).shed, XprsQosShed.oldNews);
    });
  });

  group('4.5 repeats', () {
    test('an observation on LoRa at most every 30 minutes per author', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      final o = pk('t:observation f:X3AAAA link:ble peers:3');
      expect(g.admit(o, ctx(t0)).admitted, isTrue);
      g.aired(o, XprsQosClass.presence, 100, t0);
      expect(g.admit(o, ctx(t0 + 10 * 60000)).shed, XprsQosShed.repeat);
      expect(g.admit(o, ctx(t0 + 30 * 60000)).admitted, isTrue);
      // Another author is another row.
      expect(g.admit(pk('t:observation f:X3BBBB link:ble'), ctx(t0 + 60000)).admitted, isTrue);
    });

    test('crowded: every 60 minutes', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      final o = pk('t:service f:X3AAAA serve:archive');
      g.aired(o, XprsQosClass.presence, 100, t0);
      expect(g.admit(o, ctx(t0 + 31 * 60000, stations: 8)).shed, XprsQosShed.repeat);
      expect(g.admit(o, ctx(t0 + 31 * 60000, util: 0.3)).shed, XprsQosShed.repeat);
      expect(g.admit(o, ctx(t0 + 61 * 60000, stations: 9)).admitted, isTrue);
    });

    test('Bluetooth and the LAN: every 5 minutes, with the timer\'s drift', () {
      final g = XprsQosGate(const XprsQosProfile.unmetered('lan'));
      final o = pk('t:observation f:X1AAAA link:lan');
      g.aired(o, XprsQosClass.owner, 100, t0);
      expect(g.admit(o, ctx(t0 + 60000, own: true)).shed, XprsQosShed.repeat,
          reason: 'our own beacon is a beacon too');
      expect(g.admit(o, ctx(t0 + 299800, own: true)).admitted, isTrue,
          reason: 'a 300 s timer firing 200 ms early is not a repeat');
    });

    test('an identity with a new key goes out at once', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      g.aired(pk('t:identity f:X1AAAA k:npub1old'), XprsQosClass.keys, 100, t0);
      expect(g.admit(pk('t:identity f:X1AAAA k:npub1old'), ctx(t0 + 60000)).shed,
          XprsQosShed.repeat);
      expect(g.admit(pk('t:identity f:X1AAAA k:npub1new'), ctx(t0 + 60000)).admitted, isTrue);
    });

    test('messages and statuses are never repeats', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      g.aired(pk('t:status f:X1AAAA ts:${ts(t0)} m:one'), XprsQosClass.conversation, 50, t0);
      expect(g.admit(pk('t:status f:X1AAAA ts:${ts(t0 + 1000)} m:two'), ctx(t0 + 1000)).admitted,
          isTrue);
    });
  });

  group('4.2 the owner\'s reserve', () {
    test('third parties stop at 90%, the owner at 98%, sos at 100%', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      final air = XprsQosProfile.loraLongFast.airtimeMs!(150);
      // Fill to just under 90% with third-party traffic spread over the hour
      // so the six-minute pace does not bind.
      var spent = 0, at = t0, n = 0;
      while (spent + air <= 324000) {
        g.aired(pk(msg('X1T${(n % 26 + 10).toRadixString(36).toUpperCase()}AAA', at, text: '$n')),
            XprsQosClass.conversation, 150, at);
        spent += air;
        at += 6000;
        n++;
      }
      final now = at;
      expect(g.mayAir(XprsQosClass.conversation, 'X1ZZZZ', 150, now), XprsQosShed.budget);
      expect(g.mayAir(XprsQosClass.owner, 'X1OWNR', 150, now), XprsQosShed.none);
      // Spend the reserve down to the life slice.
      while (g.mayAir(XprsQosClass.owner, 'X1OWNR', 150, now) == XprsQosShed.none) {
        g.aired(pk('t:message f:X1OWNR ts:${ts(now)} m:o'), XprsQosClass.owner, 150, now);
      }
      expect(g.spentMs(now), lessThanOrEqualTo(360000 * 0.98));
      expect(g.mayAir(XprsQosClass.life, 'X1SOS1', 150, now), XprsQosShed.none);
    });

    test('an unmetered bearer has no budget', () {
      final g = XprsQosGate(const XprsQosProfile.unmetered('ble5'));
      expect(g.mayAir(XprsQosClass.bulk, 'X1AAAA', 250, t0), XprsQosShed.none);
    });
  });

  group('4.7 pacing', () {
    test('no more than a tenth of the budget in six minutes for L2-L6', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      var n = 0;
      while (g.mayAir(XprsQosClass.conversation, 'X1A$n', 200, t0) == XprsQosShed.none) {
        g.aired(pk(msg('X1A$n', t0, text: '$n')), XprsQosClass.conversation, 200, t0);
        n++;
      }
      expect(g.spentMs(t0, 6), lessThanOrEqualTo(36000));
      expect(g.mayAir(XprsQosClass.owner, 'X1OWNR', 200, t0), XprsQosShed.none,
          reason: 'the owner is not paced');
      expect(g.mayAir(XprsQosClass.conversation, 'X1NEW', 200, t0 + 7 * 60000),
          XprsQosShed.none, reason: 'the window rolled');
    });
  });

  group('4.6 fair share', () {
    test('a lone author gets a quarter, and what others leave is shared', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      final third = (360000 * 0.9).floor();
      expect(g.fairCap('X1AAAA', t0), third ~/ 4);
      g.aired(pk(msg('X1LITE', t0)), XprsQosClass.conversation, 100, t0);
      final cap = g.fairCap('X1AAAA', t0);
      expect(cap, greaterThan(third ~/ 4), reason: 'the light author\'s unused share is lent');
      expect(cap, lessThanOrEqualTo(third ~/ 3));
    });

    test('a chatty author is held while others still go', () {
      final g = XprsQosGate(XprsQosProfile.loraLongFast);
      var at = t0;
      var n = 0;
      while (g.mayAir(XprsQosClass.conversation, 'X1CHAT', 200, at) == XprsQosShed.none) {
        g.aired(pk(msg('X1CHAT', at, text: '$n')), XprsQosClass.conversation, 200, at);
        at += 20000; // ~32 s per six minutes: under the pace
        n++;
        if (n > 500) fail('fair share never bound');
      }
      expect(g.mayAir(XprsQosClass.conversation, 'X1CHAT', 200, at), XprsQosShed.fairShare);
      expect(g.mayAir(XprsQosClass.conversation, 'X1QUIET', 200, at), XprsQosShed.none);
    });
  });

  group('4.3 order and 4.8 the queue', () {
    XprsQosQueue q() => XprsQosQueue(XprsQosGate(XprsQosProfile.loraLongFast));

    test('sos, owner, first:, urg:, oldest ts:', () {
      final qu = q();
      final c = ctx(t0, first: {'X1FRST'});
      qu.offer(msg('X1LATE', t0 - 1000), c);
      qu.offer(msg('X1OLDR', t0 - 5000), c);
      qu.offer(msg('X1HIGH', t0, extra: ' urg:high'), c);
      qu.offer(msg('X1URGT', t0, extra: ' urg:urgent'), c); // a stranger: as high
      qu.offer(msg('X1FRST', t0), c);
      qu.offer(msg('X1OWNR', t0), ctx(t0, own: true));
      qu.offer('t:sos f:X1HELP ts:${ts(t0)} m:help', c);
      final order = <String>[];
      for (var e = qu.next(t0); e != null; e = qu.next(t0)) {
        order.add(e.author);
      }
      expect(order, ['X1HELP', 'X1OWNR', 'X1FRST', 'X1HIGH', 'X1URGT', 'X1OLDR', 'X1LATE']);
    });

    test('expiry by class', () {
      final qu = q();
      qu.offer('t:command f:X3AAAA d:X3BBBB ts:${ts(t0)} cmd:ping',
          ctx(t0, heardHere: (_) => true));
      qu.offer(msg('X1AAAA', t0), ctx(t0));
      final e = qu.next(t0 + 3 * 60000);
      expect(e?.cls, XprsQosClass.conversation, reason: 'the command expired after 2 min');
      expect(qu.length, 0);
    });

    test('a full queue evicts the lowest class, never sos for anything else', () {
      final qu = q();
      for (var i = 0; i < qu.profile.queueMax; i++) {
        qu.offer('t:sos f:X1S${i.toString().padLeft(3, '0')} ts:${ts(t0)} m:help', ctx(t0));
      }
      expect(qu.offer(msg('X1OWNR', t0), ctx(t0, own: true)).shed, XprsQosShed.evicted);
      final qu2 = q();
      for (var i = 0; i < qu2.profile.queueMax; i++) {
        qu2.offer(msg('X1M${i.toString().padLeft(3, '0')}', t0), ctx(t0));
      }
      expect(qu2.offer('t:sos f:X1HELP ts:${ts(t0)} m:help', ctx(t0)).admitted, isTrue);
      expect(qu2.next(t0)?.author, 'X1HELP');
    });

    test('9.2.1: cancelled when another station airs it', () {
      final qu = q();
      final w = msg('X1AAAA', t0);
      qu.offer(w, ctx(t0));
      expect(qu.cancel(xprsQosIdOf(w)), isTrue);
      expect(qu.next(t0), isNull);
    });
  });

  test('LongFast airtime is in the measured range', () {
    final air = XprsQosProfile.loraLongFast.airtimeMs!;
    // A 190-byte XPRS wire in one Meshtastic frame (206 bytes) at SF11,
    // 250 kHz, preamble 16: Semtech's formula gives 1788 ms, LongFast's
    // ~1.1 kbit/s.
    expect(air(190), inInclusiveRange(1700, 1900));
    expect(air(240), greaterThan(air(220)), reason: 'two frames past 220 bytes');
  });
}

void _spend(XprsQosGate g, int at, int ms) {
  // Charge [ms] of owner traffic (owner traffic is neither paced nor shared).
  final per = g.profile.airtimeMs!(200);
  for (var s = 0; s < ms; s += per) {
    g.aired(pk('t:message f:X1OWNR ts:${ts(at)} m:$s'), XprsQosClass.owner, 200, at);
  }
}
