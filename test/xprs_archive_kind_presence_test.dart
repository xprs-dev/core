// A stranger's presence of a type a wapp follows (t:service, which says what
// a station serves) is kept as its newest two per station and type: a
// station that announces every eleven minutes holds two rows, not a day's
// worth, and what is followed by nobody is not capped by this.
import 'dart:io';

import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive_policy.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main() {
  late Directory dir;
  final a = XprsArchive.instance;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xprs-kindpres');
    a.init('${dir.path}/archive.zx');
  });
  tearDown(() {
    a.followedKinds = const {};
    a.close();
    dir.deleteSync(recursive: true);
  });

  String ts(int m) => '2026-11-26_${(8 + m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}:00';

  void put(String wire) => a.admit(XprsPacket.parse(wire)!, bearer: 'rns', tier: Tier.stranger);

  List<String> services(String from) => [
        for (final r in a.query(only: from, types: const ['service'], limit: 50)) '${r['wire']}'.split(' ts:').last.substring(0, 19)
      ];

  test('a followed kind: the newest two per station', () {
    a.followedKinds = {'service'};
    for (var i = 0; i < 12; i++) {
      put('t:service f:X3PTZM serve:archive count:${299000 + i} ts:${ts(i * 11)}');
      put('t:service f:X3W6ZT serve:archive ts:${ts(i * 11 + 1)}');
    }
    a.flush();
    expect(services('X3PTZM'), [ts(121), ts(110)]);
    expect(services('X3W6ZT'), [ts(122), ts(111)]);
  });

  test('not followed: not capped by this rule', () {
    for (var i = 0; i < 5; i++) {
      put('t:service f:X3PTZM serve:archive ts:${ts(i * 11)}');
    }
    a.flush();
    expect(services('X3PTZM').length, 5);
  });
}
