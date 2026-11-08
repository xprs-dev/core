// The names keeper (lib/src/services/names/names_keeper.dart, XPRS.md
// 13.0.3): a signed claim names a station in the zone; the lock keeps a label
// with its first key; replays, wrong addresses, reserved labels and floods
// are refused before anything is written. A fake DNS records the writes.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/names/names_keeper.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart';

class FakeDns implements NamesDns {
  final Map<String, (String?, String?)> zone = {};
  final List<String> ops = [];
  bool busy = false;
  bool caa = false;
  @override
  Future<void> set(String label, {String? v4, String? v6}) async {
    if (busy) throw const NamesDnsBusy();
    ops.add('set $label ${v4 ?? '-'} ${v6 ?? '-'}');
    zone[label] = (v4, v6);
  }

  @override
  Future<void> remove(String label) async {
    ops.add('remove $label');
    zone.remove(label);
  }

  @override
  Future<void> ensureCaa() async => caa = true;
}

/// A key and the callsign it derives (an X3 station of four characters).
class Station {
  Station(this.d);
  final BigInt d;
  Uint8List get pub => XprsCrypto.publicKeyXOnly(d);
  String get hex => HEX.encode(pub);
  String get npub => NostrCrypto.encodeNpub(hex);
  String get call => 'X3${NostrCrypto.deriveCallsign(hex, length: 4)}';
}

