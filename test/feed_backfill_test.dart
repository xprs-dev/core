// FeedBackfill's pure parts: reading a recovered note and the row it becomes.
// The sweep itself asks RnsService and is covered on the bench.
import 'package:reticulum/reticulum.dart' show NostrCrypto;
import 'package:test/test.dart';
import 'package:xprs_core/src/services/social/feed_backfill.dart';
import 'package:xprs_core/src/services/storage/activity_archive.dart';

void main() {
  const pub =
      '7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e';
  final from = 'X1${NostrCrypto.deriveCallsign(pub)}';

  test('activityMid is the wapps\' msg_id: two bytes of sha1(from|text)', () {
    expect(activityMid('X1ABC', 'hello'), '35c4');
  });

  test('a note reads as the callsign of its key, with its id', () {
    final n = BackfillNote.read(
        {'pub': pub, 'text': 'hi', 'ts': 1700000000, 'parent': 'ab12'},
        nowSec: 1)!;
    expect(n.from, from);
    expect(n.mid, activityMid(from, 'hi'));
    expect(n.tsSec, 1700000000);
    final row = n.toRow();
    expect(row['dir'], 'in');
    expect(row['via'], 'RET');
    expect(row['t'], 1700000000 * 1000);
    expect(row['parent'], 'ab12');
    expect(row['time'], matches(RegExp(r'^\d\d:\d\d$')));
  });

  test('empty notes and our own are not read', () {
    expect(BackfillNote.read({'pub': pub, 'text': ''}, nowSec: 1), isNull);
    expect(BackfillNote.read({'pub': '', 'text': 'x'}, nowSec: 1), isNull);
    expect(
        BackfillNote.read({'pub': pub, 'text': 'x'},
            selfPub: pub.toUpperCase(), nowSec: 1),
        isNull);
  });

  test('a note without a time takes now', () {
    expect(BackfillNote.read({'pub': pub, 'text': 'x'}, nowSec: 42)!.tsSec, 42);
  });
}
