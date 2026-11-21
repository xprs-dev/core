// What feeds XprsPeople, and the reader that closes the wait measured on
// 2026-11-21: a station that knew an archiver's LXMF announce but not its
// chat announce could not fetch a file from it.
import 'dart:convert';
import 'dart:io';
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

  test('a hardware address is a station\'s own once it has kept answering; '
      'one that rotates never is', () {
    var now = 1795000000000;
    people.nowMs = () => now;
    const board = 'A4:CF:12:0B:7E:31';
    // A board: the same address for an hour.
    expect(people.noteAddress('X3VGAZ', XprsIdType.ble, board), isFalse,
        reason: 'the first sighting proves nothing');
    now += 10 * 60 * 1000;
    expect(people.noteAddress('X3VGAZ', XprsIdType.ble, board), isFalse);
    now += 25 * 60 * 1000;
    expect(people.noteAddress('X3VGAZ', XprsIdType.ble, board), isTrue);
    expect(people.reachCall('X3VGAZ', XprsIdType.ble), [board]);
    expect(people.holders(XprsIdType.ble, board), ['~callsign:X3VGAZ']);
    // A phone: a new address every quarter of an hour.
    for (var i = 0; i < 12; i++) {
      now += 15 * 60 * 1000;
      final rotating = '5A:00:00:00:00:${i.toRadixString(16).padLeft(2, '0')}';
      people.noteAddress('X1PHONE', XprsIdType.ble, rotating);
      now += 5 * 60 * 1000;
      people.noteAddress('X1PHONE', XprsIdType.ble, rotating);
    }
    expect(people.reachCall('X1PHONE', XprsIdType.ble), isEmpty);
  });

  test('a node on another mesh is a record with no key until somebody says '
      'it is theirs', () {
    final node = XprsPeople.unclaimed(XprsIdType.meshtastic, 'MTA1B2C3D4');
    people.note(node, XprsIdType.meshtastic, 'MTA1B2C3D4',
        evidence: XprsIdEvidence.relayed, via: 'X3DCK0');
    expect(people.of(node).single.via, 'X3DCK0');
    expect(people.personWith(XprsIdType.meshtastic, 'MTA1B2C3D4'), isNull);
    // The person states it (6.3.3): theirs now, as their signed word.
    const npub =
        'npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f';
    people.stated(npub, 'meshtastic', 'MTA1B2C3D4', tsMs: 1795000000000);
    expect(people.personWith(XprsIdType.meshtastic, 'MTA1B2C3D4'), npub);
  });

  test('after a restart a derived callsign\'s key is answered from the '
      'record; an issued one is not', () {
    final rns = RnsService.instance;
    final kp = NostrCrypto.generateKeyPair();
    final call = 'X1${NostrCrypto.deriveCallsign(kp.publicKeyHex)}';
    final npub = NostrCrypto.encodeNpub(kp.publicKeyHex);
    // What an earlier run filed: the key's own callsign, by arithmetic, and
    // an issued callsign the same key bound.
    people.claim(npub, XprsIdType.callsign, call,
        evidence: XprsIdEvidence.derived);
    people.claim(npub, XprsIdType.licence, 'CT1ZZZ',
        evidence: XprsIdEvidence.signed);
    // This run has heard no identity packet.
    expect(rns.pubkeyForCallsign(call), kp.publicKeyHex);
    expect(rns.pubkeyForCallsign('$call-2'), kp.publicKeyHex,
        reason: 'a device suffix is the same person (3.1)');
    expect(rns.pubkeyForCallsign('CT1ZZZ'), isNull,
        reason: 'no arithmetic ties an issued callsign to a key (6.4.2)');
    // A callsign only OBSERVED beside a key is not proof of it.
    final other = NostrCrypto.generateKeyPair();
    people.note(NostrCrypto.encodeNpub(other.publicKeyHex),
        XprsIdType.callsign, 'X1FAKE9',
        evidence: XprsIdEvidence.observed);
    expect(rns.pubkeyForCallsign('X1FAKE9'), isNull);
  });

  test('the peer file of older builds is moved into the record once, and '
      'removed', () async {
    final rns = RnsService.instance;
    final tmp = Directory.systemTemp.createTempSync('xprspeers');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final id = await RnsIdentity.generate();
    final pubHex = id
        .getPublicKey()
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final f = File('${tmp.path}/call_peers.json')
      ..writeAsStringSync(jsonEncode({'X3OLDY': pubHex, 'junk': 'zz'}));
    rns.callPeersPath = f.path;
    addTearDown(() => rns.callPeersPath = null);
    rns.debugImportCallPeers();
    expect(f.existsSync(), isFalse, reason: 'nothing writes it any more');
    final got = rns.identityForCallsign('x3oldy');
    expect(got, isNotNull);
    expect(got!.hexHash, RnsIdentity.fromPublicKey(id.getPublicKey()).hexHash);
    rns.debugImportCallPeers(); // no file: nothing to do, nothing thrown
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
