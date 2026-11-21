// An archiver is found through Reticulum announces alone (XPRS.md 12.3): its
// chat announce carries the callsign and, after a NUL, the relay announcement
// that says it archives. Read whole as a callsign, that announce failed the
// length test, so no archiver was ever known by name over the hubs and a
// station with nobody in earshot adopted none.
import 'dart:convert';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/reticulum/rns_service.dart';

Future<RnsAnnounce> _announce(
    RnsIdentity id, List<String> aspects, Uint8List appData) async {
  final pkt = await RnsAnnounceBuilder.build(id, 'xprs', aspects,
      appData: appData);
  final a = await validateAnnounce(RnsPacket.parse(pkt.pack())!);
  return a!;
}

Uint8List _chat(String call, RelayAnnouncement? ra) {
  final cs = utf8.encode(call);
  if (ra == null) return Uint8List.fromList(cs);
  return Uint8List.fromList([...cs, 0, ...ra.encode(uptimeSeconds: 7200)]);
}

const _archiver = RelayAnnouncement(
    role: RelayRole.archiver, capacity: 3, caps: RelayCap.search);
const _leaf =
    RelayAnnouncement(role: RelayRole.leaf, capacity: 0, caps: 0);

void main() {
  final rns = RnsService.instance;

  test('a chat announce carrying an archiver role names an archiver',
      () async {
    final id = await RnsIdentity.generate();
    rns.debugObserveAnnounce(
        await _announce(id, ['chat'], _chat('X3ARCV', _archiver)));
    expect(rns.announcedCallsigns(prefix: 'X3'), contains('X3ARCV'));
    final a = rns.announcedArchivers().where((r) => r.callsign == 'X3ARCV');
    expect(a, hasLength(1));
    expect(a.first.uptimeS, 7200);
  });

  test('a leaf role, or none, names a station but not an archiver', () async {
    final leaf = await RnsIdentity.generate();
    rns.debugObserveAnnounce(
        await _announce(leaf, ['chat'], _chat('X3LEAF', _leaf)));
    final plain = await RnsIdentity.generate();
    rns.debugObserveAnnounce(
        await _announce(plain, ['chat'], _chat('X3PLAN', null)));
    expect(rns.announcedCallsigns(prefix: 'X3'),
        containsAll(['X3LEAF', 'X3PLAN']));
    final calls = rns.announcedArchivers().map((r) => r.callsign);
    expect(calls, isNot(contains('X3LEAF')));
    expect(calls, isNot(contains('X3PLAN')));
  });

  test('the dedicated relay announce marks a named node an archiver',
      () async {
    final id = await RnsIdentity.generate();
    rns.debugObserveAnnounce(
        await _announce(id, ['chat'], _chat('X3SPLT', null)));
    expect(rns.announcedArchivers().map((r) => r.callsign),
        isNot(contains('X3SPLT')));
    rns.debugObserveAnnounce(
        await _announce(id, ['relay'], _archiver.encode()));
    expect(rns.announcedArchivers().map((r) => r.callsign),
        contains('X3SPLT'));
    // And says so no longer once it announces as a leaf.
    rns.debugObserveAnnounce(await _announce(id, ['relay'], _leaf.encode()));
    expect(rns.announcedArchivers().map((r) => r.callsign),
        isNot(contains('X3SPLT')));
  });
}
