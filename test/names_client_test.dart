// The station side of the names keeper (names_client_io.dart): one claim per
// address, over a connection pinned to that address, composed and signed as
// the keeper expects (13.0.3), and no claim when the keeper sees the station
// at another address. A local HTTP server plays the keeper.
import 'dart:convert';
import 'dart:io';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/names/names_client_io.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart';

void main() {
  final d = BigInt.parse('a1' * 32, radix: 16);
  final pub = XprsCrypto.publicKeyXOnly(d);
  final hex = HEX.encode(pub);
  final npub = NostrCrypto.encodeNpub(hex);
  final call = 'X3${NostrCrypto.deriveCallsign(hex, length: 4)}';
  late HttpServer srv;
  final claims = <XprsPacket>[];
  var you = '127.0.0.1';
  const nonce = 'deadbeef00112233';

  setUp(() async {
    claims.clear();
    you = '127.0.0.1';
    srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((req) async {
      if (req.uri.path != '/api/names') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      if (req.method == 'GET') {
        req.response.write(jsonEncode({
          'ok': true, 'zone': 'xprs.dev', 'station': 'X3KEEP', 'nonce': nonce, 'you': you,
        }));
      } else {
        final body = await utf8.decodeStream(req);
        final p = XprsPacket.parse(body.trim());
        if (p != null) claims.add(p);
        final ok = p != null && xprsVerify(p, pub) == XprsSigState.verified;
        req.response.write(jsonEncode(ok
            ? {'ok': true, 'name': '${call.toLowerCase()}.xprs.dev', 'next': 604800}
            : {'ok': false, 'error': 'not signed by k:'}));
      }
      await req.response.close();
    });
  });

  tearDown(() => srv.close(force: true));

  NamesClient client() => NamesClient(
        NamesClientOptions(
          keeper: 'http://127.0.0.1:${srv.port}',
          callsign: () => call,
          npub: () => npub,
          sign: (p) => xprsSign(p, d),
        ),
        log: (_) {},
        now: () => DateTime.utc(2026, 11, 9, 10, 0, 0),
      );

  test('the claim is a signed directed t:service with dial:, k: and the nonce last',
      () async {
    final names = await client().claim(v4: '127.0.0.1');
    expect(names, ['${call.toLowerCase()}.xprs.dev']);
    expect(claims, hasLength(1));
    final p = claims.single;
    expect(p.type, 'service');
    expect(p['f'], call);
    expect(p['d'], 'X3KEEP');
    expect(p['ts'], xprsFmtTs(DateTime.utc(2026, 11, 9, 10, 0, 0)));
    expect(p['dial'], '127.0.0.1');
    expect(p['k'], npub);
    expect(p['m'], nonce);
    expect(p.fields.last.key, anyOf('sig', 'm'));
    expect(xprsVerify(p, pub), XprsSigState.verified);
  });

  test('no claim when the keeper sees another address, or without a key',
      () async {
    you = '203.0.113.9';
    expect(await client().claim(v4: '127.0.0.1'), isEmpty);
    expect(claims, isEmpty);
    you = '127.0.0.1';
    final noKey = NamesClient(
      NamesClientOptions(
        keeper: 'http://127.0.0.1:${srv.port}',
        callsign: () => call,
        npub: () => npub,
        sign: (p) => null,
      ),
      log: (_) {},
    );
    expect(await noKey.claim(v4: '127.0.0.1'), isEmpty);
    expect(claims, isEmpty);
  });

  test('an IPv6 claim leaves from the address it names', () async {
    final v6 = await HttpServer.bind(InternetAddress.loopbackIPv6, 0);
    String? seenFrom;
    v6.listen((req) async {
      seenFrom = req.connectionInfo?.remoteAddress.address;
      if (req.method == 'GET') {
        req.response.write(jsonEncode({
          'ok': true, 'zone': 'xprs.dev', 'station': 'X3KEEP', 'nonce': nonce, 'you': '::1',
        }));
      } else {
        final p = XprsPacket.parse((await utf8.decodeStream(req)).trim());
        if (p != null) claims.add(p);
        req.response.write(jsonEncode({'ok': true, 'name': 'x.xprs.dev'}));
      }
      await req.response.close();
    });
    try {
      final c = NamesClient(
        NamesClientOptions(
          keeper: 'http://[::1]:${v6.port}',
          callsign: () => call,
          npub: () => npub,
          sign: (p) => xprsSign(p, d),
        ),
        log: (_) {},
      );
      expect(await c.claim(v6: '::1'), ['x.xprs.dev']);
      expect(seenFrom, '::1');
      expect(claims.single['dial'], '::1');
    } finally {
      await v6.close(force: true);
    }
  });

  test('an address of a family the keeper has no record for is skipped, not fatal',
      () async {
    // 127.0.0.1 has no AAAA, so the IPv6 claim finds no target; the IPv4
    // one still goes through.
    final names = await client().claim(v4: '127.0.0.1', v6: '2a02::1');
    expect(names, ['${call.toLowerCase()}.xprs.dev']);
    expect(claims, hasLength(1));
  });
}
