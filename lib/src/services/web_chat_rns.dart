/*
 * The station's visitor API over a Reticulum link (spec/API-HTTP.md, "The
 * same API over a Reticulum link"): a browser through a gateway, or any
 * Reticulum client, opens a link to the station's xprs/wapp destination and
 * sends requests for [kXprsApiRequestPath]. Each carries one HTTP-shaped call
 * and is answered by the same [WebChatApi.handle] the HTTP server calls, so
 * nothing about the API differs but the transport.
 *
 * Request data (msgpack map): m method, p path, q query (string map),
 * b body (bytes or string). Response data: s status, t content type,
 * b body (bytes), h headers (string map, optional).
 *
 * The visitor is never on the station's own network: its peer is `rns:` and
 * the link id, so local-only acts (the admin claim, WiFi changes) stay closed.
 */
import 'dart:convert';
import 'dart:typed_data';

import 'reticulum/rns_service.dart';
import 'web_chat_api.dart';
import 'xprs/xprs_vocab.dart' show xprsNowTs;

/// The request path the API answers on.
const String kXprsApiRequestPath = '/xprs/api';

/// The request path the station proves itself on: the data is the client's
/// nonce; the answer is `{session, identity}`: a `t:session` signed by the
/// station whose `m:` is this link's id, a dot and the nonce, and the
/// station's latest signed `t:identity` (its `k:`). Only the holder of the
/// callsign's key signs the first, and only the far end of this link sees
/// the nonce, so a gateway in the middle cannot stand in for the station.
const String kXprsProveRequestPath = '/xprs/prove';

/// Serve [api] over Reticulum links to this node's xprs/wapp destination.
void serveWebChatOverRns(WebChatApi api, {RnsService? rns}) {
  (rns ?? RnsService.instance).serveRequests(kXprsApiRequestPath, (data, link) async {
    if (data is! Map) return {'s': 400, 't': 'application/json', 'b': _json({'ok': false, 'error': 'bad request'})};
    final m = '${data['m'] ?? 'GET'}'.toUpperCase();
    final p = '${data['p'] ?? ''}';
    if (!p.startsWith('/api/')) {
      return {'s': 404, 't': 'application/json', 'b': _json({'ok': false, 'error': 'not here'})};
    }
    final q = <String, String>{};
    final qm = data['q'];
    if (qm is Map) qm.forEach((k, v) => q['$k'] = '$v');
    final b = data['b'];
    Uint8List? raw;
    var body = '';
    if (b is List<int>) {
      raw = Uint8List.fromList(b);
      body = utf8.decode(raw, allowMalformed: true);
    } else if (b is String) {
      body = b;
    }
    final peer = 'rns:${_hex(link.linkId)}';
    final r = await api.handle(m, p, q, body, peer: peer, raw: raw);
    if (r.bytes != null) {
      return {
        's': r.status,
        't': r.contentType ?? 'application/octet-stream',
        'b': r.bytes,
        if (r.headers.isNotEmpty) 'h': r.headers,
      };
    }
    return {'s': r.status, 't': 'application/json', 'b': _json(r.json)};
  });
  (rns ?? RnsService.instance).serveRequests(kXprsProveRequestPath, (data, link) async {
    final sign = api.signAsStation;
    final nonce = data is String ? data : data is List<int> ? utf8.decode(data, allowMalformed: true) : '';
    if (sign == null || !RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(nonce)) return null;
    final me = api.selfCallsign();
    final linkHex = _hexAll(link.linkId);
    final session = sign('t:session f:$me ts:${xprsNowTs()} m:$linkHex.$nonce');
    final r = await api.handle('GET', '/api/xprs/history',
        {'call': me, 'kind': 'identity', 'limit': '20'}, '', peer: 'self');
    String? identity;
    final rows = r.json['rows'];
    if (rows is List) {
      for (final row in rows) {
        final w = row is Map ? '${row['wire'] ?? ''}' : '';
        if (w.contains(' k:') && w.contains(' sig:')) {
          identity = w;
          break;
        }
      }
    }
    return {'session': session?.encode(), 'identity': identity};
  });
}

String _hexAll(Uint8List? b) =>
    b == null ? '' : b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _json(Object o) => Uint8List.fromList(utf8.encode(jsonEncode(o)));

String _hex(Uint8List? b) =>
    b == null ? '' : b.take(8).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
