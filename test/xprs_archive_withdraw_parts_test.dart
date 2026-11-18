// XPRS.md 7.8.2 with 7.6: withdrawing a long post destroys every piece of it.
// The post is held as its parts (each with its own identifier) and maybe as
// the joined packet; a withdrawal names one of them, and they all go, so the
// words survive nowhere and no reader can rebuild the post from its parts.
import 'dart:io';

import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_id.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

void main() {
  final key = BigInt.parse('fedcba0987654321fedcba0987654321', radix: 16);
  const head = 't:status f:X1BOBB ts:2026-11-18_17:24:59';
  final whole = XprsPacket.parse('$head m:Archivers are the pillar. You should see the link.')!;
  final parts = [
    XprsPacket.parse('$head n:1/3 m:Archivers are the pillar.')!,
    XprsPacket.parse('$head n:2/3 m:You should see')!,
    XprsPacket.parse('$head n:3/3 sig:${xprsSign(whole, key)['sig']} m:the link.')!,
  ];
  final postId = xprsIdentifier(whole);

  late XprsArchive a;
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('xprs-withdraw');
    a = XprsArchive.instance;
    a.init('${dir.path}/archive.zx');
    a.keyResolver = (c) => c == 'X1BOBB' ? XprsCrypto.publicKeyXOnly(key) : null;
  });
  tearDown(() {
    a.close();
    dir.deleteSync(recursive: true);
  });

  void withdraw(String id) {
    final w = XprsPacket.parse(
        't:status f:X1BOBB ts:2026-11-18_17:40:00 r:$id remove:status')!;
    a.admit(xprsSign(w, key), bearer: 'rns');
    a.flush();
  }

  List<String> held() => [
        for (final r in a.query(types: const ['status'], from: 'X1BOBB', limit: 20))
          if (!'${r['wire']}'.contains('remove:')) '${r['wire']}'
      ];

  test('naming the joined packet takes its parts with it', () {
    a.admit(xprsSign(whole, key), bearer: 'lan');
    for (final p in parts) {
      a.admit(p, bearer: 'rns');
    }
    a.flush();
    expect(held(), hasLength(4));
    withdraw(postId);
    expect(held(), isEmpty);
  });

  test('with only the parts held, the post identifier still finds them', () {
    for (final p in parts) {
      a.admit(p, bearer: 'rns');
    }
    a.flush();
    expect(held(), hasLength(3));
    withdraw(postId);
    expect(held(), isEmpty);
  });

  test('naming one part (a reader showed a rebuilt copy) takes the set', () {
    for (final p in parts) {
      a.admit(p, bearer: 'rns');
    }
    a.flush();
    withdraw(xprsIdentifier(parts[1]));
    expect(held(), isEmpty);
  });

  test('the parts do not come back once withdrawn', () {
    for (final p in parts) {
      a.admit(p, bearer: 'rns');
    }
    a.flush();
    withdraw(postId);
    for (final p in parts) {
      a.admit(p, bearer: 'lan');
    }
    a.flush();
    expect(held(), isEmpty);
  });

  test('another post of the same author is untouched', () {
    for (final p in parts) {
      a.admit(p, bearer: 'rns');
    }
    a.admit(xprsSign(XprsPacket.parse('t:status f:X1BOBB ts:2026-11-18_17:30:00 m:keep me')!, key),
        bearer: 'rns');
    a.flush();
    withdraw(postId);
    expect(held(), [contains('keep me')]);
  });
}
