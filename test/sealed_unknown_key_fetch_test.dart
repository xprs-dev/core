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
}
