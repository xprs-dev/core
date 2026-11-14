// Rooms a station hosts (XPRS.md 10.10.1) and the alerts it shows (10.10.2).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_file_acl.dart';
import 'package:xprs_core/src/services/xprs/xprs_files.dart';
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

  WebChatApi make({MediaArchive? files}) => WebChatApi(
        publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) => [],
        held: (t) => 0,
        receive: received.add,
        mayAir: (_) => true,
        selfCallsign: () => 'X3STAT',
        keyOf: (c) => keys[c],
        appPath: () => null,
        now: () => clock,
        fileStore: files == null ? null : () => files,
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
    // The room announces itself (10.1), signed by its own key, so a mirror
    // learns the key from the record; then the administrator is offered the
    // room's moderator role, signed by the room.
    expect(kept, hasLength(2));
    final ident = XprsPacket.parse(kept.first)!;
    expect(ident.type, 'identity');
    expect(ident['f'], call);
    expect(ident['nick'], 'block-c');
    expect(xprsVerify(ident, keys[call]), XprsSigState.verified);
    expect(kept.last, contains('f:$call d:$call'));
    expect(kept.last, contains('grant:X1ALIC role:mod'));
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

  group('gallery rooms (API-HTTP.md): events, pictures, likes', () {
    test('the staff adds events and pictures; a visitor likes and adds nothing', () async {
      final a = make();
      final s = await claim(a);
      final call = (await post(a, '/api/rooms', {'action': 'create', 'session': s,
          'name': 'Photos', 'kind': 'gallery'})).json['room'] as String;
      expect((await rooms(a, s)).single['kind'], 'gallery');
      final b = await session(a, 'X1BOBB', _bob);
      // The administrator (X1ALIC claimed it) opens an event.
      final event = _signed('t:blog f:X1ALIC d:$call ts:${ts()} title:field-day-2026 m:On the hill', _alice);
      expect((await send(a, event)).status, 200);
      final eid = xprsIdentifier(XprsPacket.parse(event)!);
      expect((await send(a, _signed('t:blog f:X1ALIC d:$call ts:${ts(1)} r:$eid m:no title', _alice))).status, 400,
          reason: 'an event has a title; a gallery takes no comment');
      // A picture: the preview on a message, the original on its companion.
      const prev = 'nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg';
      const orig = 'Uc3nRw8kFa5xPd1qGz7mYb0tJe6vHs2iLoA9XfCqK4E.jpg';
      final pic = _signed('t:message f:X1ALIC d:$call ts:${ts(2)} r:$eid file:$prev m:the mast', _alice);
      expect((await send(a, pic)).status, 200);
      final pid = xprsIdentifier(XprsPacket.parse(pic)!);
      expect((await send(a, _signed('t:file f:X1ALIC d:$call ts:${ts(2)} r:$pid file:$orig size:2.1MB name:mast.jpg', _alice))).status, 200);
      // A visitor adds nothing, and likes.
      expect((await send(a, _signed('t:message f:X1BOBB d:$call ts:${ts(3)} r:$eid file:$prev', _bob))).status, 403);
      expect((await send(a, _signed('t:blog f:X1BOBB d:$call ts:${ts(3)} title:mine m:x', _bob))).status, 403);
      expect((await send(a, _signed('t:reaction f:X1BOBB d:$call ts:${ts(3)} r:$pid add:like', _bob))).status, 200);
      expect((await send(a, _signed('t:reaction f:X1BOBB d:$call ts:${ts(3)} r:$eid add:like', _bob))).status, 200);
      expect((await send(a, _signed('t:status f:X1ALIC d:$call ts:${ts(4)} m:x', _alice))).status, 403);
      // The events are the room's index.
      final t = (await a.handle('GET', '/api/rooms', {'topics': call, 'session': b}, '', peer: lan))
          .json['topics'] as List;
      expect(t.single['title'], 'field-day-2026');
      // The event's pictures, their originals and the likes, for the page.
      final rows = (await a.handle('GET', '/api/xprs/history',
              {'room': call, 'kind': 'message,file,reaction', 'session': b}, '', peer: lan))
          .json['rows'] as List;
      expect(rows.map((r) => r['type']).toSet(), {'message', 'file', 'reaction'});
      expect(received.where((w) => w.contains(call)), isEmpty, reason: 'filed, never aired');
    });
  });

  group('music and library rooms: collections like the gallery', () {
    test('the station\'s own key is its operator: it makes a music room and adds a track', () async {
      final a = make();
      await claim(a);
      final st = await session(a, 'X3STAT', _station);
      for (final kind in ['music', 'library']) {
        final r = await post(a, '/api/rooms', {'action': 'create', 'session': st, 'name': kind, 'kind': kind});
        expect(r.status, 200, reason: '${r.json}');
        final call = r.json['room'] as String;
        final album = _signed('t:blog f:X3STAT d:$call ts:${ts()} title:first-album m:demo', _station);
        expect((await send(a, album)).status, 200);
        final aid = xprsIdentifier(XprsPacket.parse(album)!);
        // An item with no preview: the message names it, the t:file is the file.
        final track = _signed('t:message f:X3STAT d:$call ts:${ts(1)} r:$aid m:opening-song', _station);
        expect((await send(a, track)).status, 200);
        final tid = xprsIdentifier(XprsPacket.parse(track)!);
        expect((await send(a, _signed('t:file f:X3STAT d:$call ts:${ts(1)} r:$tid file:Uc3nRw8kFa5xPd1qGz7mYb0tJe6vHs2iLoA9XfCqK4E.mp3 size:4.2MB name:opening-song.mp3', _station))).status, 200);
        expect((await send(a, _signed('t:message f:X1BOBB d:$call ts:${ts(2)} r:$aid m:mine', _bob))).status, 403);
        expect((await send(a, _signed('t:reaction f:X1BOBB d:$call ts:${ts(2)} r:$tid add:like', _bob))).status, 200);
      }
    });
  });

  group('a post to everybody (XPRS.md 18), from the page', () {
    test('a post is the visitor\'s to send; its parts go out as given (7.6)', () async {
      final a = make();
      final one = _signed('t:blog f:X1BOBB ts:${ts()} title:short m:Fits one packet.', _bob);
      expect((await send(a, one)).status, 200);
      expect(received.last, one);
      // The whole post never leaves the page: the station sees parts, the
      // first unsigned and the last signed over a whole it cannot see, and
      // airs each as it would any heard part (API-HTTP.md, /api/xprs/send).
      final head = 't:blog f:X1BOBB ts:${ts(1)} title:field-day';
      final whole = XprsPacket.parse('$head m:We set up on the hill. The wind took the mast twice.')!;
      final sig = xprsSign(whole, _bob)['sig']!;
      expect((await send(a, '$head n:1/2 m:We set up on the hill.')).status, 200);
      expect((await send(a, '$head n:2/2 sig:$sig m:The wind took the mast twice.')).status, 200);
      expect(received.where((w) => w.contains('field-day')).toList(), [
        '$head n:1/2 m:We set up on the hill.',
        '$head n:2/2 sig:$sig m:The wind took the mast twice.',
      ]);
      expect(kept.where((w) => w.contains('field-day')), isEmpty, reason: 'not a room: nothing filed here');
      // An unsigned post that is not a part is still refused, as every wire is.
      expect((await send(a, 't:blog f:X1BOBB ts:${ts(2)} title:bare m:no signature')).status, 400);
      // And never as this station, nor a part to somebody else's group.
      expect((await send(a, 't:blog f:X3STAT ts:${ts(2)} title:t n:1/2 m:a')).status, 403);
      expect((await send(a, 't:blog f:X1BOBB d:X5ELSE ts:${ts(2)} title:t n:1/2 m:a')).status, 400);
    });
  });

  group('sharing a room between stations (XPRS.md 10.10.1)', () {
    test('the owner shares with named peers; they are served and asked back', () async {
      final a = make();
      final s = await claim(a);
      final call = (await post(a, '/api/rooms', {'action': 'create', 'session': s, 'name': 'Radio',
          'kind': 'forum', 'visibility': 'public', 'posting': 'anyone'})).json['room'] as String;
      expect(a.roomServable(call, 'X3MIRR'), false, reason: 'not shared: never served');
      expect(a.roomServable('X5NONE', 'X3MIRR'), isNull, reason: 'not a room here');
      expect(a.mirrorPairs(), isEmpty);
      final r = await post(a, '/api/rooms', {'action': 'share', 'session': s, 'call': call,
          'shared': true, 'peers': ['x3mirr', 'X3STAT', 'bad!']});
      expect(r.status, 200);
      final j = (r.json['rooms'] as List).single;
      expect(j['shared'], true);
      expect(j['peers'], ['X3MIRR'], reason: 'a callsign each, never this station');
      expect(a.roomServable(call, 'X3MIRR'), true);
      expect(a.roomServable(call, 'X3OTHR'), false, reason: 'listed peers only');
      expect(a.roomPeers(call), ['X3MIRR']);
      expect(a.roomPeers('X5NONE'), isEmpty);
      expect(a.mirrorPairs().map((p) => '${p.group}|${p.peer}'), ['$call|X3MIRR']);
      // Shared with no list: any station, and one that asked is remembered.
      await post(a, '/api/rooms', {'action': 'share', 'session': s, 'call': call, 'shared': true, 'peers': []});
      expect(a.roomServable(call, 'X3ANYY'), true);
      expect(a.mirrorPairs().map((p) => p.peer), ['X3ANYY']);
      expect(((await rooms(a, s)).single)['seen'], ['X3ANYY']);
      await post(a, '/api/rooms', {'action': 'share', 'session': s, 'call': call, 'shared': false});
      expect(a.roomServable(call, 'X3ANYY'), false);
      expect(a.mirrorPairs(), isEmpty);
      // A private room is shared with named stations only.
      await post(a, '/api/rooms', {'action': 'update', 'session': s, 'call': call, 'visibility': 'private'});
      expect((await post(a, '/api/rooms', {'action': 'share', 'session': s, 'call': call, 'shared': true, 'peers': []})).status, 400);
    });

    test('a mirror keeps another station\'s room: filed, never signed as the room', () async {
      final a = make();
      final s = await claim(a);
      final synced = <String>[];
      a.onSync = synced.add;
      expect((await post(a, '/api/rooms', {'action': 'mirror', 'session': s, 'call': 'X1NOTG', 'owner': 'X3OWNR'})).status, 400);
      expect((await post(a, '/api/rooms', {'action': 'mirror', 'session': s, 'call': 'X5F0RM', 'owner': 'X3STAT'})).status, 400,
          reason: 'not from ourselves');
      final r = await post(a, '/api/rooms', {'action': 'mirror', 'session': s, 'call': 'X5F0RM', 'owner': 'X3OWNR', 'name': 'Radio'});
      expect(r.status, 200);
      expect(r.json['room'], 'X5F0RM');
      final j = (r.json['rooms'] as List).single;
      expect(j['mirrored'], true);
      expect(j['owner'], 'X3OWNR');
      expect(j['kind'], 'forum');
      expect(synced, ['X5F0RM'], reason: 'asked for at once');
      expect(a.roomServable('X5F0RM', 'X3OWNR'), true, reason: 'the copy is served back to its owner');
      expect(a.roomServable('X5F0RM', 'X3OTHR'), false);
      expect(a.roomPeers('X5F0RM'), ['X3OWNR']);
      expect(a.mirrorPairs().map((p) => '${p.group}|${p.peer}'), ['X5F0RM|X3OWNR']);
      expect((await post(a, '/api/rooms', {'action': 'share', 'session': s, 'call': 'X5F0RM', 'shared': true})).status, 400);
      expect((await post(a, '/api/rooms', {'action': 'add', 'session': s, 'call': 'X5F0RM', 'member': 'X1BOBB'})).status, 409,
          reason: 'no key: the mirror never grants');
      // A visitor posts in the copy; the owner's next ask pulls it.
      keys['X5F0RM'] = keys['X1CARO']!; // any key: the roster is empty, the room open
      final b = await session(a, 'X1BOBB', _bob);
      final comment = _signed('t:blog f:X1BOBB d:X5F0RM ts:${ts()} r:5f2c1a m:from the mirror', _bob);
      expect((await send(a, comment)).status, 200);
      expect(kept, contains(comment));
      expect((await rooms(a, b)).single['call'], 'X5F0RM');
      expect((await post(a, '/api/rooms', {'action': 'sync', 'session': s, 'call': 'X5F0RM'})).status, 200);
      expect(synced, hasLength(2));
      expect((await post(a, '/api/rooms', {'action': 'unmirror', 'session': s, 'call': 'X5F0RM'})).status, 200);
      expect(await rooms(a, s), isEmpty);
    });
  });

  group('the mesh (docs/plan-mesh-trust.md): a room shared with it, and the neighbours', () {
    test('a mesh room is served to trusted peers, who mirror it on their own', () async {
      final a = make();
      final s = await claim(a);
      final call = (await a.handle('POST', '/api/rooms', {}, jsonEncode({'action': 'create', 'name': 'Radio',
          'kind': 'forum', 'visibility': 'public', 'posting': 'anyone', 'session': s}), peer: lan)).json['room'] as String;
      // Nobody trusted yet (open mode): shared with the mesh means with no one.
      expect((await a.handle('POST', '/api/rooms', {}, jsonEncode({'action': 'share', 'call': call, 'mesh': true, 'session': s}), peer: lan)).status, 200);
      final r = (await rooms(a, s)).single;
      expect(r['mesh'], true);
      expect(r['shared'], true);
      expect(a.roomServable(call, 'X3TOWN'), false);
      expect(a.mirrorPairs(), isEmpty);
      // Named: the trusted peers are the room's peers and the neighbours.
      await a.handle('POST', '/api/admin', {}, jsonEncode({'action': 'set', 'session': s,
          'settings': {'peers_mode': 'named', 'peers': 'X3TOWN X3HUB'}}), peer: lan);
      expect(a.roomServable(call, 'X3TOWN'), true);
      expect(a.roomServable(call, 'X3ROGU'), false);
      expect(a.roomPeers(call), ['X3TOWN', 'X3HUB']);
      final pairs = a.mirrorPairs();
      expect(pairs.where((p) => p.group == call).map((p) => p.peer), ['X3TOWN', 'X3HUB']);
      expect(pairs.where((p) => p.neighbour).map((p) => p.peer), ['X3TOWN', 'X3HUB']);
      expect(pairs.where((p) => p.neighbour).first.kinds, 'info,warning,blog,identity');
      // A peer's mesh room met in its answer is mirrored here, once, and
      // named by its identity when that comes; a stranger's is not.
      a.autoMirror('X5MESH', 'X3TOWN', '');
      a.autoMirror('X5MESH', 'X3TOWN', 'antennas');
      a.autoMirror('X5MESH', 'X3TOWN', 'Other');
      a.autoMirror('X5ROGU', 'X3ROGU', 'Junk');
      final list = await rooms(a, s);
      final m = list.firstWhere((r) => r['call'] == 'X5MESH');
      expect(m['mirrored'], true);
      expect(m['owner'], 'X3TOWN');
      expect(m['name'], 'Antennas');
      expect(m['kind'], 'forum');
      expect(list.where((r) => r['call'] == 'X5ROGU'), isEmpty);
      expect(a.mirrorPairs().where((p) => p.group == 'X5MESH').single.peer, 'X3TOWN');
    });
  });

  group('a mesh group: the trusted stations are its roster (docs/plan-mesh-trust.md)', () {
    Future<WebChatReply> roomsDo(WebChatApi a, String s, Map<String, Object?> b) =>
        a.handle('POST', '/api/rooms', {}, jsonEncode({...b, 'session': s}), peer: lan);
    test('the owner creates it and invites; the roster is the trusted set; a few are asked', () async {
      final a = make();
      final s = await claim(a);
      await a.handle('POST', '/api/admin', {}, jsonEncode({'action': 'set', 'session': s,
          'settings': {'peers_mode': 'mesh'}}), peer: lan);
      final r = await roomsDo(a, s, {'action': 'create', 'name': 'Valley', 'kind': 'mesh', 'visibility': 'private'});
      expect(r.status, 200);
      final mesh = r.json['room'] as String;
      final card = (r.json['rooms'] as List).firstWhere((x) => x['call'] == mesh);
      expect(card['kind'], 'mesh');
      expect(card['station_role'], 'owner');
      expect((await roomsDo(a, s, {'action': 'create', 'name': 'Two', 'kind': 'mesh'})).status, 409, reason: 'one mesh');
      expect(a.trustedSet(), isEmpty);
      for (final c in ['X3AAAA', 'X3BBBB', 'X3CCCC', 'X3DDDD', 'X3EEEE', 'X3FFFF']) {
        expect((await roomsDo(a, s, {'action': 'add', 'call': mesh, 'member': c})).status, 200);
      }
      expect(a.trustedSet(), isEmpty, reason: 'invited is not trusted');
      expect(a.roomServable(mesh, 'X3AAAA'), true, reason: 'an invitee reads its offer');
      expect(a.roomServable(mesh, 'X3ROGU'), false);
      final pairs = a.mirrorPairs().where((p) => p.group == mesh).map((p) => p.peer).toSet();
      expect(pairs, {'X3AAAA', 'X3BBBB', 'X3CCCC', 'X3DDDD', 'X3EEEE', 'X3FFFF'}, reason: 'asked for their acceptance');
      // Each accepts, signed by its own key; the acts arrive in the record.
      final keysOf = <String, BigInt>{};
      var seed2 = 7000;
      final roster = groups.rosterOf(mesh);
      for (final c in ['X3AAAA', 'X3BBBB', 'X3CCCC', 'X3DDDD', 'X3EEEE', 'X3FFFF']) {
        final d = BigInt.from(seed2++) * BigInt.parse('1000003');
        keysOf[c] = d;
        keys[c] = XprsCrypto.publicKeyXOnly(d);
        final offer = roster.offers[c]!;
        expect(groups.offer(XprsPacket.parse(_signed('t:moderate f:$c d:$mesh ts:${ts()} r:$offer accept:member', d))!,
            nowMs: clock.millisecondsSinceEpoch), true);
      }
      clock = clock.add(const Duration(minutes: 1));
      expect(a.trustedSet(), {'X3AAAA', 'X3BBBB', 'X3CCCC', 'X3DDDD', 'X3EEEE', 'X3FFFF'});
      final nb = a.mirrorPairs().where((p) => p.neighbour).map((p) => p.peer).toList();
      expect(nb, hasLength(WebChatApi.syncFanout), reason: 'a few are asked, not all');
      expect(a.trustedSet().containsAll(nb), true);
      // Removed: out of the trusted set at once.
      expect((await roomsDo(a, s, {'action': 'remove', 'call': mesh, 'member': 'X3AAAA'})).status, 200);
      expect(a.trustedSet().contains('X3AAAA'), false);
      expect((await a.handle('POST', '/api/xprs/send', {}, _signed('t:blog f:X1BOBB d:$mesh ts:${ts()} title:t m:x', _bob), peer: lan)).status, 403,
          reason: 'a mesh holds its roster, not posts');
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

  group('files posted in a room (XPRS.md 11.2)', () {
    late Directory dir;
    late MediaArchive store;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('room_files_');
      store = MediaArchive.forDirectory('${dir.path}/media');
      XprsFileAcl.instance.init('${dir.path}/acl.zx');
      // The mesh's own gate, as MeshService sets it.
      XprsFileServer.instance.authorize = (sha, who, {required bool sigVerified}) =>
          XprsFileAcl.instance.isOpen(sha) || (sigVerified && XprsFileAcl.instance.authorized(sha, who));
    });
    tearDown(() {
      XprsFileServer.instance.authorize = null;
      XprsFileAcl.instance.close();
      dir.deleteSync(recursive: true);
    });

    String ref(List<int> b) =>
        '${base64Url.encode(crypto.sha256.convert(b).bytes).replaceAll('=', '')}.jpg';
    Future<int> get(WebChatApi a, String r, [String? s]) async =>
        (await a.handle('GET', '/api/xprs/file/$r', {if (s != null) 'session': s}, '', peer: lan)).status;
    Future<int> put(WebChatApi a, List<int> b, Map<String, String> q) async =>
        (await a.handle('POST', '/api/xprs/file/${ref(b)}', q, '', peer: lan, raw: Uint8List.fromList(b))).status;

    test('served to whoever reads the room, decided at each ask', () async {
      final a = make(files: store);
      final s = await claim(a);
      final call = (await post(a, '/api/rooms', {'action': 'create', 'session': s, 'name': 'Photos',
          'kind': 'gallery', 'visibility': 'public', 'posting': 'members'})).json['room'] as String;
      final offer = (await rooms(a, s)).single['offer'];
      await send(a, _signed('t:moderate f:X1ALIC d:$call ts:${ts()} r:$offer accept:mod', _alice));
      final c = await session(a, 'X1CARO', _carol);
      final pic = List<int>.generate(400, (i) => i * 3 & 0xff);
      expect(await put(a, pic, {'room': call, 'session': s}), 200);
      final ev = _signed('t:blog f:X1ALIC d:$call ts:${ts()} title:trip m:x', _alice);
      expect((await send(a, ev)).status, 200);
      final evId = xprsIdentifier(XprsPacket.parse(ev)!);
      expect((await send(a, _signed('t:message f:X1ALIC d:$call ts:${ts()} r:$evId file:${ref(pic)} m:beach', _alice))).status, 200);
      expect(XprsFileAcl.instance.groupOf(crypto.sha256.convert(pic).toString()), call);
      expect(await get(a, ref(pic)), 200, reason: "a public room's picture is anybody's");
      final r = await a.handle('GET', '/api/xprs/file/${ref(pic)}', {}, '', peer: lan);
      expect(r.headers['Cache-Control'], startsWith('public'));
      expect(XprsFileServer.instance.authorize!(crypto.sha256.convert(pic).toString(), '', sigVerified: false), isTrue,
          reason: 'and over the mesh too');

      await post(a, '/api/rooms', {'action': 'update', 'session': s, 'call': call, 'visibility': 'private'});
      expect(await get(a, ref(pic)), 403, reason: 'made private: refused without a session');
      expect(await get(a, ref(pic), c), 403, reason: 'and to carol, no member');
      expect(await get(a, ref(pic), s), 200, reason: 'but served to the administrator');
      final r2 = await a.handle('GET', '/api/xprs/file/${ref(pic)}', {'session': s}, '', peer: lan);
      expect(r2.headers['Cache-Control'], startsWith('private'));
      expect(a.openFile(ref(pic)).reply!.status, 403, reason: 'a streaming host applies the same rule');
      expect(a.openFile(ref(pic), session: s).reply, isNull);
      expect(XprsFileServer.instance.authorize!(crypto.sha256.convert(pic).toString(), '', sigVerified: false), isFalse,
          reason: 'nor to an unproven cmd:file');

      final other = List<int>.generate(300, (i) => i * 5 & 0xff);
      expect(await put(a, other, {'room': call, 'session': c}), 403, reason: 'carol cannot name the private room');
      expect(await put(a, other, {'room': call, 'session': s}), 200);
      expect(await get(a, ref(other)), 403, reason: 'an upload naming the room is closed before any post');
      final up = a.beginFilePut(ref(other), {'room': call, 'session': c}, lan, other.length);
      expect(up.reply!.status, 403, reason: 'the streamed upload too');
    });

    test('a file posted nowhere stays public', () async {
      final a = make(files: store);
      final pic = List<int>.generate(200, (i) => i & 0xff);
      expect(await put(a, pic, {}), 200);
      expect(await get(a, ref(pic)), 200);
    });
  });
}
