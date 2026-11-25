import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/mesh/mesh_courier.dart';
import 'package:xprs_core/src/services/mesh/mesh_frame.dart';
import 'package:xprs_core/src/services/xprs/xprs_fetch.dart';

/// A sealed message from a callsign whose key we do not hold asks the
/// archivers for that key (12.12.1), not only the sender: a peer reached over
/// Reticulum never hears our q:identity and never airs its t:identity to us.
void main() {
  test('an unopenable sealed message asks the archivers for the key', () {
    final fetch = XprsFetch.instance
      ..autoTick = false
      ..selfCallsign = (() => 'X1ME')
      ..archivers = (() => ['X3ARC'])
      ..send = ((_) async {});
    final before = fetch.requested - fetch.skipped;
    final wire = 't:message f:X1LUJ9 d:X1ME ts:2026-11-12_15:13:00 '
        'x:${base64Url.encode(List.filled(48, 7)).replaceAll('=', '')}';
    final f = MeshFrame.parse(Uint8List.fromList(utf8.encode(wire)));
    expect(f?.isXprs, isTrue);
    MeshCourier.instance.deliverXprs(f!, via: 'rns');
    expect(fetch.requested - fetch.skipped, before + 1);
  });

  // Reported 2026-11-22: a first message from somebody new stayed
  // unreadable for good. It was shown as "waiting for the key" at once, and
  // nothing opened it when the key came.
  test('it is held for the key, and the reader is told only after the grace',
      () async {
    final c = MeshCourier.instance;
    MeshCourier.keyGrace = const Duration(milliseconds: 50);
    addTearDown(() => MeshCourier.keyGrace = const Duration(seconds: 45));
    final had = c.waitingForKey;
    final wire = 't:message f:X1NEWB d:X1ME ts:2026-11-22_15:13:00 '
        'x:${base64Url.encode(List.filled(48, 9)).replaceAll('=', '')}';
    final f = MeshFrame.parse(Uint8List.fromList(utf8.encode(wire)))!;
    expect(c.deliverXprs(f, via: 'rns'), isFalse,
        reason: 'not delivered, so not acknowledged: the copies stay');
    expect(c.waitingForKey, had + 1);
    c.deliverXprs(f, via: 'lan');
    expect(c.waitingForKey, had + 1, reason: 'a second copy is the same message');
    c.keyLearned('X1NEWB');
    expect(c.waitingForKey, had + 1,
        reason: 'no key is held for it yet: it keeps waiting');
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(c.waitingForKey, had + 1,
        reason: 'told to the reader, and still to be opened when the key comes');
  });

  test('the stations that carried a sealed message are asked for its key first', () {
    final sent = <String>[];
    XprsFetch.instance
      ..autoTick = false
      ..selfCallsign = (() => 'X1ME')
      ..archivers = (() => ['X3ARC'])
      ..send = ((w) async => sent.add(w));
    final wire = 't:message f:X1FARA d:X1ME ts:2026-11-22_16:00:00 '
        'x:${base64Url.encode(List.filled(48, 5)).replaceAll('=', '')} '
        'via:X3FIRST,X3LAST';
    final f = MeshFrame.parse(Uint8List.fromList(utf8.encode(wire)))!;
    MeshCourier.instance.deliverXprs(f, via: 'lan');
    expect(sent.where((w) => w.contains('only:X1FARA')).first,
        contains('d:X3LAST'),
        reason: 'the nearest carrier holds the letter, and its author with it');
  });
}