void main() {
  final keeperKey = Station(BigInt.parse('11' * 32, radix: 16));
  final alice = Station(BigInt.parse('a1' * 32, radix: 16));
  final bob = Station(BigInt.parse('b2' * 32, radix: 16));
  late DateTime clock;
  late FakeDns dns;
  late MemoryNamesStore store;
  late NamesKeeper k;

  setUp(() {
    clock = DateTime.utc(2026, 11, 9, 10, 0, 0);
    dns = FakeDns();
    store = MemoryNamesStore();
    k = NamesKeeper(
      zone: 'xprs.dev',
      store: store,
      dns: dns,
      ownCallsign: keeperKey.call,
      ownKeyHex: keeperKey.hex,
      reserved: {'_gh-xprs-dev-o'},
      now: () => clock,
      log: (_) {},
      rng: Random(7),
    );
  });

  /// A claim as the station client composes it (names_client_io.dart).
  String claimWire(Station s, String nonce, String dial,
      {String? call, DateTime? ts, String? npub}) {
    final p = XprsPacket([
      const MapEntry('t', 'service'),
      MapEntry('f', call ?? s.call),
      MapEntry('d', keeperKey.call),
      MapEntry('ts', xprsFmtTs(ts ?? clock)),
      MapEntry('dial', dial),
      MapEntry('k', npub ?? s.npub),
      MapEntry('m', nonce),
    ]);
    return xprsSign(p, s.d).encode();
  }

  String nonceFor(String peer) {
    final (st, j) = k.challenge(peer);
    expect(st, 200);
    return j['nonce'] as String;
  }

  Future<(int, Map<String, Object?>)> claim(Station s, String peer,
          {String? dial, String? call, DateTime? ts, String? npub}) async =>
      k.claim(claimWire(s, nonceFor(peer), dial ?? peer, call: call, ts: ts, npub: npub),
          peer);

  test('a station claims its label from its own address; DNS gets A then AAAA',
      () async {
    final (st, j) = await claim(alice, '203.0.113.9'.replaceFirst('203.0.113', '93.184.216'));
    expect(st, 200, reason: '$j');
    final label = alice.call.toLowerCase();
    expect(j['name'], '$label.xprs.dev');
    expect(dns.zone[label], ('93.184.216.9', null));
    // The IPv6 half, over an IPv6 connection: the same record grows.
    clock = clock.add(const Duration(minutes: 1));
    final (st6, _) = await claim(alice, '2a02:908:1:2:3:4:5:6');
    expect(st6, 200);
    expect(dns.zone[label], ('93.184.216.9', '2a02:908:1:2:3:4:5:6'));
    expect(store.get(label)!.key, alice.hex);
    // An IPv4-mapped peer is the IPv4.
    clock = clock.add(const Duration(minutes: 11));
    final (stm, _) = await claim(alice, '::ffff:93.184.216.10', dial: '93.184.216.10');
    expect(stm, 200);
    expect(dns.zone[label]!.$1, '93.184.216.10');
  });

  test('the lock: another key is refused for six months after the last claim, '
      'then takes over', () async {
    final peer = '93.184.216.9';
    expect((await claim(alice, peer)).$1, 200);
    final label = alice.call.toLowerCase();
    // Bob grinds a key with the same callsign: the claim names Alice's label.
    clock = clock.add(const Duration(days: 100));
    final (st, j) = await claim(bob, '93.184.216.20', call: alice.call);
    // Bob's key does not derive the label at all...
    expect(st, 403);
    expect(j['error'], 'f: is not derived from k:');
    // ...so the lock is exercised with a record planted as a collision would.
    store.put(NamesRecord(
        label: bob.call.toLowerCase(),
        key: alice.hex,
        first: clock.millisecondsSinceEpoch,
        last: clock.millisecondsSinceEpoch,
        lastTs: 0,
        v4: '93.184.216.9'));
    final (st2, j2) = await claim(bob, '93.184.216.20');
    expect(st2, 409);
    expect(j2['error'], 'held by another key');
    expect(j2['until'], isNotNull);
    expect(dns.zone[bob.call.toLowerCase()], isNull);
    // Alice keeps claiming: the lock moves with her last claim.
    clock = clock.add(const Duration(days: 150));
    expect((await claim(alice, peer)).$1, 200);
    clock = clock.add(const Duration(days: 150));
    expect(store.get(label)!.key, alice.hex);
    // Silence for six months frees Bob's planted label.
    clock = clock.add(const Duration(days: 40));
    final (st3, j3) = await claim(bob, '93.184.216.20');
    expect(st3, 200, reason: '$j3');
    expect(store.get(bob.call.toLowerCase())!.key, bob.hex);
    expect(dns.zone[bob.call.toLowerCase()], ('93.184.216.20', null));
  });

  test('replay: the nonce is single-use, ts must be now and after the last '
      'accepted, and dial: must be the source address', () async {
    final peer = '93.184.216.9';
    final n = nonceFor(peer);
    final wire = claimWire(alice, n, peer);
    expect((await k.claim(wire, peer)).$1, 200);
    // The same wire again: the nonce is spent.
    expect((await k.claim(wire, peer)).$1, 403);
    // A fresh nonce but an old timestamp.
    clock = clock.add(const Duration(minutes: 1));
    final (stOld, jOld) = await claim(alice, peer, ts: clock.subtract(const Duration(minutes: 2)));
    expect(stOld, 403);
    expect(jOld['error'], 'ts: is not after the last claim');
    // A timestamp far from now.
    final (stFar, jFar) = await claim(alice, peer, ts: clock.add(const Duration(minutes: 20)));
    expect(stFar, 403);
    expect(jFar['error'], 'ts: is not now');
    // Heard on the air and replayed from elsewhere: dial: is not the source.
    final (stElse, jElse) = await claim(alice, '93.184.216.77', dial: peer);
    expect(stElse, 403);
    expect(jElse['error'], contains('dial:'));
    expect(jElse['you'], '93.184.216.77');
    expect(dns.zone[alice.call.toLowerCase()], (peer, null));
  });

  test('a forgery, a wrong key, a reserved or malformed label, a bogus address: '
      'refused before DNS', () async {
    final peer = '93.184.216.9';
    // Signed by Bob, says it is Alice's key.
    final (st1, j1) = await claim(bob, peer, call: alice.call, npub: alice.npub);
    expect(st1, 403);
    expect(j1['error'], 'not signed by k:');
    // Reserved labels cannot be derived from keys, so they are refused at
    // the derivation check; the reserved test is on the keeper directly.
    expect(k.isReserved('www'), isTrue);
    expect(k.isReserved('names'), isTrue);
    expect(k.isReserved('_gh-xprs-dev-o'), isTrue);
    expect(k.isReserved('_acme-challenge'), isTrue);
    expect(k.isReserved('xn--abc'), isTrue);
    expect(k.isReserved(alice.call.toLowerCase()), isFalse);
    // Not a service packet.
    final n = nonceFor(peer);
    final bad = xprsSign(
        XprsPacket.parse('t:status f:${alice.call} ts:${xprsFmtTs(clock)} dial:$peer k:${alice.npub} m:$n')!,
        alice.d).encode();
    expect((await k.claim(bad, peer)).$1, 400);
    // Addresses that cannot be a station.
    for (final a in [
      '10.0.0.5', '192.168.1.2', '172.16.0.9', '100.64.0.1', '127.0.0.1',
      '169.254.1.1', '224.0.0.1', '0.0.0.0', '255.255.255.255',
      '185.199.108.153', 'fe80::1', 'fd00::1', '::1', '2001:db8::1',
    ]) {
      expect(NamesKeeper.isClaimableAddress(a), isFalse, reason: a);
      final (st, _) = await claim(alice, a);
      expect(st, 403, reason: a);
    }
    for (final a in ['93.184.216.9', '2a02:908:2616:da20:2ecf:67ff:fe14:d505']) {
      expect(NamesKeeper.isClaimableAddress(a), isTrue, reason: a);
    }
    expect(dns.ops, isEmpty);
    // Over the body size.
    expect((await k.claim('x' * 3000, peer)).$1, 413);
  });

  test('the keeper\'s own address is only the keeper\'s', () async {
    await k.keepOwn(v4: '93.184.216.1', v6: '2a02:908:1::1');
    expect(dns.zone['names'], ('93.184.216.1', '2a02:908:1::1'));
    expect(dns.zone[keeperKey.call.toLowerCase()], ('93.184.216.1', '2a02:908:1::1'));
    expect(dns.caa, isTrue);
    final (st, j) = await claim(alice, '93.184.216.1');
    expect(st, 403);
    expect(j['error'], contains('cannot be a station here'));
    expect((await claim(keeperKey, '93.184.216.1')).$1, 200);
    // Unchanged addresses write nothing more.
    final before = dns.ops.length;
    await k.keepOwn(v4: '93.184.216.1', v6: '2a02:908:1::1');
    expect(dns.ops.length, before);
  });

  test('rate limits: per address, per key unless the address changed, and new '
      'labels a day', () async {
    final peer = '93.184.216.9';
    // Ten challenges a minute per address.
    for (var i = 0; i < NamesKeeper.perPeerPerMinute; i++) {
      expect(k.challenge(peer).$1, 200);
    }
    expect(k.challenge(peer).$1, 429);
    clock = clock.add(const Duration(minutes: 2));
    // The same address twice within ten minutes: answered, not written.
    expect((await claim(alice, peer)).$1, 200);
    clock = clock.add(const Duration(minutes: 1));
    expect((await claim(alice, peer)).$1, 200);
    expect(dns.ops.where((o) => o.startsWith('set')).length, 1);
    // A changed address is written at once.
    clock = clock.add(const Duration(minutes: 1));
    expect((await claim(alice, '93.184.216.10')).$1, 200);
    expect(dns.ops.where((o) => o.startsWith('set')).length, 2);
    // Two hundred new labels a day, then none.
    var i = 0;
    while (true) {
      i++;
      clock = clock.add(const Duration(minutes: 1));
      final s = Station(BigInt.parse('c${i.toRadixString(16).padLeft(3, '0')}' * 16, radix: 16));
      final (st, j) = await claim(s, '93.184.${(i ~/ 250) + 1}.${i % 250 + 1}');
      if (st == 429) {
        expect(j['error'], 'no new names today');
        break;
      }
      expect(st, 200, reason: '$j');
      expect(i, lessThan(NamesKeeper.newLabelsPerDay + 1));
    }
    expect(i, NamesKeeper.newLabelsPerDay); // Alice's was the first of the day
  });

  test('DNS busy: the record is kept, the answer says pending, the sweep '
      'writes it later; silence removes DNS at 90 days and frees at six months',
      () async {
    final peer = '93.184.216.9';
    dns.busy = true;
    final (st, j) = await claim(alice, peer);
    expect(st, 200);
    expect(j['dns'], 'pending');
    final label = alice.call.toLowerCase();
    expect(store.get(label)!.dnsDirty, isTrue);
    expect(dns.zone[label], isNull);
    dns.busy = false;
    await k.sweep();
    expect(dns.zone[label], (peer, null));
    expect(store.get(label)!.dnsDirty, isFalse);
    clock = clock.add(const Duration(days: 91));
    await k.sweep();
    expect(dns.zone[label], isNull);
    expect(store.get(label), isNotNull, reason: 'the lock still holds');
    clock = clock.add(const Duration(days: 100));
    await k.sweep();
    expect(store.get(label), isNull);
  });

  test('the operator releases a lost key\'s label', () async {
    expect((await claim(alice, '93.184.216.9')).$1, 200);
    expect(await k.release('nothing'), isFalse);
    expect(await k.release(alice.call), isTrue);
    expect(store.get(alice.call.toLowerCase()), isNull);
    expect(dns.zone[alice.call.toLowerCase()], isNull);
  });

  test('through the web chat API: GET gives the challenge, POST takes the claim',
      () async {
    final api = WebChatApi(
      publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) => [],
      held: (t) => 0,
      receive: (_) {},
      mayAir: (_) => true,
      selfCallsign: () => keeperKey.call,
      keyOf: (c) => null,
      appPath: () => null,
    )..names = k;
    final peer = '93.184.216.9';
    expect((await api.handle('GET', '/api/names', {}, '', peer: peer)).status, 200);
    final ch = await api.handle('GET', '/api/names', {}, '', peer: peer);
    expect(ch.json['zone'], 'xprs.dev');
    expect(ch.json['you'], peer);
    final wire = claimWire(alice, ch.json['nonce'] as String, peer);
    final r = await api.handle('POST', '/api/names', {}, wire, peer: peer);
    expect(r.status, 200, reason: jsonEncode(r.json));
    expect(r.json['name'], '${alice.call.toLowerCase()}.xprs.dev');
    // A station that keeps no names has no such endpoint.
    api.names = null;
    expect((await api.handle('GET', '/api/names', {}, '', peer: peer)).status, 404);
  });
}
