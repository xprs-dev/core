// A visitor on the web page is HEARD by the station (spec/API-HTTP.md,
// XPRS.md 12.7, 12.8.3): the page tells the core where the wire came from
// (`receiveFrom`), reports a proven session as a hearing (`onVisitor`), and
// the session reply says where the visitor's mail is kept (`holders`), offers
// this station when nobody keeps it (`offer`) and how much waits (`mail`). A
// mailbox declaration or a receipt is acted on by whoever hears it, so through
// the page it must verify against a key the station knows.
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

final _alice = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
final _other = BigInt.parse('fedcba0987654321fedcba0987654321', radix: 16);

String _signed(String wire, BigInt key) =>
    xprsSign(XprsPacket.parse(wire)!, key).encode();

void main() {
  const lan = '192.168.178.20', internet = '203.0.113.7';
  late Map<String, Uint8List> keys;
  late List<String> received;
  late List<(String wire, bool local)> heard;
  late List<(String call, bool local)> visitors;
  late List<String> holders;
  late List<String> offered;
  String? offer;
  // The per-visitor rate limit (five a second) is not what these tests are
  // about: the clock moves a second per call.
  late DateTime clock;

  setUp(() {
    keys = {'X1ALIC': XprsCrypto.publicKeyXOnly(_alice)};
    received = [];
    heard = [];
    visitors = [];
    holders = [];
    offered = [];
    offer = 'X3PTZM';
    clock = DateTime.utc(2026, 11, 8, 12);
  });

  WebChatApi make({bool seams = true, bool offers = true,
          List<Map<String, dynamic>> rows = const []}) =>
      WebChatApi(
        publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) =>
            visitor == 'X1ALIC' ? rows : <Map<String, dynamic>>[],
        held: (_) => 0,
        receive: received.add,
        mayAir: (_) => true,
        selfCallsign: () => 'X3PTZM',
        keyOf: (c) => keys[c],
        appPath: () => null,
        now: () => clock = clock.add(const Duration(seconds: 1)),
        receiveFrom: seams ? (w, {required local}) => heard.add((w, local)) : null,
        onVisitor: seams ? (c, {required local}) => visitors.add((c, local)) : null,
        holdersOf: seams ? (_) => holders : null,
        offerMailbox: seams && offers
            ? (c) {
                offered.add(c);
                return offer;
              }
            : null,
        mailFor: seams ? (_) => 3 : null,
      );

  Future<Map<String, dynamic>> prove(WebChatApi a, String peer,
      {String call = 'X1ALIC', BigInt? key}) async {
    final n = (await a.handle('GET', '/api/session', {}, '', peer: peer)).json['nonce'];
    final r = await a.handle('POST', '/api/session', {},
        _signed('t:session f:$call ts:2026-11-08_12:00:00 m:$n', key ?? _alice),
        peer: peer);
    expect(r.status, 200, reason: '${r.json}');
    return r.json;
  }

  Future<WebChatReply> post(WebChatApi a, String wire, BigInt key, {String peer = lan}) =>
      a.handle('POST', '/api/xprs/send', {}, _signed(wire, key), peer: peer);

  test('services says page.mailbox only when the host wired the seams', () async {
    expect(((await make().handle('GET', '/api/services', {}, '')).json['page'] as Map)['mailbox'], true);
    expect(((await make(seams: false).handle('GET', '/api/services', {}, '')).json['page'] as Map)
        .containsKey('mailbox'), isFalse);
  });

  test('a proven visitor is heard through the API, with where they are', () async {
    final a = make();
    await prove(a, lan);
    await prove(a, internet);
    expect(visitors, [('X1ALIC', true), ('X1ALIC', false)]);
  });

  test('a page polling with its session keeps the visitor heard, once a minute', () async {
    final a = make();
    final s = (await prove(a, lan))['session'] as String;
    expect(visitors, hasLength(1));
    // The clock moves a second per call: a poll every few seconds for a
    // minute is one hearing, the next minute another.
    for (var i = 0; i < 20; i++) {
      await a.handle('GET', '/api/xprs/history', {'session': s}, '', peer: lan);
    }
    expect(visitors, hasLength(2));
    clock = clock.add(const Duration(minutes: 1));
    await a.handle('GET', '/api/xprs/history', {'session': s}, '', peer: lan);
    expect(visitors, hasLength(3));
    // Without a session nobody is heard: anybody can read the public rows.
    await a.handle('GET', '/api/xprs/history', {}, '', peer: lan);
    expect(visitors, hasLength(3));
  });

  test('the first session is offered this station; once a holder exists, the holder and no offer', () async {
    final a = make();
    final first = await prove(a, lan);
    expect(first['holders'], isEmpty);
    expect(first['offer'], 'X3PTZM');
    expect(first['mail'], 3);
    expect(offered, ['X1ALIC']);
    // The host recorded the visitor as served (or the page declared): the
    // holder is known now, and nothing is offered again.
    holders = ['X3PTZM'];
    final second = await prove(a, lan);
    expect(second['holders'], ['X3PTZM']);
    expect(second.containsKey('offer'), isFalse);
    expect(offered, hasLength(1), reason: 'asked only for a visitor with no holder');
  });

  test('a station that is not an archiver, or is full, offers nothing', () async {
    offer = null;
    final r = await prove(make(), lan);
    expect(r.containsKey('offer'), isFalse);
    expect(r['holders'], isEmpty);
    // Without the seams the reply is what it always was.
    final plain = await prove(make(seams: false), lan);
    expect(plain.keys.toSet(), {'ok', 'session', 'call'});
  });

  test('a wire goes through receiveFrom with where it came from; receive is left alone', () async {
    final a = make();
    const wire = 't:status f:X1ALIC ts:2026-11-08_12:00:00 m:on the page';
    expect((await post(a, wire, _alice, peer: lan)).status, 200);
    expect((await post(a, wire, _alice, peer: internet)).status, 200);
    expect(heard.map((h) => h.$2), [true, false]);
    expect(heard.first.$1, startsWith('t:status f:X1ALIC'));
    expect(received, isEmpty);
    // A host without the seam gets the wire the old way.
    expect((await post(make(seams: false), wire, _alice)).status, 200);
    expect(received, hasLength(1));
  });

  test('/api/xprs/mail: what waits for a callsign, to its own session or the administrator', () async {
    // Mail belongs to its two parties (XPRS.md 12.7): the mailbox is read with
    // a session proving that callsign; a stranger's, or none, is refused.
    final a = make(rows: [
      {'id': 'aa1111', 'ts': 1, 'from': 'X1BOBB', 'to': 'X1ALIC', 'type': 'message',
       'sig': 'verified', 'own': false, 'wire': 't:message f:X1BOBB d:X1ALIC ts:2026-11-08_11:00:00 m:hi'},
      {'id': 'aa2222', 'ts': 2, 'from': 'X1ALIC', 'to': '', 'type': 'message',
       'sig': 'verified', 'own': false, 'wire': 't:message f:X1ALIC ts:2026-11-08_11:01:00 m:hello all'},
    ]);
    final bare = await a.handle('GET', '/api/xprs/mail', {'call': 'X1ALIC'}, '', peer: lan);
    expect(bare.status, 403);
    final none = await a.handle('GET', '/api/xprs/mail', {}, '', peer: lan);
    expect(none.status, 400);
    final mine = await prove(a, lan);
    final ok = await a.handle('GET', '/api/xprs/mail',
        {'call': 'X1ALIC', 'session': mine['session'] as String}, '', peer: lan);
    expect(ok.status, 200);
    expect((ok.json['rows'] as List).map((r) => r['id']), ['aa1111'],
        reason: 'only what is addressed to the callsign, not what it said');
    keys['X1OTHR'] = XprsCrypto.publicKeyXOnly(_other);
    final theirs = await prove(a, lan, call: 'X1OTHR', key: _other);
    final no = await a.handle('GET', '/api/xprs/mail',
        {'call': 'X1ALIC', 'session': theirs['session'] as String}, '', peer: lan);
    expect(no.status, 403);
  });

  test('a mailbox declaration or a receipt must verify against a known key', () async {
    final a = make();
    // An unknown key: the page sends the identity first and asks again (409),
    // exactly as for a session.
    final unknown = await post(a,
        't:mailbox f:X1NOKY ts:2026-11-08_12:00:00 hold:X3PTZM until:2026-12-08_00:00:00', _other);
    expect(unknown.status, 409);
    expect(unknown.json['error'], 'identity unknown');
    expect((await post(a, 't:receipt f:X1NOKY d:X1BOBB r:40f357 ts:2026-11-08_12:00:00 s:ack', _other))
        .status, 409);
    // A known callsign signed with somebody else's key is a forgery (400).
    final forged = await post(a,
        't:mailbox f:X1ALIC ts:2026-11-08_12:00:00 hold:X3PTZM until:2026-12-08_00:00:00', _other);
    expect(forged.status, 400);
    expect(forged.json['error'], 'forged');
    expect(heard, isEmpty, reason: 'nothing unverifiable reaches the funnel');
    // The visitor's own: taken, and handed in as heard on this network.
    final ok = await post(a,
        't:mailbox f:X1ALIC ts:2026-11-08_12:00:00 hold:X3PTZM until:2026-12-08_00:00:00', _alice);
    expect(ok.status, 200, reason: '${ok.json}');
    final receipt = await post(a,
        't:receipt f:X1ALIC d:X1BOBB r:40f357 ts:2026-11-08_12:00:00 s:ack', _alice);
    expect(receipt.status, 200, reason: '${receipt.json}');
    expect(heard, hasLength(2));
    expect(heard.first.$1, startsWith('t:mailbox f:X1ALIC'));
    expect(heard.last.$1, startsWith('t:receipt f:X1ALIC'));
    // A plain status from a key the station has never heard is still
    // relayed, unverified, as it always was: it is not acted on by anybody.
    expect((await post(a, 't:status f:X1NOKY ts:2026-11-08_12:00:00 m:hi', _other)).status, 200);
  });
}
