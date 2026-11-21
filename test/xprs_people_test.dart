// XprsPeople: one record per key, identities that accumulate under it with
// how each was learned, lookups both ways, bounded, kept in people.zx.
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/people/xprs_people.dart';

const _joao = 'npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f';
const _ana = 'npub1ptzm5k5zv9v3sjyjxv9u3pxa7n66ppl4zfa8w3e7f7lpc0eshfsqfhe4hf';
const _rns = '3e2c78de1f4eb606116c218493594745';

void main() {
  final p = XprsPeople.instance;
  var now = 1760000000000;

  setUp(() {
    p.debugReset();
    now = 1760000000000;
    p.nowMs = () => now;
  });
  tearDown(() {
    p.close();
    p.debugReset();
  });

  test('identities accumulate under the key, and are found both ways', () {
    expect(
        p.note(_joao, XprsIdType.callsign, 'x1qz3n-2',
            evidence: XprsIdEvidence.derived),
        isTrue);
    p.note(_joao, XprsIdType.licence, 'CT1ABC', evidence: XprsIdEvidence.signed);
    p.note(_joao, XprsIdType.licence, 'EA/CT1ABC',
        evidence: XprsIdEvidence.signed);
    p.note(_joao, XprsIdType.reticulum, _rns.toUpperCase(),
        evidence: XprsIdEvidence.observed, via: 'rns');
    p.note(_joao, XprsIdType.ble, 'aa-bb-cc-dd-ee-ff',
        evidence: XprsIdEvidence.observed);

    expect(p.valuesOf(_joao, XprsIdType.callsign), ['X1QZ3N'],
        reason: 'whole and uppercase, no device suffix');
    expect(p.valuesOf(_joao, XprsIdType.licence),
        unorderedEquals(['CT1ABC', 'EA/CT1ABC']),
        reason: 'one key may bind several issued callsigns (6.4.2)');
    expect(p.valuesOf(_joao, XprsIdType.ble), ['AA:BB:CC:DD:EE:FF']);
    expect(p.personWith(XprsIdType.reticulum, _rns), _joao);
    expect(p.personWith(XprsIdType.licence, 'ct1abc'), _joao);
    // The question the file fetch asks: how do I reach this callsign?
    expect(p.reach(XprsIdType.callsign, 'X1QZ3N', XprsIdType.reticulum),
        [_rns]);
    expect(p.personWith(XprsIdType.callsign, 'X1NOBODY'), isNull);
  });

  test('a value that cannot be of its type is refused', () {
    expect(
        p.note(_joao, XprsIdType.ble, 'not a mac',
            evidence: XprsIdEvidence.observed),
        isFalse);
    expect(
        p.note(_joao, XprsIdType.reticulum, 'xyz',
            evidence: XprsIdEvidence.observed),
        isFalse);
    expect(
        p.note(_joao, XprsIdType.meshtastic, 'MTA1B2C3D',
            evidence: XprsIdEvidence.relayed),
        isFalse,
        reason: 'matched whole: two letters and eight digits (3.2)');
    expect(
        p.note(_joao, XprsIdType.email, 'nobody', evidence: XprsIdEvidence.noted),
        isFalse);
    expect(p.holderCount, 0);
  });

  test('evidence only rises; a reader asks for a minimum', () {
    p.note(_joao, XprsIdType.lxmf, _rns, evidence: XprsIdEvidence.observed);
    expect(
        p.of(_joao, type: XprsIdType.lxmf, min: XprsIdEvidence.signed), isEmpty);
    expect(
        p.note(_joao, XprsIdType.lxmf, _rns, evidence: XprsIdEvidence.signed),
        isTrue,
        reason: 'the signed lx: is news');
    expect(
        p.note(_joao, XprsIdType.lxmf, _rns, evidence: XprsIdEvidence.observed),
        isFalse);
    expect(p.of(_joao, type: XprsIdType.lxmf).single.evidence,
        XprsIdEvidence.signed,
        reason: 'the next announce does not weaken it');
    // The strongest first.
    p.note(_joao, XprsIdType.lxmf, 'ab' * 16, evidence: XprsIdEvidence.observed);
    expect(p.valuesOf(_joao, XprsIdType.lxmf).first, _rns);
  });

  test('two keys may hold one issued callsign: both kept, marked contested',
      () {
    p.note(_joao, XprsIdType.licence, 'CT1ABC', evidence: XprsIdEvidence.signed);
    expect(p.contested(XprsIdType.licence, 'CT1ABC'), isFalse);
    now += 1000;
    p.note(_ana, XprsIdType.licence, 'CT1ABC', evidence: XprsIdEvidence.signed);
    expect(p.contested(XprsIdType.licence, 'CT1ABC'), isTrue);
    expect(p.holders(XprsIdType.licence, 'CT1ABC'), [_ana, _joao],
        reason: 'equal evidence: the one seen last first; nothing merged');
  });

  test('a record with no key is kept, and a key that claims it takes it over',
      () {
    final node = XprsPeople.unclaimed(XprsIdType.meshtastic, 'mta1b2c3d4');
    expect(node, '~meshtastic:MTA1B2C3D4');
    p.note(node, XprsIdType.meshtastic, 'MTA1B2C3D4',
        evidence: XprsIdEvidence.relayed, via: 'X3DCK0');
    p.note(node, XprsIdType.ble, 'AA:BB:CC:DD:EE:01',
        evidence: XprsIdEvidence.observed);
    expect(p.personWith(XprsIdType.meshtastic, 'MTA1B2C3D4'), isNull,
        reason: 'heard, and nobody\'s yet');
    expect(p.holders(XprsIdType.meshtastic, 'MTA1B2C3D4'), [node]);

    p.claim(_joao, XprsIdType.meshtastic, 'MTA1B2C3D4');
    expect(p.personWith(XprsIdType.meshtastic, 'MTA1B2C3D4'), _joao);
    expect(p.of(node), isEmpty, reason: 'the keyless record is gone');
    final ble = p.of(_joao, type: XprsIdType.ble).single;
    expect(ble.value, 'AA:BB:CC:DD:EE:01');
    expect(ble.evidence, XprsIdEvidence.observed,
        reason: 'what was only observed of the node stays observed');
  });

  test('a withdrawn identity is gone', () {
    p.note(_joao, XprsIdType.email, 'Joao@Example.org',
        evidence: XprsIdEvidence.signed, scope: 'PT,ES');
    final e = p.of(_joao, type: XprsIdType.email).single;
    expect(e.value, 'joao@example.org');
    expect(e.scope, 'PT,ES');
    expect(p.remove(_joao, XprsIdType.email, 'joao@example.org'), isTrue);
    expect(p.personWith(XprsIdType.email, 'joao@example.org'), isNull);
    expect(p.holderCount, 0);
  });

  test('bounded: so many of a type per holder, the weakest and oldest leave',
      () {
    p.note(_joao, XprsIdType.reticulum, 'ff' * 16,
        evidence: XprsIdEvidence.signed);
    for (var i = 0; i < XprsPeople.perType + 3; i++) {
      now += 1000;
      p.note(_joao, XprsIdType.reticulum, i.toRadixString(16).padLeft(32, '0'),
          evidence: XprsIdEvidence.observed);
    }
    final kept = p.valuesOf(_joao, XprsIdType.reticulum);
    expect(kept, hasLength(XprsPeople.perType));
    expect(kept.first, 'ff' * 16, reason: 'the signed one stays');
    expect(kept, isNot(contains('0' * 32)), reason: 'the oldest observed left');
    expect(p.personWith(XprsIdType.reticulum, '0' * 32), isNull);
  });

  test('kept in people.zx: read back after a restart, with what was removed '
      'gone', () {
    final tmp = Directory.systemTemp.createTempSync('xprspeople');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = '${tmp.path}/people.zx';
    p.init(path);
    expect(p.ready, isTrue);
    p.note(_joao, XprsIdType.callsign, 'X1QZ3N', evidence: XprsIdEvidence.derived);
    p.note(_joao, XprsIdType.reticulum, _rns,
        evidence: XprsIdEvidence.observed, via: 'rns');
    p.note(_joao, XprsIdType.email, 'joao@example.org',
        evidence: XprsIdEvidence.signed, scope: 'local');
    p.note(_ana, XprsIdType.callsign, 'X3PTZM', evidence: XprsIdEvidence.derived);
    p.remove(_joao, XprsIdType.email, 'joao@example.org');
    p.close();
    p.debugReset();
    expect(p.holderCount, 0);

    p.nowMs = () => now;
    p.init(path);
    expect(p.holderCount, 2);
    expect(p.reach(XprsIdType.callsign, 'X1QZ3N', XprsIdType.reticulum), [_rns]);
    final r = p.of(_joao, type: XprsIdType.reticulum).single;
    expect(r.evidence, XprsIdEvidence.observed);
    expect(r.via, 'rns');
    expect(p.of(_joao, type: XprsIdType.email), isEmpty);
    expect(p.personWith(XprsIdType.callsign, 'X3PTZM'), _ana);
  });

  test('a re-sighting within the hour is not written to the store again', () {
    final tmp = Directory.systemTemp.createTempSync('xprspeople');
    addTearDown(() => tmp.deleteSync(recursive: true));
    p.init('${tmp.path}/people.zx');
    p.note(_joao, XprsIdType.reticulum, _rns, evidence: XprsIdEvidence.observed);
    p.flush();
    final t0 = now;
    for (var i = 0; i < 50; i++) {
      now += 30 * 1000; // an announce every half minute
      p.note(_joao, XprsIdType.reticulum, _rns, evidence: XprsIdEvidence.observed);
    }
    expect(p.of(_joao).single.lastMs, now, reason: 'memory has the new time');
    expect(p.of(_joao).single.savedMs, t0,
        reason: '25 minutes of sightings, no write');
    now += 61 * 60 * 1000;
    p.note(_joao, XprsIdType.reticulum, _rns, evidence: XprsIdEvidence.observed);
    expect(p.of(_joao).single.savedMs, now, reason: 'an hour on, one write');
  });
}
