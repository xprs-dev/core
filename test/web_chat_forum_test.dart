// The topic index fold (web_chat_forum.dart): parts joined, editions by
// title, comments counted under their topic (XPRS.md 7.6, 18.1, 18.5).
import 'package:test/test.dart';
import 'package:xprs_core/src/services/web_chat_forum.dart';
import 'package:xprs_core/src/services/xprs/xprs_id.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

Map<String, dynamic> row(int ts, String wire) => {
      'id': xprsIdentifier(XprsPacket.parse(wire)!),
      'ts': ts,
      'from': XprsPacket.parse(wire)!['f'],
      'to': 'X5F0RM',
      'type': 'blog',
      'wire': wire,
    };

void main() {
  const room = 'd:X5F0RM';
  final v1 = 't:blog f:X1RD89 $room ts:2026-08-08_16:02:10 title:balun-question tag:radio m:Which balun?';
  final v2 = 't:blog f:X1RD89 $room ts:2026-08-08_18:00:00 title:balun-question m:Which balun, and did it matter?';
  final idV1 = xprsIdentifier(XprsPacket.parse(v1)!);
  final idV2 = xprsIdentifier(XprsPacket.parse(v2)!);
  final c1 = 't:blog f:X1QZ3N $room ts:2026-08-08_16:40:00 r:$idV1 m:A 1:1 current balun.';
  final c2 = 't:blog f:X1BOA3 $room ts:2026-08-08_19:00:00 root:$idV2 r:9b7e44 m:Mine too.';
  // The spec's split post, parts out of order; the whole is what a comment names.
  const head = 't:blog f:X1QZ3N $room ts:2026-08-08_14:26:40 title:antenna-notes';
  final whole = XprsPacket.parse('$head m:I rebuilt the dipole. The feed point was off. About a decibel.')!;
  final idWhole = xprsIdentifier(whole);
  final parts = [
    '$head n:2/3 m:The feed point was off.',
    '$head n:3/3 sig:KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK m:About a decibel.',
    '$head n:1/3 m:I rebuilt the dipole.',
  ];
  final c3 = 't:blog f:X1RD89 $room ts:2026-08-08_15:00:00 r:$idWhole m:Three centimetres is a lot.';
  final lost = 't:blog f:X1BOA3 $room ts:2026-08-08_20:00:00 title:lost-middle n:1/2 m:first half';
  final bare = 't:blog f:X1BOA3 $room ts:2026-08-08_20:30:00 m:neither a title nor r:';

  final rows = [
    row(1754668930, v1), row(1754675600, v2), row(1754671200, c1), row(1754679600, c2),
    row(1754663200, parts[0]), row(1754663200, parts[1]), row(1754663200, parts[2]),
    row(1754665200, c3), row(1754683200, lost), row(1754685000, bare),
  ];

  test('posts: parts joined into the whole, a holed set and a bare post left out', () {
    final posts = forumPosts(rows);
    final joined = posts.where((p) => p.title == 'antenna-notes').single;
    expect(joined.id, idWhole, reason: 'the identifier is the whole\'s, never a part\'s');
    expect(joined.packet['m'], whole['m']);
    expect(joined.packet.has('n'), false);
    expect(posts.where((p) => p.title == 'lost-middle'), isEmpty);
    expect(posts.where((p) => !p.isTopic && !p.isComment), hasLength(1),
        reason: 'a bare post is a post, and neither a topic nor a comment');
    expect(posts.where((p) => p.isComment).length, 3);
  });

  test('topics: editions by title, replies counted under the topic, newest activity first', () {
    final t = forumTopics(rows);
    expect(t.map((x) => x['title']), ['balun-question', 'antenna-notes']);
    final balun = t[0];
    expect(balun['id'], idV2, reason: 'the newest edition is shown');
    expect(balun['edited'], true);
    expect(balun['replies'], 2, reason: 'a comment on either edition counts');
    expect(balun['last'], 1754679600);
    expect(balun['from'], 'X1RD89');
    final notes = t[1];
    expect(notes['replies'], 1);
    expect(notes['edited'], false);
    expect(notes['ts'], 1754663200);
  });

  test('a removed edition is not shown; a sent-away author has no topics', () {
    final t = forumTopics(rows, removed: {idV2});
    expect(t[0]['id'], idV1);
    expect(t[0]['edited'], false);
    expect(t[0]['replies'], 1, reason: 'the comment on the removed edition no longer counts');
    expect(forumTopics(rows, away: {'X1RD89'}).map((x) => x['title']), ['antenna-notes']);
  });

  test('bounded', () {
    expect(forumTopics(rows, max: 1), hasLength(1));
  });
}
