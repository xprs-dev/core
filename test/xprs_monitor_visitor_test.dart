// A visitor heard through the web page (XPRS.md 12.8.1, 12.8.3): at the
// station's ear for `hears:` and presence, but NOT a station a held packet can
// be re-aired to. The mailbox sweep asks the monitor with `radioOnly` and
// sends nothing to a browser; a hearing off a radio makes it reachable.
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_mailbox.dart';
import 'package:xprs_core/src/services/xprs/xprs_monitor.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main() {
  final mon = XprsMonitor.instance;
  const t0 = 1700000000000;

  setUp(() {
    mon.clear();
    XprsMailbox.instance.debugReset();
  });

  test('a visitor who only proved a session is at our ear on lan, not a radio hearing', () {
    mon.noteVisitor('X1VIS', nowMs: t0);
    expect(mon.directlyHeardOn('lan', nowMs: t0), ['X1VIS']);
    expect(mon.directlyHeard(nowMs: t0), ['X1VIS'], reason: 'hears: names them');
    expect(mon.heardDirectly('X1VIS', nowMs: t0), isTrue);
    expect(mon.heardDirectly('X1VIS', nowMs: t0, radioOnly: true), isFalse);
    expect(mon.stations['X1VIS']!.viaApi, isTrue);
    expect(mon.ring, isEmpty, reason: 'nothing was on the air');
  });

  test('a packet through the API is the same; one off the radio makes it reachable', () {
    final p = XprsPacket.parse('t:status f:X1VIS ts:2026-11-08_10:00:00 m:hi')!;
    mon.offer(p, bearer: 'lan', selfCallsign: 'X3SELF', nowMs: t0, viaApi: true);
    expect(mon.heardDirectly('X1VIS', nowMs: t0, radioOnly: true), isFalse);
    expect(mon.stations['X1VIS']!.viaApi, isTrue);
    mon.offer(p, bearer: 'lan', selfCallsign: 'X3SELF', nowMs: t0 + 1000);
    expect(mon.heardDirectly('X1VIS', nowMs: t0 + 1000, radioOnly: true), isTrue);
    expect(mon.stations['X1VIS']!.viaApi, isFalse);
    // The freshest hearing decides the flag; the radio hearing stays known.
    mon.offer(p, bearer: 'lan', selfCallsign: 'X3SELF', nowMs: t0 + 2000, viaApi: true);
    expect(mon.stations['X1VIS']!.viaApi, isTrue);
    expect(mon.heardDirectly('X1VIS', nowMs: t0 + 2000, radioOnly: true), isTrue,
        reason: 'heard on the LAN a second ago');
  });

  test('the mailbox sweep sends nothing to a visitor known only through the page', () async {
    final sent = <String>[];
    XprsMailbox.instance
      ..selfCallsign = (() => 'X3SELF')
      ..held = (() => const [
            HeldMail(
                key: 'k1',
                target: 'X1VIS',
                wire: 't:message f:X1AAAA d:X1VIS ts:2026-11-08_10:00:00 m:hello'),
          ])
      // The device's lambda (mesh_service): heard directly, off a radio.
      ..reachable = ((c) => mon.heardDirectly(c, radioOnly: true))
      ..sendTo = ((c, w) async {
        sent.add(c);
        return true;
      });
    mon.noteVisitor('X1VIS', nowMs: DateTime.now().millisecondsSinceEpoch);
    expect(await XprsMailbox.instance.sweepHeld(), 0);
    expect(sent, isEmpty, reason: 'a browser hears no re-air; the page delivers');
    // The same station heard on Bluetooth: the sweep delivers.
    mon.offer(XprsPacket.parse('t:status f:X1VIS m:back')!,
        bearer: 'ble', selfCallsign: 'X3SELF');
    expect(await XprsMailbox.instance.sweepHeld(), 1);
    expect(sent, ['X1VIS']);
  });
}
