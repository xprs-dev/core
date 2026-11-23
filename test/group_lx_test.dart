// A group is reachable at its admin's address (10.3): the admin's device
// signs the group's identity with `lx:` naming where it is written to, and a
// station that holds the record can address the group without its roster.
// Nobody without the group's key can claim the group's address.
import 'dart:math';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/reticulum/rns_service.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_group_act.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

BigInt _key(int seed) {
  final r = Random(seed);
  var d = BigInt.zero;
  for (var i = 0; i < 31; i++) {
    d = (d << 8) | BigInt.from(r.nextInt(256));
  }
  return d + BigInt.one;
}

void main() {
  final group = _key(7), stranger = _key(8);
  final pub = XprsCrypto.publicKeyXOnly(group);
  final npub = NostrCrypto.encodeNpub(HEX.encode(pub));
  const lx = '0123456789abcdef0123456789abcdef';

  setUp(() {
    // The service installs its own key resolver when it is made: made
    // first, so the one below is the one in force.
    RnsService.instance;
    XprsArchive.instance.keyResolver =
        (c) => c == 'X5TEST' ? Uint8List.fromList(pub) : null;
  });
  tearDown(() {
    XprsGroupAct.ownLx = null;
    XprsArchive.instance.keyResolver = null;
  });

  test("the group's identity says where its admin is", () {
    XprsGroupAct.ownLx = () => lx;
    final p = XprsGroupAct.identity(group: 'X5TEST', npub: npub, scalar: group)!;
    expect(p['lx'], lx);
    expect(xprsVerify(p, Uint8List.fromList(pub)), XprsSigState.verified);
    XprsGroupAct.ownLx = () => null;
    expect(XprsGroupAct.identity(group: 'X5TEST', npub: npub, scalar: group)!
        .has('lx'), isFalse, reason: 'no address known: no field');
  });

  test('a station that heard it can address the group', () {
    XprsGroupAct.ownLx = () => lx;
    final p = XprsGroupAct.identity(group: 'X5TEST', npub: npub, scalar: group)!;
    RnsService.instance.noteSignedLx(p);
    expect(RnsService.instance.lxmfDestForCallsign('X5TEST'), lx);
  });

  test('a pairing not signed by the group is refused', () {
    const other = 'fedcba9876543210fedcba9876543210';
    final forged = xprsSign(
        XprsPacket.parse('t:identity f:X5TEST ts:2026-11-23_10:00:00 k:$npub lx:$other')!,
        stranger);
    RnsService.instance.noteSignedLx(forged);
    expect(RnsService.instance.lxmfDestForCallsign('X5TEST'), isNot(other));
  });
}
