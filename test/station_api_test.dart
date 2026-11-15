// The visitor's side of the station API (lib/src/services/station): a phone
// browses a station as the portal page does. Every call here goes to the
// SAME WebChatApi the HTTP server and the Reticulum link serve, so what
// passes here is what the page does against a real station.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/station/station_api.dart';
import 'package:xprs_core/src/services/station/station_browse.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/web_chat_rns.dart';
import 'package:xprs_core/src/services/xprs/xprs_file_acl.dart';
import 'package:xprs_core/src/services/xprs/xprs_groups.dart';
import 'package:xprs_core/src/services/xprs/xprs_id.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_presence.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart' show xprsParseTs, xprsNowTs;

final _station = BigInt.parse('5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a', radix: 16);
final _alice = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
final _bob = BigInt.parse('fedcba0987654321fedcba0987654321', radix: 16);

String _signed(String wire, BigInt key) => xprsSign(XprsPacket.parse(wire)!, key).encode();
String _callOf(BigInt d) =>
    'X1${NostrCrypto.deriveCallsign(HEX.encode(XprsCrypto.publicKeyXOnly(d)))}';
String _npubOf(BigInt d) => NostrCrypto.encodeNpub(HEX.encode(XprsCrypto.publicKeyXOnly(d)));

void main() {
  late Map<String, Uint8List> keys;
  late Map<String, BigInt> roomKeys;
  late List<String> kept;
  late Directory dir;
  late MediaArchive store;
  late WebChatApi api;
  final groups = XprsGroups.instance;
  final alice = _callOf(_alice), bob = _callOf(_bob);
  var seed = 2000;
  var t0 = DateTime.now().toUtc();
  String ts() => xprsNowTs((t0 = t0.add(const Duration(seconds: 1))).millisecondsSinceEpoch);

  /// The calls cross as they do on a link: the request map, packed, to the
  /// station's own answerer, and the response map, packed, back.
  StationCarrier carrier(String peer) => stationRequestCarrier((data) async =>
      msgpackDecode(msgpackEncode(await webChatLinkAnswer(api, msgpackDecode(msgpackEncode(data)), peer))));

  StationVisit visit(String call, BigInt key, {bool known = true, bool lan = false}) {
    if (known) keys[call] = XprsCrypto.publicKeyXOnly(key);
    return StationVisit('X3STAT', carrier(lan ? '192.168.1.20' : 'rns:$call'),
        visitor: StationVisitor(
          call: call,
          identityWire: () => _signed('t:identity f:$call ts:${ts()} k:${_npubOf(key)}', key),
          sign: (w) => _signed(w, key),
        ));
  }

  setUp(() {
    groups.clear();
    keys = {'X3STAT': XprsCrypto.publicKeyXOnly(_station)};
    roomKeys = {};
    kept = [];
    groups.keyResolver = (c) => keys[c];
    dir = Directory.systemTemp.createTempSync('station_api_');
    store = MediaArchive.forDirectory('${dir.path}/media');
    XprsFileAcl.instance.init('${dir.path}/acl.zx');
    api = WebChatApi(
      publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) => [],
      held: (t) => 0,
      receive: (w) {
        final p = XprsPacket.parse(w);
        final k = p?['k'];
        if (p?.type == 'identity' && k != null) {
          final hex = NostrCrypto.decodeNpub(k);
          keys[p!['f']!] = Uint8List.fromList(HEX.decode(hex));
        }
      },
      mayAir: (_) => true,
      selfCallsign: () => 'X3STAT',
      keyOf: (c) => keys[c],
      appPath: () => null,
      now: () => t0,
      fileStore: () => store,
      groups: groups,
      signAsStation: (c) => xprsSign(XprsPacket.parse(c)!, _station),
      publish: (_) {},
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
            if (untilMs == null || xprsParseTs(XprsPacket.parse(w)!['ts'])! <= untilMs)
              {
                'id': xprsIdentifier(XprsPacket.parse(w)!),
                'type': XprsPacket.parse(w)!.type,
                'from': XprsPacket.parse(w)!['f'],
                'to': room,
                'ts': xprsParseTs(XprsPacket.parse(w)!['ts'])! ~/ 1000,
                'wire': w,
              },
      ].take(limit).toList(),
    );
  });
  tearDown(() {
    XprsFileAcl.instance.close();
    dir.deleteSync(recursive: true);
  });

  String refOf(List<int> b) =>
      '${base64Url.encode(crypto.sha256.convert(b).bytes).replaceAll('=', '')}.jpg';

  /// Alice owns the station and fills a gallery with one event and [n] photos.
  Future<(String room, String event, List<int> pic)> gallery(StationVisit a,
      {int n = 1, String visibility = 'public'}) async {
    final s = (await a.session())!;
    await a.call('POST', '/api/admin', const {},
        Uint8List.fromList(utf8.encode(jsonEncode({'action': 'claim', 'session': s}))));
    final made = await a.call('POST', '/api/rooms', const {}, Uint8List.fromList(utf8.encode(jsonEncode({
      'action': 'create', 'session': s, 'name': 'Photos', 'kind': 'gallery',
      'visibility': visibility, 'posting': 'members',
    }))));
    final room = made!.json['room'] as String;
    final pic = List<int>.generate(400, (i) => i * 3 & 0xff);
    final up = await a.call('POST', '/api/xprs/file/${refOf(pic)}', {'room': room, 'session': s},
        Uint8List.fromList(pic));
    expect(up!.status, 200);
    final ev = 't:blog f:${a.visitor!.call} d:$room ts:${ts()} title:field-day m:On the hill';
    final evWire = a.visitor!.sign(ev)!;
    expect((await a.call('POST', '/api/xprs/send', const {}, Uint8List.fromList(utf8.encode(evWire))))!.status, 200);
    final eid = xprsIdentifier(XprsPacket.parse(evWire)!);
    for (var i = 0; i < n; i++) {
      final w = a.visitor!.sign('t:message f:${a.visitor!.call} d:$room ts:${ts()} r:$eid file:${refOf(pic)} m:photo $i')!;
      expect((await a.call('POST', '/api/xprs/send', const {}, Uint8List.fromList(utf8.encode(w))))!.status, 200);
      final id = xprsIdentifier(XprsPacket.parse(w)!);
      await a.send('t:file f:${a.visitor!.call} d:$room ts:${ts()} r:$id file:${refOf(pic)} size:400B name:p$i.jpg');
    }
    return (room, eid, pic);
  }

  test('a visitor the station has never heard posts its identity and gets a session', () async {
    final b = visit(bob, _bob, known: false);
    expect(await b.session(), isNotNull);
    expect(keys[bob], isNotNull, reason: 'the 409 was answered with the identity');
    expect(await b.session(), isNotNull);
  });

  test('a gallery is browsed as the page does: rooms, events, photos, likes, the file', () async {
    final a = visit(alice, _alice, lan: true);
    final (room, eid, pic) = await gallery(a);
    final b = visit(bob, _bob);
    final rooms = (await b.rooms())!;
    expect(rooms.single.call, room);
    expect(rooms.single.kind, 'gallery');
    expect(rooms.single.isCollection, isTrue);
    final topics = (await b.topics(room))!;
    expect(topics.single.id, eid);
    expect(topics.single.title, 'field-day');
    var c = (await b.collection(room))!;
    final item = c.inFolder(eid).single;
    expect(item.caption, 'photo 0');
    expect(item.preview, refOf(pic));
    expect(item.ref, refOf(pic));
    expect(item.name, 'p0.jpg');
    expect(item.likes, 0);
    expect((await b.send('t:reaction f:$bob d:$room ts:${ts()} r:${item.id} add:like'))!.status, 200);
    c = (await b.collection(room))!;
    expect(c.inFolder(eid).single.likes, 1);
    expect(c.inFolder(eid).single.liked, isTrue);
    final f = (await b.file(item.ref))!;
    expect(f.status, 200);
    expect(f.bytes, pic);
  });

  test('a private room is listed and served to its members only', () async {
    final a = visit(alice, _alice, lan: true);
    final (room, eid, pic) = await gallery(a, visibility: 'private');
    final b = visit(bob, _bob);
    expect((await b.rooms())!.where((r) => r.call == room), isEmpty);
    expect(await b.collection(room), isNull);
    expect((await b.file(refOf(pic)))!.status, 403);
    expect((await a.rooms())!.single.private, isTrue);
    expect((await a.collection(room))!.inFolder(eid), hasLength(1));
    expect((await a.file(refOf(pic)))!.status, 200);
  });

  test('a long collection is read a page at a time', () async {
    final a = visit(alice, _alice, lan: true);
    final (room, eid, _) = await gallery(a, n: 12);
    final c = (await a.collection(room, limit: 8))!;
    expect(c.items.length, lessThan(12));
    expect(c.more, isTrue);
    while (c.more) {
      await a.collection(room, into: c, limit: 8);
    }
    expect(c.inFolder(eid), hasLength(12));
    expect(c.inFolder(eid).every((i) => i.ref.isNotEmpty), isTrue,
        reason: 'a file listed on another page than its item still joins it');
  });

  test('a file larger than one answer crosses a part at a time, to its members only', () async {
    final a = visit(alice, _alice, lan: true);
    final (room, eid, _) = await gallery(a, visibility: 'private');
    final s = (await a.session())!;
    final big = Uint8List.fromList(List<int>.generate(700 * 1024, (i) => (i * 7 + i ~/ 251) & 0xff));
    expect((await a.call('POST', '/api/xprs/file/${refOf(big)}', {'room': room, 'session': s}, big))!.status, 200);
    final w = a.visitor!.sign('t:message f:$alice d:$room ts:${ts()} r:$eid file:${refOf(big)} m:film')!;
    expect((await a.call('POST', '/api/xprs/send', const {}, Uint8List.fromList(utf8.encode(w))))!.status, 200);
    final got = BytesBuilder();
    var parts = 0, size = 0;
    expect(await a.fileParts(refOf(big), (b, o, n) async {
      expect(o, got.length);
      got.add(b);
      parts++;
      size = n;
    }), 200);
    expect(parts, 3);
    expect(size, big.length);
    expect(crypto.sha256.convert(got.toBytes()), crypto.sha256.convert(big));
    // Resumed from what a stopped fetch has.
    final rest = BytesBuilder();
    expect(await a.fileParts(refOf(big), (b, o, n) async => rest.add(b), from: 600 * 1024), 200);
    expect(rest.length, 100 * 1024);
    final b = visit(bob, _bob);
    expect(await b.fileParts(refOf(big), (b, o, n) async => fail('served to a stranger')), 403);
  });

  test('a screen reads at once and is told when the visit answered', () async {
    final a = visit(alice, _alice, lan: true);
    final (room, eid, pic) = await gallery(a, n: 3);
    final b = visit(bob, _bob);
    final browse = StationBrowse.instance
      ..visit = ((_) async => b)
      ..faultOf = ((_) => '');
    Future<Map<String, dynamic>> settled(Map<String, dynamic> Function() read) async {
      var r = read();
      for (var i = 0; i < 200 && (r['busy'] == true || r['state'] == 'loading'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        r = read();
      }
      return r;
    }

    expect(browse.offers('X3STAT')['state'], 'loading', reason: 'nobody waits on the network');
    final offers = await settled(() => browse.offers('X3STAT'));
    expect(offers['state'], 'ready');
    expect(offers['known'], isTrue);
    expect((offers['rooms'] as List).single['kind'], 'gallery');
    final folders = await settled(() => browse.folders('X3STAT', room));
    final f = (folders['folders'] as List).single as Map;
    expect(f['id'], eid);
    expect(f['count'], 3);
    expect(f['cover'], 'file:${refOf(pic)}');
    final items = browse.items('X3STAT', room, eid, offset: 1);
    expect(items['total'], 3);
    expect((items['items'] as List), hasLength(2));
    expect((items['items'] as List).first['file'], 'file:${refOf(pic)}');
    browse.forget('X3STAT');
  });

  test('hundreds of stations are read by scope and by page', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    XprsDevice dev(String call, List<String> bearers, int ageS) => XprsDevice(
        callsign: call, kind: XprsKind.user, fixed: false, evidence: XprsEvidence.air,
        bearers: bearers, reachable: true, services: const [], lastSeenMs: now - ageS * 1000);
    final browse = StationBrowse.instance
      ..presence = (() => [
            for (var i = 0; i < 300; i++) dev('X1G${i.toString().padLeft(3, '0')}', ['rns'], i),
            dev('X1LORA', ['lora', 'rns'], 5),
            dev('X1NEAR', ['rns', 'ble'], 50),
            dev('X3LAN', ['lan'], 9),
          ])
      ..heardHere = ((c) => c == 'X3LAN' ? {'pos': '38.7100,-9.1400'} : null)
      ..offersApi = ((c) => c == 'X3LAN')
      ..announced = ((_) => null)
      ..here = (() => (lat: 38.7077, lon: -9.1365));
    final all = browse.list();
    expect(all['counts'], {'local': 2, 'regional': 1, 'global': 300, 'all': 303});
    final rows = all['rows'] as List;
    expect(rows, hasLength(StationBrowse.pageMax), reason: 'never the whole list');
    expect([for (final r in rows.take(3)) r['call']], ['X3LAN', 'X1NEAR', 'X1LORA'],
        reason: 'the nearest class first; what can be browsed first within it');
    expect(rows.first['api'], isTrue);
    expect(rows.first['dist_m'], inInclusiveRange(350, 450));
    expect(rows[1]['reach'], 'local', reason: 'classed by the nearest bearer it is heard on');
    final global = browse.list(scope: 'global', offset: 290);
    expect(global['total'], 300);
    expect(global['rows'], hasLength(10));
    expect(browse.list(search: 'lor')['total'], 1);
  });

  test('a proof holds only for the station, this link and this nonce', () {
    final station = 'X3${NostrCrypto.deriveCallsign(HEX.encode(XprsCrypto.publicKeyXOnly(_station)))}';
    final id = _signed('t:identity f:$station ts:${ts()} k:${_npubOf(_station)}', _station);
    Map<String, String> proof(String link, String nonce, [BigInt? by]) => {
          'identity': id,
          'session': _signed('t:session f:$station ts:${ts()} m:$link.$nonce', by ?? _station),
        };
    expect(stationProofFault(proof('ab12', 'nonce123'), station, 'nonce123', 'ab12'), isNull);
    expect(stationProofFault(proof('ab12', 'nonce123'), station, 'nonce123', 'ffff'), isNotNull,
        reason: 'another link: a gateway replaying a proof it was given');
    expect(stationProofFault(proof('ab12', 'other000'), station, 'nonce123', 'ab12'), isNotNull);
    expect(stationProofFault(proof('ab12', 'nonce123', _bob), station, 'nonce123', 'ab12'), isNotNull);
    expect(stationProofFault(proof('ab12', 'nonce123'), 'X3OTHR', 'nonce123', 'ab12'), isNotNull);
    expect(stationProofFault(null, station, 'nonce123', 'ab12'), isNotNull);
  });
}
