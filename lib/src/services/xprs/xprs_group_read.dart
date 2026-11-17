/*
 * xprs_group_read — what keeps a closed group's words private (XPRS.md 10.7,
 * 13.11.3: "a group is an address, not a boundary, only `x:` keeps content
 * private").
 *
 * `x:` seals to the addressee's key (6.2), and a group's own key is its
 * authority (10.1): whoever holds it can grant, revoke and appoint. Handing it
 * to every member would make every member the admin. So a group has a second
 * key, its READING KEY, that only ever opens and seals posts:
 *
 *   - the admin's device mints it, and a new one whenever somebody leaves or
 *     is removed, so what is said afterwards is closed to them;
 *   - it reaches each member as a sealed message FROM THE GROUP, signed with
 *     the group's key: `t:message f:<X5> d:<member> x:<sealed "nsec:...">`,
 *     the `nsec:` line of 11.10 ("a private key a station is to take, only
 *     ever sealed"). The unseal against the group's own key proves who sent
 *     it; nothing else is believed;
 *   - a member seals a post with `x:` to the reading key's public half, and
 *     every holder opens it with the private half (ECDH is symmetric). The
 *     newest key is tried first, then the older ones a member was given, so
 *     the history from before a rotation stays readable to who could read it.
 *
 * PUBLIC OR PRIVATE (10.7.1, as amended). A group is public by default: anyone reads it,
 * members post, and a member is told so by the group with `nsec:-` (the
 * field's "taken back" form, 6.3.2), which is also what lets a member's
 * device know it may post in the clear instead of waiting for a key. Turning
 * a group private mints a reading key and hands it out; turning it public
 * again sends `nsec:-`. A member's device keeps the newest word it was given.
 *
 * The record of authority stays where it was: grants, acceptances and
 * revocations are public (10.7) and signed with the group's key or the
 * person's. Only the words move behind the reading key. Reactions,
 * withdrawals and moderation acts carry no words and stay as they are.
 *
 * Keys live in the profile's encrypted store, beside the group keys (26.6):
 * a reading key is a secret of the same kind.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';

import '../../storage/store_db.dart';
import '../log_service.dart';
import '../receive/core_state.dart';
import 'xprs_body.dart';
import 'xprs_group_act.dart';
import 'xprs_group_keys.dart';
import 'xprs_groups.dart';
import 'xprs_packet.dart';
import 'xprs_vocab.dart' show xprsNowTs;

/// One reading key of one group.
class XprsReadKey {
  const XprsReadKey(this.scalar, this.pubHex, this.nsec, this.ts);
  final BigInt scalar;
  final String pubHex;
  final String nsec;
  final int ts;
}

class XprsGroupRead {
  XprsGroupRead._();
  static final XprsGroupRead instance = XprsGroupRead._();

  /// How many reading keys of one group are kept and handed to a newcomer:
  /// the history a member can read reaches back this many rotations.
  static const int keep = 8;

  ZxSqlDb? _db;
  final Map<String, List<XprsReadKey>> _cache = {};

  /// The station's own callsign (the admin is not sent its own keys) and the
  /// key of a callsign, as the host knows them. Injected so a test needs no
  /// node.
  String Function() self = () => '';
  String? Function(String call) keyOf = (_) => null;

  /// Air a wire exactly as given (signed by the group). Injected for tests.
  Future<void> Function(String wire) air = (_) async {};

  /// Whether a change schedules [tend] by itself (off in tests, which call
  /// [tend] when they mean to).
  bool autoTend = true;

  /// Called when a group's reading key arrives or is minted, so a post that
  /// waited for it (XprsKeyWait) can leave.
  void Function(String group)? onKey;

  bool get ready => _db != null;

  void init(String path) {
    close();
    final db = openStoreDb(path);
    db.execute('''
      CREATE TABLE IF NOT EXISTS xprs_group_readkeys(
        grp  TEXT NOT NULL,
        pub  TEXT NOT NULL,
        nsec TEXT NOT NULL,
        ts   INTEGER NOT NULL,
        PRIMARY KEY(grp, pub)
      )''');
    // Public or private, as the admin set it (its own groups) or as the
    // group last told this member (`nsec:-` public, a key private).
    db.execute('''
      CREATE TABLE IF NOT EXISTS xprs_group_mode(
        grp  TEXT PRIMARY KEY,
        mode TEXT NOT NULL,
        ts   INTEGER NOT NULL
      )''');
    // Which member was handed which key: the admin's side only. `-` is the
    // public word.
    db.execute('''
      CREATE TABLE IF NOT EXISTS xprs_group_readsent(
        grp    TEXT NOT NULL,
        member TEXT NOT NULL,
        pub    TEXT NOT NULL,
        PRIMARY KEY(grp, member, pub)
      )''');
    _db = db;
  }

  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
    _cache.clear();
  }

  static String _g(String group) =>
      group.trim().replaceFirst('#', '').toUpperCase();

  /// The reading keys of [group] this station holds, newest first.
  List<XprsReadKey> keysOf(String group) {
    final g = _g(group);
    final hit = _cache[g];
    if (hit != null) return hit;
    final db = _db;
    if (db == null) return const [];
    final out = <XprsReadKey>[];
    for (final r in db.select(
        'SELECT pub, nsec, ts FROM xprs_group_readkeys WHERE grp = ? '
        'ORDER BY ts DESC LIMIT $keep',
        [g])) {
      final nsec = '${r['nsec']}';
      final d = _scalarOf(nsec);
      if (d == null) continue;
      out.add(XprsReadKey(d, '${r['pub']}', nsec, (r['ts'] as num).toInt()));
    }
    return _cache[g] = out;
  }

  /// The public half posts to [group] are sealed to, or null when this
  /// station has not been given one yet.
  String? currentPubHex(String group) {
    if (isPublic(group)) return null;
    final k = keysOf(group);
    return k.isEmpty ? null : k.first.pubHex;
  }

  /// 'public', 'private', or null when this station has not been told. An
  /// administered group with no word yet is public (the default), unless it
  /// already has reading keys (made before groups could be public).
  String? modeOf(String group) {
    final g = _g(group);
    final rows = _db?.select(
        'SELECT mode FROM xprs_group_mode WHERE grp = ? LIMIT 1', [g]);
    if (rows != null && rows.isNotEmpty) return '${rows.first['mode']}';
    if (XprsGroupKeys.instance.holdsKey(g)) {
      return keysOf(g).isEmpty ? 'public' : 'private';
    }
    return null;
  }

  bool isPublic(String group) => modeOf(group) == 'public';

  /// What a station not running [group] learns from reading it: a member's
  /// post in the clear says the group is public, a sealed one that it is
  /// private. Its members are TOLD (`nsec:-` or a key); somebody outside is
  /// not, and an invitation to a group they have been reading should not say
  /// "join to read". The newest post decides, so an old one heard late does
  /// not undo a switch.
  void noteSeen(String group, {required bool sealed, int? tsMs}) {
    final g = _g(group);
    final db = _db;
    if (db == null || XprsGroupKeys.instance.holdsKey(g)) return;
    final ts = tsMs ?? DateTime.now().millisecondsSinceEpoch;
    final want = sealed ? 'private' : 'public';
    final rows = db.select(
        'SELECT mode, ts FROM xprs_group_mode WHERE grp = ? LIMIT 1', [g]);
    if (rows.isNotEmpty) {
      if ('${rows.first['mode']}' == want) return;
      final at = rows.first['ts'];
      if (at is int && at >= ts) return;
    }
    db.execute(
        'INSERT OR REPLACE INTO xprs_group_mode(grp, mode, ts) VALUES(?,?,?)',
        [g, want, ts]);
    // What the group panels show changed: "public: anyone reads".
    CoreState.instance.changed(CoreState.groups);
  }

  void _setMode(String g, String mode) {
    _db?.execute(
        'INSERT OR REPLACE INTO xprs_group_mode(grp, mode, ts) VALUES(?,?,?)',
        [g, mode, DateTime.now().millisecondsSinceEpoch]);
    CoreState.instance.changed(CoreState.groups);
  }

  /// The admin turns [group] private (a reading key, handed to every member)
  /// or public (`nsec:-` to every member). False when this station does not
  /// administer it.
  bool setPrivate(String group, bool private) {
    final g = _g(group);
    final db = _db;
    if (db == null || !XprsGroupKeys.instance.holdsKey(g)) return false;
    if ((modeOf(g) == 'private') == private) return true;
    _setMode(g, private ? 'private' : 'public');
    if (private) {
      // A fresh key: whoever read it in the open must not hold an old one.
      mint(g);
    } else {
      // Every member is told again, whatever they were told before.
      db.execute(
          "DELETE FROM xprs_group_readsent WHERE grp = ? AND pub = '-'", [g]);
    }
    poke();
    return true;
  }

  /// Take a reading key for [group] from its `nsec`. True when it was new.
  bool learn(String group, String nsec, {int? ts}) {
    final db = _db;
    final g = _g(group);
    final d = _scalarOf(nsec.trim());
    if (db == null || g.isEmpty || d == null) return false;
    final pub = _hex(XprsCrypto.publicKeyXOnly(d));
    if (db.select(
        'SELECT 1 FROM xprs_group_readkeys WHERE grp = ? AND pub = ? LIMIT 1',
        [g, pub]).isNotEmpty) {
      return false;
    }
    db.execute(
        'INSERT INTO xprs_group_readkeys(grp, pub, nsec, ts) VALUES(?,?,?,?)',
        [g, pub, nsec.trim(), ts ?? DateTime.now().millisecondsSinceEpoch]);
    _cache.remove(g);
    LogService.instance.add('XPRS: reading key for $g learned');
    onKey?.call(g);
    return true;
  }

  /// A new reading key for a group this station administers.
  XprsReadKey? mint(String group, {int? ts}) {
    final kp = NostrCrypto.generateKeyPair();
    final at = ts ?? DateTime.now().millisecondsSinceEpoch;
    // Strictly newer than any held, so "newest first" names it.
    final held = keysOf(group);
    final when = held.isNotEmpty && held.first.ts >= at ? held.first.ts + 1 : at;
    if (!learn(group, kp.nsec, ts: when)) return null;
    return keysOf(group).first;
  }

  /// Open the words of a post sealed to [p]'s group, given the sender's
  /// public key. Null when no reading key held opens it.
  String? open(XprsPacket p, Uint8List senderPub) {
    final x = p['x'];
    if (x == null) return null;
    final blob = _b64(x);
    if (blob == null) return null;
    for (final k in keysOf(p['d'] ?? '')) {
      final pt = XprsCrypto.decryptFrom(k.scalar, senderPub, blob);
      if (pt == null) continue;
      try {
        return utf8.decode(pt);
      } catch (_) {
        continue; // padding passed by chance under the wrong key
      }
    }
    return null;
  }

  /// A sealed message from a group whose body is a reading key: taken, and
  /// true so the caller hands it to no wapp. [body] is the opened text and
  /// [from] the group it came from; the unseal against the group's own key is
  /// what proves the group said it.
  bool takeKeyMessage(String from, String body) {
    final g = _g(from);
    if (!g.startsWith('X5')) return false;
    final line = body.trim();
    if (!line.startsWith('nsec:')) return false;
    if (!XprsGroups.instance.known.contains(g) &&
        !XprsGroupKeys.instance.holdsKey(g)) {
      return false;
    }
    final value = line.substring(5).trim();
    if (value == '-') {
      // The group is public: its words travel in the clear, and a post that
      // waited for a key may leave now.
      _setMode(g, 'public');
      LogService.instance.add('XPRS: $g is public');
      onKey?.call(g);
      return true;
    }
    _setMode(g, 'private');
    learn(g, value);
    return true;
  }

  // ── The admin's side ───────────────────────────────────────────────────

  Timer? _debounce;

  /// Look at the groups this station administers soon: a roster moved.
  void poke() {
    if (!autoTend) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () {
      _debounce = null;
      unawaited(tend());
    });
  }

  /// Every group whose key this station holds: a reading key exists, a
  /// member who left or was removed causes a new one, and every member holds
  /// the keys they should. Idempotent: what was handed over is recorded.
  Future<void> tend() async {
    final db = _db;
    if (db == null) return;
    final me = self().trim().toUpperCase().split('-').first;
    for (final own in XprsGroupKeys.instance.mine()) {
      final g = own.callsign;
      final scalar = XprsGroupKeys.instance.scalarFor(g);
      if (scalar == null) continue;
      final roster = XprsGroups.instance.rosterOf(g);
      final members = <String>{
        for (final e in roster.roles.entries)
          if (e.key != g &&
              e.key != me &&
              (e.value == XprsRole.member ||
                  e.value == XprsRole.mod ||
                  e.value == XprsRole.admin))
            e.key
      };
      if (modeOf(g) == 'public') {
        // Tell each member once that the group is public: their device then
        // posts in the clear rather than waiting for a key.
        var told = false;
        for (final m in members) {
          final memberKey = keyOf(m);
          if (memberKey == null || memberKey.isEmpty) continue;
          if (db.select(
              "SELECT 1 FROM xprs_group_readsent WHERE grp = ? AND member = ? "
              "AND pub = '-' LIMIT 1",
              [g, m]).isNotEmpty) {
            continue;
          }
          final wire = publicMessage(g, m, memberKey, scalar);
          if (wire == null) continue;
          db.execute(
              "INSERT OR IGNORE INTO xprs_group_readsent(grp, member, pub) "
              "VALUES(?,?,'-')",
              [g, m]);
          await air(wire);
          told = true;
        }
        if (told) {
          final id = XprsGroupAct.identity(
              group: g, npub: own.npub, scalar: scalar, nick: own.nick);
          if (id != null) await air(id.encode());
        }
        continue;
      }
      var keys = keysOf(g);
      if (keys.isEmpty) {
        mint(g);
        keys = keysOf(g);
        if (keys.isEmpty) continue;
      }
      // Somebody who was given the current key is no longer a member: what
      // is said from now on is closed to them (10.3: removal needs no
      // acceptance, and leaving is the member's own act).
      final holders = {
        for (final r in db.select(
            'SELECT member FROM xprs_group_readsent WHERE grp = ? AND pub = ? '
            'LIMIT 1000',
            [g, keys.first.pubHex]))
          '${r['member']}'
      };
      if (holders.difference(members).isNotEmpty) {
        LogService.instance.add('XPRS: $g reading key renewed (a member went)');
        mint(g);
        keys = keysOf(g);
      }
      var handed = false;
      for (final m in members) {
        final sent = {
          for (final r in db.select(
              'SELECT pub FROM xprs_group_readsent WHERE grp = ? AND member = ? '
              'LIMIT 64',
              [g, m]))
            '${r['pub']}'
        };
        final memberKey = keyOf(m);
        if (memberKey == null || memberKey.isEmpty) continue;
        // Oldest first, so the newest lands last and is the one in force.
        for (final k in keys.reversed) {
          if (sent.contains(k.pubHex)) continue;
          final wire = keyMessage(g, m, memberKey, k, scalar);
          if (wire == null) continue;
          db.execute(
              'INSERT OR IGNORE INTO xprs_group_readsent(grp, member, pub) '
              'VALUES(?,?,?)',
              [g, m, k.pubHex]);
          await air(wire);
          handed = true;
        }
      }
      // A member who was handed a key may never have heard the group say
      // its name: its `t:identity` went out once, when it was made (10.1).
      // Said again now, so the newcomer's screen reads "Friends", not a
      // callsign.
      if (handed) {
        final id = XprsGroupAct.identity(
            group: g, npub: own.npub, scalar: scalar, nick: own.nick);
        if (id != null) await air(id.encode());
      }
    }
  }

  /// `t:message f:<group> d:<member> x:<sealed "nsec:...">`, signed and
  /// sealed with the group's own key.
  static String? keyMessage(String group, String member, String memberKeyHex,
      XprsReadKey key, BigInt groupScalar) {
    final head =
        XprsPacket.parse('t:message f:$group d:$member ts:${xprsNowTs()}');
    if (head == null) return null;
    final built = xprsBuildDirect(
      head: head,
      text: 'nsec:${key.nsec}',
      private: true,
      recipientKeyHex: memberKeyHex,
      signingKey: groupScalar,
    );
    if (!built.ok || built.packets.length != 1) return null;
    return built.packets.first.encode();
  }

  /// `nsec:-`, sealed from the group: "this group has no reading key, its
  /// words are public".
  static String? publicMessage(
      String group, String member, String memberKeyHex, BigInt groupScalar) {
    final head =
        XprsPacket.parse('t:message f:$group d:$member ts:${xprsNowTs()}');
    if (head == null) return null;
    final built = xprsBuildDirect(
      head: head,
      text: 'nsec:-',
      private: true,
      recipientKeyHex: memberKeyHex,
      signingKey: groupScalar,
    );
    if (!built.ok || built.packets.length != 1) return null;
    return built.packets.first.encode();
  }

  static BigInt? _scalarOf(String nsec) {
    try {
      var d = BigInt.zero;
      for (final b in HEX.decode(NostrCrypto.decodeNsec(nsec))) {
        d = (d << 8) | BigInt.from(b);
      }
      return d == BigInt.zero ? null : d;
    } catch (_) {
      return null;
    }
  }

  static String _hex(Uint8List b) => HEX.encode(b);

  static Uint8List? _b64(String v) {
    try {
      return base64Url.decode(v.padRight((v.length + 3) & ~3, '='));
    } catch (_) {
      return null;
    }
  }
}
