/*
 * xprs_file_acl — who may fetch the BYTES behind a `file:` hash (XPRS.md §11.2).
 *
 * The hash is public: `q:have`/`have:` and the seeder index advertise it freely,
 * and anyone may learn who holds it. Serving the bytes is a separate decision.
 * A `cmd:file` ask carries the requester's callsign and a signature; an archiver
 * serves only if that callsign is AUTHORISED for the file. Authorisation is the
 * audience of the message that shared the file:
 *
 *   public  an undirected post — anyone may fetch it.
 *   group   a closed group — a current member may fetch it (the same membership
 *           the core already enforces on posting, XprsGroups.mayPost).
 *   pair    a 1:1 message — either of the two participants may fetch it.
 *
 * This binds `hash → audience` when a message referencing the hash is admitted
 * or composed, so the file inherits the reach of the words that carried it. A
 * hash with no binding is treated as public (a bare digest an operator pinned,
 * an update-mirror artifact): the default is open, private is a deliberate bind.
 *
 * It lives in the profile's encrypted storage (a zx store, KV `acl`: the hash
 * as key, {scope, grp, members} as JSON), like [XprsPassphrases] and
 * [XprsGroupKeys]: the audience of a private picture is the profile's business.
 * Lookups are single-key reads, never a scan — safe on the caller's isolate
 * (docs/architecture.md §2).
 */
import 'dart:convert';

import '../../storage/store_db.dart';
import 'package:reticulum/reticulum.dart';
import 'xprs_groups.dart';
import 'xprs_packet.dart';

/// The reach of a shared file — the audience of the message that carried it.
enum XprsFileScope { public, group, pair }

class XprsFileAcl {
  XprsFileAcl._();
  static final XprsFileAcl instance = XprsFileAcl._();

  ZxSqlDb? _db;
  ZxKvStore? _kv;
  bool get ready => _kv != null;

  void init(String path) {
    close();
    final db = openStoreDb(path);
    _db = db;
    _kv = db.kv('acl');
  }

  Map<String, Object?>? _get(String sha) {
    final v = _kv?.getString(sha);
    if (v == null) return null;
    return (jsonDecode(v) as Map).cast<String, Object?>();
  }

  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
    _kv = null;
  }

  static String _base(String c) => c.trim().split('-').first.toUpperCase();

  /// Bind [shaHex] to an audience. A later bind for the same hash replaces the
  /// earlier one (a group's membership shifts; the newest word wins). A public
  /// bind is recorded too, so re-sharing a picture publicly re-opens it.
  void bind(
    String shaHex, {
    required XprsFileScope scope,
    String? group,
    List<String> members = const [],
  }) {
    final kv = _kv;
    final sha = shaHex.trim().toLowerCase();
    if (kv == null || sha.isEmpty) return;
    try {
      kv.putString(
          sha,
          jsonEncode({
            'scope': scope.name,
            'grp': group == null ? null : _base(group),
            'members': members.map(_base).where((c) => c.isNotEmpty).join(','),
          }));
    } catch (_) {}
  }

  /// Bind every `file:` reference in [msg]'s body to the message's own audience.
  /// Called both when THIS station composes a message ([own]) and when it admits
  /// one that references a file it may come to hold, so the file is served to
  /// exactly the people the message reached. [own] adds the author's own
  /// callsign to a pair so the author can fetch back their own picture.
  void bindFromMessage(XprsPacket msg, {String? selfCallsign}) {
    // The reference is a FIELD on the wire (7.7, 7.7.7) — and, in messages
    // older than that rule, a token inside the caption. Both bind. A
    // companion `t:file r:` naming a preview's original binds the same way,
    // so the full-resolution picture is served to exactly the people the
    // message reached.
    final refs = <MediaRef>[...MediaRef.findAll(msg['m'] ?? '')];
    final field = MediaRef.parse('file:${msg['file'] ?? ''}');
    if (field != null) refs.add(field);
    if (refs.isEmpty) return;
    final d = _base(msg['d'] ?? '');
    final from = _base(msg['f'] ?? '');

    XprsFileScope scope;
    String? group;
    var members = const <String>[];
    if (d.isEmpty) {
      scope = XprsFileScope.public;
    } else if (XprsGroups.instance.known.contains(d)) {
      scope = XprsFileScope.group;
      group = d;
    } else {
      scope = XprsFileScope.pair;
      members = {
        from,
        d,
        if (selfCallsign != null) _base(selfCallsign),
      }.where((c) => c.isNotEmpty).toList();
    }
    for (final r in refs) {
      bind(r.sha256Hex, scope: scope, group: group, members: members);
    }
  }

  /// May [requester] fetch the bytes of [shaHex]?
  ///
  /// No binding → public by default (open). Public → anyone. Pair → one of the
  /// two participants. Group → a current member, decided by the same
  /// [XprsGroups.mayPost] the core uses to gate posting (fail-open when the
  /// roster cannot be verified, exactly as posting does).
  bool authorized(String shaHex, String requester) {
    final sha = shaHex.trim().toLowerCase();
    final who = _base(requester);
    if (_kv == null) return true; // no store yet: do not lock a bench out
    if (who.isEmpty) return false;
    try {
      final row = _get(sha);
      if (row == null) return true; // unbound hash is public
      final scope = row['scope'] as String? ?? 'public';
      switch (scope) {
        case 'public':
          return true;
        case 'pair':
          final members = (row['members'] as String? ?? '')
              .split(',')
              .map(_base)
              .toSet();
          return members.contains(who);
        case 'group':
          final grp = row['grp'] as String? ?? '';
          return grp.isNotEmpty && XprsGroups.instance.mayPost(grp, who);
        default:
          return false;
      }
    } catch (_) {
      return false; // a store that errors denies a private fetch, never leaks
    }
  }

  /// Whether a closed group's files are anybody's: a room a station hosts
  /// that is public reads to everyone (XPRS.md 10.10.1), so do its files.
  /// Set by the host of the rooms (WebChatApi); null: no group is open.
  bool Function(String group)? openGroup;

  /// The group [shaHex] is bound to, or null (unbound, public, a pair).
  String? groupOf(String shaHex) {
    if (_kv == null) return null;
    try {
      final row = _get(shaHex.trim().toLowerCase());
      if (row == null || row['scope'] != 'group') return null;
      final g = row['grp'] as String? ?? '';
      return g.isEmpty ? null : g;
    } catch (_) {
      return null;
    }
  }

  /// Whether anyone may fetch [shaHex], proven or not: unbound, public, or
  /// bound to a group whose host says it is open ([openGroup]).
  bool isOpen(String shaHex) {
    final scope = scopeOf(shaHex);
    if (scope == null || scope == XprsFileScope.public) return true;
    if (scope != XprsFileScope.group) return false;
    final g = groupOf(shaHex);
    return g != null && (openGroup?.call(g) ?? false);
  }

  /// The recorded scope of a hash, for tests and status. Null when unbound.
  XprsFileScope? scopeOf(String shaHex) {
    if (_kv == null) return null;
    try {
      final row = _get(shaHex.trim().toLowerCase());
      if (row == null) return null;
      return XprsFileScope.values.firstWhere((s) => s.name == row['scope']);
    } catch (_) {
      return null;
    }
  }
}
