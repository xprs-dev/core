// XPRS.md 10.9.3: a byte ceiling per X5 group, the oldest first, the group's
// record (its acts and identity) never.
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main() {

  test('a loud group is cut to its ceiling, oldest first; its record stays', () {
    final dir = Directory.systemTemp.createTempSync('xprs-ceiling');
    final a = XprsArchive.instance;
    addTearDown(() {
      a.close();
      dir.deleteSync(recursive: true);
    });
    a.init('${dir.path}/archive.sqlite');
    a.maxGroupBytes = 3000;
    const group = 'X5GRP1';
    const quiet = 'X5QUIE';
    String ts(int i) => '2026-11-06_10:${(i ~/ 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')}';
    a.admit(XprsPacket.parse('t:identity f:$group ts:${ts(0)} k:npub1x nick:loud')!, bearer: 'web');
    a.admit(XprsPacket.parse('t:moderate f:$group d:$group ts:${ts(1)} grant:X1RD89 role:mod')!, bearer: 'web');
    for (var i = 2; i < 60; i++) {
      a.admit(XprsPacket.parse('t:blog f:X1RD89 d:$group ts:${ts(i)} title:post-$i m:${'x' * 100}')!, bearer: 'web');
      a.flush();
    }
    a.admit(XprsPacket.parse('t:blog f:X1RD89 d:$quiet ts:${ts(61)} title:only m:a quiet group keeps its one post')!, bearer: 'web');
    a.flush();
    // The ceiling is checked every twentieth flush: by now it has been, twice.
    for (var i = 0; i < 20; i++) {
      a.flush();
    }
    final after = a.query(types: const ['blog'], to: const [group], limit: 1000);
    expect(after.length, lessThan(58));
    expect(after.length, greaterThan(0));
    expect(a.groupPruned, greaterThan(0));
    // What stayed is the newest: the oldest went first.
    expect(after.first['wire'], contains('title:post-59'));
    expect(after.any((r) => '${r['wire']}'.contains('title:post-2 ')), false);
    expect(a.query(types: const ['identity'], from: group, limit: 10), hasLength(1));
    expect(a.query(types: const ['moderate'], to: const [group], limit: 10), hasLength(1));
    expect(a.query(types: const ['blog'], to: const [quiet], limit: 10), hasLength(1),
        reason: 'a quiet group is untouched');
  });
}
