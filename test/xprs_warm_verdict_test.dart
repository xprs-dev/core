// A signature checked on the crypto worker is the same verdict the inline
// check gives, and the inline check then only looks it up. What lets the
// archive's periodic write keep curve arithmetic off the isolate that draws
// the screen (performance.md 8.25).
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

void main() {
  final key = BigInt.parse('00c0ffee1234567890abcdef00c0ffee', radix: 16);
  final pub = XprsCrypto.publicKeyXOnly(key);
  final other = XprsCrypto.publicKeyXOnly(BigInt.parse('7777777777', radix: 16));

  test('a good signature is verified off the main isolate, then looked up',
      () async {
    final p = xprsSign(
        XprsPacket.parse('t:message f:X1WARM ts:2026-11-22_22:00:00 m:warm one')!, key);
    final before = xprsWarmed;
    await xprsWarmVerdict(p, pub);
    expect(xprsWarmed, before + 1);
    expect(xprsVerify(p, pub), XprsSigState.verified);
    await xprsWarmVerdict(p, pub);
    expect(xprsWarmed, before + 1, reason: 'known already: not asked again');
  });

  test('a signature under somebody else\'s key is forged either way', () async {
    final p = xprsSign(
        XprsPacket.parse('t:message f:X1WARM ts:2026-11-22_22:00:01 m:warm two')!, key);
    await xprsWarmVerdict(p, other);
    expect(xprsVerify(p, other), XprsSigState.forged);
  });

  test('nothing to do without a signature, without a key, or for a part',
      () async {
    final before = xprsWarmed;
    await xprsWarmVerdict(
        XprsPacket.parse('t:message f:X1WARM ts:2026-11-22_22:00:02 m:unsigned')!, pub);
    final signed = xprsSign(
        XprsPacket.parse('t:message f:X1WARM ts:2026-11-22_22:00:03 m:three')!, key);
    await xprsWarmVerdict(signed, null);
    expect(xprsWarmed, before);
  });
}
