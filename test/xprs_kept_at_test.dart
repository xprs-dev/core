// Where a message this station sent is kept: a station's signed word
// (`t:observation s:held r:<id>`, XPRS.md 12.7.1) and the archivers a copy
// was handed to, recorded with the outbox for the message's Info page.
import 'dart:io';

import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/profile/iwi_profile.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_ingest.dart';
import 'package:xprs_core/src/services/xprs/xprs_outbox.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_self.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

void main() {
  late Directory dir;
  final o = XprsOutbox.instance;
  final station = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xprs-kept');
    o.init('${dir.path}/outbox.zx');
    XprsArchive.instance.keyResolver =
        (c) => c == 'X3STAT' ? XprsCrypto.publicKeyXOnly(station) : null;
    XprsSelf.instance.profile = () => const IwiProfile(
        id: 'p1',
        nickname: 'maria',
        callsign: 'X1MARI',
        npub: 'npub1x',
        nsec: 'nsec1x',
        createdAt: 1);
  });
  tearDown(() {
    o.close();
    XprsArchive.instance.keyResolver = null;
    dir.deleteSync(recursive: true);
  });

  XprsPacket held(String id, {String to = 'X1MARI', BigInt? key, String from = 'X3STAT'}) =>
      xprsSign(
          XprsPacket.parse(
              't:observation f:$from d:$to ts:2026-11-22_20:00:00 s:held r:$id')!,
          key ?? station);

  test('a handed copy is recorded, and a station saying it keeps it outranks that', () {
    expect(o.noteKept('abc123', 'x3stat', XprsOutbox.keptHanded), isTrue);
    expect(o.keptAt('abc123'), {'X3STAT': 'handed'});
    expect(o.noteKept('abc123', 'X3STAT', XprsOutbox.keptHeld), isTrue);
    expect(o.noteKept('abc123', 'X3STAT', XprsOutbox.keptHanded), isFalse,
        reason: 'its own word is not walked back to a send');
    expect(o.keptAt('abc123'), {'X3STAT': 'held'});
    expect(o.keptAt('ffffff'), isEmpty);
  });

  test('it survives a restart', () {
    o.noteKept('abc123', 'X3STAT', XprsOutbox.keptHeld);
    o.close();
    o.init('${dir.path}/outbox.zx');
    expect(o.keptAt('abc123'), {'X3STAT': 'held'});
  });

  test('a station\'s signed word is taken; anybody else\'s is not', () {
    expect(XprsIngest.noteHeld(held('abc123')), isTrue);
    expect(o.keptAt('abc123'), {'X3STAT': 'held'});
    expect(XprsIngest.noteHeld(held('abc124', to: 'X1OTHR')), isFalse,
        reason: 'said to somebody else');
    expect(XprsIngest.noteHeld(held('abc125', key: BigInt.from(99))), isFalse,
        reason: 'not signed by the station it names');
    expect(XprsIngest.noteHeld(held('abc126', from: 'X1PERS', key: BigInt.from(99))),
        isFalse);
    expect(o.keptAt('abc124'), isEmpty);
    expect(o.keptAt('abc125'), isEmpty);
  });
}
