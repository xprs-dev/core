// A history request for one callsign is answered from the indexes: the
// same rows as before (sent by it, addressed to it, observations naming it
// when asked), without walking every row in the window. Measured on the
// Pi's server, 2026-11-23: 2 to 10 s per request, most of them answering 404.
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main() {
  late Directory dir;
  final a = XprsArchive.instance;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xprs-only');
    a.init('${dir.path}/archive.zx');
  });
  tearDown(() {
    a.close();
    dir.deleteSync(recursive: true);
  });

  void put(String wire) =>
      a.admit(XprsPacket.parse(wire)!, bearer: 'lan');

  String ts(int i) =>
      '2026-11-23_${(10 + i ~/ 3600).toString().padLeft(2, '0')}:'
      '${((i ~/ 60) % 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')}';

  test('sent by, addressed to, and observations naming the callsign', () {
    for (var i = 0; i < 3000; i++) {
      put('t:message f:X1N${i % 97} ts:${ts(i)} m:noise $i');
    }
    put('t:message f:X1ALIC ts:${ts(3001)} m:from alice');
    put('t:message f:X1BOBB d:X1ALIC ts:${ts(3002)} m:to alice');
    put('t:observation f:X3STAT ts:${ts(3003)} hears:X1ALIC link:lan');
    put('t:message f:X5GRUP d:X5GRUP ts:${ts(3004)} m:a group post');
    put('t:message f:X1CARL d:X5GRUP ts:${ts(3005)} m:to the group');
    a.flush();

    List<String> ask(String c, {List<String>? types}) => [
          for (final r in a.query(only: c, types: types, limit: 50))
            '${r['wire']}'.split(' m:').last.split(' hears:').first
        ];

    expect(ask('X1ALIC'), ['t:observation f:X3STAT ts:${ts(3003)}', 'to alice', 'from alice']);
    expect(ask('X1ALIC', types: const ['message']), ['to alice', 'from alice']);
    expect(ask('X5GRUP', types: const ['message']), ['to the group', 'a group post']);
    expect(ask('X1NOBODY', types: const ['message']), isEmpty);
    expect(a.query(only: 'X1N5', types: const ['message'], limit: 7).length, 7);
  });

  test("a stranger is answered from this station's own rows, by name", () {
    a.selfCallsign = 'X3SELF';
    for (var i = 0; i < 2000; i++) {
      put('t:message f:X1N${i % 97} ts:${ts(i)} m:noise $i');
    }
    a.admit(XprsPacket.parse('t:status f:X3SELF ts:${ts(2001)} m:ours')!,
        bearer: 'lan', own: true);
    a.admit(XprsPacket.parse('t:message f:X3SELF ts:${ts(2002)} m:also ours')!,
        bearer: 'lan', own: true);
    a.flush();
    final got = [
      for (final r in a.query(ownOnly: true, types: const ['message', 'status'], limit: 10))
        '${r['wire']}'.split(' m:').last
    ];
    expect(got, ['also ours', 'ours']);
    a.selfCallsign = '';
  });
}
