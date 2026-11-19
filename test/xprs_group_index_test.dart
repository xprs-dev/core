// XPRS.md 12.9.7: ranking public groups from archivers' groups indexes.
// The sketch, the file, what an archiver counts and lists, and how a reader
// puts several archivers together.
import 'dart:io';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart' show NostrCrypto;

import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_directory.dart';
import 'package:xprs_core/src/services/xprs/xprs_group_index.dart';
import 'package:xprs_core/src/services/xprs/xprs_groups.dart';
import 'package:xprs_core/src/services/xprs/xprs_id.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

final _keys = <String, ({BigInt d, Uint8List pub})>{};
({BigInt d, Uint8List pub}) _keyFor(String c) => _keys.putIfAbsent(c, () {
      final kp = NostrCrypto.generateKeyPair();
      var d = BigInt.zero;
      for (final b in HEX.decode(kp.privateKeyHex)) {
        d = (d << 8) | BigInt.from(b);
      }
      return (d: d, pub: Uint8List.fromList(HEX.decode(kp.publicKeyHex)));
    });

/// [member] joins [g]: the group's grant and the member's acceptance.
void _join(String g, String member) {
  final gr = xprsSign(
      XprsPacket.parse('t:moderate f:$g d:$g ts:2026-11-01_10:00:00 '
          'grant:$member')!,
      _keyFor(g).d);
  XprsGroups.instance.offer(gr);
  XprsGroups.instance.offer(xprsSign(
      XprsPacket.parse('t:moderate f:$member d:$g ts:2026-11-01_10:01:00 '
          'r:${xprsIdentifier(gr)} accept:member')!,
      _keyFor(member).d));
}

int _ms(String iso) => DateTime.parse('${iso}Z').millisecondsSinceEpoch;

XprsPacket _post(String from, String to, String ts, String text,
        {bool sealed = false}) =>
    XprsPacket.parse('t:message f:$from d:$to ts:$ts '
        '${sealed ? 'x:${'A' * 40}' : 'm:$text'}')!;

