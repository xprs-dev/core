// A station's own rooms, moderated (XPRS.md 10.10): the station is the group,
// its key signs the admin's acts, moderators accept and then sign their own
// removals and revocations, and the station enforces them on what it serves.
import 'dart:convert';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_groups.dart';
import 'package:xprs_core/src/services/xprs/xprs_id.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

final _station = BigInt.parse('5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a', radix: 16);
final _alice = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
final _bob = BigInt.parse('fedcba0987654321fedcba0987654321', radix: 16);
final _carol = BigInt.parse('0badc0de0badc0de0badc0de0badc0de', radix: 16);

String _signed(String wire, BigInt key) =>
    xprsSign(XprsPacket.parse(wire)!, key).encode();

void main() {
  late Map<String, Uint8List> keys;
  late List<String> received, aired;
  late DateTime clock;
  const lan = '192.168.1.20';
  final groups = XprsGroups.instance;
  // Two rooms' worth of rows: Carol's message, Carol's call for help, Bob's.
  final carolMsg = _signed('t:message f:X1CARO ts:2026-11-06_09:00:00 m:spam spam', _carol);
  final carolSos = _signed('t:sos f:X1CARO ts:2026-11-06_09:00:05 m:help', _carol);
  final bobMsg = _signed('t:message f:X1BOBB ts:2026-11-06_09:00:10 m:hello', _bob);
  String id(String w) => xprsIdentifier(XprsPacket.parse(w)!);

  String ts([int plusMin = 0]) {
    final t = clock.add(Duration(minutes: plusMin));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  WebChatApi make() => WebChatApi(
        publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) => [
          for (final w in [carolMsg, carolSos, bobMsg])
            {
              'id': id(w),
              'type': XprsPacket.parse(w)!.type,
              'from': XprsPacket.parse(w)!['f'],
              'to': '',
              'own': false,
              'wire': w,
            },
        ],
        held: (t) => 3,
        receive: received.add,
        mayAir: (_) => true,
        selfCallsign: () => 'X3STAT',
        keyOf: (c) => keys[c],
        appPath: () => null,
        now: () => clock,
        groups: groups,
        signAsStation: (c) => xprsSign(XprsPacket.parse(c)!, _station),
        publish: aired.add,
      );

  setUp(() {
    groups.clear();
    keys = {
      'X3STAT': XprsCrypto.publicKeyXOnly(_station),
      'X1ALIC': XprsCrypto.publicKeyXOnly(_alice),
      'X1BOBB': XprsCrypto.publicKeyXOnly(_bob),
      'X1CARO': XprsCrypto.publicKeyXOnly(_carol),
    };
    groups.keyResolver = (c) => keys[c];
    received = [];
    aired = [];
    clock = DateTime.now().toUtc();
  });

  Future<String> session(WebChatApi a, String call, BigInt key) async {
    final n = (await a.handle('GET', '/api/session', {}, '', peer: lan)).json['nonce'];
    final r = await a.handle('POST', '/api/session', {},
        _signed('t:session f:$call ts:${ts()} m:$n', key), peer: lan);
    return r.json['session'] as String;
  }

  Future<WebChatReply> admin(WebChatApi a, Map<String, Object?> b) =>
      a.handle('POST', '/api/admin', {}, jsonEncode(b), peer: lan);
  Future<Map<String, dynamic>> state(WebChatApi a, String s) async =>
      (await a.handle('GET', '/api/admin', {'session': s}, '', peer: lan)).json;
  Future<WebChatReply> post(WebChatApi a, String w) =>
      a.handle('POST', '/api/xprs/send', {}, w, peer: lan);
  Future<List<String>> shown(WebChatApi a) async => [
        for (final r in (await a.handle('GET', '/api/xprs/history', {}, '', peer: lan))
            .json['rows'] as List)
          '${r['id']}',
      ];

  /// Alice claims and accepts; Bob is appointed and accepts.
  Future<({String alice, String bob})> staff(WebChatApi a) async {
    final s = await session(a, 'X1ALIC', _alice);
    await admin(a, {'action': 'claim', 'session': s});
    var st = await state(a, s);
    expect(st['role'], 'invited', reason: 'claiming offers the moderator role');
    expect(aired.single, contains('grant:X1ALIC role:mod'),
        reason: 'signed and aired by the station');
    expect((await post(a, _signed('t:moderate f:X1ALIC d:X3STAT ts:${ts()} r:${st['offer']} accept:mod', _alice))).status, 200);
    expect((await state(a, s))['role'], 'mod');
    final b = await session(a, 'X1BOBB', _bob);
    expect((await admin(a, {'action': 'appoint', 'session': s, 'call': 'X1BOBB'})).status, 200);
    st = await state(a, b);
    expect(st['role'], 'invited');
    await post(a, _signed('t:moderate f:X1BOBB d:X3STAT ts:${ts()} r:${st['offer']} accept:mod', _bob));
    expect((await state(a, b))['role'], 'mod');
    expect((await state(a, s))['moderators'], ['X1ALIC', 'X1BOBB']);
    return (alice: s, bob: b);
  }

  test('services says the station is moderated', () async {
    final r = await make().handle('GET', '/api/services', {}, '');
    expect((r.json['page'] as Map)['moderation'], true);
  });

  test('a moderator deletes a message: gone from history, listed as removed', () async {
    final a = make();
    await staff(a);
    final del = _signed('t:moderate f:X1BOBB d:X3STAT ts:${ts(1)} r:${id(carolMsg)} remove:message', _bob);
    expect((await post(a, del)).status, 200);
    expect(received, contains(del), reason: 'the act goes on like any wire');
    expect(await shown(a), isNot(contains(id(carolMsg))));
    final h = (await a.handle('GET', '/api/xprs/history', {}, '', peer: lan)).json;
    expect((h['moderation'] as Map)['removed'], contains(id(carolMsg)));
  });

  test('a moderator sends somebody away: hidden, refused, safety still shown', () async {
    final a = make();
    final s = await staff(a);
    final kick = _signed('t:moderate f:X1BOBB d:X3STAT ts:${ts(1)} revoke:X1CARO until:${ts(60)}', _bob);
    expect((await post(a, kick)).status, 200);
    final ids = await shown(a);
    expect(ids, isNot(contains(id(carolMsg))));
    expect(ids, contains(id(carolSos)), reason: 'XPRS.md 10.7: a call for help is never hidden');
    expect(ids, contains(id(bobMsg)));
    final again = _signed('t:message f:X1CARO ts:${ts(2)} m:let me back', _carol);
    expect((await post(a, again)).status, 403);
    expect((await state(a, s.alice))['away'], [
      {'call': 'X1CARO', 'until': isA<String>()}
    ]);
    // The suspension lapses on its own.
    clock = clock.add(const Duration(minutes: 61));
    expect((await post(a, _signed('t:message f:X1CARO ts:${ts()} m:back', _carol))).status, 200);
  });

  test('the admin lifts a removal and dismisses a moderator', () async {
    final a = make();
    final s = await staff(a);
    await post(a, _signed('t:moderate f:X1BOBB d:X3STAT ts:${ts(1)} revoke:X1CARO', _bob));
    expect((await state(a, s.alice))['away'], [{'call': 'X1CARO'}]);
    clock = clock.add(const Duration(minutes: 2));
    expect((await admin(a, {'action': 'lift', 'session': s.alice, 'call': 'X1CARO'})).status, 200);
    expect((await state(a, s.alice))['away'], isEmpty);
    expect(await shown(a), contains(id(carolMsg)));
    expect((await admin(a, {'action': 'dismiss', 'session': s.alice, 'call': 'X1BOBB'})).status, 200);
    expect((await state(a, s.bob))['role'], isNot('mod'));
    expect((await post(a, _signed('t:moderate f:X1BOBB d:X3STAT ts:${ts(3)} r:${id(bobMsg)} remove:message', _bob))).status, 403);
  });

  test('refused: a visitor who is not a moderator, an unknown key, a moderator appointing', () async {
    final a = make();
    final s = await staff(a);
    expect((await post(a, _signed('t:moderate f:X1CARO d:X3STAT ts:${ts(1)} r:${id(bobMsg)} remove:message', _carol))).status, 403);
    keys.remove('X1CARO');
    expect((await post(a, _signed('t:moderate f:X1CARO d:X3STAT ts:${ts(1)} revoke:X1BOBB', _carol))).status, 403);
    expect((await post(a, _signed('t:moderate f:X1BOBB d:X3STAT ts:${ts(1)} grant:X1CARO role:mod', _bob))).status, 403);
    expect((await post(a, _signed('t:moderate f:X1BOBB d:X5OTHR ts:${ts(1)} revoke:X1CARO', _bob))).status, 403,
        reason: "only this station's rooms");
    expect((await admin(a, {'action': 'appoint', 'session': s.bob, 'call': 'X1CARO'})).status, 403,
        reason: "appointing is the administrator's");
    expect(await shown(a), hasLength(3));
  });
}
