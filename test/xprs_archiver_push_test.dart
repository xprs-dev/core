// What one archiver hands the others as it arrives (XPRS.md 12.9.8), and
// which archiver holds which file (12.9.2).
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_archiver_push.dart';
import 'package:xprs_core/src/services/xprs/xprs_file_index.dart';
import 'package:xprs_core/src/services/xprs/xprs_folder.dart' show xprsFileRefOf;
import 'package:xprs_core/src/services/xprs/xprs_monitor.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart';

final _key = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
final now = DateTime.utc(2026, 11, 27, 12).millisecondsSinceEpoch;
XprsPacket pk(String w) => xprsSign(XprsPacket.parse(w)!, _key);
String at(int secondsAgo) => xprsNowTs(now - secondsAgo * 1000);

void main() {
  group('handing on', () {
    final push = XprsArchiverPush.instance;
    late List<(String, String)> sent;
    var always = true;
    var signed = true;

    setUp(() {
      push.reset();
      sent = [];
      always = signed = true;
      push
        ..enabled = (() => always)
        ..self = (() => 'X3HERE')
        ..peers = (() => ['X3ONE', 'X3TWO', 'X3HERE'])
        ..verified = ((_) => signed)
        ..sendTo = (call, wire) async {
          sent.add((call, wire));
          return true;
        };
    });

    int offer(String w, {String bearer = 'web'}) =>
        push.offer(pk(w), bearer: bearer, nowMs: now);

    test('Global talk a visitor said here goes to every other archiver, once', () {
      final w = 't:message f:X1ANNA ts:${at(5)} scope:global m:hello';
      expect(offer(w), 2);
      expect([for (final s in sent) s.$1], ['X3ONE', 'X3TWO']);
      expect(sent.first.$2, contains('via:X3HERE'), reason: 'marked as handed on');
      expect(sent.first.$2, contains(' m:hello'));
      expect(offer(w), 0, reason: 'a packet is handed on once');
      expect(sent, hasLength(2));
    });

    test('with no scope word it is Global too', () {
      expect(offer('t:message f:X1ANNA ts:${at(5)} m:hello'), 2);
    });

    test('Regional and Local talk stays at the archiver it was said at', () {
      expect(offer('t:message f:X1ANNA ts:${at(5)} scope:regional m:valley'), 0);
      expect(offer('t:message f:X1ANNA ts:${at(5)} scope:local m:here'), 0);
      expect(sent, isEmpty);
    });

    test('mail is never handed on: it has its own custody', () {
      expect(offer('t:message f:X1ANNA d:X1BOBB ts:${at(5)} m:for bob'), 0);
      expect(offer('t:receipt f:X1BOBB d:X1ANNA ts:${at(5)} r:aabbcc s:ack'), 0);
    });

    test("another archiver's hand-on is passed along, never back and never twice", () {
      // Archivers do not all know each other (a hub passes few announces),
      // so what X3ONE handed here goes on to X3TWO, and not back to X3ONE.
      final w = 't:message f:X1ANNA ts:${at(5)} m:hello';
      final handed = xprsAppendVia(pk(w), 'X3ONE');
      expect(push.offer(handed, bearer: 'rns', nowMs: now), 1);
      expect(sent.single.$1, 'X3TWO');
      expect(sent.single.$2, contains('via:X3ONE,X3HERE'));
      expect(push.offer(handed, bearer: 'rns', nowMs: now), 0, reason: 'once');
      // It has been through here: nothing more.
      final back = xprsAppendVia(
          xprsAppendVia(pk('t:message f:X1ANNA ts:${at(5)} m:again'), 'X3HERE'),
          'X3ONE');
      expect(push.offer(back, bearer: 'rns', nowMs: now), 0);
    });

    test('the hop budget every relay keeps ends it', () {
      var p = pk('t:message f:X1ANNA ts:${at(5)} m:far');
      for (final hop in ['X3AAA', 'X3BBB', 'X3CCC']) {
        p = xprsAppendVia(p, hop);
      }
      expect(push.offer(p, bearer: 'rns', nowMs: now), 0);
    });

    test('a station that handed something here is handed to first', () {
      push.peers = () => [for (var i = 0; i < 40; i++) 'X3P${i.toString().padLeft(3, '0')}'];
      final fromNew = xprsAppendVia(pk('t:message f:X1ANNA ts:${at(5)} m:one'), 'X3NEWA');
      push.offer(fromNew, bearer: 'rns', nowMs: now);
      sent.clear();
      expect(offer('t:message f:X1ANNA ts:${at(4)} m:two'), XprsArchiverPush.maxPeers);
      expect(sent.first.$1, 'X3NEWA',
          reason: 'it hands on, so it is an archiver like this one');
    });

    test('a deposit from a station that chose this archiver is first-hand', () {
      expect(offer('t:message f:X1ANNA ts:${at(5)} m:hello', bearer: 'rns'), 2);
    });

    test('history is not news: an old packet is asked for, not pushed', () {
      expect(offer('t:message f:X1ANNA ts:${at(3600)} m:old'), 0);
    });

    test('only an always-on public archiver hands on, and only what it checked', () {
      always = false;
      expect(offer('t:message f:X1ANNA ts:${at(5)} m:one'), 0);
      expect(push.notArchiver, 1);
      always = true;
      signed = false;
      expect(offer('t:message f:X1ANNA ts:${at(5)} m:two'), 0);
      expect(push.unverified, 1);
      expect(sent, isEmpty);
    });

    test("the room's upkeep goes too: a removal, a mailbox, a file record", () {
      expect(offer('t:moderate f:X1MODR ts:${at(5)} r:89a9c8 remove:message'), 2);
      expect(offer('t:mailbox f:X1ANNA ts:${at(5)} hold:X3HERE'), 2);
      expect(
          offer('t:file f:X3HERE ts:${at(5)} '
              'file:${xprsFileRefOf('ab' * 32, 'png')} size:100',
              bearer: 'own'),
          2);
      // A group's act is the group's (it has a d:), and the bytes of a file
      // are not a statement about one.
      expect(offer('t:moderate f:X1MODR d:X5GRPA ts:${at(5)} r:89a9c8 remove:message'), 0);
      expect(
          offer('t:file f:X1ANNA ts:${at(5)} '
              'file:${xprsFileRefOf('ab' * 32, 'png')} size:100 off:0 b:AAAA'),
          0);
    });

    test('a key binding goes, once an hour per author', () {
      String id(int ago) => 't:identity f:X1ANNA ts:${at(ago)} k:npub1anna';
      expect(offer(id(9)), 2);
      expect(offer(id(5)), 0, reason: 'the same author, minutes later');
      expect(
          push.offer(pk(id(0)), bearer: 'web', nowMs: now + 61 * 60 * 1000), 0,
          reason: 'that one is old by then');
      expect(
          push.offer(pk('t:identity f:X1ANNA ts:${xprsNowTs(now + 61 * 60 * 1000)} k:npub1anna'),
              bearer: 'web', nowMs: now + 61 * 60 * 1000),
          2);
    });

    test('the author and this station are not handed their own packet', () {
      expect(offer('t:mailbox f:X3ONE ts:${at(5)} hold:X3HERE', bearer: 'rns'), 1);
      expect(sent.single.$1, 'X3TWO');
    });
  });

  group('the file index', () {
    final idx = XprsFileIndex.instance;
    late List<String> said;
    late Map<String, List<String>> holders;
    final sha = 'cd' * 32;

    setUp(() {
      idx.reset();
      said = [];
      holders = {};
      idx
        ..enabled = (() => true)
        ..self = (() => 'X3HERE')
        ..publish = said.add
        ..verified = ((_) => true)
        ..holdersOf = ((s) => holders[s] ?? const [])
        ..keep = ((s, h) => (holders[s] ??= []).add(h));
    });

    test('a file that lands is said once, as a t:file record', () {
      idx.landed(sha, 4096, 'png', nowMs: now);
      idx.landed(sha, 4096, 'png', nowMs: now);
      expect(said, hasLength(1));
      final p = XprsPacket.parse(said.single)!;
      expect(p.type, 'file');
      expect(p['f'], 'X3HERE');
      expect(p['size'], '4096');
      expect(XprsFileIndex.recordOf(p), sha);
      // The store's own name for a file (43 characters) is taken as well.
      idx.reset();
      idx.landed(xprsFileRefOf('ef' * 32, ''), 10, 'bin', nowMs: now);
      expect(XprsFileIndex.recordOf(XprsPacket.parse(said.last)!), 'ef' * 32);
    });

    test('a library dropped in at once is not announced file by file', () {
      for (var i = 0; i < 50; i++) {
        idx.landed(i.toRadixString(16).padLeft(64, '0'), 10, 'mp3', nowMs: now);
      }
      expect(said, hasLength(XprsFileIndex.perMinute));
      expect(idx.heldBack, 50 - XprsFileIndex.perMinute);
    });

    test("another archiver's record names it as a holder", () {
      final rec = pk('t:file f:X3ONE ts:${at(5)} '
          'file:${xprsFileRefOf(sha, 'png')} size:4096');
      expect(idx.offer(rec), isTrue);
      expect(holders[sha], ['X3ONE']);
      expect(idx.offer(rec), isFalse, reason: 'noted already');
      // Not a record: the bytes of a file, a file sent to one person.
      expect(
          idx.offer(pk('t:file f:X3TWO ts:${at(5)} '
              'file:${xprsFileRefOf(sha, 'png')} size:4096 off:0 b:AAAA')),
          isFalse);
      expect(
          idx.offer(pk('t:file f:X3TWO d:X1ANNA ts:${at(5)} '
              'file:${xprsFileRefOf(sha, 'png')} size:4096')),
          isFalse);
      idx.verified = (_) => false;
      expect(
          idx.offer(pk('t:file f:X3TWO ts:${at(5)} '
              'file:${xprsFileRefOf(sha, 'png')} size:4096')),
          isFalse,
          reason: 'an unsigned claim names nobody');
      expect(holders[sha], ['X3ONE']);
    });
  });

  group('who is in reach', () {
    test('a handed-on or replayed packet does not put its author in reach', () {
      final m = XprsMonitor.instance;
      m.noteRemote('X1FARR', nowMs: now, present: false);
      expect(m.heardDirectly('X1FARR', nowMs: now), isFalse);
      m.noteRemote('X1NEAR', nowMs: now);
      expect(m.heardDirectly('X1NEAR', nowMs: now), isTrue);
    });
  });
}
