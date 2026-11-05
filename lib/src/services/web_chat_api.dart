/*
 * The station API a visitor's browser gets from this phone: just enough of
 * spec/API-HTTP.md for the web chat page (the sibling repo `webchat`), and
 * nothing else.
 *
 * It is NOT the remote API. That one is loopback-only, off by default, and
 * switches bearers and administers groups; this one faces whoever joined the
 * hotspot, so it is an allowlist of three reads and one write, with the rules
 * that makes safe on a phone that holds its owner's mail:
 *
 *   GET  /api/services      what this host offers: which tabs, and `app`
 *   GET  /api/xprs/history  PUBLIC rows only (no `d:`, no mail, no group)
 *   POST /api/xprs/send     a finished wire the visitor signed in the browser
 *   GET/POST /api/admin     the station's administrator and their settings
 *
 * The administrator is a visitor who proved their key (a session, below).
 * A station with none lets the first such visitor ON ITS OWN NETWORK claim
 * it: that is the moment after a board is flashed or a server installed. A
 * visitor from the internet cannot, or the first stranger to find a public
 * station would own it. The settings say what visitors from outside the
 * station's network may see and who may post.
 *
 * The browser holds the key and signs; this host never sees a private key and
 * never signs for the visitor. A wire is refused unless it is signed, is not
 * written as this station, is one of the few types a visitor may post, and
 * fits the packet. What it accepts goes through the core's one receive door
 * (the callback below); the bridge carries it on, so the rest of the mesh sees
 * the visitor's own packet, with the visitor's own signature.
 *
 * Pure over its callbacks (no sockets, no singletons) so every rule is tested
 * without a phone; ShareAppService is the socket half.
 */
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:hex/hex.dart';

import '../platform/key_value_store.dart';

import 'xprs/xprs_archive.dart' show XprsArchive;
import 'xprs/xprs_id.dart';
import 'xprs/xprs_packet.dart';
import 'xprs/xprs_sig.dart';
import 'xprs/xprs_vocab.dart' show xprsParseTs, xprsScope, XprsScope;

/// One answer: a status and a JSON body.
class WebChatReply {
  final int status;
  final Map<String, dynamic> json;
  const WebChatReply(this.status, this.json);
}

class WebChatApi {
  /// Rows of [types] that are PUBLIC (undirected), newest first.
  final List<Map<String, dynamic>> Function(
      {int? sinceMs,
      int? untilMs,
      required List<String> types,
      String? from,
      String? visitor,
      String? room,
      required int limit}) publicRows;

  /// How many public rows the archive holds (the page's "N packets held").
  final int Function(List<String> types) held;

  /// A visitor's wire, to the core's receive door as heard on the hotspot.
  /// That is all: carrying it on to the other bearers is the bridge's and the
  /// digipeater's job, under the owner's policy and the hop budget, the same
  /// as for a packet heard on any other bearer.
  final void Function(String wire) receive;

  /// Whether the core would air this packet (a closed group this station
  /// does not belong to is not ours to post into).
  final bool Function(XprsPacket p) mayAir;

  /// This station's own callsign, which a visitor must never write as `f:`.
  final String Function() selfCallsign;

  /// The key a callsign is bound to, when this station has heard one.
  final Uint8List? Function(String baseCallsign) keyOf;

  /// The path of the download page, or null when this copy cannot be handed
  /// on (an app store install in pieces).
  final String? Function() appPath;

  final DateTime Function() now;

  /// Where the administrator and the settings are kept. Null: in memory
  /// (they last until the host restarts).
  final KeyValueStore? store;

  /// Whether a visitor's address is on this station's own network. Default
  /// [isPrivateAddress]; a host that knows its own public prefixes (an IPv6
  /// LAN has no private addresses) widens it.
  final bool Function(String peer) isLocalPeer;

  WebChatApi({
    required this.publicRows,
    required this.held,
    required this.receive,
    required this.mayAir,
    required this.selfCallsign,
    required this.keyOf,
    required this.appPath,
    DateTime Function()? now,
    this.store,
    bool Function(String peer)? isLocalPeer,
  })  : now = now ?? DateTime.now,
        isLocalPeer = isLocalPeer ?? isPrivateAddress;

  /// What a visitor may read: conversation, not machinery. An identity is a
  /// public broadcast and is how a browser finds the key a callsign is bound
  /// to, to seal to it or to open what it sealed.
  static const Set<String> readable = {
    'message', 'reaction', 'status', 'info', 'warning', 'event', 'blog', 'sos',
    'identity',
  };

