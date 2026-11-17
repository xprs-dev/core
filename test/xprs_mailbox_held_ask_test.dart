// A held ask is handed over once, and a newer copy of the same question
// replaces the older ones (12.9.4, 12.10.2). Mail is unchanged: it stays
// held until a receipt.
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_mailbox.dart';

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

  test('mail stays held until a receipt', () async {
    store = [
      row('m', 't:message f:X10FCG d:X3APDH ts:2026-11-17_22:26:45 m:hello'),
    ];
    expect(await XprsMailbox.instance.sweepHeld(), 1);
    expect(dropped, isEmpty);
  });
}
