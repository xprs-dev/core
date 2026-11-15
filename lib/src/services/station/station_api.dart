/*
 * A visitor's side of the station API (spec/API-HTTP.md): what the portal
 * page does in JavaScript, in Dart, so a phone browses another station (its
 * rooms, galleries, music, libraries) exactly as a browser does.
 *
 * ONE client for every deployment that serves the API (the firmware, the
 * server edition, a phone): the calls are HTTP-shaped and a [StationCarrier]
 * takes them there. Over a Reticulum link that is `/xprs/api`
 * ([stationLinkCarrier]); a test hands the calls straight to a WebChatApi.
 *
 * The visitor is the active profile: it posts its `t:identity`, signs the
 * station's nonce (`t:session`) and holds the token, which is what opens the
 * private rooms it is a member of. Nothing here decides what the visitor may
 * see; the station does, and answers 403/404.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart';

import '../xprs/xprs_id.dart';
import '../xprs/xprs_packet.dart';
import '../xprs/xprs_sig.dart';
import '../xprs/xprs_vocab.dart' show xprsNowTs;

/// One answer: the HTTP status, and a body that is JSON or bytes.
class StationReply {
  const StationReply(this.status,
      {this.json = const {}, this.bytes, this.contentType, this.headers = const {}});
  final int status;
  final Map<String, dynamic> json;
  final Uint8List? bytes;
  final String? contentType;
  final Map<String, String> headers;
  bool get ok => status >= 200 && status < 300;
}

/// Takes one API call to the station; null when it could not be reached.
typedef StationCarrier = Future<StationReply?> Function(
    String method, String path, Map<String, String> query, Uint8List? body,
    {Map<String, String> headers});

/// A room the station hosts, as `/api/rooms` lists it for this visitor.
class StationRoom {
  StationRoom(Map<String, dynamic> j)
      : call = '${j['call'] ?? ''}',
        name = '${j['name'] ?? ''}',
        about = '${j['about'] ?? ''}',
        kind = '${j['kind'] ?? 'chat'}',
        visibility = '${j['visibility'] ?? 'public'}',
        role = '${j['role'] ?? 'none'}',
        canPost = j['can_post'] == true,
        members = j['members'] is int ? j['members'] as int : 0;
  final String call, name, about, kind, visibility, role;
  final bool canPost;
  final int members;
  bool get private => visibility == 'private';

  /// A gallery, a music room or a library: folders of items with files.
  bool get isCollection => kind == 'gallery' || kind == 'music' || kind == 'library';

  Map<String, dynamic> toJson() => {
        'call': call, 'name': name, 'about': about, 'kind': kind,
        'private': private, 'role': role, 'can_post': canPost, 'members': members,
      };
}

/// A folder of a collection (an event, an album, a shelf) or a forum topic.
class StationTopic {
  StationTopic(Map<String, dynamic> j)
      : id = '${j['id'] ?? ''}',
        title = '${j['title'] ?? ''}',
        from = '${j['from'] ?? ''}',
        ts = j['ts'] is int ? j['ts'] as int : 0,
        replies = j['replies'] is int ? j['replies'] as int : 0;
  final String id, title, from;
  final int ts, replies;
  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'from': from, 'ts': ts, 'replies': replies};
}

/// One item of a collection: a photo, a track, a file.
class StationItem {
  StationItem({required this.id, required this.folder, required this.from,
      required this.ts, required this.caption, required this.preview});
  final String id, folder, from, caption;
  final int ts;

  /// The reference of the small picture shown in a grid ('' when none).
  final String preview;

  /// The file itself (XPRS.md 7.7.7), when its `t:file` was listed.
  String ref = '';
  String name = '';

  /// As the station wrote it (`2.1MB`, `400B`): shown, not computed with.
  String size = '';
  int likes = 0;
  bool liked = false;

  Map<String, dynamic> toJson() => {
        'id': id, 'folder': folder, 'from': from, 'ts': ts, 'caption': caption,
        'preview': preview, 'ref': ref, 'name': name, 'size': size,
        'likes': likes, 'liked': liked,
      };
}

/// A collection room's rows put together: items by folder, each with its
/// file and its likes. The page's `galTree`, one implementation for Dart.
class StationCollection {
  final Map<String, StationItem> items = {};
  final Map<String, List<String>> byFolder = {};

  /// The packets that name files (an item's preview, its `t:file`), with the
  /// identifier each has, newest read last: what a media index is told so a
  /// viewer knows the original a preview stands for. Emptied by the reader.
  final List<(XprsPacket, String)> named = [];

  /// True when the station had older rows than it sent: ask again with
  /// [oldestTs] as `until`.
  bool more = false;
  int oldestTs = 0;

  List<StationItem> inFolder(String id) =>
      [for (final i in byFolder[id] ?? const <String>[]) items[i]!];

  /// Fold [rows] (newest first, as the station sends them) into the tree.
  void add(List<dynamic> rows, {String me = ''}) {
    final orig = <String, XprsPacket>{};
    final likes = <String, Set<String>>{};
    for (final r in rows.reversed) {
      if (r is! Map) continue;
      final p = XprsPacket.parse('${r['wire'] ?? ''}');
      if (p == null) continue;
      final ts = r['ts'] is int ? r['ts'] as int : 0;
      if (ts > 0 && (oldestTs == 0 || ts < oldestTs)) oldestTs = ts;
      final to = p['r'] ?? '';
      if (to.isEmpty) continue;
      final from = '${r['from'] ?? p['f'] ?? ''}';
      if (p.type == 'message') {
        final id = '${r['id'] ?? xprsIdentifier(p)}';
        if (items.containsKey(id)) continue;
        items[id] = StationItem(id: id, folder: to, from: from, ts: ts,
            caption: p['m'] ?? '', preview: p['file'] ?? '');
        (byFolder[to] ??= []).add(id);
        if (p.has('file')) named.add((p, id));
      } else if (p.type == 'file') {
        orig[to] = p;
        named.add((p, '${r['id'] ?? xprsIdentifier(p)}'));
      } else if (p.type == 'reaction' && p['add'] == 'like') {
        (likes[to] ??= {}).add(from);
      }
    }
    orig.forEach((id, p) {
      final it = items[id];
      if (it == null) return;
      it.ref = p['file'] ?? '';
      it.name = p['name'] ?? '';
      it.size = p['size'] ?? '';
    });
    likes.forEach((id, who) {
      final it = items[id];
      if (it == null) return;
      it.likes += who.length;
      if (me.isNotEmpty && who.contains(me)) it.liked = true;
    });
  }
}

/// Why a station's proof was refused, or null when it holds: its callsign
/// derives from the key in `identity`, both wires are signed with that key,
/// and the session names this link and our nonce. A relay or a gateway in
/// the middle can produce none of the three.
String? stationProofFault(Object? proof, String call, String nonce, String linkHex) {
  if (proof is! Map) return 'the station sent no proof';
  final c = call.toUpperCase().split('-').first;
  final id = XprsPacket.parse('${proof['identity'] ?? ''}');
  final sess = XprsPacket.parse('${proof['session'] ?? ''}');
  if (id == null || sess == null) return 'the station sent no proof';
  String bare(String? f) => (f ?? '').toUpperCase().split('-').first;
  if (bare(id['f']) != c) return 'the identity is not $c';
  final npub = id['k'];
  if (npub == null) return 'the identity carries no key';
  final String keyHex;
  try {
    keyHex = NostrCrypto.decodeNpub(npub);
  } catch (_) {
    return 'the key is not an npub';
  }
  if (c.length < 4 ||
      NostrCrypto.deriveCallsign(keyHex, length: c.length - 2) != c.substring(2)) {
    return '$c is not derived from that key';
  }
  final pub = Uint8List.fromList([
    for (var i = 0; i < 32; i++) int.parse(keyHex.substring(2 * i, 2 * i + 2), radix: 16)
  ]);
  if (xprsVerify(id, pub) != XprsSigState.verified) return 'the identity is not signed by its key';
  if (bare(sess['f']) != c) return 'the session is not from $c';
  if (sess['m'] != '$linkHex.$nonce') return 'the session does not name this link';
  if (xprsVerify(sess, pub) != XprsSigState.verified) return 'the session is not signed by $c';
  return null;
}

/// Who is visiting: the callsign, its signed `t:identity`, and its signature.
class StationVisitor {
  const StationVisitor({required this.call, required this.identityWire, required this.sign});
  final String call;
  final String? Function() identityWire;

  /// [wire] signed with the visitor's key, or null when no key is held.
  final String? Function(String wire) sign;
}

/// One visit to one station: the calls the portal page makes, typed.
class StationVisit {
  StationVisit(this.station, this._carry, {this.visitor});

  final String station;
  final StationCarrier _carry;
  final StationVisitor? visitor;

  /// Calls made and calls that got no answer (a `perf:` line reads these).
  static int calls = 0, unanswered = 0;

  Map<String, dynamic>? _services;
  String? _session;
  Future<String?>? _opening;
  int lastUsedMs = 0;

  Future<StationReply?> call(String method, String path,
      [Map<String, String> query = const {}, Uint8List? body,
      Map<String, String> headers = const {}]) async {
    calls++;
    lastUsedMs = DateTime.now().millisecondsSinceEpoch;
    final r = await _carry(method, path, query, body, headers: headers);
    if (r == null) unanswered++;
    return r;
  }

  /// `/api/services`: what the station does (asked once per visit).
  Future<Map<String, dynamic>?> services() async {
    if (_services != null) return _services;
    final r = await call('GET', '/api/services');
    if (r == null || !r.ok) return null;
    return _services = r.json;
  }

  /// The session token, proving the visitor's key once per visit; null when
  /// there is no visitor key or the station refused. A station that has not
  /// heard the visitor's key answers 409: the identity is posted and the
  /// proof tried once more, as the page does.
  Future<String?> session() {
    if (_session != null) return Future.value(_session);
    return _opening ??= _openSession().whenComplete(() {
      _opening = null;
    });
  }

  Future<String?> _openSession() async {
    final v = visitor;
    if (v == null) return null;
    for (var attempt = 0; attempt < 2; attempt++) {
      final n = await call('GET', '/api/session');
      final nonce = n?.json['nonce'];
      if (n == null || !n.ok || nonce is! String) return null;
      final wire = v.sign('t:session f:${v.call} ts:${xprsNowTs()} m:$nonce');
      if (wire == null) return null;
      final r = await call('POST', '/api/session', const {},
          Uint8List.fromList(utf8.encode(jsonEncode({'wire': wire}))));
      if (r == null) return null;
      if (r.ok && r.json['session'] is String) return _session = r.json['session'] as String;
      if (r.status != 409 || attempt > 0) return null;
      final id = v.identityWire();
      if (id == null) return null;
      final sent = await call('POST', '/api/xprs/send', const {},
          Uint8List.fromList(utf8.encode(jsonEncode({'wire': id}))));
      if (sent == null || !sent.ok) return null;
    }
    return null;
  }

  Future<Map<String, String>> _withSession([Map<String, String> q = const {}]) async {
    final s = await session();
    return {...q, if (s != null) 'session': s};
  }

  /// The rooms this visitor may see, private ones it belongs to included.
  /// Null when the station hosts none (no `/api/rooms`).
  Future<List<StationRoom>?> rooms() async {
    final r = await call('GET', '/api/rooms', await _withSession());
    final list = r?.json['rooms'];
    if (r == null || !r.ok || list is! List) return null;
    return [for (final j in list) if (j is Map<String, dynamic>) StationRoom(j)];
  }

  /// The folders of a collection, or the topics of a forum.
  Future<List<StationTopic>?> topics(String room) async {
    final r = await call('GET', '/api/rooms', await _withSession({'topics': room}));
    final list = r?.json['topics'];
    if (r == null || !r.ok || list is! List) return null;
    return [for (final j in list) if (j is Map<String, dynamic>) StationTopic(j)];
  }

  /// Rows of a room's history (newest first), one page.
  Future<StationReply?> history(Map<String, String> query) async =>
      call('GET', '/api/xprs/history', await _withSession(query));

  /// A collection room's items, a page at a time: the first call reads the
  /// newest [limit] rows; pass the same [into] again to read what is older.
  /// A station answers with fewer rows than asked when that is what fits its
  /// memory (the API's "What fits"), so "more" is "this page had rows".
  Future<StationCollection?> collection(String room,
      {StationCollection? into, int limit = 200}) async {
    final t = into ?? StationCollection();
    final r = await history({
      'room': room,
      'kind': 'message,file,reaction',
      'limit': '$limit',
      if (into != null && into.oldestTs > 0) 'until': '${into.oldestTs - 1}',
    });
    final rows = r?.json['rows'];
    if (r == null || !r.ok || rows is! List) {
      if (into == null) return null;
      t.more = false;
      return t;
    }
    t.add(rows, me: visitor?.call ?? '');
    t.more = rows.isNotEmpty && rows.length >= (limit < 200 ? limit : 200) ~/ 2;
    return t;
  }

  /// A file by reference, whole, when it fits one answer (a preview, a
  /// photo): 413 when it does not, and [fileParts] reads it then.
  Future<StationReply?> file(String ref) async =>
      call('GET', '/api/xprs/file/$ref', await _withSession());

  /// A file of any size, a part at a time (`Range`, answered 206): each part
  /// goes to [onPart] with its offset and the file's size, so the caller
  /// writes it to disk and never holds the file. Starts at [from] (a fetch
  /// that stopped goes on from what it has). The status that ended it: 200
  /// when the whole file was read, the station's refusal otherwise, 0 when
  /// it stopped answering. A station that does not cut answers the whole
  /// file to the first ask (one part), or 413.
  Future<int> fileParts(String ref,
      Future<void> Function(Uint8List part, int offset, int size) onPart,
      {int from = 0, int part = 256 * 1024}) async {
    final q = await _withSession();
    var at = from;
    while (true) {
      final r = await call('GET', '/api/xprs/file/$ref', q, null,
          {'Range': 'bytes=$at-${at + part - 1}'});
      if (r == null) return 0;
      final b = r.bytes;
      if (r.status == 200 && b != null) {
        if (at > 0 && b.length <= at) return 200;
        await onPart(at > 0 ? Uint8List.sublistView(b, at) : b, at, b.length);
        return 200;
      }
      if (r.status == 416) return 200;
      if (r.status != 206 || b == null || b.isEmpty) return r.status;
      final total = int.tryParse((r.headers['Content-Range'] ?? '').split('/').last) ?? 0;
      await onPart(b, at, total);
      at += b.length;
      if (total <= 0 || at >= total) return 200;
    }
  }

  /// Post a signed packet as the visitor (a like, a message in a room).
  Future<StationReply?> send(String unsignedWire) async {
    final wire = visitor?.sign(unsignedWire);
    if (wire == null) return null;
    return call('POST', '/api/xprs/send', const {},
        Uint8List.fromList(utf8.encode(jsonEncode({'wire': wire}))));
  }
}

/// A [StationCarrier] over a Reticulum request link: each call is one
/// `/xprs/api` request.
StationCarrier stationLinkCarrier(RnsRequestClient link,
        {Duration timeout = const Duration(seconds: 60)}) =>
    stationRequestCarrier((data) => link.request('/xprs/api', data, timeout: timeout));

/// A [StationCarrier] over anything that takes the `/xprs/api` request map
/// and gives the response map (spec/API-HTTP.md, "The same API over a
/// Reticulum link").
StationCarrier stationRequestCarrier(Future<Object?> Function(Object? data) ask) {
  return (method, path, query, body, {headers = const {}}) async {
    final a = await ask({
      'm': method, 'p': path, 'q': query,
      if (body != null) 'b': body,
      if (headers.isNotEmpty) 'h': headers,
    });
    if (a is! Map) return null;
    final status = a['s'] is int ? a['s'] as int : 0;
    final type = '${a['t'] ?? ''}';
    final h = <String, String>{};
    final hm = a['h'];
    if (hm is Map) hm.forEach((k, v) => h['$k'] = '$v');
    final b = a['b'];
    final bytes = b is Uint8List
        ? b
        : b is List<int>
            ? Uint8List.fromList(b)
            : b is String
                ? Uint8List.fromList(utf8.encode(b))
                : Uint8List(0);
    if (type.startsWith('application/json')) {
      try {
        final j = jsonDecode(utf8.decode(bytes, allowMalformed: true));
        if (j is Map<String, dynamic>) return StationReply(status, json: j, contentType: type);
      } catch (_) {}
      return StationReply(status, contentType: type);
    }
    return StationReply(status, bytes: bytes, contentType: type, headers: h);
  };
}