  /// What a visitor may post. An identity so others can verify their
  /// signature; a command or a group act is never a visitor's to send.
  static const Set<String> postable = {
    'message', 'status', 'reaction', 'identity',
  };

  static const int maxLimit = 200;
  static const int defaultLimit = 30;

  /// One visitor, one address: no more than a few in a second and thirty in
  /// a minute. A walk-up page is not a bulk lane.
  static const int burst = 5;
  static const int perMinute = 30;
  final Map<String, List<int>> _sent = {};

  /// A visitor proves they hold the key behind a callsign before this host
  /// shows them mail addressed to it: anybody on the hotspot can WRITE any
  /// callsign. The host gives a one-time nonce, the browser signs it, and the
  /// host checks the signature against the key it has heard for that
  /// callsign. A session is that proof, kept for a day, and names one callsign.
  static const Duration nonceLife = Duration(minutes: 5);
  static const Duration sessionLife = Duration(hours: 24);
  static const int maxSessions = 64;
  final Map<String, DateTime> _nonces = {};
  final Map<String, ({String call, DateTime until})> _sessions = {};
  final Random _rng = Random.secure();

  String _token(int bytes) => [
        for (var i = 0; i < bytes; i++)
          _rng.nextInt(256).toRadixString(16).padLeft(2, '0')
      ].join();

  /// The callsign a session proves, or null (unknown, expired).
  String? sessionCall(String? token) {
    if (token == null || token.isEmpty) return null;
    final s = _sessions[token];
    if (s == null) return null;
    if (now().isAfter(s.until)) {
      _sessions.remove(token);
      return null;
    }
    return s.call;
  }

  /// Distinct visitors that have talked to this host since it started, and
  /// who to tell when another arrives (the Share screen's count).
  final Set<String> visitors = {};
  void Function(int count)? onVisitors;

  Future<WebChatReply> handle(
      String method, String path, Map<String, String> query, String body,
      {String peer = ''}) async {
    if (peer.isNotEmpty && visitors.add(peer)) onVisitors?.call(visitors.length);
    if (method == 'GET' && path == '/api/services') return _services();
    if (method == 'GET' && path == '/api/xprs/history') {
      return _history(query, peer);
    }
    if (path == '/api/admin') {
      if (method == 'GET') return _adminState(query['session'], peer);
      if (method == 'POST') return _adminAct(body, peer);
    }
    if (path == '/api/session') {
      if (method == 'GET') return _challenge(peer);
      if (method == 'POST') return _prove(_wireOf(body), peer);
    }
    if (path == '/api/xprs/send' && (method == 'POST' || method == 'GET')) {
      // GET with ?wire= is the fallback the page uses when a captive WebView
      // refuses a POST (spec/API-HTTP.md); it is the same send.
      final wire = method == 'GET' ? (query['wire'] ?? '') : _wireOf(body);
      return _send(wire, peer);
    }
    return const WebChatReply(404, {'ok': false, 'error': 'not here'});
  }

  WebChatReply _services() {
    final app = appPath();
    return WebChatReply(200, {
      'ok': true,
      // The station's callsign, which the page shows next to its title.
      'station': selfCallsign(),
      'features': <String, bool>{},
      'serve': <String>[],
      'page': {
        'tabs': ['chat', 'traffic'],
        'config': false,
        // This host gives a visitor who proves their key their own mail.
        'session': true,
        // And has an administrator (GET/POST /api/admin).
        'admin': true,
        if (app != null) 'app': app,
      },
    });
  }

  /// `since`/`until` are epoch seconds or the packet timestamp form.
  static int? _when(String? v) {
    if (v == null || v.isEmpty) return null;
    final secs = int.tryParse(v);
    if (secs != null) return secs * 1000;
    return xprsParseTs(v);
  }

  WebChatReply _challenge(String peer) {
    if (!_allowed(peer)) return const WebChatReply(429, {'ok': false, 'error': 'slow down'});
    final t = now();
    _nonces.removeWhere((_, until) => t.isAfter(until));
    if (_nonces.length > 256) _nonces.clear();
    final nonce = _token(8);
    _nonces[nonce] = t.add(nonceLife);
    return WebChatReply(200, {'ok': true, 'nonce': nonce});
  }

