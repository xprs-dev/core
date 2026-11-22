// XPRS.md 6.4.2: an issued callsign has no arithmetic tie to any key, so two
// stations may each bind one to a key of their own, and both verify. A
// packet from an issued callsign is good under ANY key that signed for it;
// the first key heard does not hold the callsign.
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/people/xprs_people.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

final _a = BigInt.parse(
    '3f2a9c1d7e5b4a6c8d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e',
    radix: 16);
final _b = BigInt.parse(
    '1f2a9c1d7e5b4a6c8d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e',
    radix: 16);
final _c = BigInt.parse(
    '2f2a9c1d7e5b4a6c8d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e',
    radix: 16);

Uint8List _pub(BigInt d) => XprsCrypto.publicKeyXOnly(d);
String _npub(BigInt d) => NostrCrypto.encodeNpub(HEX.encode(_pub(d)));

XprsPacket _msg(String from, BigInt key, String text) => xprsSign(
    XprsPacket.parse('t:message f:$from ts:2026-11-22_10:00:00 m:$text')!,
    key);

void main() {
  final people = XprsPeople.instance;
  var now = 1795300000000;

  setUp(() {
    people.debugReset();
    now = 1795300000000;
    people.nowMs = () => now;
    // The hook as RnsService wires it: every key that signed for the
    // callsign, from the record.
    xprsAlternateKeys = (call) => [
          for (final npub in people.signersOfLicence(call))
            Uint8List.fromList(HEX.decode(NostrCrypto.decodeNpub(npub))),
        ];
  });
  tearDown(() {
    xprsAlternateKeys = null;
    people.debugReset();
  });

  test('two keys bound one issued callsign: a packet from either verifies',
      () {
    people.claim(_npub(_a), XprsIdType.licence, 'CT1ABC',
        evidence: XprsIdEvidence.signed);
    now += 60000;
    people.claim(_npub(_b), XprsIdType.licence, 'CT1ABC',
        evidence: XprsIdEvidence.signed);
    expect(people.signersOfLicence('CT1ABC'), [_npub(_a), _npub(_b)],
        reason: 'the first to sign first; neither outranks the other');
    expect(people.contested(XprsIdType.licence, 'CT1ABC'), isTrue);

    // A resolver gives one key, the first heard.
    final first = _pub(_a);
    expect(xprsVerify(_msg('CT1ABC', _a, 'from the first'), first),
        XprsSigState.verified);
    expect(xprsVerify(_msg('CT1ABC', _b, 'from the second'), first),
        XprsSigState.verified,
        reason: 'it was dropped as forged while only the first key was kept');
    // And with a device suffix, which is the same callsign (3.1).
    expect(xprsVerify(_msg('CT1ABC-9', _b, 'mobile'), first),
        XprsSigState.verified);
  });

  test('a key that never signed for the callsign is still a forgery', () {
    people.claim(_npub(_a), XprsIdType.licence, 'CT1ABC',
        evidence: XprsIdEvidence.signed);
    expect(xprsVerify(_msg('CT1ABC', _c, 'not theirs'), _pub(_a)),
        XprsSigState.forged);
    // A callsign somebody was only SEEN beside is not one they signed for.
    people.note(_npub(_c), XprsIdType.licence, 'CT1ABC',
        evidence: XprsIdEvidence.observed);
    expect(people.signersOfLicence('CT1ABC'), [_npub(_a)]);
    expect(xprsVerify(_msg('CT1ABC', _c, 'still not'), _pub(_a)),
        XprsSigState.forged);
  });

  test('no key from this run, but the record holds one: verified', () {
    // After a restart the resolver's own table is empty.
    people.claim(_npub(_b), XprsIdType.licence, 'CT1ABC',
        evidence: XprsIdEvidence.signed);
    expect(xprsVerify(_msg('CT1ABC', _b, 'after a restart'), null),
        XprsSigState.verified);
    expect(xprsVerify(_msg('CT1ABC', _c, 'a stranger'), null),
        XprsSigState.unverified,
        reason: 'no key given and none matched: not known, not forged');
  });

  test('a derived callsign has one key, and nothing else is tried', () {
    expect(people.signersOfLicence('X1QZ3N'), isEmpty);
    people.claim(_npub(_b), XprsIdType.callsign, 'X1QZ3N',
        evidence: XprsIdEvidence.signed);
    expect(xprsVerify(_msg('X1QZ3N', _b, 'x'), _pub(_a)), XprsSigState.forged);
  });

  test('an unsigned packet stays unsigned', () {
    people.claim(_npub(_a), XprsIdType.licence, 'CT1ABC',
        evidence: XprsIdEvidence.signed);
    final p = XprsPacket.parse('t:message f:CT1ABC ts:2026-11-22_10:00:00 m:x')!;
    expect(xprsVerify(p, _pub(_a)), XprsSigState.unsigned);
  });
}