void main() {
  group('the sketch', () {
    test('estimates distinct things to within its error', () {
      for (final n in [10, 100, 1000, 20000]) {
        final s = XprsSketch();
        for (var i = 0; i < n; i++) {
          s.add('item$i');
        }
        // Adding again changes nothing: a sketch counts distinct things.
        for (var i = 0; i < n; i++) {
          s.add('item$i');
        }
        final e = s.estimate();
        expect((e - n).abs() / n, lessThan(0.35), reason: 'n=$n e=$e');
      }
    });

    test('two archivers that saw overlapping posts combine without double '
        'counting', () {
      final a = XprsSketch(), b = XprsSketch();
      for (var i = 0; i < 600; i++) {
        a.add('post$i'); // 0..599
      }
      for (var i = 400; i < 1000; i++) {
        b.add('post$i'); // 400..999: 200 in common
      }
      final both = a.copy()..merge(b);
      final e = both.estimate();
      expect((e - 1000).abs() / 1000, lessThan(0.35),
          reason: 'the union is 1000, not 1200 (a sum) or 600 (an average)');
    });

    test('64 characters, and back', () {
      final s = XprsSketch()..add('X1QZ3N')..add('X1RD89');
      final t = s.encode();
      expect(t.length, 64);
      expect(XprsSketch.decode(t)!.encode(), t);
      expect(XprsSketch().encode(), 'A' * 64);
      expect(XprsSketch.decode('short'), isNull);
    });
  });

  test('weeks are counted from 1970, so a date needs no clock', () {
    expect(xprsWeekOf(_ms('2026-11-19T00:00:00')), 2968);
    expect(xprsWeekOf(_ms('2026-11-18T23:59:59')), 2967);
  });

  test('an open group is a name no callsign could have', () {
    expect(xprsIsOpenGroupName('LISBOA'), isTrue);
    expect(xprsIsOpenGroupName('X1QZ3N'), isFalse);
    expect(xprsIsOpenGroupName('X5A3F2'), isFalse);
    expect(xprsIsOpenGroupName('CT1ABC'), isFalse);
    expect(xprsIsOpenGroupName('MT0012ABCD'), isFalse);
    expect(xprsIsOpenGroupName(''), isFalse);
  });

  group('the file', () {
    test('composes and parses back, and names the index on the directory', () {
      final g = XprsGroupStats('X5A3F2')
        ..members = 42
        ..membersTs = _ms('2026-11-18T21:14:03')
        ..membersId = '9f3c21';
      g.week(2968).kinds['p'] = XprsSketch()..add('a1b2c3');
      g.week(2968).kinds['s'] = XprsSketch()..add('X1QZ3N');
      final o = XprsGroupStats('LISBOA');
      o.week(2967).kinds['p'] = XprsSketch()..add('ffeedd');
      final text = XprsGroupIndexFile.compose([g, o]);
      expect(text.split('\n').first, 'XGRP1');
      expect(text, contains('X5A3F2 m 42 2026-11-18_21:14:03 9f3c21'));
      expect(text, isNot(contains(' j ')), reason: 'an empty sketch is left out');
      final back = XprsGroupIndexFile.parse(text)!;
      expect(back['X5A3F2']!.members, 42);
      expect(back['X5A3F2']!.weeks[2968]!.kinds['p']!.encode(),
          g.weeks[2968]!.kinds['p']!.encode());
      expect(back['LISBOA']!.members, isNull);
      expect(XprsGroupIndexFile.parse('XDIR1\n'), isNull);

      final dir = XprsDirectory.compose([], indexRef: 'q${'A' * 42}.xgrp');
      expect(dir, contains('XGRP1 file:'));
      expect(XprsDirectory.parse(dir), isEmpty,
          reason: 'a reader that does not know the line skips it');
      expect(XprsDirectory.indexShaIn(dir), isNotNull);
    });
  });

  group('what an archiver counts', () {
    late Directory dir;
    final idx = XprsGroupIndex.instance;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('xprs-gidx');
      XprsGroups.instance.clear();
      idx.debugReset();
      idx.init('${dir.path}/index.zx');
      idx.now = () => _ms('2026-11-19T12:00:00');
    });
    tearDown(() {
      idx.close();
      dir.deleteSync(recursive: true);
    });

    void file(XprsPacket p) =>
        idx.offer(p, xprsIdentifier(p), XprsSigState.unsigned);

    test('posts and posters of an open group, one person counted once', () {
      for (var i = 0; i < 30; i++) {
        file(_post('X1QZ3N', 'LISBOA', '2026-11-19_10:${(i % 60).toString().padLeft(2, '0')}:00', 'hi $i'));
      }
      file(_post('X1RD89', 'LISBOA', '2026-11-19_11:00:00', 'hello'));
      final s = idx.stats().singleWhere((s) => s.group == 'LISBOA');
      final w = s.weeks[2968]!.kinds;
      expect(w['p']!.estimate(), inInclusiveRange(25, 40));
      expect(w['s']!.estimate(), 2);
      expect(s.members, isNull, reason: 'an open group has no members');
    });

    test('a private group is never listed, a public one is', () {
      file(_post('X1QZ3N', 'X5PRIV', '2026-11-19_10:00:00', '', sealed: true));
      file(_post('X1QZ3N', 'X5PUBL', '2026-11-19_10:00:00', 'in the clear'));
      final listed = idx.stats().map((s) => s.group).toSet();
      expect(listed, contains('X5PUBL'));
      expect(listed, isNot(contains('X5PRIV')));
      // Gone private: its newest post is sealed, so it leaves the index.
      file(_post('X1QZ3N', 'X5PUBL', '2026-11-19_11:00:00', '', sealed: true));
      expect(idx.stats().map((s) => s.group), isNot(contains('X5PUBL')));
    });

    test('a person is not a group, and a post far in the future is refused',
        () {
      file(_post('X1QZ3N', 'X1RD89', '2026-11-19_10:00:00', 'just us'));
      file(_post('X1QZ3N', 'LISBOA', '2030-01-01_00:00:00', 'from the future'));
      expect(idx.stats(), isEmpty);
      expect(idx.refusedAhead, 1);
    });

    test('without a clock: the four newest weeks are kept', () {
      idx.now = null; // a station that does not know the date
      for (final day in ['10-01', '10-08', '10-15', '10-22', '10-29', '11-05']) {
        file(_post('X1QZ3N', 'LISBOA', '2026-${day}_10:00:00', 'week'));
      }
      final weeks = idx.stats().single.weeks.keys.toList()..sort();
      expect(weeks.length, 4);
      expect(weeks.last, xprsWeekOf(_ms('2026-11-05T10:00:00')));
      // An older week than the four kept is not counted at all.
      file(_post('X1RD89', 'LISBOA', '2026-09-01_10:00:00', 'old'));
      expect(idx.stats().single.weeks.keys, isNot(contains(
          xprsWeekOf(_ms('2026-09-01T10:00:00')))));
    });

    test('a stranger\'s post does not decide public or private', () {
      // X1RD89 is the only member; a stranger's sealed post must not hide the
      // group, nor a post dated ahead.
      final g = 'X5PUBL';
      XprsGroups.instance.keyResolver = (c) => _keys[c]?.pub;
      _join(g, 'X1RD89');
      file(_post('X1RD89', g, '2026-11-19_10:00:00', 'in the clear'));
      file(_post('X1NOPE', g, '2026-11-19_11:00:00', '', sealed: true));
      file(_post('X1RD89', g, '2030-01-01_00:00:00', '', sealed: true));
      expect(idx.stats().map((s) => s.group), contains(g));
    });

    test('a private room this station hosts is never listed', () {
      idx.hostedPrivate = (g) => g == 'X5ROOM';
      file(_post('X1QZ3N', 'X5ROOM', '2026-11-19_10:00:00', 'in the clear'));
      expect(idx.stats(), isEmpty);
    });

    test('the counts survive a restart', () {
      file(_post('X1QZ3N', 'LISBOA', '2026-11-19_10:00:00', 'kept'));
      idx.close();
      idx.init('${dir.path}/index.zx');
      expect(idx.stats().single.group, 'LISBOA');
    });
  });

  group('putting archivers together', () {
    final r = XprsGroupRanking.instance;
    setUp(r.debugReset);
    final now = _ms('2026-11-19T12:00:00');

    XprsGroupStats posts(String g, int from, int to, {int week = 2968}) {
      final s = XprsGroupStats(g);
      for (var i = from; i < to; i++) {
        s.week(week).kinds.putIfAbsent('p', () => XprsSketch()).add('$g-$i');
        s.week(week).kinds.putIfAbsent('s', () => XprsSketch()).add('X1P${i % 7}');
      }
      return s;
    }

    test('members from the newest record, activity from the combined sketch',
        () {
      final a = posts('X5BUSY', 0, 300)
        ..members = 40
        ..membersTs = _ms('2026-11-10T00:00:00');
      final b = posts('X5BUSY', 200, 500)
        ..members = 38
        ..membersTs = _ms('2026-11-18T00:00:00');
      r.put('X3ARC1', 'a', {'X5BUSY': a});
      r.put('X3ARC2', 'b', {'X5BUSY': b});
      final g = r.merged(nowMs: now).single;
      expect(g.members, 38, reason: 'the record that saw the newest act');
      expect((g.posts - 500).abs(), lessThan(150),
          reason: 'about 500 posts in all: 200 seen by both count once');
      expect(g.posters, 7);
    });

    test('ranked by activity, members or growth; open groups by activity',
        () {
      final quiet = posts('X5CALM', 0, 5)..members = 90..membersTs = now;
      quiet.week(2968).kinds['j'] = XprsSketch()..add('X1NEW1');
      final loud = posts('LISBOA', 0, 400);
      final mid = posts('X5MIDL', 0, 60)..members = 10..membersTs = now;
      for (var i = 0; i < 9; i++) {
        mid.week(2967).kinds.putIfAbsent('j', () => XprsSketch()).add('X1J$i');
      }
      r.put('X3ARC1', 'a', {'X5CALM': quiet, 'LISBOA': loud, 'X5MIDL': mid});
      expect(r.ranked('active', nowMs: now).map((g) => g.group).toList(),
          ['LISBOA', 'X5MIDL', 'X5CALM']);
      expect(r.ranked('members', nowMs: now).map((g) => g.group).toList(),
          ['X5CALM', 'X5MIDL'], reason: 'an open group has no members');
      expect(r.ranked('growing', nowMs: now).map((g) => g.group).toList(),
          ['X5MIDL', 'X5CALM']);
    });

    test('a station counts its own index with the archivers\'', () {
      r.own = () => [posts('PORTO', 0, 20)];
      r.put('X3ARC1', 'a', {'LISBOA': posts('LISBOA', 0, 50)});
      expect(r.ranked('active', nowMs: now).map((g) => g.group).toList(),
          ['LISBOA', 'PORTO']);
      expect(r.sources, 2);
    });

    test('weeks after the reader\'s own and long past are not counted', () {
      r.put('X3ARC1', 'a', {
        'LISBOA': posts('LISBOA', 0, 50, week: 2975), // the future
        'PORTO': posts('PORTO', 0, 50, week: 2960), // two months ago
      });
      expect(r.ranked('active', nowMs: now), isEmpty);
    });
  });
}
