// A held ask is handed over once, and a newer copy of the same question
// replaces the older ones (12.9.4, 12.10.2). Mail is unchanged: it stays
// held until a receipt.
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_mailbox.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main() {
  late List<HeldMail> store;
  late List<String> sent;
  late List<String> dropped;

  HeldMail row(String key, String wire) =>
      HeldMail(key: key, target: 'X3APDH', wire: wire);

  setUp(() {
    XprsMailbox.instance.debugReset();
    XprsMailboxCounters.debugReset();
    sent = [];
    dropped = [];
    XprsMailbox.instance
      ..selfCallsign = (() => 'X3PTZM')
      ..held = (() => store.where((m) => !dropped.contains(m.key)).toList())
      ..reachable = ((_) => true)
      ..noteAttempt = ((_) {})
      ..drop = ((k) => dropped.add(k))
      ..sendTo = ((c, w) async {
        sent.add(w);
        return true;
      });
  });

  test('an ask is handed over once, then dropped', () async {
    store = [
      row('a1', 't:command f:X10FCG d:X3APDH ts:2026-11-17_22:26:45 '
          'cmd:history kind:message since:2026-11-11_09:02:55'),
    ];
    expect(await XprsMailbox.instance.sweepHeld(), 1);
    expect(dropped, ['a1']);
    expect(await XprsMailbox.instance.sweepHeld(), 0);
    expect(sent, hasLength(1));
  });

  test('older copies of the same question are superseded unsent', () async {
    store = [
      row('n', 't:command f:X1WATT d:X3APDH ts:2026-11-17_22:58:28 '
          'cmd:history kind:message,mailbox since:2026-11-10_21:33:23'),
      row('o', 't:command f:X1WATT d:X3APDH ts:2026-11-17_22:13:24 '
          'cmd:history kind:message,mailbox since:2026-11-10_21:33:23'),
      row('other', 't:command f:X1WATT d:X3APDH ts:2026-11-17_22:25:45 '
          'cmd:history kind:identity only:X5APD2 since:2026-11-10_22:25:45'),
    ];
    expect(await XprsMailbox.instance.sweepHeld(), 2);
    expect(sent.any((w) => w.contains('ts:2026-11-17_22:13:24')), isFalse,
        reason: 'only one of the two copies of the question was sent');
    expect(dropped.toSet(), {'n', 'o', 'other'});
    expect(XprsMailboxCounters.asksSuperseded, 1);
  });

  test('an answer is handed over once too', () async {
    store = [
      row('r', 't:result f:X3VGAZ d:X3APDH ts:2026-11-17_22:44:34 '
          'r:b2e6a9 code:404'),
    ];
    expect(await XprsMailbox.instance.sweepHeld(), 1);
    expect(dropped, ['r']);
  });

  // The way back (2026-11-27): a receipt is carried to the writer like any
  // mail, handed over once (nothing acknowledges a receipt), and not past
  // three days.
  String stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final u = t.toUtc();
    return '${u.year}-${two(u.month)}-${two(u.day)}_'
        '${two(u.hour)}:${two(u.minute)}:${two(u.second)}';
  }

  test('a receipt is handed to its writer once, then dropped', () async {
    final ts = stamp(DateTime.now().subtract(const Duration(hours: 5)));
    store = [row('k', 't:receipt f:X1U3K8 d:X3APDH ts:$ts r:9d0664 s:ack')];
    expect(await XprsMailbox.instance.sweepHeld(), 1);
    expect(dropped, ['k']);
    expect(await XprsMailbox.instance.sweepHeld(), 0);
    expect(sent, hasLength(1));
  });

  test('a receipt older than three days is dropped, not sent', () async {
    final ts = stamp(DateTime.now().subtract(const Duration(days: 4)));
    store = [row('old', 't:receipt f:X1U3K8 d:X3APDH ts:$ts r:9d0664 s:ack')];
    expect(await XprsMailbox.instance.sweepHeld(), 0);
    expect(sent, isEmpty);
    expect(dropped, ['old']);
    expect(XprsMailboxCounters.receiptsExpired, 1);
  });

  test('staleReceipt judges receipts only, by their ts', () {
    final now = DateTime.utc(2026, 11, 27, 12).millisecondsSinceEpoch;
    XprsPacket p(String w) => XprsPacket.parse(w)!;
    expect(
        XprsMailbox.staleReceipt(
            p('t:receipt f:A1 d:B1 ts:2026-11-23_12:00:00 r:abcdef s:ack'),
            nowMs: now),
        isTrue);
    expect(
        XprsMailbox.staleReceipt(
            p('t:receipt f:A1 d:B1 ts:2026-11-25_12:00:00 r:abcdef s:ack'),
            nowMs: now),
        isFalse);
    expect(
        XprsMailbox.staleReceipt(
            p('t:message f:A1 d:B1 ts:2026-11-01_12:00:00 m:old'),
            nowMs: now),
        isFalse,
        reason: 'mail is kept by the store\'s own limits, not this one');
  });

  test('mail stays held until a receipt', () async {
    store = [
      row('m', 't:message f:X10FCG d:X3APDH ts:2026-11-17_22:26:45 m:hello'),
    ];
    expect(await XprsMailbox.instance.sweepHeld(), 1);
    expect(dropped, isEmpty);
  });

  test('a sweep started while one runs does not deliver the same rows',
      () async {
    store = [
      row('a1', 't:command f:X10FCG d:X3APDH ts:2026-11-17_22:26:45 '
          'cmd:history kind:message since:2026-11-11_09:02:55'),
    ];
    final first = XprsMailbox.instance.sweepHeld();
    final second = XprsMailbox.instance.sweepHeld();
    expect(await first + await second, 1);
    expect(sent, hasLength(1));
  });
}
