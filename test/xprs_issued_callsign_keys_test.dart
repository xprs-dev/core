// XPRS.md 6.4.2: an issued callsign has no arithmetic tie to any key, so it
// is held by lease. One key holds it for a year after that key was last
// active under it; any other key using the callsign meanwhile is an
// impostor; after a year of silence the callsign is free. Every time is
// when THIS station heard, never the date a packet carries.
import 'dart:io';
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

Uint8List _pub(BigInt d) => XprsCrypto.publicKeyXOnly(d);
String _npub(BigInt d) => NostrCrypto.encodeNpub(HEX.encode(_pub(d)));

XprsPacket _msg(String from, BigInt key, String text,
        {String ts = '2026-11-22_10:00:00'}) =>
    xprsSign(XprsPacket.parse('t:message f:$from ts:$ts m:$text')!, key);

const _day = 24 * 60 * 60 * 1000;

void main() {
  final people = XprsPeople.instance;
  var now = 1795300000000;

  setUp(() {
    people.debugReset();
    now = 1795300000000;
    people.nowMs = () => now;
    // The hooks as RnsService wires them.
    xprsAlternateKeys = (call) {
      final npub = people.leaseHolder(call);
      return npub == null
          ? const []
          : [Uint8List.fromList(HEX.decode(NostrCrypto.decodeNpub(npub)))];
    };
    xprsVerifiedAs = (call, key) =>
        people.licenceActive(call, NostrCrypto.encodeNpub(HEX.encode(key)));
  });
  tearDown(() {
    xprsAlternateKeys = null;
    xprsVerifiedAs = null;
    people.close();
    people.debugReset();
  });

  test('the first key heard claiming a callsign holds it; a second is refused',
      () {
    expect(people.claimLicence(_npub(_a), 'CT1ABC'), XprsClaim.taken);
    expect(people.claimLicence(_npub(_a), 'ct1abc-9'), XprsClaim.held,
        reason: 'a device suffix is the same callsign (3.1)');
    now += 30 * _day;
    expect(people.claimLicence(_npub(_b), 'CT1ABC'), XprsClaim.refused);
    expect(people.leaseHolder('CT1ABC'), _npub(_a));
    expect(people.leasesRefused, 1);
  });

  test('a packet verifies under the holder\'s key and under no other', () {
    people.claimLicence(_npub(_a), 'CT1ABC');
    people.claimLicence(_npub(_b), 'CT1ABC'); // refused
    expect(xprsVerify(_msg('CT1ABC', _a, 'the holder'), null),
        XprsSigState.verified,
        reason: 'no key from the caller: the holder\'s is used');
    expect(xprsVerify(_msg('CT1ABC', _b, 'an impostor'), _pub(_a)),
        XprsSigState.forged);
    // Even when a caller hands over the impostor's own key, the packet is
    // "verified" only as that key's, which is the caller's business; the
    // resolver never hands it over (pubkeyForCallsign gives the holder).
    expect(xprsVerify(_msg('CT1ABC', _b, 'an impostor'), null),
        XprsSigState.unverified);
  });

  test('a date written in a packet buys nothing: only hearing counts', () {
    // The real holder is heard today.
    people.claimLicence(_npub(_a), 'CT1ABC');
    final since = people.leaseOf('CT1ABC')!.sinceMs;
    expect(since, now);
    // A forger then airs packets dated two years back, to look older.
    now += _day;
    final old = _msg('CT1ABC', _b, 'I was here first', ts: '2024-01-01_00:00:00');
    expect(people.claimLicence(_npub(_b), 'CT1ABC'), XprsClaim.refused);
    expect(xprsVerify(old, _pub(_a)), XprsSigState.forged);
    expect(people.leaseHolder('CT1ABC'), _npub(_a));
    expect(people.leaseOf('CT1ABC')!.sinceMs, since,
        reason: 'the holder\'s seniority is when this station heard it');
  });

  test('a year after the holder was last active the callsign is free', () {
    people.claimLicence(_npub(_a), 'CT1ABC');
    // Active for two months: a verified packet starts the year again.
    now += 60 * _day;
    expect(xprsVerify(_msg('CT1ABC', _a, 'still here'), null),
        XprsSigState.verified);
    expect(people.leaseOf('CT1ABC')!.lastMs, now);
    // 364 days later it is still theirs.
    now += 364 * _day;
    expect(people.leaseHolder('CT1ABC'), _npub(_a));
    expect(people.claimLicence(_npub(_b), 'CT1ABC'), XprsClaim.refused);
    // Two more days of silence and it is free; the next claim takes it.
    now += 2 * _day;
    expect(people.leaseHolder('CT1ABC'), isNull);
    expect(people.claimLicence(_npub(_b), 'CT1ABC'), XprsClaim.taken);
    expect(people.leaseHolder('CT1ABC'), _npub(_b));
    expect(people.leaseOf('CT1ABC')!.sinceMs, now);
    // The old holder is the impostor now.
    expect(people.claimLicence(_npub(_a), 'CT1ABC'), XprsClaim.refused);
    expect(people.leasesExpired, 1);
  });

  test('an impostor\'s packets do not keep anybody\'s lease alive', () {
    people.claimLicence(_npub(_a), 'CT1ABC');
    final last = people.leaseOf('CT1ABC')!.lastMs;
    now += 10 * _day;
    xprsVerify(_msg('CT1ABC', _b, 'noise'), null);
    people.licenceActive('CT1ABC', _npub(_b));
    expect(people.leaseOf('CT1ABC')!.lastMs, last);
  });

  test('a derived callsign is not leased: arithmetic decides it', () {
    expect(people.claimLicence(_npub(_a), 'X1QZ3N'), XprsClaim.derived);
    expect(people.leaseHolder('X1QZ3N'), isNull);
  });

  test('the lease is kept in people.zx and read back after a restart', () {
    final tmp = Directory.systemTemp.createTempSync('xprslease');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = '${tmp.path}/people.zx';
    people.init(path);
    people.claimLicence(_npub(_a), 'CT1ABC');
    final since = now;
    people.close();
    people.debugReset();
    people.nowMs = () => now;
    now += 5 * _day;
    people.init(path);
    expect(people.leaseHolder('CT1ABC'), _npub(_a));
    expect(people.leaseOf('CT1ABC')!.sinceMs, since);
    expect(people.claimLicence(_npub(_b), 'CT1ABC'), XprsClaim.refused,
        reason: 'a restart does not free a callsign');
  });
}