  /// `t:session f:<call> ts:<stamp> sig:<..> m:<nonce>`: never aired, never
  /// filed; it exists only to be checked here.
  WebChatReply _prove(String wire, String peer) {
    WebChatReply no(int status, String why) =>
        WebChatReply(status, {'ok': false, 'error': why});
    final p = XprsPacket.parse(wire.trim());
    if (p == null || p.type != 'session') return no(400, 'malformed');
    final from = (p['f'] ?? '').trim().toUpperCase();
    final nonce = (p['m'] ?? '').trim();
    final until = _nonces[nonce];
    if (from.isEmpty || until == null || now().isAfter(until)) {
      return no(403, 'no such challenge');
    }
    final key = keyOf(from.split('-').first);
    // Without the key this host cannot tell who signed. The page sends its
    // identity first and asks again; the challenge stays good meanwhile.
    if (key == null) return no(409, 'identity unknown');
    if (xprsVerify(p, key) != XprsSigState.verified) return no(403, 'not signed by that key');
    _nonces.remove(nonce);
    final t = now();
    _sessions.removeWhere((_, s) => t.isAfter(s.until));
    while (_sessions.length >= maxSessions) {
      _sessions.remove(_sessions.keys.first);
    }
    final token = _token(16);
    _sessions[token] = (call: from.split('-').first, until: t.add(sessionLife));
    return WebChatReply(200, {'ok': true, 'session': token, 'call': from});
  }

  /// `room=` (spec/API-HTTP.md): one of the three chat rooms, else none.
  static String? _room(String? v) =>
      const {'local', 'regional', 'global'}.contains(v) ? v : null;

  WebChatReply _history(Map<String, String> q, String peer) {
    // The Local room is the station's own neighbourhood: kept from visitors
    // outside its network when the administrator says so (the default).
    final hideLocal = localPrivate && !isLocalPeer(peer);
    if (hideLocal && q['room'] == 'local') {
      return WebChatReply(200, {
        'ok': true, 'count': 0, 'held': 0, 'time': 'synced', 'rows': const [],
        'private': true,
      });
    }
    var types = <String>[
      for (final t in (q['kind'] ?? q['only'] ?? '').split(','))
        if (readable.contains(t.trim())) t.trim(),
    ];
    // Asked for nothing readable, or for nothing in particular: conversation.
    if (types.isEmpty) types = readable.toList();
    final limit =
        (int.tryParse(q['limit'] ?? '') ?? defaultLimit).clamp(1, maxLimit);
    var rows = publicRows(
      sinceMs: _when(q['since']),
      untilMs: _when(q['until']),
      types: types,
      from: (q['call'] ?? '').trim().isEmpty ? null : q['call']!.trim(),
      visitor: sessionCall(q['session']),
      room: _room(q['room']),
      limit: limit,
    );
    if (hideLocal) rows = [for (final r in rows) if (!_isLocalRow(r)) r];
    final dir = q['dir'];
    if (dir == 'in') rows = [for (final r in rows) if (r['own'] != true) r];
    if (dir == 'out') rows = [for (final r in rows) if (r['own'] == true) r];
    return WebChatReply(200, {
      'ok': true,
      'count': rows.length,
      'held': held(types),
      'time': 'synced',
      'rows': rows,
    });
  }

  static String _wireOf(String body) {
    final b = body.trim();
    if (b.startsWith('{')) {
      final m = RegExp(r'"wire"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(b);
      if (m == null) return '';
      return m[1]!
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', r'\')
          .replaceAll(r'\n', ' ');
    }
    // A form body, `wire=…`, or the packet itself.
    if (b.startsWith('wire=')) {
      return Uri.decodeQueryComponent(b.substring(5));
    }
    return b;
  }

  bool _allowed(String peer) {
    final t = now().millisecondsSinceEpoch;
    final log = _sent.putIfAbsent(peer, () => <int>[]);
    log.removeWhere((x) => t - x > 60000);
    if (log.length >= perMinute) return false;
    final lastSecond = log.where((x) => t - x < 1000).length;
    if (lastSecond >= burst) return false;
    log.add(t);
    return true;
  }

  Future<WebChatReply> _send(String wire, String peer) async {
    WebChatReply no(int status, String why) =>
        WebChatReply(status, {'ok': false, 'error': why});
    final p = XprsPacket.parse(wire.trim());
    if (p == null || !p.fits) return no(400, 'malformed');
    if (!postable.contains(p.type)) return no(403, 'not for a visitor to send');
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty) return no(400, 'no f:');
    // Never as this station: the publisher would sign an unsigned wire that
    // speaks as the phone, and a visitor would be writing in its owner's name.
    final me = selfCallsign().trim().toUpperCase();
    String base(String c) => c.split('-').first;
    if (me.isNotEmpty && base(from) == base(me)) {
      return no(403, 'not as this station');
    }
    if (!p.has('sig')) return no(400, 'unsigned');
    // When this station already knows the key that callsign is bound to, the
    // signature must hold; with none known it is relayed as unverified, which
    // is what every receiver will conclude for themselves.
    final state = xprsVerify(p, keyOf(base(from)));
    if (state == XprsSigState.forged) return no(400, 'forged');
    if (!mayAir(p)) return no(403, 'not a member of that group');
    switch (whoMayPost) {
      case 'nobody':
        return no(403, 'this station is read-only');
      case 'local':
        if (!isLocalPeer(peer)) {
          return no(403, "only from this station's network");
        }
    }
    if (!_allowed(peer)) return no(429, 'slow down');
    final w = p.encode();
    receive(w);
    return WebChatReply(200, {'ok': true, 'id': _idOf(p), 'wire': w});
  }

