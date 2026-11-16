/*
 * The station's visitor API over a Reticulum link (spec/API-HTTP.md, "The
 * same API over a Reticulum link"): a browser through a gateway, or any
 * Reticulum client, opens a link to the station's xprs/wapp destination and
 * sends requests for [kXprsApiRequestPath]. Each carries one HTTP-shaped call
 * and is answered by the same [WebChatApi.handle] the HTTP server calls, so
 * nothing about the API differs but the transport.
 *
 * Request data (msgpack map): m method, p path, q query (string map),
 * b body (bytes or string), h headers (string map, optional: `Range` on a
 * file, answered 206 with `Content-Range` as over HTTP, which is how a file
 * larger than one answer crosses a link, a part at a time). Response data: s status, t content type,
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

/// The answer to one `/xprs/api` request: [data] is the request map, the
/// result the response map. [peer] names the link (never a local visitor).
Future<Object?> webChatLinkAnswer(WebChatApi api, Object? data, String peer) async {
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
  final range = _rangeOf(data['h']);
  if (m == 'GET' && range != null && p.startsWith(_filePath)) {
    return _filePart(api, p.substring(_filePath.length), q['session'], range);
  }
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
}

/// Serve [api] over Reticulum links to this node's xprs/wapp destination.
void serveWebChatOverRns(WebChatApi api, {RnsService? rns}) {
  (rns ?? RnsService.instance).serveRequests(kXprsApiRequestPath,
      (data, link) => webChatLinkAnswer(api, data, 'rns:${_hex(link.linkId)}'));
  (rns ?? RnsService.instance).serveRequests(kXprsProveRequestPath,
      (data, link) => webChatLinkProof(api, data, link.linkId));
}

/// The answer to one `/xprs/prove` request on link [linkId]: `{session,
/// identity}`, or null when [data] is no nonce or this node cannot sign.
Future<Object?> webChatLinkProof(WebChatApi api, Object? data, Uint8List? linkId) async {
  final sign = api.signAsStation;
  final nonce = data is String ? data : data is List<int> ? utf8.decode(data, allowMalformed: true) : '';
  if (sign == null || !RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(nonce)) return null;
  final me = api.selfCallsign();
  final linkHex = _hexAll(linkId);
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
  // A node that keeps no copy of its own identity (a phone airs it and
  // archives what it hears) signs one now.
  identity ??= api.ownIdentity?.call();
  return {'session': session?.encode(), 'identity': identity};
}

const String _filePath = '/api/xprs/file/';

/// The most one ranged answer carries: a part crosses the link as a
/// Resource, and a smaller one keeps the link answering other calls between.
const int kXprsLinkPartMax = 256 * 1024;

/// `Range: bytes=a-b` (or `a-`) from the request's headers, as (first, last
/// or -1); null when there is none or it is not that form.
(int, int)? _rangeOf(Object? headers) {
  if (headers is! Map) return null;
  String? v;
  headers.forEach((k, x) {
    if ('$k'.toLowerCase() == 'range') v = '$x';
  });
  final m = v == null ? null : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(v!.trim());
  if (m == null) return null;
  return (int.parse(m[1]!), m[2]!.isEmpty ? -1 : int.parse(m[2]!));
}

/// One part of a held file: the audience rule of the whole file
/// ([WebChatApi.openFile]), read from the store without holding the rest.
Map<String, Object?> _filePart(WebChatApi api, String ref, String? session, (int, int) range) {
  final f = api.openFile(ref, session: session);
  final no = f.reply;
  if (no != null) return {'s': no.status, 't': 'application/json', 'b': _json(no.json)};
  final first = range.$1;
  if (first >= f.size) {
    return {'s': 416, 't': 'application/json', 'b': _json({'ok': false, 'error': 'past the end'}),
        'h': {'Content-Range': 'bytes */${f.size}'}};
  }
  var last = range.$2 < 0 || range.$2 >= f.size ? f.size - 1 : range.$2;
  if (last - first + 1 > kXprsLinkPartMax) last = first + kXprsLinkPartMax - 1;
  final bytes = f.read(first, last - first + 1);
  if (bytes == null) return {'s': 404, 't': 'application/json', 'b': _json({'ok': false, 'error': 'not held'})};
  return {
    's': 206,
    't': f.contentType,
    'b': bytes,
    'h': {...f.headers, 'Content-Range': 'bytes $first-$last/${f.size}', 'Accept-Ranges': 'bytes'},
  };
}

String _hexAll(Uint8List? b) =>
    b == null ? '' : b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _json(Object o) => Uint8List.fromList(utf8.encode(jsonEncode(o)));

String _hex(Uint8List? b) =>
    b == null ? '' : b.take(8).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
