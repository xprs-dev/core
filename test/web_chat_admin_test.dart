// The station's administrator (spec/API-HTTP.md /api/admin): claimed once,
// from the station's own network, by a visitor who proved their key; and the
// settings it holds, enforced on what a visitor reads and posts.
import 'dart:convert';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

final _alice = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);
final _bob = BigInt.parse('fedcba0987654321fedcba0987654321', radix: 16);

String _signed(String wire, BigInt key) =>
    xprsSign(XprsPacket.parse(wire)!, key).encode();

void main() {
  late Map<String, Uint8List> keys;
  late List<String> received;
  const lan = '192.168.178.20', internet = '203.0.113.7';

  WebChatApi make({Map<String, bool> switches = const {}}) => WebChatApi(
        publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) => [
          {'type': 'message', 'from': 'X1AAA', 'to': '', 'own': false,
           'wire': 't:message f:X1AAA ts:2026-10-15_12:00:00 scope:local m:near'},
          {'type': 'message', 'from': 'X1BBB', 'to': '', 'own': false,
           'wire': 't:message f:X1BBB ts:2026-10-15_12:00:01 m:far'},
        ],
        held: (t) => 2,
        receive: received.add,
        mayAir: (_) => true,
        selfCallsign: () => 'X3PTZM',
        keyOf: (c) => keys[c],
        appPath: () => null,
        hostSwitches: switches,
      );

  setUp(() {
    keys = {
      'X1ALIC': XprsCrypto.publicKeyXOnly(_alice),
      'X1BOBB': XprsCrypto.publicKeyXOnly(_bob),
    };
    received = [];
  });

  Future<String> session(WebChatApi a, String call, BigInt key, String peer) async {
    final n = (await a.handle('GET', '/api/session', {}, '', peer: peer)).json['nonce'];
    final r = await a.handle('POST', '/api/session', {},
        _signed('t:session f:$call ts:2026-10-15_12:00:00 m:$n', key), peer: peer);
    return r.json['session'] as String;
  }

  Future<WebChatReply> act(WebChatApi a, String peer, Map<String, Object?> b) =>
      a.handle('POST', '/api/admin', {}, jsonEncode(b), peer: peer);

  test('private addresses are the station\'s network, public ones are not', () {
    for (final p in ['127.0.0.1', '10.1.2.3', '192.168.178.20', '172.20.0.1',
        '169.254.1.1', '100.64.0.9', '::1', 'fd88:41d1:1224::5', 'fe80::1%eth0',
        '::ffff:192.168.1.9']) {
      expect(isPrivateAddress(p), isTrue, reason: p);
    }
    for (final p in ['203.0.113.7', '2a02:908::1', '::ffff:8.8.8.8', '', 'x']) {
      expect(isPrivateAddress(p), isFalse, reason: p);
    }
  });

  test('services names the station and offers the admin page', () async {
    final r = await make().handle('GET', '/api/services', {}, '');
    expect(r.json['station'], 'X3PTZM');
    expect((r.json['page'] as Map)['admin'], true);
  });

  test('services says where the internet reaches the web chat when the host '
      'knows, and the page then gets its Station view', () async {
    final a = make();
    var r = await a.handle('GET', '/api/services', {}, '');
    expect(r.json.containsKey('urls'), isFalse);
    expect((r.json['page'] as Map)['tabs'], isNot(contains('station')));
    a.addresses = () => const WebAddresses(
        urls: ['https://1-2-3-4.nip.io/'], pending: ['2a02-1--5.nip.io']);
    r = await a.handle('GET', '/api/services', {}, '');
    expect(r.json['urls'], ['https://1-2-3-4.nip.io/']);
    expect(r.json['urls_pending'], ['2a02-1--5.nip.io']);
    expect((r.json['page'] as Map)['tabs'], contains('station'));
  });

  test('with no admin, a proven visitor on the network claims it', () async {
    final a = make();
    final s = await session(a, 'X1ALIC', _alice, lan);
    var st = (await a.handle('GET', '/api/admin', {'session': s}, '', peer: lan)).json;
    expect(st['admin'], isNull);
    expect(st['claimable'], isTrue);
    final r = await act(a, lan, {'action': 'claim', 'session': s});
    expect(r.status, 200);
    expect(r.json['admin'], 'X1ALIC');
    expect(r.json['you'], isTrue);
    expect(r.json['settings'], WebChatApi.settingDefaults);
    // Nobody else can claim it now.
    final b = await session(a, 'X1BOBB', _bob, lan);
    expect((await act(a, lan, {'action': 'claim', 'session': b})).status, 409);
    st = (await a.handle('GET', '/api/admin', {'session': b}, '', peer: lan)).json;
    expect(st['you'], isFalse);
    expect(st.containsKey('settings'), isFalse);
  });

  test('a claim from the internet, or without a session, is refused', () async {
    final a = make();
    final s = await session(a, 'X1ALIC', _alice, internet);
    expect((await a.handle('GET', '/api/admin', {'session': s}, '', peer: internet))
        .json['claimable'], isFalse);
    expect((await act(a, internet, {'action': 'claim', 'session': s})).status, 403);
    expect((await act(a, lan, {'action': 'claim', 'session': 'made-up'})).status, 403);
    expect(a.adminCall, isNull);
  });

  test('a host switch (auto_update) is reported with its default and set '
      'like a setting; a station without it refuses the name', () async {
    final a = make(switches: {'auto_update': true});
    final s = await session(a, 'X1ALIC', _alice, lan);
    final claimed = await act(a, lan, {'action': 'claim', 'session': s});
    expect(claimed.json['settings']['auto_update'], isTrue);
    expect((await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'auto_update': 'off'}})).status, 400);
    final off = await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'auto_update': false}});
    expect(off.json['settings']['auto_update'], isFalse);
    expect(a.settings['auto_update'], isFalse);
    final plain = make();
    final s2 = await session(plain, 'X1ALIC', _alice, lan);
    await act(plain, lan, {'action': 'claim', 'session': s2});
    expect((await act(plain, lan, {'action': 'set', 'session': s2,
        'settings': {'auto_update': false}})).status, 400);
    expect(plain.settings.containsKey('auto_update'), isFalse);
  });

  test('settings: only the admin sets them, and only known values', () async {
    final a = make();
    final s = await session(a, 'X1ALIC', _alice, lan);
    await act(a, lan, {'action': 'claim', 'session': s});
    final b = await session(a, 'X1BOBB', _bob, lan);
    expect((await act(a, lan, {'action': 'set', 'session': b,
        'settings': {'local_private': false}})).status, 403);
    expect((await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'who_may_post': 'admins'}})).status, 400);
    expect((await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'colour': 'red'}})).status, 400);
    final r = await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'local_private': false, 'who_may_post': 'local'}});
    expect(r.json['settings'], {
      'local_private': false, 'who_may_post': 'local', 'who_may_alert': 'moderators',
      'reach_alerts': 'regional', 'reach_posts': 'regional', 'reach_chat': 'global',
      'follow': '', 'peers_mode': 'open', 'peers': '',
    });
    // The mesh settings: a reach word, a mode, and lists of callsigns.
    expect((await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'reach_alerts': 'far'}})).status, 400);
    expect((await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'peers': 'X3TOWN not-a-call'}})).status, 400);
    expect((await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'follow': 'npub1notlongenough'}})).status, 400);
    Map<String, Object>? told;
    a.onSettings = (m) => told = m;
    final npub = 'npub1${'q' * 58}';
    final mesh = await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'reach_alerts': 'global', 'peers_mode': 'named', 'peers': ' x3town, X3HUB ',
                     'follow': 'X1ALIC $npub'}});
    expect(mesh.json['settings']['peers'], 'X3TOWN X3HUB');
    expect(mesh.json['settings']['follow'], 'X1ALIC $npub');
    expect(told?['peers_mode'], 'named');
    // What the page defines for itself (page_<name>): a bounded string,
    // stored as given, reported under page on /api/services, gone when emptied.
    expect((await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'page_css': 'x' * (WebChatApi.maxPageSettingChars + 1)}})).status, 400);
    expect((await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'page_': 'x'}})).status, 400);
    expect((await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'page_banner': 1}})).status, 400);
    final set = await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'page_banner': '<b>Hill</b>', 'page_css': '.logo{color:red}'}});
    expect(set.json['settings']['page_banner'], '<b>Hill</b>');
    final page = (await a.handle('GET', '/api/services', {}, '', peer: lan)).json['page'] as Map;
    expect(page['banner'], '<b>Hill</b>');
    expect(page['css'], '.logo{color:red}');
    expect((await act(a, lan, {'action': 'set', 'session': s,
        'settings': {'page_css': ''}})).json['settings'].containsKey('page_css'), false);
    // The admin manages from anywhere once claimed (the internet included).
    final far = await session(a, 'X1ALIC', _alice, internet);
    expect((await act(a, internet, {'action': 'set', 'session': far,
        'settings': {'who_may_post': 'everyone'}})).status, 200);
  });

  test('released, the station can be claimed again', () async {
    final a = make();
    final s = await session(a, 'X1ALIC', _alice, lan);
    await act(a, lan, {'action': 'claim', 'session': s});
    expect((await act(a, lan, {'action': 'release', 'session': s})).json['admin'], isNull);
    final b = await session(a, 'X1BOBB', _bob, lan);
    expect((await act(a, lan, {'action': 'claim', 'session': b})).json['admin'], 'X1BOBB');
  });

  test('a callsign whose key changed is not the admin any more', () async {
    final a = make();
    final s = await session(a, 'X1ALIC', _alice, lan);
    await act(a, lan, {'action': 'claim', 'session': s});
    keys['X1ALIC'] = XprsCrypto.publicKeyXOnly(_bob);
    expect((await a.handle('GET', '/api/admin', {'session': s}, '', peer: lan))
        .json['you'], isFalse);
  });

  group('the settings, enforced', () {
    Future<List> rows(WebChatApi a, String peer, [Map<String, String>? q]) async =>
        (await a.handle('GET', '/api/xprs/history', q ?? {}, '', peer: peer))
            .json['rows'] as List;

    test('the Local room is kept from the internet by default', () async {
      final a = make();
      expect(await rows(a, lan), hasLength(2));
      final far = await rows(a, internet);
      expect(far.map((r) => r['from']), ['X1BBB']);
      expect(await rows(a, internet, {'room': 'local'}), isEmpty);
    });

    test('an admin may open it', () async {
      final a = make();
      final s = await session(a, 'X1ALIC', _alice, lan);
      await act(a, lan, {'action': 'claim', 'session': s});
      await act(a, lan, {'action': 'set', 'session': s,
          'settings': {'local_private': false}});
      expect(await rows(a, internet), hasLength(2));
    });

    test('who may post: everyone, the network, nobody', () async {
      final a = make();
      final s = await session(a, 'X1ALIC', _alice, lan);
      await act(a, lan, {'action': 'claim', 'session': s});
      final w = _signed('t:message f:X1BOBB ts:2026-10-15_12:00:00 m:hi', _bob);
      Future<int> post(String peer) async =>
          (await a.handle('POST', '/api/xprs/send', {}, w, peer: peer)).status;
      expect(await post(internet), 200);
      await act(a, lan, {'action': 'set', 'session': s, 'settings': {'who_may_post': 'local'}});
      expect(await post(internet), 403);
      expect(await post(lan), 200);
      await act(a, lan, {'action': 'set', 'session': s, 'settings': {'who_may_post': 'nobody'}});
      expect(await post(lan), 403);
    });
  });
}
