// XPRS.md 7.6, 9.1.1: a part carries the signature of the whole; alone it
// proves nothing, so the archive keeps it as unverified, never as forged.
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:reticulum/reticulum.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

void main() {

  test('the signed last part of a split post is kept, unverified', () {
    final dir = Directory.systemTemp.createTempSync('xprs-parts');
    final a = XprsArchive.instance;
    addTearDown(() {
      a.close();
      dir.deleteSync(recursive: true);
    });
    a.init('${dir.path}/archive.zx');
    final key = BigInt.parse('fedcba0987654321fedcba0987654321', radix: 16);
    a.keyResolver = (c) => c == 'X1BOBB' ? XprsCrypto.publicKeyXOnly(key) : null;
    const head = 't:blog f:X1BOBB ts:2026-11-06_10:00:00 title:field-day';
    final whole = XprsPacket.parse('$head m:We set up on the hill. The wind took the mast.')!;
    final sig = xprsSign(whole, key)['sig']!;
    a.admit(XprsPacket.parse('$head n:1/2 m:We set up on the hill.')!, bearer: 'rns');
    a.admit(XprsPacket.parse('$head n:2/2 sig:$sig m:The wind took the mast.')!, bearer: 'rns');
    // A whole packet whose signature does not hold is still a forgery.
    a.admit(XprsPacket.parse('t:blog f:X1BOBB ts:2026-11-06_10:01:00 title:fake sig:$sig m:not his words')!, bearer: 'rns');
    a.flush();
    final rows = a.query(types: const ['blog'], from: 'X1BOBB', limit: 10);
    expect(rows.map((r) => r['wire']).where((w) => '$w'.contains('field-day')), hasLength(2));
    expect(rows.where((r) => '${r['wire']}'.contains('title:fake')), isEmpty);
    expect(a.forged, 1);
  });
}
