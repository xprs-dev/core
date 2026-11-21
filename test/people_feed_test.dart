// What feeds XprsPeople, and the reader that closes the wait measured on
// 2026-11-21: a station that knew an archiver's LXMF announce but not its
// chat announce could not fetch a file from it.
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/people/xprs_people.dart';
import 'package:xprs_core/src/services/reticulum/rns_service.dart';

void main() {
  final people = XprsPeople.instance;
  setUp(people.debugReset);
  tearDown(people.debugReset);

  test('a callsign is filed under its keyless record until the key arrives',
      () {
    const rns = '3e2c78de1f4eb606116c218493594745';
    expect(people.holderOfCall('x3ptzm'), '~callsign:X3PTZM');
    people.noteForCall('X3PTZM', XprsIdType.reticulum, rns,
        evidence: XprsIdEvidence.observed, via: 'rns');
    expect(people.reachCall('X3PTZM', XprsIdType.reticulum), [rns]);
    expect(people.personWith(XprsIdType.callsign, 'X3PTZM'), isNull);

    // Its t:identity verifies: the key takes the record over.
    const npub =
        'npub1ptzm5k5zv9v3sjyjxv9u3pxa7n66ppl4zfa8w3e7f7lpc0eshfsqfhe4hf';
    people.claim(npub, XprsIdType.callsign, 'X3PTZM',
        evidence: XprsIdEvidence.derived);
    expect(people.holderOfCall('X3PTZM'), npub);
    expect(people.reachCall('X3PTZM', XprsIdType.reticulum), [rns],
        reason: 'what was learned before the key is the person\'s now');
    expect(people.of('~callsign:X3PTZM'), isEmpty);
  });

  test('an issued callsign is a licence, a derived one a callsign', () {
    expect(XprsPeople.callType('X1QZ3N'), XprsIdType.callsign);
    expect(XprsPeople.callType('x5grup'), XprsIdType.callsign);
    expect(XprsPeople.callType('CT1ABC'), XprsIdType.licence);
    expect(XprsPeople.callType('EA/CT1ABC'), XprsIdType.licence);
    expect(people.holderOfCall('CT1ABC'), '~licence:CT1ABC');
  });

  test('a station named only by its LXMF announce is reachable by callsign',
      () async {
    final rns = RnsService.instance;
    final id = await RnsIdentity.generate();
    expect(rns.identityForCallsign('X3ARCH'), isNull);
    // Its lxmf.delivery announce, carrying its name; no chat announce.
    final pkt = await RnsAnnounceBuilder.build(id, 'lxmf', const ['delivery'],
        appData: Uint8List.fromList('X3ARCH'.codeUnits));
    final ann = await validateAnnounce(RnsPacket.parse(pkt.pack())!);
    await rns.debugObserveAnnounce(ann!);
    final got = rns.identityForCallsign('X3ARCH');
    expect(got, isNotNull,
        reason: 'every destination of a node hangs off one identity');
    expect(got!.hexHash, RnsIdentity.fromPublicKey(id.getPublicKey()).hexHash);
    expect(
        people.reachCall('X3ARCH', XprsIdType.reticulum), [got.hexHash]);
    expect(people.reachCall('X3ARCH', XprsIdType.lxmf), hasLength(1));
  });
}
