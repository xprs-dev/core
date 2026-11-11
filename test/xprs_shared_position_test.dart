// A station's position goes out only when its owner shares it, coarsened to
// their radius, and the stations that hear it remember where it said it is.
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_monitor.dart';
import 'package:xprs_core/src/services/xprs/xprs_observation.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_shared_position.dart';

void main() {
  group('coarsening', () {
    test('10 m: four decimals (15.1), the true spot within the cell', () {
      final c = xprsCoarsePos(38.70771234, -9.13654321, 10);
      expect(c.acc, 10);
      final parts = c.pos.split(',');
      expect(parts[0].split('.')[1].length, 4);
      expect((double.parse(parts[0]) - 38.70771234).abs() * 111320, lessThan(10));
    });

    test('1 km: two decimals; 10 km: one', () {
      expect(xprsCoarsePos(38.7077, -9.1365, 1000).pos.split(',')[0].split('.')[1].length, 2);
      expect(xprsCoarsePos(38.7077, -9.1365, 10000).pos.split(',')[0].split('.')[1].length, 1);
    });

    test('the same cell every time: nearby points inside one cell agree', () {
      final a = xprsCoarsePos(38.70712, -9.13651, 1000);
      final b = xprsCoarsePos(38.70714, -9.13649, 1000);
      expect(a.pos, b.pos);
    });

    test('a position written by hand is read back, nonsense is not', () {
      expect(xprsParseLatLon('38.7077,-9.1365'), isNotNull);
      expect(xprsParseLatLon('91,0'), isNull);
      expect(xprsParseLatLon('here'), isNull);
    });
  });

  group('sharing', () {
    final sp = XprsSharedPosition.instance;
    var on = false;
    var fixed = '';
    setUp(() {
      sp.debugReset();
      on = false;
      fixed = '';
      sp.enabled = () => on;
      sp.radiusM = () => 100;
      sp.fixed = () => fixed;
    });

    test('off: nothing, whatever the station knows', () {
      sp.debugSetFix(38.7, -9.1);
      fixed = '38.7,-9.1';
      expect(sp.current(), isNull);
    });

    test('on with no GPS: the fixed position, coarsened', () {
      on = true;
      fixed = '38.70771,-9.13654';
      final c = sp.current()!;
      expect(c.acc, 100);
      expect(c.pos.split(',')[0].split('.')[1].length, 3);
    });

    test('on with a fix: the fix wins', () {
      on = true;
      fixed = '0,0';
      sp.debugSetFix(38.7077, -9.1365);
      expect(sp.current()!.pos.startsWith('38.'), isTrue);
    });
  });

  test('the beacon carries pos: and acc: only when given', () {
    final with_ = xprsComposeObservation(
        self: 'X3STN1', link: 'lan', heard: const [], budget: 250,
        pos: '38.708,-9.137', accM: 100)!;
    expect(with_['pos'], '38.708,-9.137');
    expect(with_['acc'], '100');
    final without = xprsComposeObservation(
        self: 'X3STN1', link: 'lan', heard: const [], budget: 250)!;
    expect(without.has('pos'), isFalse);
  });

  group('heard positions', () {
    final mon = XprsMonitor.instance;
    const t0 = 1700000000000;
    setUp(mon.clear);

    test('a beacon says where its station is; an event names a place', () {
      mon.offer(
          XprsPacket.parse('t:observation f:X3STN1 link:lan pos:38.708,-9.137 acc:100 ts:2026-11-08_10:00:00')!,
          bearer: 'lan', selfCallsign: 'X3SELF', nowMs: t0);
      var row = mon.stationJson('X3STN1', nowMs: t0)!;
      expect(row['pos'], '38.708,-9.137');
      expect(row['acc'], 100);
      mon.offer(
          XprsPacket.parse('t:event f:X3STN1 pos:40.1,-8.2 title:fair ts:2026-11-08_10:05:00')!,
          bearer: 'lan', selfCallsign: 'X3SELF', nowMs: t0 + 1000);
      row = mon.stationJson('X3STN1', nowMs: t0 + 1000)!;
      expect(row['pos'], '38.708,-9.137', reason: 'an event elsewhere does not move the station');
      expect(mon.stationsJson(nowMs: t0 + 1000), contains('"pos":"38.708,-9.137"'));
    });

    test('a station that shares nothing has no position', () {
      mon.offer(XprsPacket.parse('t:observation f:X3QUIET link:lan')!,
          bearer: 'lan', selfCallsign: 'X3SELF', nowMs: t0);
      expect(mon.stationJson('X3QUIET', nowMs: t0)!.containsKey('pos'), isFalse);
    });
  });
}
