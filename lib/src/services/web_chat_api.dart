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
 * Moderation is XPRS.md 10.10: the station is the group of its own rooms
 * (`d:` its callsign), its key signs the admin's acts (appoint, dismiss,
 * lift), and moderators sign theirs in the browser and post them like any
 * wire: `r:<id> remove:message` and `revoke:<call> [until:]`. The replay is
 * the core's XprsGroups, the one every closed group uses.
 *
 * Rooms the station hosts (XPRS.md 10.10.1) are closed groups whose key the
 * station holds: created by the administrator, public or private, posted to
 * through the station and filed here, never aired. Alerts (10.10.2) are the
 * `t:warning` and `t:info` the station holds; posting one through it is for
 * moderators and the administrator unless the administrator opens it.
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
import 'package:reticulum/reticulum.dart' show NostrCrypto;

import '../platform/key_value_store.dart';

import 'xprs/xprs_archive.dart' show XprsArchive;
import 'xprs/xprs_group_mirror.dart';
import 'xprs/xprs_groups.dart';
import 'xprs/xprs_id.dart';
import 'xprs/xprs_packet.dart';
import 'xprs/xprs_parts.dart';
import 'xprs/xprs_mesh_policy.dart';
import 'xprs/xprs_sig.dart';
import 'web_chat_forum.dart';
import 'xprs/xprs_vocab.dart' show xprsParseTs, xprsNowTs, xprsScope, XprsScope;

/// The keys of the rooms a station hosts (XPRS.md 10.10.1): the host's store.
class WebChatRoomKeys {
  const WebChatRoomKeys({required this.create, required this.scalar});

  /// Make a new group keypair named [nick]; its `X5` callsign, or null.
  final String? Function(String nick) create;