  String _idOf(XprsPacket p) => xprsIdentifier(p);

  /// An undirected row written for the Local room (`scope:local`).
  static bool _isLocalRow(Map<String, dynamic> r) {
    final p = XprsPacket.parse('${r['wire'] ?? ''}');
    return p != null && xprsScope(p).scope == XprsScope.local;
  }

  // ---- the administrator -------------------------------------------------

  static const _kAdmin = 'webchat.admin';
  static const _kSettings = 'webchat.settings';
  final Map<String, String> _mem = {};

  String? _load(String k) => store != null ? store!.getString(k) : _mem[k];
  void _save(String k, String? v) {
    if (v == null) {
      if (store != null) {
        store!.remove(k);
      } else {
        _mem.remove(k);
      }
    } else if (store != null) {
      store!.setString(k, v);
    } else {
      _mem[k] = v;
    }
  }

  Map<String, dynamic> _json(String k) {
    try {
      final v = _load(k);
      return v == null ? {} : Map<String, dynamic>.from(jsonDecode(v) as Map);
    } catch (_) {
      return {};
    }
  }

  /// The administrator's callsign, or null when the station has none.
  String? get adminCall => _json(_kAdmin)['call'] as String?;

  /// The settings and their defaults. Kept to what the page can explain.
  static const Map<String, Object> settingDefaults = {
    // The Local room is not shown to visitors outside the station's network.
    'local_private': true,
    // Who may post through this page: everyone, local (the station's
    // network), nobody (read-only).
    'who_may_post': 'everyone',
  };

  Map<String, Object> get settings {
    final s = _json(_kSettings);
    return {
      for (final e in settingDefaults.entries)
        e.key: (s[e.key] ?? e.value) as Object,
    };
  }

  bool get localPrivate => settings['local_private'] == true;
  String get whoMayPost => '${settings['who_may_post']}';

  /// The session's callsign when it is the administrator's, proven by the
  /// same key it was claimed with.
  String? _adminOf(String? session) {
    final call = sessionCall(session);
    final a = _json(_kAdmin);
    if (call == null || a['call'] != call) return null;
    final key = keyOf(call);
    if (key == null || HEX.encode(key) != a['key']) return null;
    return call;
  }

  WebChatReply _adminState(String? session, String peer) {
    final admin = adminCall;
    final you = _adminOf(session) != null;
    final local = isLocalPeer(peer);
    return WebChatReply(200, {
      'ok': true,
      'admin': admin,
      'you': you,
      'local': local,
      // Who could claim now: nobody holds it and the asker is on the network.
      'claimable': admin == null && local,
      if (you) 'settings': settings,
    });
  }

