// How many messages a room holds: a number asked of the store once and then
// kept in step with what is filed and what goes, never a page of rows
// counted (app/docs/performance.md 8.7). What a group's page shows beside
// each folder.
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main() {
  late Directory dir;
  final a = XprsArchive.instance;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xprs-held');
    a.init('${dir.path}/archive.zx');
  });
  tearDown(() {
    a.close();
    dir.deleteSync(recursive: true);
  });

  void pkt(String type, String from, String time, String rest) => a.admit(
      XprsPacket.parse('t:$type f:$from ts:2026-11-22_$time $rest')!,
      bearer: 'lan');

  test('messages to a room are counted, and nothing else', () {
    pkt('message', 'X1AAAA', '10:00:00', 'd:X5FOLD m:one');
    pkt('message', 'X1BBBB', '10:00:01', 'd:X5FOLD m:two');
    pkt('message', 'X1AAAA', '10:00:02', 'd:X5ELSE m:elsewhere');
    pkt('message', 'X1AAAA', '10:00:03', 'm:to everybody');
    pkt('reaction', 'X1CCCC', '10:00:04', 'd:X5FOLD r:abcdef m:+');
    a.flush();
    expect(a.messagesTo('X5FOLD'), 2);
    expect(a.messagesTo('x5fold'), 2);
    expect(a.messagesTo('X5ELSE'), 1);
    expect(a.messagesTo('X5NONE'), 0);
    expect(a.messagesTo(''), 0);
  });

  test('the kept number follows what is filed and what goes', () {
    pkt('message', 'X1AAAA', '11:00:00', 'd:X5FOLD m:one');
    a.flush();
    expect(a.messagesTo('X5FOLD'), 1);
    pkt('message', 'X1AAAA', '11:00:01', 'd:X5FOLD m:two');
    pkt('message', 'X1AAAA', '11:00:01', 'd:X5FOLD m:two'); // heard again
    pkt('message', 'X1BBBB', '11:00:02', 'd:X5FOLD m:three');
    a.flush();
    expect(a.messagesTo('X5FOLD'), 3, reason: 'a second copy is one message');
    a.debugDelete("DELETE FROM packets WHERE toc = 'X5FOLD' AND fromc = 'X1BBBB'");
    expect(a.messagesTo('X5FOLD'), 2);
  });
}
