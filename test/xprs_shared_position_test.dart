// A station's position goes out only when its owner shares it, cut to their
// range with the digits past it hidden for whoever holds the code (XPRS.md
// 6.2.1), and the stations that hear it remember where it said it is.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:xprs_core/src/platform/core_host.dart';
import 'package:xprs_core/src/services/xprs/xprs_monitor.dart';
import 'package:xprs_core/src/services/xprs/xprs_observation.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_shared_position.dart';

void main() {
  group('what everyone reads, and what is hidden (6.2.1)', () {
    test('100 km: whole degrees stay readable, the rest is marked', () {
      final a = xprsPosAuthored(38.70771234, -9.13654321, 100000);
      expect(a.authored, '38((.7077)),-9((.1365))');
      expect(a.barred, '38█████,-9█████');
      expect(a.public, '38,-9');
      expect(a.acc, 100000);
    });

    test('each range leaves one more decimal out of the parentheses', () {
      expect(xprsPosAuthored(38.7077, -9.1365, 10000).authored, '38.7((077)),-9.1((365))');
      expect(xprsPosAuthored(38.7077, -9.1365, 1000).authored, '38.70((77)),-9.13((65))');
      expect(xprsPosAuthored(38.7077, -9.1365, 100).authored, '38.707((7)),-9.136((5))');
      final exact = xprsPosAuthored(38.7077, -9.1365, 10);
      expect(exact.authored, '38.7077,-9.1365', reason: 'nothing left to hide');
      expect(exact.acc, 10);
    });

    test('a range from an older version is never made finer', () {
      expect(xprsPosDecimals(50), 3);
      expect(xprsPosDecimals(500), 2);
      expect(xprsPosDecimals(5000), 1);
      expect(xprsPosDecimals(100000), 0);
    });

    test('the same square on every airing: the public digits are a prefix', () {
      final a = xprsPosAuthored(38.70712, -9.13651, 1000);
      final b = xprsPosAuthored(38.70987, -9.13049, 1000);
      expect(a.public, b.public);
    });

    test('south and west, and just under zero, keep their sign', () {
      expect(xprsPosAuthored(-33.8688, 151.2093, 100000).public, '-33,151');
      expect(xprsPosAuthored(-0.5, -0.25, 100000).authored, '-0((.5000)),-0((.2500))');
    });

    test('a reader drops the bars: the wire value is still a position', () {
      expect(xprsPosStrip('38█████,-9█████'), '38,-9');
      final at = xprsParseLatLon('38.7███,-9.1███')!;
      expect(at.lat, 38.7);
      expect(at.lon, -9.1);
      expect(xprsParseLatLon('91,0'), isNull);
      expect(xprsParseLatLon('here'), isNull);
    });

    test('a barred value is the middle of its square, not its corner', () {
      final c = xprsPosCell('38█████,-9█████')!;
      expect(c.lat, 38.5);
      expect(c.lon, -9.5);
      expect(c.halfM, 55660);
      final d = xprsPosCell('38.7███,-9.1███')!;
      expect(d.lat, closeTo(38.75, 1e-9));
      expect(d.lon, closeTo(-9.15, 1e-9));
      final z = xprsPosCell('-0█████,0█████')!;
      expect(z.lat, -0.5);
      expect(z.lon, 0.5);
      final plain = xprsPosCell('38.7077,-9.1365')!;
      expect(plain.halfM, 0);
      expect(plain.lat, 38.7077);
    });

    test('a code is sixteen unambiguous characters in four groups', () {
      final c = xprsNewPosCode();
      expect(RegExp(r'^([A-HJ-NP-Z2-9]{4}-){3}[A-HJ-NP-Z2-9]{4}$').hasMatch(c), isTrue, reason: c);
      expect(xprsNewPosCode(), isNot(c));
    });

    test('hidden with a code, opened with it, and with no other', () {
      final red = jsonDecode(xprsPosRedactCompute(
          {'text': '38((.7077)),-9((.1365))', 'pass': 'ABCD-EFGH'})) as Map;
      expect(red['barred'], '38█████,-9█████');
      final xr = red['xr'] as String;
      expect(xprsPosRestoreCompute({'barred': red['barred'] as String, 'xr': xr, 'pass': 'ABCD-EFGH'}),
          '38.7077,-9.1365');
      expect(xprsPosRestoreCompute({'barred': red['barred'] as String, 'xr': xr, 'pass': 'nope'}), '');
    });
  });

  group('sharing', () {
    final sp = XprsSharedPosition.instance;
    var on = false;
    var fixed = '';
    var front = true;
    var asked = 0;
    var hidden = 0;
    var said = <String>[];
    setUp(() {
      said = [];
      sp.announce = (pos, acc) => said.add('$pos $acc');
      sp.debugReset();
      on = false;
      fixed = '';
      front = true;
      asked = 0;
      hidden = 0;
      sp.enabled = () => on;
      sp.radiusM = () => 100000;
      sp.fixed = () => fixed;
      sp.code = () => 'ABCD-EFGH';
      sp.foreground = () => front;
      sp.redact = (job) async {
        hidden++;
        return xprsPosRedactCompute(job);
      };
      CoreHost.locationFix = ({Duration maxAge = Duration.zero, Duration timeLimit = Duration.zero}) async {
        asked++;
        return (lat: 38.7077, lon: -9.1365, acc: 8.0);
      };
    });

    test('off: nothing, whatever the station knows', () async {
      sp.debugSetFix(38.7, -9.1);
      fixed = '38.7,-9.1';
      await sp.refresh();
      expect(sp.current(), isNull);
      expect(asked, 0);
    });

    test('before the hidden form is worked out: the bars, nothing to open', () {
      on = true;
      fixed = '38.70771,-9.13654';
      final c = sp.current()!;
      expect(c.pos, '38█████,-9█████');
      expect(c.acc, 100000);
      expect(c.xr, isNull);
    });

    test('after a refresh: bars for everyone, the blob for the code', () async {
      on = true;
      await sp.refresh();
      final c = sp.current()!;
      expect(c.pos, '38█████,-9█████');
      expect(c.xr, isNotNull);
      expect(xprsPosRestoreCompute({'barred': c.pos, 'xr': c.xr!, 'pass': 'ABCD-EFGH'}),
          '38.7077,-9.1365');
    });

    test('a station that has not moved pays for one derivation, not one a beacon', () async {
      on = true;
      await sp.refresh();
      await sp.refresh();
      await sp.refresh();
      expect(hidden, 1);
      expect(sp.current()!.xr, isNotNull);
      sp.debugSetFix(38.7078, -9.1365);
      await sp.refresh();
      expect(hidden, 2, reason: 'eleven metres on is another position');
    });

    test('a fix is asked for only while the app is in front', () async {
      on = true;
      front = false;
      fixed = '40.1,-8.2';
      await sp.refresh();
      expect(asked, 0);
      expect(sp.current()!.pos, '40█████,-8█████', reason: 'the fixed position still goes out');
      front = true;
      await sp.refresh();
      expect(asked, 1);
      expect(sp.current()!.pos, startsWith('38'), reason: 'the fix wins');
    });

    test('the identity is told the square, and only when it changes', () async {
      on = true;
      await sp.refresh();
      sp.debugSetFix(38.9001, -9.0002);
      await sp.refresh();
      expect(said, ['38█████,-9█████ 100000'], reason: 'the same square: said once');
      sp.debugSetFix(39.1, -9.2);
      await sp.refresh();
      expect(said.last, '39█████,-9█████ 100000');
      on = false;
      await sp.refresh();
      expect(said.last, ' 0', reason: 'sharing turned off withdraws it');
      expect(said.length, 3);
    });
  });

  test('the beacon carries the bars and the blob together', () {
    final p = xprsComposeObservation(
        self: 'X1PHONE', link: 'lan', heard: const [], budget: 250,
        pos: '38█████,-9█████', accM: 100000, xr: 'AAECAwQFBgcICQoLxyz')!;
    expect(p['pos'], '38█████,-9█████');
    expect(p['xr'], 'AAECAwQFBgcICQoLxyz');
    expect(XprsPacket.parse(p.encode())!['pos'], '38█████,-9█████', reason: 'it parses back');
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

    group('a position with hidden digits', () {
      final un = XprsPosUnlock.instance;
      late String barred, xr;
      var codes = <String, String>{};
      var opened = 0;
      setUp(() {
        un.debugReset();
        codes = {};
        opened = 0;
        un.codeFor = (peer) => codes[peer];
        un.restore = (job) async {
          opened++;
          return xprsPosRestoreCompute(job);
        };
        final red = jsonDecode(xprsPosRedactCompute(
            {'text': '38((.7077)),-9((.1365))', 'pass': 'ABCD-EFGH'})) as Map;
        barred = red['barred'] as String;
        xr = red['xr'] as String;
      });
      XprsPacket beacon() => XprsPacket.parse(
          't:observation f:X1FRND link:lan pos:$barred acc:100000 xr:$xr')!;

      test('a stranger: the square, and nothing paid for', () async {
        mon.offer(beacon(), bearer: 'lan', selfCallsign: 'X3SELF', nowMs: t0);
        await Future<void>.delayed(Duration.zero);
        expect(opened, 0);
        expect(mon.stationJson('X1FRND', nowMs: t0)!['pos'], barred,
            reason: 'a visitor is told what the wire says');
        final mine = mon.stationJson('X1FRND', nowMs: t0, forOwner: true)!;
        expect(mine['pos'], '38.5,-9.5', reason: 'the middle of the square, never bars');
        expect(mine['acc'], 100000);
      });

      test('a friend with the code: the spot, opened once, kept from visitors', () async {
        codes['X1FRND'] = 'ABCD-EFGH';
        mon.offer(beacon(), bearer: 'lan', selfCallsign: 'X3SELF', nowMs: t0);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        mon.offer(beacon(), bearer: 'lan', selfCallsign: 'X3SELF', nowMs: t0 + 60000);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(opened, 1, reason: 'the same blob is the same answer');
        final mine = mon.stationJson('X1FRND', nowMs: t0 + 60000, forOwner: true)!;
        expect(mine['pos'], '38.7077,-9.1365');
        expect(mine['acc'], 10);
        expect(mon.stationJson('X1FRND', nowMs: t0 + 60000)!['pos'], barred);
        expect(mon.stationsJson(nowMs: t0 + 60000), isNot(contains('38.7077')));
      });

      test('the wrong code opens nothing', () async {
        codes['X1FRND'] = 'WRONG';
        mon.offer(beacon(), bearer: 'lan', selfCallsign: 'X3SELF', nowMs: t0);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(mon.stationJson('X1FRND', nowMs: t0, forOwner: true)!['pos'], '38.5,-9.5');
      });
    });
  });
}
