// A page that asks again is told only what the station filed since its last
// ask (spec/API-HTTP.md: `cursor` in a listing, `after` in the next ask).
// Measured 2026-11-28 on a page over a Reticulum link: with since= alone, a
// line said in the last five minutes came back on every ask.
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main() {
  late Directory dir;
  final a = XprsArchive.instance;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xprs-filed');
    a.init('${dir.path}/archive.zx');
  });
  tearDown(() {
    a.close();
    dir.deleteSync(recursive: true);
  });

  void say(String from, String time, String words) => a.admit(
      XprsPacket.parse('t:message f:$from ts:2026-11-22_$time m:$words')!,
      bearer: 'lan');

  WebChatApi api() => WebChatApi(
        publicRows: archivePublicRows,
        cursor: () => a.cursor,
        filedAfter: a.filedAfter,
        held: (_) => 0,
        receive: (_) {},
        mayAir: (_) => true,
        selfCallsign: () => 'X3PTZM',
        keyOf: (_) => null,
        appPath: () => null,
      );

  Future<(String, List<String>)> ask([String? after]) async {
    final r = await api().handle('GET', '/api/xprs/history',
        {'kind': 'message', 'since': '2026-11-22_00:00:00', if (after != null) 'after': after}, '');
    expect(r.status, 200);
    return (
      '${r.json['cursor']}',
      [for (final x in r.json['rows'] as List) '${x['wire']}'.split(' m:').last],
    );
  }

  test('asked again with the mark: only what was filed since', () async {
    say('X1AAAA', '10:00:00', 'one');
    say('X1BBBB', '10:00:01', 'two');
    a.flush();
    final (m1, all) = await ask();
    expect(all, ['two', 'one']);

    final (m2, none) = await ask(m1);
    expect(none, isEmpty, reason: 'nothing was filed: nothing is said twice');
    expect(m2, m1);

    // A packet that arrives late, with a time before the others'.
    say('X1CCCC', '09:00:00', 'late');
    a.flush();
    final (m3, fresh) = await ask(m2);
    expect(fresh, ['late']);
    expect(m3, isNot(m2));

    // Heard again on another bearer: it was told already.
    say('X1CCCC', '09:00:00', 'late');
    a.flush();
    expect((await ask(m3)).$2, isEmpty);
  });

  test('a mark the station cannot place is answered in full', () async {
    say('X1AAAA', '10:00:00', 'one');
    a.flush();
    expect((await ask('zz.5')).$2, ['one'], reason: 'another run of the station');
    expect((await ask('nonsense')).$2, ['one']);
    final (mark, _) = await ask();
    expect((await ask('${mark.split('.').first}.99')).$2, ['one'],
        reason: 'a mark ahead of the filing');
  });

  test('a mark older than what is remembered is answered in full', () async {
    final (m0, _) = await ask();
    for (var i = 0; i < 1100; i++) {
      say('X1AAAA', '10:${(i ~/ 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')}', 'n$i');
    }
    a.flush();
    final (_, rows) = await ask(m0);
    expect(rows.length, 30, reason: 'the default listing, not a filtered one');
  });
}
