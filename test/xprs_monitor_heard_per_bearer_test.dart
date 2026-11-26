// The BLE5 lane is the bearer `ble` here (kBearers).
// The station list wapps read (hal_xprs_stations) says how long ago each
// station was heard on each bearer: Check-in lists only stations heard over
// BLE5 in the last ten minutes, and the newest bearer alone would lose a
// station heard on Bluetooth a moment before a LAN packet arrived.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_monitor.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main() {
  final mon = XprsMonitor.instance;
  const t0 = 1700000000000;
  setUp(mon.clear);

  Map<String, dynamic> row(String call, int now) {
    final s = jsonDecode(mon.stationsJson(nowMs: now)) as List;
    final items = (s.first as Map)['items'] as List;
    return items.cast<Map<String, dynamic>>().firstWhere((r) => r['id'] == call);
  }

  void hear(String call, String bearer, int at, {int rssi = 0}) => mon.offer(
      XprsPacket.parse('t:observation f:$call link:$bearer ts:2026-11-08_10:00:00')!,
      bearer: bearer,
      rssi: rssi,
      selfCallsign: 'X3SELF',
      nowMs: at);

  test('each bearer with how long ago it was heard on it', () {
    hear('X3BLE1', 'ble', t0, rssi: -61);
    hear('X3BLE1', 'lan', t0 + 30000);
    final r = row('X3BLE1', t0 + 42000);
    expect(r['heard'], {'ble': 42, 'lan': 12});
    expect(r['subtitle'], startsWith('LAN'), reason: 'the newest bearer, as before');
  });

  test('a station only on the LAN has no Bluetooth age', () {
    hear('X3LAN1', 'lan', t0);
    expect((row('X3LAN1', t0 + 1000)['heard'] as Map).containsKey('ble'), isFalse);
  });
}
