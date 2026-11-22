// A room's newest rows are found once and kept: later asks are answered from
// what was found plus what was filed since. Measured on a station with a
// 120 MB archive (2026-11-22): every ask scanned every undirected row, 2.5
// to 17 seconds each, and a visitor's key lookup timed out behind them.
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main() {
  late Directory dir;
  final a = XprsArchive.instance;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xprs-rooms');
    a.init('${dir.path}/archive.zx');
  });
  tearDown(() {
    a.close();
    dir.deleteSync(recursive: true);
  });

  void say(String from, String time, String rest) => a.admit(
      XprsPacket.parse('t:message f:$from ts:2026-11-22_$time $rest')!,
      bearer: 'lan');
  List<String> room(String r, {int limit = 50}) => [
        for (final x in a.query(
            types: const ['message'], to: const [''], room: r, limit: limit))
          '${x['wire']}'.split(' m:').last,
      ];

  test('the same answer as a scan, without scanning again', () {
    say('X1AAAA', '10:00:00', 'scope:local m:one');
    say('X1BBBB', '10:00:01', 'm:everywhere');
    say('X1CCCC', '10:00:02', 'scope:regional m:region');
    a.flush();
    expect(room('local'), ['one']);
    expect(room('global'), ['everywhere']);
    expect(a.roomScans, 2);

    say('X1AAAA', '10:01:00', 'scope:local m:two');
    say('X1DDDD', '10:01:01', 'd:X1AAAA scope:local m:private');
    say('X1BBBB', '10:01:02', 'm:scope:local is only words here');
    a.flush();
    expect(room('local'), ['two', 'one'], reason: 'newest first, mail left out');
    expect(room('global'), ['scope:local is only words here', 'everywhere']);
    expect(room('local'), ['two', 'one']);
    expect(a.roomScans, 2, reason: 'no scan after the first of each room');
    expect(a.roomHits, 3);
  });

  test('the window stays the size that was asked for', () {
    for (var i = 0; i < 5; i++) {
      say('X1AAAA', '11:00:0$i', 'scope:local m:m$i');
    }
    a.flush();
    expect(room('local', limit: 3), ['m4', 'm3', 'm2']);
    say('X1AAAA', '11:00:09', 'scope:local m:m9');
    a.flush();
    expect(room('local', limit: 3), ['m9', 'm4', 'm3']);
  });

  test('a row that was changed is not served twice from memory', () {
    say('X1AAAA', '12:00:00', 'scope:local m:kept');
    a.flush();
    final first = a.query(
        types: const ['message'], to: const [''], room: 'local', limit: 10);
    first.single['wire'] = 'scribbled on by a caller';
    expect(room('local', limit: 10), ['kept']);
  });

  test('a deletion elsewhere leaves a room alone; one in it scans again', () {
    say('X1AAAA', '13:00:00', 'scope:local m:stays');
    say('X1AAAA', '13:00:01', 'scope:local m:goes');
    a.admit(XprsPacket.parse('t:observation f:X3SSSS ts:2026-11-22_13:00:02 hears:X1AAAA')!,
        bearer: 'lan');
    a.flush();
    expect(room('local'), ['goes', 'stays']);
    final scans = a.roomScans;
    a.debugDelete("DELETE FROM packets WHERE type = 'observation'");
    expect(room('local'), ['goes', 'stays']);
    expect(a.roomScans, scans, reason: 'presence rows are in no room');
    a.debugDelete("DELETE FROM packets WHERE wire LIKE '%m:goes'");
    expect(room('local'), ['stays']);
    expect(a.roomScans, scans + 1);
  });

  test('the newest of some types, whatever the room, is kept the same way', () {
    say('X1AAAA', '14:00:00', 'scope:local m:a');
    say('X1BBBB', '14:00:01', 'm:b');
    a.flush();
    List<String> talk() => [
          for (final x in a.query(
              types: const ['message'], to: const [''], limit: 10))
            '${x['wire']}'.split(' m:').last,
        ];
    expect(talk(), ['b', 'a']);
    final scans = a.roomScans;
    say('X1CCCC', '14:00:02', 'scope:regional m:c');
    a.flush();
    expect(talk(), ['c', 'b', 'a']);
    expect(a.roomScans, scans);
  });

  // The periodic write: everything heard in twenty seconds used to go in
  // one transaction on the isolate that draws the screen (2 to 5 s on a
  // phone). It goes in slices, with the event loop given a turn between.
  test('the periodic write goes in slices and loses nothing', () async {
    for (var i = 0; i < 20; i++) {
      say('X1AAAA', '15:00:${i.toString().padLeft(2, '0')}', 'scope:local m:s$i');
    }
    final before = XprsArchive.slices;
    var turns = 0;
    final watch = Stream<void>.periodic(const Duration(milliseconds: 5))
        .listen((_) => turns++);
    await a.flushInSlices();
    await watch.cancel();
    expect(XprsArchive.slices - before, greaterThanOrEqualTo(4),
        reason: 'twenty rows are several slices');
    expect(turns, greaterThan(3), reason: 'other work ran between them');
    expect(room('local', limit: 50).length, 20);
  });
}
