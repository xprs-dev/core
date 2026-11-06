// Rooms a station hosts (XPRS.md 10.10.1) and the alerts it shows (10.10.2).
import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_groups.dart';
import 'package:xprs_core/src/services/xprs/xprs_id.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart' show xprsParseTs;

final _station = BigInt.parse('5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a', radix: 16);
final _alice = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
final _bob = BigInt.parse('fedcba0987654321fedcba0987654321', radix: 16);
final _carol = BigInt.parse('0badc0de0badc0de0badc0de0badc0de', radix: 16);

String _signed(String wire, BigInt key) =>
    xprsSign(XprsPacket.parse(wire)!, key).encode();

void main() {
  late Map<String, Uint8List> keys;
  late Map<String, BigInt> roomKeys;
  late List<String> received, kept;
  late DateTime clock;
  const lan = '192.168.1.20';
  final groups = XprsGroups.instance;
  var seed = 1000;

  String ts([int plusMin = 0]) {
    final t = clock.add(Duration(minutes: plusMin));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  WebChatApi make() => WebChatApi(
        publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) => [],
        held: (t) => 0,
        receive: received.add,
        mayAir: (_) => true,
        selfCallsign: () => 'X3STAT',
        keyOf: (c) => keys[c],
        appPath: () => null,
        now: () => clock,
        groups: groups,
        signAsStation: (c) => xprsSign(XprsPacket.parse(c)!, _station),
        publish: received.add,
        roomKeys: WebChatRoomKeys(
          create: (nick) {
            final d = BigInt.from(seed++) * BigInt.parse('1000003');
            final pub = XprsCrypto.publicKeyXOnly(d);
            final call = 'X5${NostrCrypto.deriveCallsign(HEX.encode(pub))}';
            keys[call] = pub;
            roomKeys[call] = d;
            return call;
          },
          scalar: (c) => roomKeys[c],
        ),
        keep: kept.add,
        roomRows: ({required room, sinceMs, untilMs, required types, required limit}) => [
          for (final w in kept.reversed)
            if (XprsPacket.parse(w)!['d'] == room && types.contains(XprsPacket.parse(w)!.type))
              {
                'id': xprsIdentifier(XprsPacket.parse(w)!),
                'type': XprsPacket.parse(w)!.type,
                'from': XprsPacket.parse(w)!['f'],
                'to': room,
                'ts': xprsParseTs(XprsPacket.parse(w)!['ts'])! ~/ 1000,
                'wire': w,
              },
        ],
      );

  setUp(() {
    groups.clear();
    keys = {
      'X3STAT': XprsCrypto.publicKeyXOnly(_station),
      'X1ALIC': XprsCrypto.publicKeyXOnly(_alice),
      'X1BOBB': XprsCrypto.publicKeyXOnly(_bob),
      'X1CARO': XprsCrypto.publicKeyXOnly(_carol),
    };
    roomKeys = {};
    groups.keyResolver = (c) => keys[c];
    received = [];
    kept = [];
    clock = DateTime.now().toUtc();
  });

  Future<String> session(WebChatApi a, String call, BigInt key) async {
    final n = (await a.handle('GET', '/api/session', {}, '', peer: lan)).json['nonce'];
    final r = await a.handle('POST', '/api/session', {},
        _signed('t:session f:$call ts:${ts()} m:$n', key), peer: lan);
    return r.json['session'] as String;
  }

  Future<WebChatReply> post(WebChatApi a, String path, Map<String, Object?> b) =>
      a.handle('POST', path, {}, jsonEncode(b), peer: lan);
  Future<WebChatReply> send(WebChatApi a, String w) =>
      a.handle('POST', '/api/xprs/send', {}, w, peer: lan);
  Future<List> rooms(WebChatApi a, String s) async =>
      (await a.handle('GET', '/api/rooms', {'session': s}, '', peer: lan)).json['rooms'] as List;
  Future<WebChatReply> history(WebChatApi a, String room, String s) =>
      a.handle('GET', '/api/xprs/history', {'room': room, 'session': s}, '', peer: lan);

  /// Alice claims the station.
  Future<String> claim(WebChatApi a) async {
    final s = await session(a, 'X1ALIC', _alice);
    await post(a, '/api/admin', {'action': 'claim', 'session': s});
    return s;
  }

  test('services offers rooms and the alerts tab', () async {
    final r = await make().handle('GET', '/api/services', {}, '');
    final page = r.json['page'] as Map;
    expect(page['rooms'], true);
    expect(page['tabs'], contains('alerts'));
    expect(page['alerts'], 'moderators');
  });

  test('only the administrator creates; the room is a group the station holds', () async {
    final a = make();
    final s = await claim(a);
    final b = await session(a, 'X1BOBB', _bob);
    expect((await post(a, '/api/rooms', {'action': 'create', 'session': b, 'name': 'x'})).status, 403);
    final r = await post(a, '/api/rooms', {'action': 'create', 'session': s, 'name': 'Block C',
        'about': 'residents', 'visibility': 'public', 'posting': 'members'});
    expect(r.status, 200);
    final call = r.json['room'] as String;
    expect(call, startsWith('X5'));
    expect(groups.rosterOf(call).roles[call], XprsRole.admin);
    // The administrator is offered the room's moderator role, signed by the room.
    expect(kept.single, contains('f:$call d:$call'));
    expect(kept.single, contains('grant:X1ALIC role:mod'));
    expect(received.where((w) => w.contains(call)), isEmpty,
        reason: 'a hosted room is never aired (10.10.1)');
  });

  test('a public members-only room: everybody reads, members post', () async {
    final a = make();
    final s = await claim(a);
    final call = (await post(a, '/api/rooms', {'action': 'create', 'session': s, 'name': 'Block C',
        'visibility': 'public', 'posting': 'members'})).json['room'] as String;
    final b = await session(a, 'X1BOBB', _bob);
    expect((await rooms(a, b)).single['can_post'], false);
    final msg = _signed('t:message f:X1BOBB d:$call ts:${ts()} m:hi', _bob);
    expect((await send(a, msg)).status, 403);
    // The administrator adds Bob; Bob accepts with his own signature.
    await post(a, '/api/rooms', {'action': 'add', 'session': s, 'call': call, 'member': 'X1BOBB'});
    final mine = (await rooms(a, b)).single;
    expect(mine['role'], 'invited');
    expect((await send(a, _signed('t:moderate f:X1BOBB d:$call ts:${ts()} r:${mine['offer']} accept:member', _bob))).status, 200);
    expect((await rooms(a, b)).single['role'], 'member');
    expect((await send(a, msg)).status, 200);
    expect(kept, contains(msg), reason: 'filed by the station');
    expect(received, isNot(contains(msg)), reason: 'and not aired');
    final c = await session(a, 'X1CARO', _carol);
    final h = await history(a, call, c);
    expect((h.json['rows'] as List).map((r) => r['wire']), [msg],
        reason: 'a public room is read by anybody');
  });

  test('a private room is listed and served only to its members', () async {
    final a = make();
    final s = await claim(a);
    final call = (await post(a, '/api/rooms', {'action': 'create', 'session': s, 'name': 'Board',
        'visibility': 'private', 'posting': 'anyone'})).json['room'] as String;
    final c = await session(a, 'X1CARO', _carol);
    expect(await rooms(a, c), isEmpty, reason: 'not even listed');
    expect((await history(a, call, c)).status, 404);
    expect((await rooms(a, s)).single['posting'], 'members',
        reason: 'a private room is always members-only');
    await post(a, '/api/rooms', {'action': 'add', 'session': s, 'call': call, 'member': 'X1CARO'});
    final offer = (await rooms(a, c)).single['offer'];
    await send(a, _signed('t:moderate f:X1CARO d:$call ts:${ts()} r:$offer accept:member', _carol));
    expect((await history(a, call, c)).status, 200);
  });

  test('a room moderator removes a message and sends somebody away', () async {
    final a = make();
    final s = await claim(a);
    final call = (await post(a, '/api/rooms', {'action': 'create', 'session': s, 'name': 'Open',
        'visibility': 'public', 'posting': 'anyone'})).json['room'] as String;
    final aliceOffer = (await rooms(a, s)).single['offer'];
    await send(a, _signed('t:moderate f:X1ALIC d:$call ts:${ts()} r:$aliceOffer accept:mod', _alice));
    expect((await rooms(a, s)).single['role'], 'mod');
    final spam = _signed('t:message f:X1CARO d:$call ts:${ts()} m:spam', _carol);
    expect((await send(a, spam)).status, 200, reason: 'anyone may post in this room');
    final id = xprsIdentifier(XprsPacket.parse(spam)!);
    expect((await send(a, _signed('t:moderate f:X1ALIC d:$call ts:${ts(1)} r:$id remove:message', _alice))).status, 200);
    final c = await session(a, 'X1CARO', _carol);
    expect((await history(a, call, c)).json['rows'], isEmpty);
    await send(a, _signed('t:moderate f:X1ALIC d:$call ts:${ts(1)} revoke:X1CARO', _alice));
    expect((await send(a, _signed('t:message f:X1CARO d:$call ts:${ts(2)} m:again', _carol))).status, 403);
    expect((await send(a, _signed('t:moderate f:X1BOBB d:$call ts:${ts(1)} revoke:X1ALIC', _bob))).status, 403,
        reason: 'not a moderator of the room');
  });

  test('update and close', () async {
    final a = make();
    final s = await claim(a);
    final call = (await post(a, '/api/rooms', {'action': 'create', 'session': s, 'name': 'Old'}))
        .json['room'] as String;
    await post(a, '/api/rooms', {'action': 'update', 'session': s, 'call': call, 'name': 'New',
        'visibility': 'private'});
    final r = (await rooms(a, s)).single;
    expect([r['name'], r['visibility'], r['posting']], ['New', 'private', 'members']);
    expect((await post(a, '/api/rooms', {'action': 'update', 'session': s, 'call': call,
        'visibility': 'secret'})).status, 400);
    await post(a, '/api/rooms', {'action': 'close', 'session': s, 'call': call});
    expect(await rooms(a, s), isEmpty);
  });

  group('forum rooms (XPRS.md 18.5)', () {
    Future<String> forum(WebChatApi a, String s) async =>
        (await post(a, '/api/rooms', {'action': 'create', 'session': s, 'name': 'Radio',
            'kind': 'forum', 'visibility': 'public', 'posting': 'anyone'})).json['room'] as String;
    Future<WebChatReply> topics(WebChatApi a, String call, String s) =>
        a.handle('GET', '/api/rooms', {'topics': call, 'session': s}, '', peer: lan);
    Future<List> thread(WebChatApi a, String call, String root, String s) async =>
        (await a.handle('GET', '/api/xprs/history',
                {'room': call, 'kind': 'blog', 'root': root, 'session': s}, '', peer: lan))
            .json['rows'] as List;

    test('a topic, a comment, the index that counts them, the thread in order', () async {
      final a = make();
      final s = await claim(a);
      final call = await forum(a, s);
      expect((await rooms(a, s)).single['kind'], 'forum');
      final b = await session(a, 'X1BOBB', _bob);
      final topic = _signed('t:blog f:X1BOBB d:$call ts:${ts()} title:balun-question tag:radio m:Which balun?', _bob);
      expect((await send(a, topic)).status, 200);
      final id = xprsIdentifier(XprsPacket.parse(topic)!);
      expect((await send(a, _signed('t:blog f:X1CARO d:$call ts:${ts(1)} m:no title and no r:', _carol))).status, 400);
      expect((await send(a, _signed('t:blog f:X1CARO d:$call ts:${ts(1)} title:Not-A-Label m:x', _carol))).status, 400);
      final comment = _signed('t:blog f:X1CARO d:$call ts:${ts(2)} r:$id m:A 1:1 current balun.', _carol);
      expect((await send(a, comment)).status, 200);
      expect(received.where((w) => w.contains(call)), isEmpty, reason: 'filed, never aired');
      final t = (await topics(a, call, b)).json['topics'] as List;
      expect(t, hasLength(1));
      expect(t[0]['title'], 'balun-question');
      expect(t[0]['id'], id);
      expect(t[0]['replies'], 1);
      expect(t[0]['tags'], 'radio');
      expect((await thread(a, call, id, b)).map((r) => r['wire']), [topic, comment],
          reason: 'the thread, oldest first');
      // A chat room takes no post, and only a forum room has an index.
      final chat = (await post(a, '/api/rooms', {'action': 'create', 'session': s, 'name': 'Chat'})).json['room'] as String;
      expect((await send(a, _signed('t:blog f:X1BOBB d:$chat ts:${ts()} title:x m:y', _bob))).status, 403);
      expect((await topics(a, chat, b)).status, 400);
      expect((await topics(a, 'X5NONE', b)).status, 404);
    });

    test('a replaced topic is one topic, edited; a moderator takes an edition down', () async {
      final a = make();
      final s = await claim(a);
      final call = await forum(a, s);
      final offer = (await rooms(a, s)).single['offer'];
      await send(a, _signed('t:moderate f:X1ALIC d:$call ts:${ts()} r:$offer accept:mod', _alice));
      final v1 = _signed('t:blog f:X1BOBB d:$call ts:${ts()} title:log m:first', _bob);
      final v2 = _signed('t:blog f:X1BOBB d:$call ts:${ts(5)} title:log m:corrected', _bob);
      await send(a, v1);
      await send(a, v2);
      final id1 = xprsIdentifier(XprsPacket.parse(v1)!), id2 = xprsIdentifier(XprsPacket.parse(v2)!);
      await send(a, _signed('t:blog f:X1CARO d:$call ts:${ts(1)} r:$id1 m:on the first', _carol));
      var t = (await topics(a, call, s)).json['topics'] as List;
      expect(t, hasLength(1));
      expect(t[0]['id'], id2);
      expect(t[0]['edited'], true);
      expect(t[0]['replies'], 1, reason: 'a comment on an earlier edition is the topic\'s');
      // An act is judged at its moment: after the acceptance that made Alice
      // a moderator and not from the future (five minutes of slack); a post's
      // ts: is the author's claim and may be later than that.
      expect((await send(a, _signed('t:moderate f:X1ALIC d:$call ts:${ts(1)} r:$id2 remove:message', _alice))).status, 200);
      t = (await topics(a, call, s)).json['topics'] as List;
      expect(t[0]['id'], id1, reason: 'the edition that is left');
      expect(t[0]['edited'], false);
    });

    test('a split topic is held and verified on its last part (9.1.1)', () async {
      final a = make();
      final s = await claim(a);
      final call = await forum(a, s);
      final head = 't:blog f:X1BOBB d:$call ts:${ts()} title:antenna-notes';
      final whole = XprsPacket.parse('$head m:I rebuilt the dipole. The feed point was off.')!;
      final sig = xprsSign(whole, _bob)['sig']!;
      final r1 = await send(a, '$head n:1/2 m:I rebuilt the dipole.');
      expect(r1.status, 202);
      expect(kept.where((w) => w.contains('antenna-notes')), isEmpty, reason: 'held, not filed');
      final r2 = await send(a, '$head n:2/2 sig:$sig m:The feed point was off.');
      expect(r2.status, 200);
      expect(r2.json['id'], xprsIdentifier(whole));
      expect(kept.where((w) => w.contains('antenna-notes')).single, whole.with_('sig', sig).encode(),
          reason: 'the whole is filed, signed, not the parts');
      final t = (await topics(a, call, s)).json['topics'] as List;
      expect(t.single['id'], xprsIdentifier(whole));
      expect((await thread(a, call, xprsIdentifier(whole), s)).single['wire'], whole.with_('sig', sig).encode(),
          reason: 'the thread opens with the whole post');
      // A set whose signature covers something else is refused and nothing of it is filed.
      final head2 = 't:blog f:X1BOBB d:$call ts:${ts(1)} title:other';
      expect((await send(a, '$head2 n:1/2 m:some')).status, 202);
      expect((await send(a, '$head2 n:2/2 sig:$sig m:words')).status, 409);
      expect(kept.where((w) => w.contains('title:other')), isEmpty);
      // Who may post is decided before a part is held.
      await send(a, _signed('t:moderate f:X1ALIC d:$call ts:${ts()} r:${(await rooms(a, s)).single['offer']} accept:mod', _alice));
      await send(a, _signed('t:moderate f:X1ALIC d:$call ts:${ts(1)} revoke:X1CARO', _alice));
      expect((await send(a, 't:blog f:X1CARO d:$call ts:${ts(2)} title:t n:1/2 m:a')).status, 403);
    });
  });

  group('alerts (10.10.2)', () {
    String alert(String call, BigInt key) =>
        _signed('t:warning f:$call kind:outage sev:watch ts:${ts()} m:power cut', key);

    test('by default only moderators and the administrator post one', () async {
      final a = make();
      await claim(a);
      expect((await send(a, alert('X1BOBB', _bob))).status, 403);
      expect((await send(a, alert('X1ALIC', _alice))).status, 200, reason: 'the administrator');
      expect((await send(a, _signed('t:sos f:X1BOBB ts:${ts()} m:help', _bob))).status, 200,
          reason: 'a call for help is never refused (10.7), and is no alert setting');
    });

    test('the administrator may open it to everyone', () async {
      final a = make();
      final s = await claim(a);
      await post(a, '/api/admin', {'action': 'set', 'session': s,
          'settings': {'who_may_alert': 'everyone'}});
      expect((await send(a, alert('X1BOBB', _bob))).status, 200);
      expect((await post(a, '/api/admin', {'action': 'set', 'session': s,
          'settings': {'who_may_alert': 'nobody'}})).status, 400);
    });

    test('an author withdraws their own alert whatever the setting', () async {
      final a = make();
      await claim(a);
      expect((await send(a, _signed('t:warning f:X1BOBB ts:${ts()} r:3c7e21 remove:warning', _bob))).status, 200);
    });
  });
}