  /// The private scalar of a room this station holds, or null.
  final BigInt? Function(String call) scalar;
}

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

  /// The moderation record (XPRS.md 10.10). Null: no moderation here.
  final XprsGroups? groups;

  /// Sign a canonical wire as this station, or null when it cannot (no key).
  final XprsPacket? Function(String canonical)? signAsStation;

  /// Air a wire this station signed (its own moderation acts).
  final void Function(String wire)? publish;

  /// The host's hook to ask a shared room's peers now (XprsGroupMirror.poke):
  /// the administrator pressed Sync, or just mirrored a room.
  void Function(String group)? onSync;

  /// Hosted rooms (10.10.1): their keys, filing a packet without airing it,
  /// and reading a room's rows back. All three, or no hosted rooms.
  final WebChatRoomKeys? roomKeys;
  final void Function(String wire)? keep;
  final List<Map<String, dynamic>> Function(
      {required String room,
      int? sinceMs,
      int? untilMs,
      required List<String> types,
      required int limit})? roomRows;

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
    this.groups,
    this.signAsStation,
    this.publish,
    this.roomKeys,
    this.keep,
    this.roomRows,
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
    // A post (18): the visitor's own signed words, like a status, kept and
    // read later. One longer than a packet comes as parts (7.6).
    'blog',
    // Alerts (10.10.2), under the station's setting.
    'warning', 'info',
    // A call for help is never refused (10.7), whoever asks through here.
    'sos',
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
    if (path == '/api/rooms' && _hostsRooms) {
      if (method == 'GET') {
        final t = query['topics'];
        return t == null ? _roomList(query['session']) : _roomTopics(t, query['session']);
      }
      if (method == 'POST') return _roomAct(body);
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
        'tabs': ['chat', 'traffic', 'alerts'],
        // Who may post an alert through this station (10.10.2).
        'alerts': settings['who_may_alert'],
        // What the page defines for itself and the administrator set
        // (`page_<name>` settings): the banner, its CSS, its logo.
        for (final e in settings.entries)
          if (e.key.startsWith(pagePrefix)) e.key.substring(pagePrefix.length): e.value,
        // Rooms this station hosts (10.10.1): GET/POST /api/rooms.
        if (_hostsRooms) 'rooms': true,
        'config': false,
        // This host gives a visitor who proves their key their own mail.
        'session': true,
        // And has an administrator (GET/POST /api/admin).
        'admin': true,
        // And moderators (XPRS.md 10.10).
        if (groups != null) 'moderation': true,
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
    final hosted = _hostedRoom(q['room']);
    if (hosted != null) return _roomHistory(hosted, q);
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
    final mod = _moderation();
    if (mod != null) {
      rows = [
        for (final r in rows)
          if (!mod.removed.contains('${r['id']}') &&
              !(mod.away.contains(_base('${r['from'] ?? ''}')) &&
                  !_safety.contains('${r['type']}')))
            r,
      ];
    }
    final dir = q['dir'];
    if (dir == 'in') rows = [for (final r in rows) if (r['own'] != true) r];
    if (dir == 'out') rows = [for (final r in rows) if (r['own'] == true) r];
    return WebChatReply(200, {
      'ok': true,
      'count': rows.length,
      'held': held(types),
      'time': 'synced',
      'rows': rows,
      // What a page already showing should take down (XPRS.md 10.10).
      if (mod != null)
        'moderation': {
          'removed': mod.removed.take(200).toList(),
          'away': mod.away.toList(),
        },
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
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty) return no(400, 'no f:');
    if (p.type == 'moderate') return _moderateFromVisitor(p, from, peer);
    // A hosted room decides what it takes (a forum room takes posts too,
    // which no visitor may air); everything else is the visitor's to send
    // only when [postable] says so.
    final room = _hostedRoom(p['d']);
    if (room != null) return _postInRoom(p, from, room);
    if (!postable.contains(p.type)) return no(403, 'not for a visitor to send');
    if ((p.type == 'warning' || p.type == 'info') &&
        !(p['remove'] ?? '').startsWith(p.type) &&
        settings['who_may_alert'] != 'everyone' &&
        !_isStaff(from)) {
      return no(403, 'on this station only moderators post alerts');
    }
    // Somebody sent away may not post, except a call for help (10.7).
    final mod = _moderation();
    if (mod != null && p.type != 'sos' && mod.away.contains(_base(from))) {
      return no(403, "you were sent away from this station's rooms");
    }
    // Never as this station: the publisher would sign an unsigned wire that
    // speaks as the phone, and a visitor would be writing in its owner's name.
    final me = selfCallsign().trim().toUpperCase();
    String base(String c) => c.split('-').first;
    if (me.isNotEmpty && base(from) == base(me)) {
      return no(403, 'not as this station');
    }
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
    // A post longer than one packet comes as its parts (7.6), signed once
    // over the whole on the last (9.1.1): a part alone is neither signed nor
    // verifiable, and is aired as given, like any heard part. The page that
    // reads the feed joins the set and judges the signature on the whole.
    // Only a post to everybody: one to a room went the room's way above,
    // and a part to anybody else's group is not the page's to send.
    final part = p.type == 'blog' && p.has('n') && !p.has('d');
    if (!part) {
      if (!p.has('sig')) return no(400, 'unsigned');
      // When this station already knows the key that callsign is bound to,
      // the signature must hold; with none known it is relayed as
      // unverified, which is what every receiver will conclude for
      // themselves.
      final state = xprsVerify(p, keyOf(base(from)));
      if (state == XprsSigState.forged) return no(400, 'forged');
    }
    final w = p.encode();
    receive(w);
    return WebChatReply(200, {'ok': true, 'id': _idOf(p), 'wire': w});
  }

  String _idOf(XprsPacket p) => xprsIdentifier(p);

  // ---- moderation (XPRS.md 10.10) ---------------------------------------

  /// Never hidden by a record (10.7): a call for help is shown whatever.
  static const Set<String> _safety = {'sos', 'warning', 'info'};

  static String _base(String c) => c.trim().toUpperCase().split('-').first;

  String get _station => _base(selfCallsign());

  /// The removed messages and the people sent away, as they stand now.
  ({Set<String> removed, Set<String> away})? _moderation() {
    final g = groups;
    final st = _station;
    if (g == null || st.isEmpty) return null;
    final r = g.rosterOf(st);
    final t = now().millisecondsSinceEpoch;
    return (
      removed: {
        ...r.hidden,
        for (final m in r.moderation)
          if (m.kind == 'remove') m.target,
      },
      away: {
        for (final e in r.away.entries)
          if (e.value == 0 || e.value > t) e.key,
      },
    );
  }

  /// [call]'s place in the record of [group] (default the station's rooms):
  /// admin, mod, member, invited, or none.
  String roleOf(String call, {String? group}) {
    final g = groups;
    if (g == null) return 'none';
    final role =
        g.rosterOf(group ?? _station).roles[_base(call)] ?? XprsRole.none;
    return switch (role) {
      XprsRole.admin => 'admin',
      XprsRole.mod => 'mod',
      XprsRole.member => 'member',
      XprsRole.invited => 'invited',
      _ => 'none',
    };
  }

  /// The station's administrator (by key) or one of its moderators.
  bool _isStaff(String call) {
    final c = _base(call);
    final a = _json(_kAdmin);
    final key = keyOf(c);
    if (a['call'] == c && key != null && HEX.encode(key) == a['key']) {
      return true;
    }
    return roleOf(c) == 'mod';
  }

  // ---- rooms the station hosts (XPRS.md 10.10.1) --------------------------

  static const _kRooms = 'webchat.rooms';
  bool get _hostsRooms =>
      groups != null && roomKeys != null && keep != null && roomRows != null;

  /// call -> {name, about, visibility, posting, created}.
  Map<String, Map<String, dynamic>> get _rooms {
    final m = _json(_kRooms);
    return {
      for (final e in m.entries)
        if (e.value is Map) e.key: Map<String, dynamic>.from(e.value as Map),
    };
  }

  void _saveRooms(Map<String, Map<String, dynamic>> r) =>
      _save(_kRooms, jsonEncode(r));

  /// The hosted room [v] names, or null.
  String? _hostedRoom(String? v) {
    if (v == null || !_hostsRooms) return null;
    final c = _base(v);
    return c.startsWith('X5') && _rooms.containsKey(c) ? c : null;
  }

  bool _isMember(String room, String? call) {
    if (call == null) return false;
    final r = roleOf(call, group: room);
    return r == 'member' || r == 'mod' || r == 'admin';
  }

  /// Whether the visitor behind [session] may read [room].
  bool _mayRead(String room, String? session) {
    final meta = _rooms[room];
    if (meta == null) return false;
    if (meta['visibility'] != 'private') return true;
    return _isMember(room, sessionCall(session)) || _adminOf(session) != null;
  }

  ({Set<String> removed, Set<String> away}) _roomModeration(String room) {
    final r = groups!.rosterOf(room);
    final t = now().millisecondsSinceEpoch;
    return (
      removed: {
        ...r.hidden,
        for (final m in r.moderation)
          if (m.kind == 'remove') m.target,
      },
      away: {
        for (final e in r.away.entries)
          if (e.value == 0 || e.value > t) e.key,
      },
    );
  }

  WebChatReply _roomHistory(String room, Map<String, String> q) {
    if (!_mayRead(room, q['session'])) {
      return const WebChatReply(404, {'ok': false, 'error': 'no such room'});
    }
    final limit =
        (int.tryParse(q['limit'] ?? '') ?? defaultLimit).clamp(1, maxLimit);
    var types = <String>[
      for (final t in (q['kind'] ?? q['only'] ?? '').split(','))
        if (readable.contains(t.trim())) t.trim(),
    ];
    if (types.isEmpty) types = const ['message', 'reaction'];
    // A thread (7.4, 18.5): the post itself and what names it, oldest first.
    final root = _rootRe.hasMatch(q['root'] ?? '') ? q['root'] : null;
    final mod = _roomModeration(room);
    var rows = [
      for (final row in roomRows!(
          room: room,
          sinceMs: _when(q['since']),
          untilMs: _when(q['until']),
          types: types,
          limit: root == null ? limit : maxLimit))
        if (!mod.removed.contains('${row['id']}') &&
            !mod.away.contains(_base('${row['from'] ?? ''}')))
          row,
    ];
    if (root != null) {
      // The opening post's own rows: one, or the parts of a split one, whose
      // identifier is the whole's and so not on any row (7.6).
      final own = <String>{
        for (final p in forumPosts(rows))
          if (p.id == root) ...p.rowIds,
      };
      bool inThread(Map<String, dynamic> row) {
        if ('${row['id']}' == root || own.contains('${row['id']}')) return true;
        final p = XprsPacket.parse('${row['wire'] ?? ''}');
        return p != null && (p['root'] == root || p['r'] == root);
      }

      rows = rows.where(inThread).toList().reversed.take(limit).toList();
    }
    return WebChatReply(200, {
      'ok': true,
      'count': rows.length,
      'held': rows.length,
      'time': 'synced',
      'rows': rows,
      'moderation': {
        'removed': mod.removed.take(200).toList(),
        'away': mod.away.toList(),
      },
    });
  }

  static final RegExp _rootRe = RegExp(r'^[0-9a-f]{6}$');

  /// `title:` is a label (XPRS.md 18.1): lowercase letters, digits and `-`.
  static final RegExp _labelRe = RegExp(r'^[a-z0-9][a-z0-9-]{0,39}$');

  /// The rows the topic index folds: the newest posts of a room. A window,
  /// not the room (performance.md: never a page fetched to count).
  static const int forumWindow = 500;

  /// Parts of split posts still short (7.6), by (f, ts). Nothing is filed
  /// until the whole verifies (9.1.1), and then it is the whole that is
  /// filed, as the receive door files a rejoined message: a part's `sig:`
  /// covers the whole and would read as forged on the part alone, and a
  /// reader wants the post, not its fragments.
  final XprsPartTable _parts = XprsPartTable();
  final Map<String, int> _partsHeld = {};

  /// What a `t:blog` in a forum room must be (18, 18.5): a topic has a
  /// title; a comment has none and names its post; a correction or a
  /// withdrawal names what it acts on. Null when it is one of those.
  static String? forumShape(XprsPacket p) {
    final title = p['title'];
    if (title != null) {
      return _labelRe.hasMatch(title) ? null : 'title: is a label: lowercase letters, digits and -';
    }
    if (p.has('r') || p.has('edit')) return null;
    return 'a post needs a title: to open a topic, or r: to comment on one';
  }

  /// A visitor's message (or reaction, or in a forum room a post) in a
  /// hosted room: filed, not aired.
  WebChatReply _postInRoom(XprsPacket p, String from, String room) {
    WebChatReply no(int status, String why) =>
        WebChatReply(status, {'ok': false, 'error': why});
    final meta = _rooms[room]!;
    if (meta['kind'] == 'mesh') return no(403, 'a mesh holds its roster, not posts');
    final forum = meta['kind'] == 'forum';
    if (p.type == 'blog') {
      if (!forum) return no(403, 'posts go in a forum room');
      final why = forumShape(p);
      if (why != null) return no(400, why);
    } else if (p.type != 'message' && p.type != 'reaction') {
      return no(403, 'only messages and reactions in a room');
    }
    // A split post is signed once, on its last part, over the packet the
    // parts reassemble into (9.1.1): the parts are held and the whole is
    // verified when it is complete. Who may post is decided before holding.
    final split = p.type == 'blog' && p.has('n');
    if (!split &&
        xprsVerify(p, keyOf(_base(from))) != XprsSigState.verified) {
      // The record is judged by signature, so a room takes only a wire it can
      // verify: the visitor's page sends its identity first.
      return no(409, 'identity unknown');
    }
    if (_roomModeration(room).away.contains(_base(from))) {
      return no(403, 'you were sent away from this room');
    }
    final membersOnly =
        meta['visibility'] == 'private' || meta['posting'] != 'anyone';
    if (membersOnly && !_isMember(room, from)) {
      return no(403, 'only members post in this room');
    }
    if (split) return _postPart(p, from);
    final w = p.encode();
    keep!(w);
    return WebChatReply(200, {'ok': true, 'id': _idOf(p), 'wire': w});
  }

  WebChatReply _postPart(XprsPacket p, String from) {
    WebChatReply no(int status, String why) =>
        WebChatReply(status, {'ok': false, 'error': why});
    final key = xprsSetKey(p);
    final n = int.tryParse((p['n'] ?? '').split('/').first);
    if (key == null || n == null) return no(400, 'a part needs ts: and n:');
    final done = _parts.offer(p, clear: p['m'] ?? '', now: now());
    if (_partsHeld.length >= XprsPartTable.maxSets && !_partsHeld.containsKey(key)) {
      _partsHeld.remove(_partsHeld.keys.first);
    }
    if (done == null) {
      final held = (_partsHeld[key] ?? 0) + 1;
      _partsHeld[key] = held;
      return WebChatReply(202, {'ok': true, 'held': held});
    }
    _partsHeld.remove(key);
    final whole = done.sig == null ? done.packet : done.packet.with_('sig', done.sig!);
    if (xprsVerify(whole, keyOf(_base(from))) != XprsSigState.verified) {
      return no(409, 'the signature does not cover the whole post, or the key is unknown');
    }
    final w = whole.encode();
    keep!(w);
    return WebChatReply(200, {'ok': true, 'id': _idOf(whole), 'wire': w, 'parts': done.partIds.length});
  }

  /// The topic index of a forum room (API-HTTP.md, XPRS.md 18.5).
  WebChatReply _roomTopics(String call, String? session) {
    final room = _hostedRoom(call);
    if (room == null || !_mayRead(room, session)) {
      return const WebChatReply(404, {'ok': false, 'error': 'no such room'});
    }
    if (_rooms[room]!['kind'] != 'forum') {
      return const WebChatReply(400, {'ok': false, 'error': 'not a forum room'});
    }
    final mod = _roomModeration(room);
    final rows = roomRows!(room: room, types: const ['blog'], limit: forumWindow);
    return WebChatReply(200, {
      'ok': true,
      'room': room,
      'topics': forumTopics(rows, removed: mod.removed, away: mod.away),
    });
  }

  /// File the room's `t:identity` (10.1), signed with its own key.
  void _roomIdentity(String call, String name) {
    final scalar = roomKeys!.scalar(call);
    final pub = keyOf(call);
    if (scalar == null || pub == null) return;
    final npub = NostrCrypto.encodeNpub(HEX.encode(pub));
    final nick = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final p = XprsPacket.parse('t:identity f:$call ts:${xprsNowTs(now().millisecondsSinceEpoch)} '
        'k:$npub${nick.isEmpty ? '' : ' nick:$nick'}');
    if (p == null) return;
    keep!(xprsSign(p, scalar).encode());
  }

  /// Sign [body] as [room] (the station holds its key) and file it.
  String? _roomSign(String room, String body) {
    final scalar = roomKeys!.scalar(room);
    if (scalar == null) return 'this station does not hold that room';
    final ts = now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${ts.year}-${two(ts.month)}-${two(ts.day)}_'
        '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}';
    final p = XprsPacket.parse('t:moderate f:$room d:$room ts:$stamp $body');
    if (p == null) return 'malformed';
    final signed = xprsSign(p, scalar);
    if (!groups!.offer(signed, nowMs: now().millisecondsSinceEpoch)) {
      return 'the act was not taken';
    }
    keep!(signed.encode());
    return null;
  }

  Map<String, dynamic> _roomJson(
      String call, Map<String, dynamic> meta, String? who, bool admin) {
    final r = groups!.rosterOf(call);
    final role = who == null ? 'none' : roleOf(who, group: call);
    final membersOnly =
        meta['visibility'] == 'private' || meta['posting'] != 'anyone';
    final sentAway =
        who != null && _roomModeration(call).away.contains(_base(who));
    List<String> having(XprsRole role) => [
          for (final e in r.roles.entries)
            if (e.value == role) e.key,
        ]..sort();
    return {
      'call': call,
      'name': meta['name'],
      'about': meta['about'] ?? '',
      'kind': meta['kind'] ?? 'chat',
      'visibility': meta['visibility'],
      // Sharing with other stations (10.10.1): the peers it lists, and the
      // ones that asked for it and were answered.
      'shared': meta['shared'] == true,
      'mesh': meta['mesh'] == true,
      if (meta['shared'] == true) ...{
        'peers': [for (final x in meta['peers'] as List? ?? const []) '$x'],
        'seen': [for (final x in meta['seen'] as List? ?? const []) '$x'],
      },
      if (meta['mirrored'] == true) ...{'mirrored': true, 'owner': meta['owner']},
      'posting': meta['posting'],
      'role': role,
      if (role == 'invited' && who != null) ...{
        'offer': r.offers[_base(who)],
        'offer_role':
            r.offerRoles[_base(who)] == XprsRole.mod ? 'mod' : 'member',
      },
      'can_post': who != null &&
          !sentAway &&
          (!membersOnly || role == 'member' || role == 'mod' || role == 'admin'),
      if (admin || role == 'mod') ...{
        'members': having(XprsRole.member),
        'moderators': having(XprsRole.mod),
        'invited': having(XprsRole.invited),
      },
      // A mesh: where this station stands in it, for the administrator.
      if (meta['kind'] == 'mesh') ...{
        'station_role': meta['mirrored'] == true ? roleOf(_station, group: call) : 'owner',
        if (r.offers[_station] != null) 'station_offer': r.offers[_station],
      },
    };
  }

  WebChatReply _roomList(String? session) {
    final who = sessionCall(session);
    final admin = _adminOf(session) != null;
    final out = <Map<String, dynamic>>[];
    final rooms = _rooms.entries.toList()
      ..sort((a, b) => '${a.value['name']}'.compareTo('${b.value['name']}'));
    for (final e in rooms) {
      final private = e.value['visibility'] == 'private';
      final role = who == null ? 'none' : roleOf(who, group: e.key);
      // A private room is not even listed to somebody who is not in it.
      if (private && !admin && role == 'none') continue;
      out.add(_roomJson(e.key, e.value, who, admin));
    }
    return WebChatReply(200, {'ok': true, 'rooms': out});
  }

  WebChatReply _roomAct(String body) {
    WebChatReply no(int status, String why) =>
        WebChatReply(status, {'ok': false, 'error': why});
    Map<String, dynamic> b;
    try {
      b = Map<String, dynamic>.from(jsonDecode(body) as Map);
    } catch (_) {
      return no(400, 'malformed');
    }
    final session = '${b['session'] ?? ''}';
    if (_adminOf(session) == null) {
      return no(403, "only the station's administrator manages rooms");
    }
    final rooms = _rooms;
    String? opt(String k, Set<String> allowed) {
      final v = b[k];
      if (v == null) return null;
      return allowed.contains(v) ? v as String : '';
    }

    final visibility = opt('visibility', const {'public', 'private'});
    final posting = opt('posting', const {'members', 'anyone'});
    final kind = opt('kind', const {'chat', 'forum', 'mesh'});
    if (visibility == '' || posting == '' || kind == '') {
      return no(400, 'visibility is public or private; posting members or anyone; kind chat or forum');
    }
    String clean(Object? v, int max) {
      final s = '${v ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
      return s.length > max ? s.substring(0, max) : s;
    }

    final action = b['action'];
    if (action == 'create') {
      final name = clean(b['name'], 32);
      if (name.isEmpty) return no(400, 'a room needs a name');
      final call = roomKeys!.create(name);
      if (call == null) return no(503, 'could not make a key; try again');
      if (kind == 'mesh' && _meshCall() != null) return no(409, 'this station is already in a mesh');
      rooms[call] = {
        'name': name,
        'about': clean(b['about'], 120),
        'kind': kind ?? 'chat',
        'visibility': visibility ?? 'public',
        'posting': visibility == 'private' ? 'members' : (posting ?? 'anyone'),
        'created': now().millisecondsSinceEpoch,
      };
      _saveRooms(rooms);
      // The room's own announcement first (10.1): a station that mirrors the
      // room learns its key from the record itself, ahead of the acts the
      // key signed, which nothing verifies without it.
      _roomIdentity(call, name);
      // The administrator moderates the room too: offered, and accepted by
      // their own signature in the page (10.3.1).
      final admin = adminCall;
      if (admin != null && kind != 'mesh') _roomSign(call, 'grant:$admin role:mod');
      return _roomListFor(session, call);
    }
    final call = _base('${b['call'] ?? ''}');
    if (action == 'mirror') {
      // A room another station holds (10.10.1, shared): this station keeps a
      // copy under the owner's record and never signs as the room.
      final owner = _base('${b['owner'] ?? ''}');
      if (!call.startsWith('X5') || !_callRe.hasMatch(call)) {
        return no(400, "call is the room's X5 callsign");
      }
      if (!_callRe.hasMatch(owner) || owner == _station || owner == call) {
        return no(400, 'owner is the station that holds the room');
      }
      if (rooms.containsKey(call)) return no(409, 'already a room here');
      if (kind == 'mesh' && _meshCall() != null) return no(409, 'this station is already in a mesh');
      final name = clean(b['name'], 32);
      rooms[call] = {
        'name': name.isEmpty ? call : name,
        'about': clean(b['about'], 120),
        'kind': kind ?? 'forum',
        'visibility': visibility ?? 'public',
        'posting': visibility == 'private' ? 'members' : (posting ?? 'anyone'),
        'mirrored': true,
        'owner': owner,
        'created': now().millisecondsSinceEpoch,
      };
      _saveRooms(rooms);
      onSync?.call(call);
      return _roomListFor(session, call);
    }
    final meta = rooms[call];
    if (meta == null) return no(404, 'no such room');
    switch (action) {
      case 'share':
        if (meta['mirrored'] == true) return no(400, 'a mirrored room is shared by its owner');
        // With the mesh (docs/plan-mesh-trust.md): served to every trusted
        // peer, who mirrors it on its own; a shared room, with the peers
        // being whoever the administrator trusts at the time.
        final mesh = b['mesh'] == true;
        final shared = b['shared'] == true || mesh;
        meta['mesh'] = mesh;
        final peers = <String>[
          for (final x in b['peers'] is List ? b['peers'] as List : const [])
            if (_callRe.hasMatch(_base('$x')) && _base('$x') != _station) _base('$x'),
        ];
        if (shared && meta['visibility'] == 'private' && peers.isEmpty) {
          return no(400, 'a private room is shared with named stations');
        }
        meta['shared'] = shared;
        meta['peers'] = peers.take(16).toList();
        if (!shared) meta.remove('seen');
        rooms[call] = meta;
        _saveRooms(rooms);
        return _roomListFor(session, call);
      case 'unmirror':
        if (meta['mirrored'] != true) return no(400, 'not a mirrored room');
        rooms.remove(call);
        _saveRooms(rooms);
        return _roomList(session);
      case 'sync':
        if (meta['mirrored'] != true && meta['shared'] != true) {
          return no(400, 'not a shared room');
        }
        onSync?.call(call);
        return _roomListFor(session, call);
      case 'update':
        if (b.containsKey('name')) {
          final name = clean(b['name'], 32);
          if (name.isEmpty) return no(400, 'a room needs a name');
          meta['name'] = name;
        }
        if (b.containsKey('about')) meta['about'] = clean(b['about'], 120);
        if (kind != null) meta['kind'] = kind;
        if (visibility != null) meta['visibility'] = visibility;
        if (posting != null) meta['posting'] = posting;
        if (meta['visibility'] == 'private') meta['posting'] = 'members';
        rooms[call] = meta;
        _saveRooms(rooms);
        return _roomListFor(session, call);
      case 'close':
        rooms.remove(call);
        _saveRooms(rooms);
        return _roomList(session);
      case 'add':
      case 'appoint':
      case 'remove':
        final who = _base('${b['member'] ?? ''}');
        if (!_callRe.hasMatch(who) || who == call) {
          return no(400, 'a callsign, please');
        }
        final body = switch (action) {
          'add' => 'grant:$who',
          'appoint' => 'grant:$who role:mod',
          _ => 'revoke:$who',
        };
        // A mesh this station helps run but does not hold the key of: the
        // act is signed by this station, as the moderator it was made (10.3).
        final why = meta['mirrored'] == true && meta['kind'] == 'mesh'
            ? _stationAct(body, to: call, file: true)
            : _roomSign(call, body);
        if (why != null) return no(409, why);
        _trustedAt = 0;
        onSync?.call(call);
        return _roomListFor(session, call);
      case 'accept':
        // This station accepts what a mesh offered it, by its own signature
        // (26.3.1): the record carries the offer's identifier.
        final r = groups!.rosterOf(call);
        final offer = r.offers[_station];
        if (offer == null) return no(409, 'nothing offered to this station');
        final role = r.offerRoles[_station] == XprsRole.mod ? 'mod' : 'member';
        final why = _stationAct('r:$offer accept:$role', to: call, file: true);
        if (why != null) return no(409, why);
        _trustedAt = 0;
        onSync?.call(call);
        return _roomListFor(session, call);
    }
    return no(400,
        'action must be create, update, close, add, appoint, remove, accept, share, mirror, unmirror or sync');
  }

  /// May [group]'s rows be served to [asker] over `cmd:history` (10.10.1)?
  /// Null: not a room here. False: a room not shared with them. True: a
  /// shared room's listed peer, anybody for a public room shared with no
  /// list, or the owner of a room this station mirrors. An unlisted asker a
  /// public room answered is remembered (bounded), so the room asks them back.
  bool? roomServable(String group, String asker) {
    if (!_hostsRooms) return null;
    final rooms = _rooms;
    final call = _base(group);
    final meta = rooms[call];
    if (meta == null) return null;
    final a = _base(asker);
    if (a.isEmpty || a == _station) return false;
    if (meta['kind'] == 'mesh') {
      // Its record to every station on its roster, the invited included (so
      // an invitee can read what it is offered), and to whoever holds it.
      if (a == _base('${meta['owner'] ?? ''}')) return true;
      return (groups?.rosterOf(call).roles[a] ?? XprsRole.none) != XprsRole.none;
    }
    if (meta['mirrored'] == true) return a == _base('${meta['owner'] ?? ''}');
    if (meta['shared'] != true) return false;
    if (meta['mesh'] == true) return isTrusted(a);
    final peers = [for (final x in meta['peers'] as List? ?? const []) '$x'];
    if (peers.contains(a)) return true;
    if (peers.isNotEmpty || meta['visibility'] == 'private') return false;
    final seen = [for (final x in meta['seen'] as List? ?? const []) '$x'];
    if (!seen.contains(a)) {
      seen.add(a);
      meta['seen'] = seen.length > 16 ? seen.sublist(seen.length - 16) : seen;
      rooms[call] = meta;
      _saveRooms(rooms);
    }
    return true;
  }

  /// The stations that hold a copy of [group] besides this one: a shared
  /// room's listed peers and the ones seen asking, a mirrored room's owner.
  /// Named in a `404 m:try` so a third station finds a holder (12.9).
  List<String> roomPeers(String group) {
    if (!_hostsRooms) return const [];
    final meta = _rooms[_base(group)];
    if (meta == null) return const [];
    if (meta['mirrored'] == true) {
      final o = _base('${meta['owner'] ?? ''}');
      return o.isEmpty ? const [] : [o];
    }
    if (meta['shared'] != true) return const [];
    if (meta['mesh'] == true) return trustedSet().toList();
    return {
      for (final x in meta['peers'] as List? ?? const []) '$x',
      for (final x in meta['seen'] as List? ?? const []) '$x',
    }.toList();
  }

  /// The stations this one trusts (docs/plan-mesh-trust.md): in `named`
  /// mode the administrator's list; in `mesh` mode the roster of the mesh
  /// group (members, moderators and the station that holds it, never the
  /// invited); in `open` mode nobody. Recomputed at most every 30 seconds:
  /// the roster changes when an act arrives, and this is asked per packet.
  Set<String> trustedSet() {
    final t = now().millisecondsSinceEpoch;
    if (t - _trustedAt < 30000) return _trusted;
    _trustedAt = t;
    final s = settings;
    final mode = '${s['peers_mode']}';
    final out = <String>{};
    if (mode == 'named') {
      out.addAll(xprsCallsignList(s['peers']).map(_base));
    } else if (mode == 'mesh') {
      final g = _meshCall();
      if (g != null && groups != null) {
        final meta = _rooms[g]!;
        final owner = _base('${meta['owner'] ?? ''}');
        if (owner.isNotEmpty) out.add(owner);
        for (final e in groups!.rosterOf(g).roles.entries) {
          final c = _base(e.key);
          if (c.startsWith('X5')) continue; // the group itself, as its admin
          if (e.value == XprsRole.member || e.value == XprsRole.mod || e.value == XprsRole.admin) {
            out.add(c);
          }
        }
      }
    }
    out.remove(_station);
    return _trusted = out;
  }

  Set<String> _trusted = const {};
  int _trustedAt = 0;

  bool isTrusted(String call) => trustedSet().contains(_base(call));

  /// The mesh group this station is in, held or mirrored: one at most.
  String? _meshCall() {
    if (!_hostsRooms) return null;
    for (final e in _rooms.entries) {
      if (e.value['kind'] == 'mesh') return e.key;
    }
    return null;
  }

  /// Whom this station asks, of those it trusts (docs/plan-mesh-trust.md):
  /// every record is a signed original that each member keeps and serves,
  /// so a few peers carry the mesh as well as all of them, at a fraction of
  /// the asks. [syncFanout] of them, a different few each week so the load
  /// spreads, chosen the same way on every restart.
  static const int syncFanout = 4;
  List<String> syncSet() {
    final all = trustedSet().toList();
    if (all.length <= syncFanout) return all;
    final week = now().millisecondsSinceEpoch ~/ (7 * 86400000);
    int h(String c) {
      var x = 0x811c9dc5;
      for (final u in '$_station|$c|$week'.codeUnits) {
        x = ((x ^ u) * 0x01000193) & 0xffffffff;
      }
      return x;
    }
    all.sort((a, b) => h(a).compareTo(h(b)));
    return all.take(syncFanout).toList();
  }

  /// A room a trusted peer hosts and shares with the mesh, met in its answer
  /// (XprsGroupMirror.onMeshRoom): mirrored here when it is new.
  void autoMirror(String room, String peer, String nick) {
    if (!_hostsRooms) return;
    final call = _base(room), owner = _base(peer);
    if (!isTrusted(owner)) return;
    final rooms = _rooms;
    if (!call.startsWith('X5') || !_callRe.hasMatch(call)) return;
    final have = rooms[call];
    if (have != null) {
      // Met first by a post, named by its identity when that arrives.
      if (have['mirrored'] == true && have['owner'] == owner && have['name'] == call && nick.isNotEmpty) {
        have['name'] = _nickName(nick);
        rooms[call] = have;
        _saveRooms(rooms);
      }
      return;
    }
    rooms[call] = _mirroredMeta(owner, nick.isEmpty ? call : _nickName(nick), 'forum', 'public', 'anyone');
    _saveRooms(rooms);
    onSync?.call(call);
  }

  /// A room's nick is a label (`antenna-talk`, _roomIdentity); its name
  /// reads as words: `Antenna talk`.
  static String _nickName(String nick) {
    final w = nick.replaceAll('-', ' ').trim();
    return w.isEmpty ? nick : w[0].toUpperCase() + w.substring(1);
  }

  Map<String, Object?> _mirroredMeta(String owner, String name, String kind, String visibility, String posting) => {
        'name': name,
        'about': '',
        'kind': kind,
        'visibility': visibility,
        'posting': visibility == 'private' ? 'members' : posting,
        'mirrored': true,
        'owner': owner,
        'created': now().millisecondsSinceEpoch,
      };

  /// Every (group, peer) this station keeps in step (XprsGroupMirror): a
  /// mirrored room with its owner, a shared room with each peer it lists or
  /// has seen asking.
  List<MirrorPair> mirrorPairs() {
    if (!_hostsRooms) return const [];
    final out = <MirrorPair>[];
    for (final e in _rooms.entries) {
      final meta = e.value;
      if (meta['kind'] == 'mesh') {
        // The mesh's own record: with its holder, a few members, and every
        // station invited and not yet answered (its acceptance is here).
        final r = groups?.rosterOf(e.key);
        final peers = <String>{
          if (meta['mirrored'] == true) _base('${meta['owner'] ?? ''}'),
          ...syncSet(),
          for (final x in r?.roles.entries ?? const <MapEntry<String, XprsRole>>[])
            if (x.value == XprsRole.invited) _base(x.key),
        }..remove(_station)..remove('');
        for (final p in peers) {
          out.add(MirrorPair(group: e.key, peer: p));
        }
      } else if (meta['mirrored'] == true) {
        final owner = _base('${meta['owner'] ?? ''}');
        if (owner.isNotEmpty) out.add(MirrorPair(group: e.key, peer: owner));
      } else if (meta['shared'] == true) {
        final peers = meta['mesh'] == true
            ? trustedSet()
            : <String>{
                for (final x in meta['peers'] as List? ?? const []) '$x',
                for (final x in meta['seen'] as List? ?? const []) '$x',
              };
        for (final p in peers) {
          out.add(MirrorPair(group: e.key, peer: p));
        }
      }
    }
    // The neighbours (12.9.3): each trusted peer's noticeboard, kept in step.
    for (final p in syncSet()) {
      out.add(MirrorPair(peer: p, kinds: XprsGroupMirror.neighbourKinds));
    }
    return out;
  }

  WebChatReply _roomListFor(String session, String call) {
    final r = _roomList(session);
    return WebChatReply(200, {...r.json, 'room': call});
  }

  /// A moderator's act, or a person's acceptance, signed in the browser.
  WebChatReply _moderateFromVisitor(XprsPacket p, String from, String peer) {
    WebChatReply no(int status, String why) =>
        WebChatReply(status, {'ok': false, 'error': why});
    final g = groups;
    final st = _station;
    if (g == null || st.isEmpty) return no(403, 'no moderation here');
    final target = _base(p['d'] ?? '');
    final room = _hostedRoom(target);
    if (target != st && room == null) return no(403, "only this station's rooms");
    if (_base(from) == st || _base(from) == target) {
      return no(403, 'not as this station');
    }
    // A record is only as good as its signatures: an act this station cannot
    // verify changes nothing, so it is not taken in.
    if (xprsVerify(p, keyOf(_base(from))) != XprsSigState.verified) {
      return no(403, 'not signed by a key this station knows');
    }
    final self = p.has('accept') || p.has('leave');
    if (!self) {
      // Appointing and lifting are the admin's, which the station signs.
      if (p.has('grant')) return no(403, 'only the administrator appoints');
      if (roleOf(from, group: target) != 'mod') {
        return no(403, 'not a moderator here');
      }
    }
    // Not paced like a post: only a verified moderator, or somebody answering
    // an offer made to them, gets this far.
    g.offer(p);
    final w = p.encode();
    // A hosted room's record stays at the station (10.10.1).
    if (room != null) {
      keep!(w);
    } else {
      receive(w);
    }
    return WebChatReply(200, {'ok': true, 'id': _idOf(p), 'wire': w});
  }

  /// Sign [body] as this station about its own rooms, file it and air it.
  String? _stationAct(String body, {String? to, bool file = false}) {
    final g = groups;
    final st = _station;
    final sign = signAsStation;
    if (g == null || sign == null || st.isEmpty) return 'no moderation here';
    final ts = now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${ts.year}-${two(ts.month)}-${two(ts.day)}_'
        '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}';
    final p = sign('t:moderate f:$st d:${to ?? st} ts:$stamp $body');
    if (p == null) return 'this station cannot sign';
    if (!g.offer(p, nowMs: now().millisecondsSinceEpoch)) {
      return 'the act was not taken';
    }
    // A mesh's act is filed and travels by the mesh's own asks (10.10.1),
    // never aired: the record is the members' business.
    if (file) {
      keep!(p.encode());
    } else {
      (publish ?? receive)(p.encode());
    }
    return null;
  }

  static final RegExp _callRe = RegExp(r'^[A-Z0-9]{3,12}(-[A-Z0-9]{1,3})?$');

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
    // Who may post an alert (t:warning, t:info) through this station: the
    // moderators and the administrator, or everyone (XPRS.md 10.10.2).
    'who_may_alert': 'moderators',
    // The mesh (docs/plan-mesh-trust.md, xprs_mesh_policy.dart): how far
    // away a kind may come from and still be kept; whose words are fetched
    // from anywhere; which stations this one exchanges records with.
    'reach_alerts': 'regional',
    'reach_posts': 'regional',
    'reach_chat': 'global',
    'follow': '',
    'peers_mode': 'open',
    'peers': '',
  };

  /// Told after the administrator changed the settings, with the new map:
  /// the host rebuilds what reads them on a hot path (the mesh policy).
  void Function(Map<String, Object> settings)? onSettings;

  static final RegExp _meshCallRe = RegExp(r'^X[1-5][A-Z0-9]{2,5}$');
  static final RegExp _npubRe = RegExp(r'^npub1[a-z0-9]{58}$');

  /// A setting the page defines for itself (`page_banner`, `page_css`,
  /// `page_logo`, whatever it adds next): a string the station stores as
  /// given and reports under `page` on /api/services. The page owns its
  /// meaning; the station owns nothing but the bound.
  static const String pagePrefix = 'page_';
  static const int maxPageSettingChars = 8000;

  Map<String, Object> get settings {
    final s = _json(_kSettings);
    return {
      for (final e in settingDefaults.entries)
        e.key: (s[e.key] ?? e.value) as Object,
      for (final e in s.entries)
        if (e.key.startsWith(pagePrefix) && e.value is String) e.key: e.value as Object,
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
      if (groups != null) ..._moderationState(session, you),
    });
  }

  /// The asker's place in the record, and for a moderator or the admin the
  /// record itself: moderators, invitations, people sent away.
  Map<String, dynamic> _moderationState(String? session, bool you) {
    final call = sessionCall(session);
    final r = groups!.rosterOf(_station);
    final role = call == null ? 'none' : roleOf(call);
    final t = now().millisecondsSinceEpoch;
    final out = <String, dynamic>{
      'station': _station,
      'role': role,
      if (role == 'invited' && call != null) 'offer': r.offers[_base(call)],
    };
    if (you || role == 'mod') {
      out['moderators'] = [
        for (final e in r.roles.entries)
          if (e.value == XprsRole.mod) e.key,
      ]..sort();
      out['invited'] = [
        for (final e in r.roles.entries)
          if (e.value == XprsRole.invited && r.offers.containsKey(e.key)) e.key,
      ]..sort();
      out['away'] = [
        for (final e in r.away.entries)
          if (e.value == 0 || e.value > t)
            {
              'call': e.key,
              if (e.value > 0)
                'until': DateTime.fromMillisecondsSinceEpoch(e.value, isUtc: true)
                    .toIso8601String(),
            },
      ];
    }
    return out;
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
        // The administrator moderates too: the station offers them the role,
        // and their page accepts it with their own signature (10.3.1).
        if (groups != null && roleOf(call) != 'mod') {
          _stationAct('grant:$call role:mod');
        }
        return _adminState(session, peer);
      case 'appoint':
      case 'dismiss':
      case 'lift':
        if (_adminOf(session) == null) return no(403, 'not the administrator');
        final who = _base('${b['call'] ?? ''}');
        if (!_callRe.hasMatch(who)) return no(400, 'a callsign, please');
        if (who == _station) return no(400, 'not the station itself');
        // 10.10: a grant with role:mod appoints; a grant without a role makes
        // somebody an ordinary visitor again (dismisses, or lifts).
        final why = _stationAct(
            b['action'] == 'appoint' ? 'grant:$who role:mod' : 'grant:$who');
        if (why != null) return no(409, why);
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
            case 'who_may_alert':
              if (!const {'moderators', 'everyone'}.contains(v)) {
                return no(400, '$k must be moderators or everyone');
              }
              next[k] = v as String;
            case 'reach_alerts':
            case 'reach_posts':
            case 'reach_chat':
              if (!XprsMeshPolicy.kinds.contains(v)) {
                return no(400, '$k must be local, regional or global');
              }
              next[k] = v as String;
            case 'peers_mode':
              if (!const {'open', 'named', 'mesh'}.contains(v)) {
                return no(400, '$k must be open, named or mesh');
              }
              next[k] = v as String;
            case 'peers':
            case 'follow':
              if (v is! String) return no(400, '$k is a list of callsigns');
              final list = xprsCallsignList(v);
              final max = k == 'peers' ? 32 : 64;
              if (list.length > max) return no(400, '$k holds at most $max');
              for (final c in list) {
                final ok = _meshCallRe.hasMatch(c) ||
                    (k == 'follow' && _npubRe.hasMatch(c.toLowerCase()));
                if (!ok) return no(400, '$k: $c is not a callsign${k == 'follow' ? ' or an npub' : ''}');
              }
              next[k] = list.map((c) => c.startsWith('NPUB1') ? c.toLowerCase() : c).join(' ');
            default:
              if (!k.startsWith(pagePrefix) || k.length == pagePrefix.length) {
                return no(400, 'unknown setting $k');
              }
              if (v is! String || v.length > maxPageSettingChars) {
                return no(400, '$k is text of at most $maxPageSettingChars characters');
              }
              if (v.isEmpty) {
                next.remove(k);
              } else {
                next[k] = v;
              }
          }
        }
        _save(_kSettings, jsonEncode(next));
        _trustedAt = 0;
        onSettings?.call(settings);
        return _adminState(session, peer);
    }
    return no(400, 'action must be claim, release, set, appoint, dismiss or lift');
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
