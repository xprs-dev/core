import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_archiver_choice.dart';

void main() {
  const now = 10 * 3600 * 1000;
  ArchiverOffer o(String c, String bearer, {int agoS = 10, int up = 0}) =>
      ArchiverOffer(
          callsign: c,
          lastHeardMs: now - agoS * 1000,
          bearer: bearer,
          uptimeS: up);

  test('an internet or LAN volunteer beats a radio one', () {
    final pick = XprsArchiverChoice.pick(
        [o('X3BLE1', 'ble', up: 9999), o('X3LAN1', 'lan')],
        selfBase: 'X1ME', nowMs: now);
    expect(pick, 'X3LAN1');
  });

  test('an adopted on-grid archiver is kept against a newcomer', () {
    final pick = XprsArchiverChoice.pick(
        [o('X3LAN1', 'lan'), o('X3RNS1', 'rns', up: 99999)],
        selfBase: 'X1ME', nowMs: now, current: 'X3LAN1');
    expect(pick, 'X3LAN1');
  });

  test('an adopted radio-only archiver gives way to a LAN volunteer', () {
    final pick = XprsArchiverChoice.pick(
        [o('X3BLE1', 'ble'), o('X3LAN1', 'lan')],
        selfBase: 'X1ME', nowMs: now, current: 'X3BLE1');
    expect(pick, 'X3LAN1');
  });

  test('a radio-only archiver is kept while nothing better is heard', () {
    final pick = XprsArchiverChoice.pick(
        [o('X3BLE1', 'ble'), o('X3BLE2', 'ble', up: 99999)],
        selfBase: 'X1ME', nowMs: now, current: 'X3BLE1');
    expect(pick, 'X3BLE1');
  });

  test('a stale LAN claim does not displace the radio archiver', () {
    final pick = XprsArchiverChoice.pick(
        [o('X3BLE1', 'ble'), o('X3LAN1', 'lan', agoS: 7 * 3600)],
        selfBase: 'X1ME', nowMs: now, current: 'X3BLE1');
    expect(pick, 'X3BLE1');
  });

  test('among equals on the bearer: room first, then what keeps it going',
      () {
    ArchiverOffer r(String c, {bool room = true, int rank = 0}) =>
        ArchiverOffer(
            callsign: c,
            lastHeardMs: now - 10000,
            bearer: 'rns',
            uptimeS: 99999,
            room: room,
            rank: rank);
    expect(
        XprsArchiverChoice.pick([r('X3GRID'), r('X3SOLAR', rank: 121)],
            selfBase: 'X1ME', nowMs: now),
        'X3SOLAR');
    expect(
        XprsArchiverChoice.pick(
            [r('X3FULL', room: false, rank: 121), r('X3GRID')],
            selfBase: 'X1ME', nowMs: now),
        'X3GRID',
        reason: 'room:no is never chosen over one with room');
  });
}
