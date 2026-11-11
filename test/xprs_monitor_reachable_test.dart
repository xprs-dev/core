// What the Android status notification counts as "n reachable": stations
// heard recently on a local (BLE, LAN) or regional (LoRa) bearer.
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_monitor.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main() {
  final mon = XprsMonitor.instance;
  const t0 = 1700000000000;
  XprsPacket status(String from) =>
      XprsPacket.parse('t:status f:$from ts:2026-11-08_10:00:00 m:hi')!;

  setUp(mon.clear);

  test('stations on BLE, LAN and LoRa count once each; our own echo does not', () {
    expect(mon.reachableCount(nowMs: t0), 0);
    mon.offer(status('X1BLE'), bearer: 'ble', selfCallsign: 'X3SELF', nowMs: t0);
    mon.offer(status('X1LAN'), bearer: 'lan', selfCallsign: 'X3SELF', nowMs: t0);
    mon.offer(status('X1LORA'), bearer: 'lora', selfCallsign: 'X3SELF', nowMs: t0);
    mon.offer(status('X1LAN'), bearer: 'ble', selfCallsign: 'X3SELF', nowMs: t0);
    mon.offer(status('X3SELF'), bearer: 'lan', selfCallsign: 'X3SELF', nowMs: t0);
    expect(mon.reachableCount(nowMs: t0), 3);
  });

  test('a station that went quiet stops counting', () {
    mon.offer(status('X1BLE'), bearer: 'ble', selfCallsign: 'X3SELF', nowMs: t0);
    final later = t0 + XprsMonitor.staleAfter.inMilliseconds + 1000;
    mon.offer(status('X1LORA'), bearer: 'lora', selfCallsign: 'X3SELF', nowMs: later);
    expect(mon.reachableCount(nowMs: later), 1);
  });
}
