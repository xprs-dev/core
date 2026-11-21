// XPRS.md 6.3.3: a person states the other identities they go by, one signed
// identity packet per kind (`idtype:` and `data:`). The newest packet of a
// kind replaces that kind, `data:-` withdraws it, `scope:` says how far it
// goes, and a kind this station does not know is kept as written.
import 'dart:convert';

import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/people/xprs_people.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_profiles.dart';
import 'package:xprs_core/src/services/xprs/xprs_publisher.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

final _d = BigInt.parse(
    '3f2a9c1d7e5b4a6c8d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e',
    radix: 16);

XprsPacket _say(String idtype, List<String> values,
        {String ts = '2026-11-21_10:00:00', String scope = '', BigInt? key}) =>
    XprsPacket.parse(XprsPublisher.composeIdentityStatement(
        call: 'X1QZ3N',
        idtype: idtype,
        values: values,
        ts: ts,
        signingKey: key ?? _d,
        scope: scope)!)!;

void main() {
  final people = XprsPeople.instance;
  final profiles = XprsProfiles.instance;
  final pub = XprsCrypto.publicKeyXOnly(_d);
  late String npub;

  setUp(() {
    people.debugReset();
    profiles.keyResolver = (_) => pub;
    profiles.identityRows = (_) => const [];
    npub = NostrCrypto.encodeNpub(
        pub.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
  });
  tearDown(people.debugReset);

  group('composing', () {
    test('one kind a packet, the set comma-separated, signed, with its scope',
        () {
      final p = _say('ble', ['A4:CF:12:0B:7E:31', 'A4:CF:12:0B:80:02'],
          scope: 'local');
      expect(p.type, 'identity');
      expect(p['idtype'], 'ble');
      expect(p['data'], 'A4:CF:12:0B:7E:31,A4:CF:12:0B:80:02');
      expect(p['scope'], 'local');
      expect(xprsVerify(p, pub), XprsSigState.verified);
      expect(p.has('k'), isFalse);
      expect(p.has('m'), isFalse, reason: 'm: is the description, untouched');
    });

    test('an empty set withdraws the kind; global scope is not written', () {
      final p = _say('email', const [], scope: 'global');
      expect(p['data'], '-');
      expect(p.has('scope'), isFalse);
    });

    test('a set that does not fit a packet is cut, never continued', () {
      final many = [for (var i = 0; i < 40; i++) 'box$i@example.org'];
      final p = _say('email', many);
      expect(utf8.encode(p.encode()).length,
          lessThanOrEqualTo(XprsPacket.maxBytes));
      final kept = p['data']!.split(',');
      expect(kept.length, lessThan(many.length));
      expect(kept.first, 'box0@example.org', reason: 'the first ones stay');
    });

    test('a value with a space or a comma, or a kind that is not a word, is '
        'not something a field can carry', () {
      expect(_say('email', ['a b@example.org', 'ok@example.org'])['data'],
          'ok@example.org');
      expect(
          XprsPublisher.composeIdentityStatement(
              call: 'X1QZ3N',
              idtype: 'e mail',
              values: const ['x'],
              ts: '2026-11-21_10:00:00',
              signingKey: _d),
          isNull);
    });
  });

  group('receiving', () {
    test('filed under the person\'s key, as their signed word', () {
      profiles.offer('X1QZ3N', _say('email', ['Joao@Example.org'], scope: 'PT,ES'));
      final e = people.of(npub, type: XprsIdType.email).single;
      expect(e.value, 'joao@example.org');
      expect(e.evidence, XprsIdEvidence.signed);
      expect(e.scope, 'PT,ES');
      expect(e.via, XprsPeople.said);
      expect(people.personWith(XprsIdType.email, 'joao@example.org'), npub);
      expect(profiles.identitiesStated, greaterThan(0));
    });

    test('the newest packet of a kind replaces the kind', () {
      profiles.offer('X1QZ3N',
          _say('ble', ['A4:CF:12:0B:7E:31'], ts: '2026-11-21_10:00:00'));
      profiles.offer(
          'X1QZ3N',
          _say('ble', ['A4:CF:12:0B:7E:31', 'A4:CF:12:0B:80:02'],
              ts: '2026-11-21_11:00:00'));
      expect(people.valuesOf(npub, XprsIdType.ble), hasLength(2));
      profiles.offer('X1QZ3N',
          _say('ble', ['A4:CF:12:0B:80:02'], ts: '2026-11-21_12:00:00'));
      expect(people.valuesOf(npub, XprsIdType.ble), ['A4:CF:12:0B:80:02']);
      // Another kind is another packet and is not touched.
      profiles.offer('X1QZ3N', _say('meshtastic', ['MTA1B2C3D4']));
      expect(people.valuesOf(npub, XprsIdType.ble), hasLength(1));
      expect(people.valuesOf(npub, XprsIdType.meshtastic), ['MTA1B2C3D4']);
    });

    test('data:- withdraws the kind, and an older packet cannot bring it back',
        () {
      final old = _say('email', ['joao@example.org'], ts: '2026-11-21_10:00:00');
      profiles.offer('X1QZ3N', old);
      profiles.offer(
          'X1QZ3N', _say('email', const [], ts: '2026-11-22_08:00:00'));
      expect(people.of(npub, type: XprsIdType.email), isEmpty);
      profiles.offer('X1QZ3N', old); // replayed by an archiver later
      expect(people.of(npub, type: XprsIdType.email), isEmpty);
    });

    test('what this station saw itself is not the person\'s to withdraw', () {
      people.claim(npub, XprsIdType.callsign, 'X1QZ3N',
          evidence: XprsIdEvidence.derived);
      people.note(npub, XprsIdType.ble, 'A4:CF:12:0B:7E:31',
          evidence: XprsIdEvidence.observed, via: 'ble');
      profiles.offer(
          'X1QZ3N', _say('ble', const [], ts: '2026-11-22_08:00:00'));
      expect(people.valuesOf(npub, XprsIdType.ble), ['A4:CF:12:0B:7E:31']);
    });

    test('a kind this station does not know is kept as written', () {
      profiles.offer('X1QZ3N', _say('matrix', ['@joao:example.org']));
      expect(people.valuesOf(npub, 'matrix'), ['@joao:example.org']);
    });

    test('a statement that does not verify is ignored', () {
      final other = BigInt.parse(
          '1f2a9c1d7e5b4a6c8d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e',
          radix: 16);
      profiles.offer('X1QZ3N', _say('email', ['evil@example.org'], key: other));
      expect(people.personWith(XprsIdType.email, 'evil@example.org'), isNull);
    });

    test('two keys may state one identity: both kept, neither merged', () {
      profiles.offer('X1QZ3N', _say('meshtastic', ['MTA1B2C3D4']));
      const other =
          'npub1ptzm5k5zv9v3sjyjxv9u3pxa7n66ppl4zfa8w3e7f7lpc0eshfsqfhe4hf';
      people.stated(other, 'meshtastic', 'MTA1B2C3D4', tsMs: 1795000000000);
      expect(people.contested(XprsIdType.meshtastic, 'MTA1B2C3D4'), isTrue);
    });
  });

  test('scope decides what may be told on, and to whom', () {
    people.stated(npub, 'ble', 'A4:CF:12:0B:7E:31',
        tsMs: 1, scope: 'local');
    people.stated(npub, 'email', 'joao@example.org', tsMs: 1, scope: 'PT,ES');
    people.stated(npub, 'meshtastic', 'MTA1B2C3D4', tsMs: 1);
    people.note(npub, XprsIdType.wlan, 'A4:CF:12:0B:7E:32',
        evidence: XprsIdEvidence.observed);
    List<String> types(String reach) =>
        [for (final e in people.tellable(npub, reach: reach)) e.type]..sort();
    expect(types('local'), ['ble', 'email', 'meshtastic']);
    expect(types('regional'), ['email', 'meshtastic']);
    expect(types('global'), ['meshtastic']);
    expect(types('local'), isNot(contains('wlan')),
        reason: 'what was only observed is never told on');
  });
}