  WebChatReply _adminAct(String body, String peer) {
    WebChatReply no(int status, String why) =>
        WebChatReply(status, {'ok': false, 'error': why});
    Map<String, dynamic> b;
    try {
      b = Map<String, dynamic>.from(jsonDecode(body) as Map);
    } catch (_) {
      return no(400, 'malformed');
    }
    final session = '${b['session'] ?? ''}';
    switch (b['action']) {
      case 'claim':
        // Paced like a post: claiming is the one act open to anybody.
        // Setting and releasing need the administrator's session already.
        if (!_allowed(peer)) return no(429, 'slow down');
        final call = sessionCall(session);
        if (call == null) return no(403, 'prove your key first (a session)');
        if (adminCall != null) return no(409, 'this station has an administrator');
        if (!isLocalPeer(peer)) {
          return no(403, "claim it from the station's own network");
        }
        final key = keyOf(call);
        if (key == null) return no(409, 'identity unknown');
        _save(_kAdmin, jsonEncode({'call': call, 'key': HEX.encode(key)}));
        return _adminState(session, peer);
      case 'release':
        if (_adminOf(session) == null) return no(403, 'not the administrator');
        _save(_kAdmin, null);
        return _adminState(session, peer);
      case 'set':
        if (_adminOf(session) == null) return no(403, 'not the administrator');
        final want = b['settings'];
        if (want is! Map) return no(400, 'no settings');
        final next = Map<String, Object>.of(settings);
        for (final e in want.entries) {
          final k = '${e.key}';
          final v = e.value;
          switch (k) {
            case 'local_private':
              if (v is! bool) return no(400, '$k must be true or false');
              next[k] = v;
            case 'who_may_post':
              if (!const {'everyone', 'local', 'nobody'}.contains(v)) {
                return no(400, '$k must be everyone, local or nobody');
              }
              next[k] = v as String;
            default:
              return no(400, 'unknown setting $k');
          }
        }
        _save(_kSettings, jsonEncode(next));
        return _adminState(session, peer);
    }
    return no(400, 'action must be claim, release or set');
  }
}

/// Whether [address] (as a socket reports it) is on a private network:
/// loopback, RFC 1918, link-local, CGNAT's shared space, IPv6 ULA and
/// link-local, and IPv4 written as IPv6 (`::ffff:192.168.1.9`).
bool isPrivateAddress(String address) {
  var a = address.trim().toLowerCase();
  if (a.startsWith('[') && a.endsWith(']')) a = a.substring(1, a.length - 1);
  final pct = a.indexOf('%'); // zone id: fe80::1%eth0
  if (pct >= 0) a = a.substring(0, pct);
  if (a.startsWith('::ffff:') && a.contains('.')) a = a.substring(7);
  final v4 = a.split('.');
  if (v4.length == 4) {
    final b = v4.map(int.tryParse).toList();
    if (b.any((x) => x == null || x < 0 || x > 255)) return false;
    final o0 = b[0]!, o1 = b[1]!;
    return o0 == 127 ||
        o0 == 10 ||
        (o0 == 172 && o1 >= 16 && o1 < 32) ||
        (o0 == 192 && o1 == 168) ||
        (o0 == 169 && o1 == 254) ||
        (o0 == 100 && o1 >= 64 && o1 < 128);
  }
  if (!a.contains(':')) return false;
  if (a == '::1') return true;
  final first = int.tryParse(a.split(':').first.isEmpty ? '0' : a.split(':').first,
      radix: 16);
  if (first == null) return false;
  return (first & 0xfe00) == 0xfc00 || // fc00::/7 unique local
      (first & 0xffc0) == 0xfe80; // fe80::/10 link-local
}

/// The archive-backed [WebChatApi.publicRows]: undirected rows of [types]
/// only. A mailbox, a group's traffic and a direct message all carry a `d:`,
/// so `to: ['']` (the undirected shelf) leaves them out by construction.
///
/// For a [visitor] who proved a callsign it adds that callsign's own mail,
/// both ways (what was sent to it and what it sent), and nobody else's.
List<Map<String, dynamic>> archivePublicRows(
    {int? sinceMs,
    int? untilMs,
    required List<String> types,
    String? from,
    String? visitor,
    String? room,
    required int limit}) {
  final a = XprsArchive.instance;
  final open = a.query(
    sinceMs: sinceMs,
    untilMs: untilMs,
    types: types,
    to: const [''],
    from: from,
    room: room,
    limit: limit,
  );
  // A room is undirected traffic: a visitor's own mail is no room's.
  if (room != null || visitor == null || visitor.isEmpty) return open;
  final mine = <Map<String, dynamic>>[
    ...a.query(
        sinceMs: sinceMs,
        untilMs: untilMs,
        types: types,
        to: [visitor],
        from: from,
        limit: limit),
    ...a.query(
        sinceMs: sinceMs,
        untilMs: untilMs,
        types: types,
        from: visitor,
        limit: limit),
  ];
  final byId = <Object?, Map<String, dynamic>>{
    for (final r in [...open, ...mine]) r['id']: r,
  };
  final rows = byId.values.toList()
    ..sort((x, y) => (y['ts'] as int).compareTo(x['ts'] as int));
  return rows.length > limit ? rows.sublist(0, limit) : rows;
}
