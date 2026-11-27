// The public rooms' moderators (XPRS.md 10.10.3): a key listed at
// xprs.dev/moderators.json removes a message from Regional and Global with
// the act section 10.4.1 already has, addressed to nobody. Removal only, and
// only by a listed key at the act's own date.
import 'dart:io';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive_policy.dart';
import 'package:xprs_core/src/services/xprs/xprs_id.dart';
import 'package:xprs_core/src/services/xprs/xprs_ingest.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_public_moderators.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

final _mod = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
final _other = BigInt.parse('fedcba0987654321fedcba0987654321', radix: 16);
final _carol = BigInt.parse('0badc0de0badc0de0badc0de0badc0de', radix: 16);

XprsPacket _signed(String wire, BigInt key) =>
    xprsSign(XprsPacket.parse(wire)!, key);
String _npub(BigInt key) =>
    NostrCrypto.encodeNpub(HEX.encode(XprsCrypto.publicKeyXOnly(key)));
String _list(BigInt key, {String since = '', String until = ''}) =>
    '{"moderators":[{"npub":"${_npub(key)}","since":"$since","until":"$until"}]}';

void main() {
  final mods = XprsPublicModerators.instance;
  final now = DateTime.utc(2026, 11, 27, 12).millisecondsSinceEpoch;
  XprsPacket act(BigInt key, {String ts = '2026-11-27_11:00:00', String f = 'X1MODR', String extra = ''}) =>
      _signed('t:moderate f:$f ts:$ts r:89a9c8 remove:message$extra', key);

  setUp(() {
    mods.reset();
    expect(mods.refresh(_list(_mod)), isTrue);
  });
  tearDown(mods.reset);

  group('the list and the verdict', () {
    test('no key is in the program: until the list is read, nobody moderates', () {
      mods.reset();
      expect(mods.list, isEmpty);
      expect(mods.judge(act(_mod), nowMs: now), isNull);
    });

    test('a listed key removes; an unlisted one does not', () {
      expect(mods.judge(act(_mod), nowMs: now), '89a9c8');
      expect(mods.judge(act(_other), nowMs: now), isNull);
      expect(mods.offer(act(_mod), nowMs: now), isTrue);
      expect(mods.removed, ['89a9c8']);
      expect(mods.offer(act(_other), nowMs: now), isFalse);
      expect(mods.refused, 1);
    });

    test('authority is the key, whatever name the act wears', () {
      // The callsign in f: is a label: a listed key under another name still
      // counts, and an unlisted key under the moderator's name does not --
      // not even when that name is bound to the unlisted key elsewhere.
      xprsAlternateKeys = (_) => [XprsCrypto.publicKeyXOnly(_other)];
      addTearDown(() => xprsAlternateKeys = null);
      expect(mods.judge(act(_mod, f: 'CT1ABC'), nowMs: now), '89a9c8');
      expect(mods.judge(act(_other, f: 'X1MODR'), nowMs: now), isNull);
    });

    test('a flood of forged removals costs a bounded number of checks a minute', () {
      // Each forged act is a different packet, so no remembered verdict
      // helps: only the budget stops the curve work.
      XprsPacket forged(int i) => _signed(
          't:moderate f:X1FLOD ts:2026-11-27_11:00:${(i % 60).toString().padLeft(2, '0')} '
          'r:${(i + 0x100000).toRadixString(16)} remove:message',
          _other);
      for (var i = 0; i < 40; i++) {
        expect(mods.offer(forged(i), nowMs: now), isFalse);
      }
      expect(mods.unchecked,
          40 - XprsPublicModerators.failedChecksPerMinute);
      // A moderator already known is still heard through the flood...
      mods.reset();
      mods.refresh(_list(_mod));
      expect(mods.offer(act(_mod), nowMs: now), isTrue);
      for (var i = 0; i < 40; i++) {
        mods.offer(forged(i), nowMs: now);
      }
      expect(
          mods.offer(act(_mod, ts: '2026-11-27_11:30:00'), nowMs: now), isTrue);
      // ...and the next minute starts with a whole budget.
      final before = mods.unchecked;
      expect(mods.offer(forged(99), nowMs: now + 61000), isFalse);
      expect(mods.unchecked, before);
    });

    test('only a removal addressed to nobody is such an act', () {
      bool shaped(String w) => XprsPublicModerators.shaped(XprsPacket.parse(w)!);
      expect(shaped('t:moderate f:X1MODR ts:2026-11-27_11:00:00 r:89a9c8 remove:message'), isTrue);
      expect(shaped('t:moderate f:X1MODR d:X3STAT ts:2026-11-27_11:00:00 r:89a9c8 remove:message'), isFalse);
      expect(shaped('t:moderate f:X1MODR ts:2026-11-27_11:00:00 r:89a9c8 hide:message'), isFalse);
      expect(shaped('t:moderate f:X1MODR ts:2026-11-27_11:00:00 revoke:X1CARO'), isFalse);
      expect(shaped('t:moderate f:X1MODR ts:2026-11-27_11:00:00 r:zzz remove:message'), isFalse);
      expect(shaped('t:message f:X1MODR ts:2026-11-27_11:00:00 r:89a9c8 remove:message'), isFalse);
    });

    test('judged at the date of the act: since, until, and not from the future', () {
      mods.refresh(_list(_mod, since: '2026-11-20', until: '2026-11-27'));
      expect(mods.judge(act(_mod, ts: '2026-11-19_23:59:59'), nowMs: now), isNull);
      expect(mods.judge(act(_mod, ts: '2026-11-26_23:59:59'), nowMs: now), '89a9c8');
      expect(mods.judge(act(_mod, ts: '2026-11-27_00:00:00'), nowMs: now), isNull);
      mods.refresh(_list(_mod));
      expect(mods.judge(act(_mod, ts: '2026-11-27_12:04:00'), nowMs: now), '89a9c8');
      expect(mods.judge(act(_mod, ts: '2026-11-27_12:06:00'), nowMs: now), isNull);
    });

    test('the switch off: nobody is listed and nothing is honoured', () {
      mods.honoured = false;
      expect(mods.list, isEmpty);
      expect(mods.offer(act(_mod), nowMs: now), isFalse);
    });

    test('what is not a list leaves the list held', () {
      for (final junk in [
        '<html>Sign in to this network</html>',
        '{"moderators":"nobody"}',
        '[]',
        '{"moderators":[{"npub":"npub1${'x' * 9000000}"}]}',
      ]) {
        expect(mods.refresh(junk), isFalse);
        expect(mods.judge(act(_mod), nowMs: now), '89a9c8');
      }
      // A list with nobody in it is a list: the rooms have no moderators.
      expect(mods.refresh('{"moderators":[]}'), isTrue);
      expect(mods.judge(act(_mod), nowMs: now), isNull);
      // An entry that is not a key is skipped, the rest stands.
      expect(
          mods.refresh('{"moderators":[{"npub":"npub1nonsense"},{"npub":"${_npub(_mod)}"}]}'),
          isTrue);
      expect(mods.list.length, 1);
    });

    test('sync: the kept list first, the site at most every twelve hours', () async {
      var asked = 0, keptAt = 0;
      String? kept;
      Future<void> run(int t, {String? site}) => mods.sync(
            honour: () => true,
            kept: () => kept ?? '',
            askedMs: () => keptAt,
            keep: ({json, required askedMs}) async {
              if (json != null) kept = json;
              keptAt = askedMs;
            },
            fetch: (u) async {
              asked++;
              expect('$u', XprsPublicModerators.url);
              return site;
            },
            nowMs: t,
          );
      mods.reset();
      await run(now, site: _list(_other));
      expect(asked, 1);
      expect(mods.judge(act(_other), nowMs: now), '89a9c8');
      await run(now + 3600 * 1000, site: _list(_mod));
      expect(asked, 1, reason: 'asked an hour ago');
      // A restart reads what was kept before it asks anybody.
      mods.reset();
      await run(now + 2 * 3600 * 1000);
      expect(mods.judge(act(_other), nowMs: now), '89a9c8');
      // Unreachable or junk: the list held stands, and it is asked again
      // after ten minutes rather than in twelve hours or at once.
      await run(now + 13 * 3600 * 1000, site: '<html>');
      expect(asked, 2);
      expect(mods.judge(act(_other), nowMs: now), '89a9c8');
      await run(now + 13 * 3600 * 1000 + 60 * 1000, site: _list(_mod));
      expect(asked, 2);
      await run(now + 13 * 3600 * 1000 + 11 * 60 * 1000, site: _list(_mod));
      expect(asked, 3);
      expect(mods.judge(act(_mod), nowMs: now), '89a9c8');
    });
  });

  group('the archive', () {
    late Directory dir;
    final a = XprsArchive.instance;
    String put(String wire, BigInt key) {
      final p = _signed(wire, key);
      a.admit(p, bearer: 'lan');
      return xprsIdentifier(p);
    }

    List<String> ids({List<String> types = const ['message', 'sos']}) =>
        [for (final r in a.query(types: types, limit: 50)) '${r['id']}'];

    setUp(() {
      dir = Directory.systemTemp.createTempSync('xprs-pubmod');
      a
        ..init('${dir.path}/archive.zx')
        ..selfCallsign = 'X3SELF';
    });
    tearDown(() {
      a.close();
      dir.deleteSync(recursive: true);
    });

    test('a removed message goes, with its edits, and a late copy is refused', () {
      final spam = put('t:message f:X1CARO ts:2026-11-27_10:00:00 scope:global m:spam', _carol);
      final edit = put('t:message f:X1CARO ts:2026-11-27_10:01:00 scope:global edit:$spam m:more spam', _carol);
      final fine = put('t:message f:X1CARO ts:2026-11-27_10:02:00 m:hello', _carol);
      a.flush();
      expect(ids(), containsAll([spam, edit, fine]));
      a.purgePublic(spam);
      expect(ids(), [fine]);
      put('t:message f:X1CARO ts:2026-11-27_10:00:00 scope:global m:spam', _carol);
      a.flush();
      expect(ids(), [fine], reason: 'replayed by a station that still holds it');
    });

    test('the removal that arrives first still stops the message', () {
      final p = _signed('t:message f:X1CARO ts:2026-11-27_10:05:00 m:spam', _carol);
      a.purgePublic(xprsIdentifier(p));
      a.admit(p, bearer: 'lan');
      a.flush();
      expect(ids(), isEmpty);
    });

    test('out of reach: the Local room, a call for help, mail', () {
      final local = put('t:message f:X1CARO ts:2026-11-27_10:00:00 scope:local m:here', _carol);
      final sos = put('t:sos f:X1CARO ts:2026-11-27_10:00:01 m:help', _carol);
      final mail = put('t:message f:X1CARO d:X1BOBB ts:2026-11-27_10:00:02 m:for bob', _carol);
      a.flush();
      for (final id in [local, sos, mail]) {
        a.purgePublic(id);
      }
      expect(ids(), containsAll([local, sos]));
      expect([for (final r in a.query(only: 'X1BOBB', types: const ['message'], limit: 5)) '${r['id']}'],
          [mail]);
    });

    test('a removal naming what is out of reach is not remembered as one', () {
      final talk = put('t:message f:X1CARO ts:2026-11-27_10:00:00 scope:regional m:talk', _carol);
      final sos = put('t:sos f:X1CARO ts:2026-11-27_10:00:01 m:help', _carol);
      a.flush();
      expect(a.publicOutOfReach(sos), isTrue);
      expect(a.publicOutOfReach(talk), isFalse);
      expect(a.publicOutOfReach('000000'), isFalse, reason: 'not held: it may still arrive');
      XprsPacket rm(String id) =>
          _signed('t:moderate f:X1MODR ts:2026-11-27_11:00:00 r:$id remove:message', _mod);
      expect(mods.offer(rm(sos), nowMs: now, outOfReach: a.publicOutOfReach), isTrue,
          reason: "still a listed moderator's act");
      expect(mods.offer(rm(talk), nowMs: now, outOfReach: a.publicOutOfReach), isTrue);
      expect(mods.removed, [talk]);
      // What was removed is known again after a restart, from the archive.
      a.purgePublic(talk);
      a.flush();
      mods.reset();
      mods.remember(a.publicRemoved().reversed);
      expect(mods.removed, contains(talk));
    });
  });

  group('the receive funnel', () {
    late Directory dir;
    final a = XprsArchive.instance;
    final now = DateTime.now().toUtc();
    String ts(int minAgo) {
      final t = now.subtract(Duration(minutes: minAgo));
      String two(int n) => n.toString().padLeft(2, '0');
      return '${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    }

    setUp(() {
      dir = Directory.systemTemp.createTempSync('xprs-pubmod-in');
      // A private phone that follows the rooms: the least any station keeps.
      XprsIngest.policy = const XprsArchivePolicy(followRooms: true);
      a
        ..init('${dir.path}/archive.zx')
        ..selfCallsign = 'X3SELF';
    });
    tearDown(() {
      XprsIngest.policy = const XprsArchivePolicy();
      a.close();
      dir.deleteSync(recursive: true);
    });

    test('a removal heard on a bearer deletes, and is kept to hand on', () {
      final spam = _signed('t:message f:X1CARO ts:${ts(10)} m:spam', _carol);
      XprsIngest.heard(spam, bearer: 'lan', selfCallsign: 'X3SELF');
      a.flush();
      expect(a.query(types: const ['message'], limit: 5), hasLength(1));
      final id = xprsIdentifier(spam);
      // Somebody who is not listed says the same thing: nothing happens.
      XprsIngest.heard(
          _signed('t:moderate f:X1OTHR ts:${ts(2)} r:$id remove:message', _other),
          bearer: 'lan', selfCallsign: 'X3SELF');
      a.flush();
      expect(a.query(types: const ['message'], limit: 5), hasLength(1));
      expect(a.query(types: const ['moderate'], limit: 5), isEmpty,
          reason: "a stranger's act about nothing is not the room's record");
      XprsIngest.heard(
          _signed('t:moderate f:X1MODR ts:${ts(1)} r:$id remove:message', _mod),
          bearer: 'lan', selfCallsign: 'X3SELF');
      a.flush();
      expect(a.query(types: const ['message'], limit: 5), isEmpty);
      expect(a.query(types: const ['moderate'], limit: 5).single['wire'],
          contains('r:$id remove:message'));
      expect(mods.removed, [id]);
    });
  });

  group('through a station', () {
    late List<String> received;
    final clock = DateTime.utc(2026, 11, 27, 12);
    const lan = '192.168.1.20';
    final spam = _signed('t:message f:X1CARO ts:2026-11-27_09:00:00 m:spam', _carol);
    final keys = <String, Uint8List>{};

    WebChatApi make() => WebChatApi(
          publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) => [
            {
              'id': xprsIdentifier(spam),
              'type': 'message',
              'from': 'X1CARO',
              'to': '',
              'own': false,
              'wire': spam.encode(),
            },
          ],
          held: (t) => 1,
          receive: received.add,
          mayAir: (_) => true,
          selfCallsign: () => 'X3STAT',
          keyOf: (c) => keys[c],
          appPath: () => null,
          now: () => clock,
        );
    Future<WebChatReply> post(WebChatApi a, XprsPacket p) =>
        a.handle('POST', '/api/xprs/send', {}, p.encode(), peer: lan);
    String removal(BigInt key) =>
        't:moderate f:X1MODR ts:2026-11-27_11:59:00 r:${xprsIdentifier(spam)} remove:message';

    setUp(() => received = []);

    test('a listed visitor removes; the page is told; anybody else is refused', () async {
      final a = make();
      Future<List> rows() async =>
          (await a.handle('GET', '/api/xprs/history', {}, '', peer: lan)).json['rows'] as List;
      expect((await rows()).length, 1);
      final no = await post(a, _signed(removal(_other), _other));
      expect(no.status, 403);
      expect(received, isEmpty, reason: 'not filed, not aired');
      final yes = await post(a, _signed(removal(_mod), _mod));
      expect(yes.status, 200);
      expect(received.single, contains('remove:message'));
      final h = (await a.handle('GET', '/api/xprs/history', {}, '', peer: lan)).json;
      expect(h['rows'], isEmpty);
      expect(h['moderation']['removed'], [xprsIdentifier(spam)]);
    });

    test('the station says whose removals it honours', () async {
      final a = make();
      final st = (await a.handle('GET', '/api/admin', {}, '', peer: lan)).json;
      expect(st['public_moderators'], [_npub(_mod)]);
      mods.honoured = false;
      expect((await a.handle('GET', '/api/admin', {}, '', peer: lan)).json['public_moderators'],
          isEmpty);
    });
  });
}
