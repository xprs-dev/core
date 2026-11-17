// A phone's X3 beacons the install's one `lx:` beside the person's X1. The
// address keeps naming the person (an inbound chat is theirs), and the X3 --
// the archiver -- still resolves to it.
import 'package:test/test.dart';
import 'package:xprs_core/src/services/reticulum/rns_service.dart';

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
}
