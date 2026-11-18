// A phone's X3 beacons the install's one `lx:` beside the person's X1. The
// address keeps naming the person (an inbound chat is theirs), and the X3 --
// the archiver -- still resolves to it.
import 'package:test/test.dart';
import 'package:reticulum/reticulum.dart' show XprsCrypto;
import 'package:xprs_core/src/services/reticulum/rns_service.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

void main() {
  const dest = '0123456789abcdef0123456789abcdef';
  final rns = RnsService.instance;

  test('the person first, then the device: the device is an alias', () {
    rns.noteLxmfCallsign(dest, 'X1PERSN');
    rns.noteLxmfCallsign(dest, 'X3DEVCE');
    expect(rns.callsignForLxmfDest(dest), 'X1PERSN');
    expect(rns.lxmfDestForCallsign('X3DEVCE'), dest);
  });

  test('the device first, then the person: the person takes the address', () {
    const d2 = 'fedcba9876543210fedcba9876543210';
    rns.noteLxmfCallsign(d2, 'X3DEVC2');
    rns.noteLxmfCallsign(d2, 'X1PERS2');
    expect(rns.callsignForLxmfDest(d2), 'X1PERS2');
    expect(rns.lxmfDestForCallsign('X3DEVC2'), d2);
  });

  test("a signed observation's lx: teaches where its X3 is; a forged one does not",
      () {
    final d = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
    XprsArchive.instance.keyResolver = (_) => XprsCrypto.publicKeyXOnly(d);
    addTearDown(() => XprsArchive.instance.keyResolver = null);
    const lx = 'aaaabbbbccccddddaaaabbbbccccdddd';
    rns.noteLxmfCallsign(lx, 'X1OWNER');
    final obs = xprsSign(
        XprsPacket.parse('t:observation f:X3ARCHV ts:2026-11-18_00:00:00 '
            'link:lan serve:archive lx:$lx')!,
        d);
    final forged = XprsPacket.parse(
        obs.encode().replaceFirst('X3ARCHV', 'X3OTHER'))!;
    rns.noteSignedLx(forged);
    expect(rns.lxmfDestForCallsign('X3OTHER'), '');
    rns.noteSignedLx(obs);
    expect(rns.lxmfDestForCallsign('X3ARCHV'), lx);
    expect(rns.callsignForLxmfDest(lx), 'X1OWNER');
  });
}
