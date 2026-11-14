// The device's own X3 (DeviceIdentity): its callsign is the station form of
// its key, it signs what it says about itself, and the policy answer it
// gives verifies under that key and names its owners.
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/profile/device_identity.dart';
import 'dart:convert';

import 'package:xprs_core/src/services/xprs/xprs_history_server.dart';
import 'package:xprs_core/src/services/xprs/xprs_ingest.dart';
import 'package:xprs_core/src/services/xprs/xprs_observation.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';
import 'package:xprs_core/src/services/xprs/xprs_station_policy.dart';

void main() {
  final keys = NostrKeyGenerator.generateKeyPair();
  setUp(() => DeviceIdentity.instance
    ..resetForTest()
    ..adoptForTest(keys.nsec));
  tearDown(DeviceIdentity.instance.resetForTest);

  test('the callsign is the X3 form of the device key', () {
    final dev = DeviceIdentity.instance;
    expect(dev.ready, isTrue);
    expect(dev.callsign, NostrKeyGenerator.deriveStationCallsign(keys.npub));
    expect(dev.callsign.startsWith('X3'), isTrue);
    expect(dev.isDevice('${dev.callsign}-2'), isTrue);
    expect(dev.isDevice(keys.callsign), isFalse); // the X1 of the same key
  });

  test('the policy answer is signed by the device and names its owners', () {
    final dev = DeviceIdentity.instance;
    final wire = xprsPolicyReportWire(dev.callsign, 'X1ASKR',
        const XprsStationPolicy(owners: ['X1OWNR'], serve: ['relay']))!;
    final p = xprsSign(XprsPacket.parse(wire)!, dev.scalar!);
    final pub = XprsCrypto.publicKeyXOnly(dev.scalar!);
    expect(xprsVerify(XprsPacket.parse(p.encode())!, pub),
        XprsSigState.verified);
    expect(p['owner'], 'X1OWNR');
    expect(p['f'], dev.callsign);
  });

  test('its observation carries the place and verifies', () {
    final dev = DeviceIdentity.instance;
    final p = xprsComposeObservation(
      self: dev.callsign,
      link: 'lan',
      heard: const ['X1ABCD'],
      budget: XprsPacket.maxBytes,
      pos: '38.7077,-9.1365',
      accM: 10,
      signingKey: dev.scalar,
    )!;
    expect(p['f'], dev.callsign);
    expect(p['pos'], '38.7077,-9.1365');
    expect(p.has('lx'), isFalse);
    expect(xprsVerify(p, XprsCrypto.publicKeyXOnly(dev.scalar!)),
        XprsSigState.verified);
  });

  test('a history ask to the device gets a signed 404 from the device', () async {
    final dev = DeviceIdentity.instance;
    final srv = XprsHistoryServer.instance..install();
    final aired = <String>[];
    srv.txOverride = (key, bytes, ttl) async {
      aired.add(utf8.decode(bytes));
      return true;
    };
    addTearDown(() => srv.txOverride = null);
    final ask = XprsPacket.parse('t:command f:X3ASKR d:${dev.callsign} '
        'ts:2026-11-14_14:26:08 cmd:history kind:message')!;
    XprsIngest.onCommand!(ask, selfBase: 'X1OWNR', bearer: 'lan');
    await Future<void>.delayed(Duration.zero);
    expect(aired, hasLength(1));
    final r = XprsPacket.parse(aired.single)!;
    expect(r.type, 'result');
    expect(r['f'], dev.callsign);
    expect(r['d'], 'X3ASKR');
    expect(r['code'], '404');
    expect(xprsVerify(r, XprsCrypto.publicKeyXOnly(dev.scalar!)),
        XprsSigState.verified);
  });
}
