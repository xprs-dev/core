/*
 * xprs_archive — the spool of what this station has heard.
 *
 * docs/XPRS.md section 31.3 leaves retention to the station, section 24 names
 * the role (`serve:archive` "keeps a spool of what it has heard, and re-airs
 * it on cmd:history"), and until now no station kept one: the monitor's ring
 * forgets after 200 packets and a restart forgets everything. This is the
 * missing disk. Bounded — the caps are ours to pick and to change — and on by
 * default, because a spool nobody keeps is a network nobody can catch up on.
 *
 * Duplicates collapse on the derived identifier (section 25.2.1), so hearing
 * the same packet from three digipeaters costs one row. The wire is stored
 * exactly as heard — a replay re-airs original packets, unchanged — except
 * that a copy with fewer `via:` hops replaces one with more, because the
 * zero-hop copy is the closest thing to what the author transmitted.
 *
 * The hot path writes nothing: admit() appends to RAM and returns. A 20 s
 * timer flushes in one transaction, verifies signatures off the hot path,
 * and prunes in bounded batches (the ActivityArchive discipline). Nothing
 * here blocks the UI isolate for longer than one small indexed transaction.
 *
 * Also holds the `t:mailbox` declarations (section 13.12) that decide which
 * Reticulum-borne traffic may enter at all — see XprsIngest for the rule.
 */
import 'dart:async';
import 'dart:typed_data';


import '../../storage/store_db.dart';
import 'package:reticulum/reticulum.dart';
import '../log_service.dart';
import '../receive/core_state.dart';
import 'xprs_id.dart';
import 'xprs_archive_policy.dart';
import 'xprs_directory.dart' show XprsDirectoryEntry;
import 'xprs_packet.dart';
import 'xprs_presence.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';
import '../../platform/fs.dart';

/// Packet types that are never spooled.
///
/// `ping`/`pong` — section 36.1: a stale one answers a question nobody is
/// still asking. `receipt`/`result` — control traffic whose whole value is
/// consumed the moment it is heard; store-and-forward never carries them and
/// a history page re-airing day-old receipts wastes the page. `command` IS
/// kept: section 36.1 calls a command to a sleeping station mail.
// `kXprsNeverArchived` now lives with the rest of the admission rule, in
// xprs_archive_policy.dart, and is re-exported here for its existing readers.
export 'xprs_archive_policy.dart' show kXprsNeverArchived;

class _Pending {
  _Pending(this.p, this.bearer, this.rssi, this.own, this.nowMs, this.tier);
  final XprsPacket p;
  final String bearer;
  final int rssi;
  final bool own;
  final int nowMs;

  /// Which shelf the admission rule put it on (xprs_archive_policy.dart).
  /// Stored with the row, because retention reads it: mine and the people I
  /// follow are exempt from the caps, strangers are what the quota bounds.
  final Tier tier;
}

class XprsArchive {
  XprsArchive._();
  static final XprsArchive instance = XprsArchive._();

  ZxSqlDb? _db;
  bool get ready => _db != null;

  /// The stored packet whose §5 identifier is [id], or null when the spool
  /// holds none. This is how the core answers a read receipt for a message too
  /// old to be in [XprsReceipt]'s live pocket: the packet is resolved from the
  /// core's own persistent spool -- the sender and addressing composeRead needs
  /// -- rather than a wapp handing those fields across the door. Cheap: `id` is
  /// the packets table's primary key.
  XprsPacket? packetById(String id) {
    final w = wireById(id);
    return w == null ? null : XprsPacket.parse(w);
  }

  /// The raw wire of a received packet by its §5 id, or null. Used by the §9.2.1
  /// unlock path, which must restore bars across the ORIGINAL wire (a re-parse
  /// loses the exact bytes), so it needs the string, not the parsed packet.
  String? wireById(String id) {
    final key = id.trim().toLowerCase();
    if (key.isEmpty) return null;
    final db = _db;
    if (db == null) return null;
    try {
      final rows =
          db.select('SELECT wire FROM packets WHERE id = ? LIMIT 1', [key]);
      if (rows.isEmpty) return null;
      return rows.first.columnAt(0) as String;
    } catch (_) {
      return null;
    }
  }

  /// Caps. Prefs-backed by the owner (MeshService reads them at init and on
  /// change); the defaults are a judgement, not a specification (§31.3).
  int maxBytes = 500 * 1024 * 1024;

  /// XPRS.md 10.9.3: a byte ceiling per `X5` group, and within it the oldest
  /// goes first, so one loud group cannot crowd every quiet one out of the
  /// spool. A fourth axis on 12.11, not a change to its three. The group's
  /// acts and its identity are its record and never go (a roster without
  /// its grants is no roster, 10.4), nor does what this station itself said.
  int maxGroupBytes = 8 * 1024 * 1024;
  int groupPruned = 0;
  int maxAgeDays = 365;

  /// The signer's x-only key for a callsign, or null when not held. Injected
  /// (RnsService.pubkeyForCallsign in production) so tests need no node.
  Uint8List? Function(String baseCallsign)? keyResolver;

  /// The base callsigns of the people this operator follows.
  ///
  /// The middle tier of XPRS.md 12, and the reason a pocket phone keeps
  /// anything at all beyond its own words. Rebuilt by RnsService whenever the
  /// follow list changes — never derived per packet, which would put a bech32
  /// encode in the receive funnel.
  ///
  /// This replaces `protectedCallsigns`, a hook that was declared, plumbed
  /// into the eviction SQL, and never written by anybody.
  Set<String> followed = const {};

  /// The subset of [followed] followed BY CALLSIGN (a device, XPRS.md 11.7.1),
  /// whose observations are kept and capped per station. Pushed by RnsService
  /// with [followed]; the receive funnel does one lookup.
  Set<String> followedStations = const {};

  /// Counters for /api and for honest logs.
  int admitted = 0, dropped = 0, forged = 0;

  /// Told, at flush, what each packet's signature turned out to be — including
  /// the forged ones this drops. Set by the owner so the air view can badge a
  /// station without doing the curve work a second time.
  void Function(String callsign, XprsSigState state)? onVerdict;

  final List<_Pending> _pending = [];
  static const int _pendingMax = 512;
  static const int _flushEarlyAt = 64;
  Timer? _flushTimer;
  bool _prunedThisSession = false;
  int _flushesSinceCap = 0;

  /// Open (and migrate) the spool. Safe to call again on profile switch.
  void init(String path) {
    close();
    try {
      fs.directory(fs.file(path).parent.path).createSync(recursive: true);
      final db = openStoreDb(path);
      db.execute('''
        CREATE TABLE IF NOT EXISTS packets(
          id     TEXT PRIMARY KEY,
          ts     INTEGER NOT NULL,
          pts    INTEGER NOT NULL,
          type   TEXT NOT NULL,
          fromc  TEXT NOT NULL,
          toc    TEXT NOT NULL DEFAULT '',
          bearer TEXT NOT NULL,
          rssi   INTEGER NOT NULL DEFAULT 0,
          mine   INTEGER NOT NULL DEFAULT 0,
          own    INTEGER NOT NULL DEFAULT 0,
          sig    INTEGER NOT NULL DEFAULT 3,
          viac   INTEGER NOT NULL DEFAULT 0,
          heard  INTEGER NOT NULL DEFAULT 1,
          last   INTEGER NOT NULL,
          tier   INTEGER NOT NULL DEFAULT 2,
          wire   TEXT NOT NULL
        )''');
      // tier: the shelf a row sits on — 0 mine, 1 followed, 2 stranger.
      db.execute('CREATE INDEX IF NOT EXISTS idx_pk_tier ON packets(tier, pts)');
      db.execute('CREATE INDEX IF NOT EXISTS idx_pk_pts ON packets(pts)');
      db.execute(
          'CREATE INDEX IF NOT EXISTS idx_pk_from ON packets(fromc, pts)');
      db.execute('CREATE INDEX IF NOT EXISTS idx_pk_to ON packets(toc, pts)');
      db.execute('''
        CREATE TABLE IF NOT EXISTS mailbox_decl(
          id    TEXT PRIMARY KEY,
          fromc TEXT NOT NULL,
          pos   INTEGER NOT NULL DEFAULT 0,
          since INTEGER,
          until INTEGER,
          ts    INTEGER NOT NULL,
          wire  TEXT NOT NULL
        )''');
      db.execute(
          'CREATE INDEX IF NOT EXISTS idx_decl_from ON mailbox_decl(fromc)');
      // Visitors this station serves through its web page (12.7, 12.8.3):
      // callsigns that proved their key on `/api/session` and were offered
      // this station as their mailbox. The station is their holder until they
      // declare one (13.12): their mail is shelved protected, delivered
      // through the page, and counted in `room:`.
      db.execute('''
        CREATE TABLE IF NOT EXISTS served_visitors(
          call  TEXT PRIMARY KEY,
          since INTEGER NOT NULL,
          last  INTEGER NOT NULL
        )''');
      _served
        ..clear()
        ..addAll([
          for (final r in db.select('SELECT call FROM served_visitors'))
            r['call'] as String,
        ]);
      // XPRS.md 7.8.2: what a verified withdrawal destroyed. Identifiers only,
      // no text, so a replayed original or edit is refused instead of bringing
      // the words back.
      // Counters kept with the rows (performance.md: no scan to count): per
      // (type, undirected, tier), how many rows and how many wire bytes.
      // Every insert and delete of `packets` moves them in the same
      // transaction, through RETURNING. countOf, countsByTier and the byte
      // cap read them.
      db.execute('''
        CREATE TABLE IF NOT EXISTS counts(
          k TEXT PRIMARY KEY,
          n INTEGER NOT NULL,
          b INTEGER NOT NULL
        )''');
      // The newest packet time per author, for the directory (12.9): kept at
      // flush, read in callsign order (a GROUP BY over the spool was a scan).
      db.execute('''
        CREATE TABLE IF NOT EXISTS newest(
          fromc TEXT PRIMARY KEY,
          pts   INTEGER NOT NULL
        )''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS withdrawn(
          id    TEXT NOT NULL,
          fromc TEXT NOT NULL,
          ts    INTEGER NOT NULL,
          PRIMARY KEY(id, fromc)
        )''');
      _db = db;
      _loadCounts(db);
      _prunedThisSession = false;
      _flushTimer?.cancel();
      _flushTimer =
          Timer.periodic(const Duration(seconds: 20), (_) => flush());
    } catch (e) {
      _db = null;
      // A broken disk degrades to no archive, never to a crash.
      LogService.instance.add('XPRS archive: open failed: $e');
    }
  }

  // ── counters ─────────────────────────────────────────────────────────────

  /// key "type|u|tier" (u 1: undirected) -> [rows, wire bytes].
  final Map<String, List<int>> _counts = {};
  final Set<String> _countsDirty = {};

  static String _ck(String type, String toc, int tier) =>
      '$type|${toc.isEmpty ? 1 : 0}|$tier';

  void _bump(String type, String toc, int tier, int rows, int bytes) {
    final k = _ck(type, toc, tier);
    final c = _counts.putIfAbsent(k, () => [0, 0]);
    c[0] += rows;
    c[1] += bytes;
    _countsDirty.add(k);
  }

  void _loadCounts(ZxSqlDb db) {
    _counts.clear();
    _countsDirty.clear();
    for (final r in db.select('SELECT k, n, b FROM counts')) {
      _counts[r['k'] as String] = [r['n'] as int, r['b'] as int];
    }
    if (_counts.isEmpty &&
        // arch-ignore: no-page-fetch-to-count an existence probe (LIMIT 1), not a count
        db.select('SELECT 1 FROM packets LIMIT 1').isNotEmpty) {
      // A spool without counters: count it once.
      for (final r in db.select(
          "SELECT type, toc = '' u, tier, COUNT(*) n, SUM(length(wire)) b "
          'FROM packets GROUP BY type, toc = \'\', tier')) {
        final k = '${r['type']}|${r['u']}|${r['tier']}';
        _counts[k] = [r['n'] as int, (r['b'] as num?)?.toInt() ?? 0];
        _countsDirty.add(k);
      }
      db.transaction(() => _saveCounts(db));
    }
  }

  void _saveCounts(ZxSqlDb db) {
    for (final k in _countsDirty) {
      final c = _counts[k];
      if (c == null || c[0] <= 0) {
        _counts.remove(k);
        db.execute('DELETE FROM counts WHERE k = ?', [k]);
      } else {
        db.execute(
            'INSERT INTO counts(k, n, b) VALUES(?, ?, ?) '
            'ON CONFLICT(k) DO UPDATE SET n = excluded.n, b = excluded.b',
            [k, c[0], c[1]]);
      }
    }
    _countsDirty.clear();
  }

  /// Deletes `packets` rows ([sql] is a DELETE without RETURNING), moving
  /// the counters by what went. Returns the rows deleted.
  int _delete(ZxSqlDb db, String sql, [List<Object?> params = const []]) {
    final gone = db.select('$sql RETURNING type, toc, tier, length(wire) b', params);
    for (final r in gone) {
      _bump(r['type'] as String, r['toc'] as String, r['tier'] as int, -1,
          -((r['b'] as num?)?.toInt() ?? 0));
    }
    return gone.length;
  }

  /// The wire bytes the spool holds (what the byte cap measures).
  int get dataBytes => _counts.values.fold(0, (a, c) => a + c[1]);

  void close() {
    flush();
    _flushTimer?.cancel();
    _flushTimer = null;
    _db?.dispose();
    _db = null;
    _served.clear();
  }

  /// The person, with any device suffix removed: `X1ABCD-1` -> `X1ABCD`
  /// (spec section 3.1). One definition, shared, so the person/device
  /// split cannot drift between the archive, the ingest and the server.
  static String _base(String c) => NostrCrypto.bareCallsign(c);

  /// Record a heard packet. O(1): RAM append, nothing else — this sits on the
  /// radio receive path. [own] marks our own publication at transmit time.
  /// Test seam: every packet this archive accepted, in order. The retention
  /// policy lives in XprsIngest and the only honest way to test it is to watch
  /// what actually arrives here.
  void Function(XprsPacket p)? debugOnAdmit;

  void admit(
    XprsPacket p, {
    required String bearer,
    int rssi = 0,
    bool own = false,
    int? nowMs,
    /// Which shelf, when the caller has already decided (the ingest funnel
    /// always has). Omitted, our own traffic is ours and anything else is a
    /// stranger's — the safe reading for a direct caller.
    Tier? tier,
  }) {
    debugOnAdmit?.call(p);
    if (_db == null) return;
    if (kXprsNeverArchived.contains(p.type)) return;
    if ((p['f'] ?? '').trim().isEmpty) return;
    if (_pending.length >= _pendingMax) {
      _pending.removeAt(0);
      dropped++;
    }
    _pending.add(_Pending(p, bearer, rssi, own,
        nowMs ?? DateTime.now().millisecondsSinceEpoch,
        tier ?? (own ? Tier.self : Tier.stranger)));
    if (_pending.length >= _flushEarlyAt) flush();
  }

  /// Write the pending batch, verify signatures, prune. Public so tests and
  /// close() can force it; otherwise the 20 s timer calls it.
  /// A row that is now ACTUALLY in the table: the sender's base callsign and
  /// the packet's `ts:`.
  ///
  /// Fired here rather than at [admit], which only queues. The catch-up sweep
  /// advances a watermark on this, and firing it at admit time advanced it past
  /// packets the flush then dropped — a forged signature is discarded a few
  /// lines below — so the sweep believed it held history it had never stored,
  /// and stopped asking for it.
  void Function(String fromBase, int? tsMs)? onStored;

  void flush({int? nowMs}) {
    final db = _db;
    if (db == null || _pending.isEmpty) {
      if (db != null) _prune(db, nowMs: nowMs);
      return;
    }
    final batch = List.of(_pending);
    // Collected during the write and fired after the transaction, so a hook
    // that throws cannot leave the batch half-committed.
    final stored = <MapEntry<String, int?>>[];
    /// Senders whose identity rows need collapsing after this batch.
    final identities = <String>{};
    /// Stations followed by callsign whose presence rows need capping.
    final capped = <String>{};
    _pending.clear();
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final newest = <String, int>{};
    try {
      db.execute('BEGIN');
      final oldTier = db.prepare('SELECT tier FROM packets WHERE id = ?');
      final ins = db.prepare('''
        INSERT INTO packets(id,ts,pts,type,fromc,toc,bearer,rssi,mine,own,
                            sig,viac,heard,last,tier,wire)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,1,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          heard = heard + 1,
          last  = excluded.last,
          rssi  = excluded.rssi,
          mine  = MAX(mine, excluded.mine),
          own   = MAX(own, excluded.own),
          wire  = CASE WHEN excluded.viac < viac
                       THEN excluded.wire ELSE wire END,
          -- The best shelf wins: hearing a stranger's copy of a followed
          -- station's packet must never demote the row we already keep.
          tier  = MIN(tier, excluded.tier),
          viac  = MIN(viac, excluded.viac)
        RETURNING heard, tier, length(wire) b''');
      final tomb = db.prepare(
          'INSERT OR IGNORE INTO withdrawn(id,fromc,ts) VALUES(?,?,?)');
      try {
        for (final e in batch) {
          final p = e.p;
          // Signature state, off the hot path. A forged packet is somebody
          // else's words under a callsign, and a spool that replays it later
          // repeats the lie — dropped, same policy as the courier.
          var sig = XprsSigState.unsigned;
          if (p.has('sig')) {
            // A part carries the signature of the whole it belongs to (9.1.1:
            // "a partial set proves nothing"): it is neither verified nor
            // forged until whoever reads the set joins it, so the archive
            // keeps it as unverified rather than dropping the last part of
            // every long post as a forgery.
            sig = p.has('n')
                ? XprsSigState.unverified
                : xprsVerify(p, keyResolver?.call(_base(p['f'] ?? '')));
          }
          // Report before acting on it: a forged packet is dropped from the
          // spool, and if the verdict went with it nothing would ever be able
          // to say that a callsign had been used to sign something it could
          // not have signed.
          try {
            onVerdict?.call(_base(p['f'] ?? ''), sig);
          } catch (_) {
            // A view that throws must not cost the spool its flush.
          }
          if (sig == XprsSigState.forged) {
            forged++;
            continue;
          }
          final fromc = _base(p['f'] ?? '');
          final toc = _base(p['d'] ?? '');
          // A verified withdrawal destroys the text it names (7.8.2); the
          // withdrawal itself is stored like any packet below.
          if (sig == XprsSigState.verified) {
            _purgeWithdrawn(db, tomb, p, fromc, e.nowMs);
          }
          // The words of something already withdrawn do not come back.
          if (_isWithdrawn(db, p, fromc)) continue;
          stored.add(MapEntry(fromc, xprsParseTs(p['ts'])));
          final id = xprsIdentifier(p);
          final toWire = (p['d'] ?? '').trim().isEmpty ? '' : toc;
          // A higher shelf may lift an existing row (tier = MIN): know where
          // it stood, so its count moves. Only a mine or followed copy can.
          final before = e.tier.index < 2
              ? (oldTier.select([id]).firstOrNull?['tier'] as int?)
              : null;
          final res = ins.select([
            id,
            e.nowMs,
            xprsParseTs(p['ts']) ?? e.nowMs,
            p.type,
            fromc,
            toWire,
            e.bearer,
            e.rssi,
            (!e.own && toc.isNotEmpty && toc == _selfBase) ? 1 : 0,
            e.own ? 1 : 0,
            sig.index,
            xprsVia(p).length,
            e.nowMs,
            e.tier.index,
            p.encode(),
          ]).first;
          final tierNow = res['tier'] as int;
          final bytes = (res['b'] as num).toInt();
          if (res['heard'] == 1) {
            _bump(p.type, toWire, tierNow, 1, bytes);
          } else if (before != null && before != tierNow) {
            _bump(p.type, toWire, before, -1, -bytes);
            _bump(p.type, toWire, tierNow, 1, bytes);
          }
          if (fromc.isNotEmpty) {
            final t = xprsParseTs(p['ts']) ?? e.nowMs;
            if ((newest[fromc] ?? -1) < t) newest[fromc] = t;
          }
          admitted++;
          if (p.type == 'identity') identities.add(fromc);
          if (e.tier == Tier.followed &&
              xprsIsPresenceType(p.type) &&
              followedStations.contains(fromc)) {
            capped.add(fromc);
          }
        }
      } finally {
        ins.dispose();
        tomb.dispose();
        oldTier.dispose();
      }
      for (final c in identities) {
        _collapseIdentities(db, c);
      }
      for (final c in capped) {
        _capFollowedPresence(db, c);
      }
      newest.forEach((c, t) => db.execute(
          'INSERT INTO newest(fromc, pts) VALUES(?, ?) '
          'ON CONFLICT(fromc) DO UPDATE SET pts = MAX(pts, excluded.pts)',
          [c, t]));
      _saveCounts(db);
      db.execute('COMMIT');
    } catch (e) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {}
      // The rolled-back rows moved the counters in memory: read them back.
      _loadCounts(db);
      LogService.instance.add('XPRS archive: flush failed: $e');
    }
    _prune(db, nowMs: now);
    // The archive's counters moved, and its dashboard is somebody's screen.
    // Once per flush rather than once per row: a backlog drain writes hundreds
    // in one transaction, and the reader re-reads the whole status anyway.
    if (stored.isNotEmpty) CoreState.instance.changed(CoreState.archive);

    // Only now, and only for rows the transaction actually wrote.
    final notify = onStored;
    if (notify != null) {
      for (final e in stored) {
        try {
          notify(e.key, e.value);
        } catch (_) {
          // A watermark that throws must not cost the spool its flush.
        }
      }
    }
  }

  /// The types 7.8.1 lets an author correct and 7.8.2 lets an author withdraw.
  static const Set<String> _withdrawable = {
    'message', 'status', 'info', 'warning', 'offer', 'need', 'event', 'place',
    'passage', 'blog',
  };

  static final RegExp _idRe = RegExp(r'^[0-9a-f]{6}$');

  /// Drop the original and every edit of it that [p] (a verified withdrawal)
  /// names, and remember the identifiers. Only the author's own rows: the
  /// delete is keyed on the signer's `fromc`, so a withdrawal can never reach
  /// somebody else's packet.
  void _purgeWithdrawn(ZxSqlDb db, ZxSqlDbStatement tomb, XprsPacket p,
      String fromc, int nowMs) {
    final kind = (p['remove'] ?? '').trim().toLowerCase();
    if (kind.isEmpty || !_withdrawable.contains(kind)) return;
    final target = (p['r'] ?? '').trim().toLowerCase();
    if (!_idRe.hasMatch(target) || fromc.isEmpty) return;
    tomb.execute([target, fromc, nowMs]);
    final edits = db.select(
        'SELECT id FROM packets WHERE fromc = ? '
        "AND (wire LIKE '% edit:' || ? || ' %' OR wire LIKE '% edit:' || ?)",
        [fromc, target, target]);
    for (final r in edits) {
      tomb.execute([r['id'] as String, fromc, nowMs]);
    }
    _delete(db, 'DELETE FROM packets WHERE fromc = ? AND id = ?',
        [fromc, target]);
    for (final r in edits) {
      _delete(db, 'DELETE FROM packets WHERE fromc = ? AND id = ?',
          [fromc, r['id']]);
    }
  }

  /// A moderator's removal of [target] in [group] (10.4.1), already checked
  /// against the roster at its moment: drop the message and its edits, which
  /// were sent to the group, whoever wrote them. Remembered under the group's
  /// own name so a replay is refused the same way.
  void purgeModerated(String group, String target) {
    final db = _db;
    final g = _base(group);
    if (db == null || g.isEmpty || !_idRe.hasMatch(target)) return;
    try {
      // A restart replays every act: the first time did the work, so later
      // ones are one primary-key lookup instead of a walk of the group's rows.
      if (db.select('SELECT 1 FROM withdrawn WHERE id = ? AND fromc = ? LIMIT 1',
              [target, '*$g']).isNotEmpty) {
        return;
      }
      final ids = [
        target,
        for (final r in db.select(
            'SELECT id FROM packets WHERE toc = ? '
            "AND (wire LIKE '% edit:' || ? || ' %' OR wire LIKE '% edit:' || ?)",
            [g, target, target]))
          r['id'] as String,
      ];
      final now = DateTime.now().millisecondsSinceEpoch;
      // 10.10: a station's own rooms are undirected, so a removal in them
      // (the station is the group) deletes the undirected row too.
      final own = g == _selfBase.toUpperCase();
      db.transaction(() {
        for (final id in ids) {
          _delete(db, 'DELETE FROM packets WHERE toc = ? AND id = ?', [g, id]);
          if (own) {
            _delete(db, "DELETE FROM packets WHERE toc = '' AND id = ?", [id]);
          }
          db.execute(
              'INSERT OR IGNORE INTO withdrawn(id,fromc,ts) VALUES(?,?,?)',
              [id, '*$g', now]);
        }
        _saveCounts(db);
      });
    } catch (e) {
      LogService.instance.add('XPRS archive: moderated purge failed: $e');
    }
  }

  /// True when [p] is an original or an edit that a verified withdrawal of
  /// the same author already destroyed. A withdrawal itself is never refused.
  bool _isWithdrawn(ZxSqlDb db, XprsPacket p, String fromc) {
    if (p.has('remove') || !_withdrawable.contains(p.type)) return false;
    final root = (p['edit'] ?? '').trim().toLowerCase();
    final ids = [xprsIdentifier(p), if (_idRe.hasMatch(root)) root];
    final to = _base(p['d'] ?? '');
    for (final id in ids) {
      final r = db.select(
          'SELECT 1 FROM withdrawn WHERE id = ? AND (fromc = ? OR fromc = ?) '
          'LIMIT 1',
          [id, fromc, '*$to']);
      if (r.isNotEmpty) return true;
    }
    return false;
  }

  /// How many presence rows a station followed by callsign keeps on the
  /// followed shelf: a week of a device reporting every five minutes.
  static const int followedPresenceMax = 2016;

  /// Keep the newest [followedPresenceMax] presence rows of [fromc] on the
  /// followed shelf and drop the rest.
  ///
  /// The followed tier has no quota and no expiry (XPRS.md 12), which is right
  /// for what a person says and unbounded for a device that says the same
  /// thing every minute for years. Ordered by the packet's own `ts:`, so a
  /// replayed old page never displaces a newer reading; served by
  /// idx_pk_from(fromc, pts). A row a public archiver keeps for strangers is
  /// on another shelf and not touched.
  void _capFollowedPresence(ZxSqlDb db, String fromc) {
    if (fromc.isEmpty) return;
    _delete(db,
        'DELETE FROM packets WHERE fromc = ? AND tier = ? '
        "AND type IN ('observation','service') AND id NOT IN ("
        'SELECT id FROM packets WHERE fromc = ? AND tier = ? '
        "AND type IN ('observation','service') ORDER BY pts DESC LIMIT ?)",
        [fromc, Tier.followed.index, fromc, Tier.followed.index,
         followedPresenceMax]);
  }

  /// Keep, per callsign, only the identity announcements that still carry the
  /// newest value of some field.
  ///
  /// §6.3.2: "An identity announcement carries any subset of these fields, and
  /// a receiver keeps, for each field, **the value from the newest verifiable
  /// announcement that carried it**." A station re-announces every thirty
  /// minutes (§18.1) and each announcement carries a fresh `ts:`, so each is a
  /// different §5 identifier and a different row: 48 rows a day per station if
  /// nothing collapses them.
  ///
  /// The fields are `k:` (the key binding, re-sent often) and the decoration,
  /// `nick:`, `file:` and `m:`, which may arrive split across packets because
  /// the whole does not fit one frame on every bearer. A row goes only when
  /// every field it carries is also carried by a NEWER row, so a key-only
  /// announcement can never evict the picture, and a picture-only one can never
  /// evict the description. Newest is the packet's own `ts:`, not when we heard
  /// it, so a re-aired old announcement cannot displace a newer one.
  ///
  /// Only a verified row covers a verified one: a decoration stored while the
  /// sender's key was still unknown must not evict the one that was checked.
  /// Unverified rows are collapsed among themselves the same way. At most four
  /// rows of each kind per station, for ever.
  static const _identityFields = ['k', 'nick', 'file', 'm', 'url'];

  void _collapseIdentities(ZxSqlDb db, String fromc) {
    if (fromc.isEmpty) return;
    final rows = db.select(
        "SELECT id, wire, sig FROM packets WHERE type = 'identity' AND fromc = ? "
        'ORDER BY pts DESC, ts DESC LIMIT 64',
        [fromc]);
    final coveredVerified = <String>{};
    final coveredAny = <String>{};
    for (final r in rows) {
      final p = XprsPacket.parse(r['wire'] as String? ?? '');
      final fields = <String>{
        for (final f in _identityFields)
          if (p != null && p.has(f)) f,
      };
      final verified = (r['sig'] as int? ?? 0) == XprsSigState.verified.index;
      final covered = verified ? coveredVerified : coveredAny;
      if (fields.every(covered.contains)) {
        _delete(db, 'DELETE FROM packets WHERE id = ?', [r['id']]);
        continue;
      }
      coveredAny.addAll(fields);
      if (verified) coveredVerified.addAll(fields);
    }
  }

  /// Have [a] and [b] exchanged a DIRECT message before, in either direction?
  ///
  /// Section 13.7.1 gates the automatic receipt on exactly this: "a direct
  /// message has already passed between the two callsigns, in either
  /// direction". Not politeness — an acknowledgement is airtime on a shared
  /// channel, and answering a stranger also confirms to everyone listening that
  /// this callsign is here and awake. Two stations that have already exchanged
  /// have both costs priced in; a stranger has not agreed to either.
  ///
  /// Indexed on `(fromc, toc)` via the existing type/time index; the limit makes
  /// it a lookup rather than a scan.
  bool hasExchanged(String a, String b) {
    final db = _db;
    if (db == null) return false;
    final x = _base(a), y = _base(b);
    if (x.isEmpty || y.isEmpty) return false;
    // Two lookups on idx_pk_from (fromc, ...): an OR of the two pairs made
    // the planner scan the spool.
    bool sent(String f, String t) => db.select(
        "SELECT 1 FROM packets WHERE fromc = ? AND toc = ? AND type = 'message' "
        'LIMIT 1',
        [f, t]).isNotEmpty;
    return sent(x, y) || sent(y, x);
  }

  /// Our base callsign, set by the owner at init/profile switch so `mine` can
  /// be computed at flush time without asking a service from inside the store.
  ///
  /// This is the name this station AIRS: an operator's licensed callsign when
  /// they have one, else the one their key derives (XPRS.md 6.4.1). We wear
  /// exactly one name on the air (XPRS.md 3.0.1).
  String selfCallsign = '';
  String get _selfBase => _base(selfCallsign);

  /// Names this station still ANSWERS to, bare and uppercase.
  ///
  /// An operator who sets their licensed callsign starts airing `CT1ABC`, but
  /// every peer that has met them holds a binding for the callsign their key
  /// derives, and a 1:1 already on its way is addressed to that one. Refusing
  /// it as not-for-us would lose mail for the sake of tidiness.
  ///
  /// So we send under one name and answer to both. This holds the ones we no
  /// longer air, which today means exactly one: the derived callsign. It is
  /// deliberately NOT used by the echo skip (a packet bearing our old name is
  /// not our own echo, and suppressing it would hide a diagnostic) and NOT by
  /// closed-group membership, which is a verified record of a name and is not
  /// ours to alias (XPRS.md 6.4.2).
  Set<String> selfAlsoKnownAs = const {};

  /// Is [d] addressed to this station, under any name it answers to?
  ///
  /// THE test for "our own mail". It was four hand-written comparisons, two of
  /// which compared the whole string rather than the base, so a 1:1 to another
  /// of our own devices (`X1SELF-2`, XPRS.md 3.1) was already read as
  /// somebody else's at the gateway.
  bool addressesUs(String? d) {
    final to = _base((d ?? '').trim()).toUpperCase();
    if (to.isEmpty) return false;
    return to == _selfBase.toUpperCase() || selfAlsoKnownAs.contains(to);
  }

  void _prune(ZxSqlDb db, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    // Age, once per session. Our own side of the conversation is exempt, the
    // same way the byte cap below already exempts it: this station IS its own
    // archive, and a log that deletes what you said and what was said to you
    // is not one. Everyone else's traffic still ages out — that is the
    // archiver's job and where the storage actually goes.
    //
    // Own `observation` beacons are the exception to the exemption: one every
    // 300 s is ~100k rows a year, and a beacon is telemetry rather than
    // something anybody said. They age out with the rest.
    //
    // Expired declarations go in the same breath.
    if (!_prunedThisSession) {
      _prunedThisSession = true;
      try {
        db.transaction(() {
        // `identity` never ages out. It is the key binding, and a station
        // heard once a year ago is exactly the one whose signature this
        // station cannot check without it (§18.1). Bounded by construction —
        // `_collapseIdentities` keeps two rows per callsign, ever — so ten
        // thousand distinct stations is about 3.6 MB against a 500 MB spool.
        // A followed station's traffic does not age out either (30.3), so the
        // age pass is a strangers' pass: `tier = 2`, with our own beacons the
        // one thing of ours that still expires.
        _delete(db,
            'DELETE FROM packets WHERE pts < ? '
            "AND (tier = 2 OR (own = 1 AND type = 'observation')) "
            "AND mine = 0 AND type != 'identity'",
            [now - maxAgeDays * 86400000]);
        db.execute(
            'DELETE FROM mailbox_decl WHERE until IS NOT NULL AND until < ?',
            [now]);
        // A year is far longer than any copy is held or replayed.
        db.execute('DELETE FROM withdrawn WHERE ts < ?',
            [now - 365 * 86400000]);
        _saveCounts(db);
        });
      } catch (e) {
        LogService.instance.add('XPRS archive: age prune failed: $e');
      }
    }
    // Byte cap, every 20th flush (~7 min of dense traffic). One bounded
    // batch that converges over successive flushes rather than looping.
    if (++_flushesSinceCap < 20) return;
    _flushesSinceCap = 0;
    try {
      db.transaction(() {
        _pruneGroups(db);
        _saveCounts(db);
      });
    } catch (e) {
      LogService.instance.add('XPRS archive: group prune failed: $e');
    }
    try {
      _capBytes(db, now);
    } catch (e) {
      _loadCounts(db);
      LogService.instance.add('XPRS archive: cap prune failed: $e');
    }
    // The file appends; superseded pages stay until a compaction. Rewrite it
    // once it has doubled since the last one (ZxSqlDb.maybeCompact).
    try {
      if (db.maybeCompact()) {
        LogService.instance
            .add('XPRS archive: compacted to ${db.stats().fileBytes} bytes');
      }
    } catch (e) {
      LogService.instance.add('XPRS archive: compaction failed: $e');
    }
  }

  /// The byte cap: the wire bytes held (the counters) against [maxBytes].
  ///
  /// The cap is the STRANGERS' quota. Mine and the people I follow are
  /// exempt by tier (XPRS.md 30.3: "a station holds the notes of the people
  /// its operator follows and never drops them… and it discards a stranger's
  /// chatter within hours"), so the number the operator sets is honestly a
  /// bound on other people's traffic rather than on everything. Identity is
  /// exempt too: the cap evicts OLDEST FIRST, and a key binding heard long
  /// ago is the row most likely to be oldest and least likely to be heard
  /// again. One bounded batch per call, converging over successive flushes.
  ///
  /// §12.11: class first, age second. The spool (ordinary heard traffic, no
  /// `d:`) goes before custody mail (`d:` for a station that did NOT name
  /// us), which goes before declared mail (`d:` for a callsign whose
  /// `t:mailbox hold:` names us) — the last thing an archiver may drop.
  void _capBytes(ZxSqlDb db, int now) {
    final bytes = dataBytes;
    if (bytes <= maxBytes) return;
    var rows = 0, strangerBytes = 0;
    _counts.forEach((k, c) {
      if (k.endsWith('|2') && !k.startsWith('identity|')) {
        rows += c[0];
        strangerBytes += c[1];
      }
    });
    if (rows == 0) return;
    final avg = (strangerBytes / rows).clamp(64, 1 << 20);
    var drop = ((bytes - maxBytes) / avg).ceil() + 500;
    if (drop > 20000) drop = 20000;
    const strangers = "own = 0 AND mine = 0 AND type != 'identity' AND tier = 2";
    final ids = <String>[
      // class 1: the spool, oldest first (idx_pk_to: toc = '', by pts)
      for (final r in db.select(
          "SELECT id FROM packets WHERE toc = '' AND $strangers "
          'ORDER BY pts ASC LIMIT ?',
          [drop]))
        r['id'] as String,
    ];
    if (ids.length < drop) {
      final declared = <String>{
        for (final r in db.select(
            'SELECT DISTINCT fromc FROM mailbox_decl WHERE pos >= 0 '
            'AND (until IS NULL OR until >= ?)',
            [now]))
          r['fromc'] as String,
      };
      final custody = <String>[], held = <String>[];
      for (final r in db.select(
          "SELECT id, toc FROM packets WHERE tier = 2 AND toc <> '' "
          "AND own = 0 AND mine = 0 AND type != 'identity' "
          'ORDER BY pts ASC LIMIT ?',
          [drop - ids.length])) {
        (declared.contains(r['toc']) ? held : custody).add(r['id'] as String);
      }
      ids.addAll(custody);
      ids.addAll(held);
    }
    db.transaction(() {
      for (final id in ids.take(drop)) {
        _delete(db, 'DELETE FROM packets WHERE id = ?', [id]);
      }
      _saveCounts(db);
    });
  }

  /// The per-group ceiling (10.9.3), one bounded batch per group over it.
  void _pruneGroups(ZxSqlDb db) {
    final over = db.select(
        'SELECT toc, SUM(length(wire)) b, COUNT(*) n FROM packets '
        "WHERE toc >= 'X5' AND toc < 'X6' AND own = 0 "
        "AND type NOT IN ('identity', 'moderate') "
        'GROUP BY toc HAVING b > ?',
        [maxGroupBytes]);
    for (final r in over) {
      final toc = r['toc'] as String;
      final b = r['b'] as int;
      final n = r['n'] as int;
      if (n == 0) continue;
      final avg = (b / n).clamp(64, 1 << 20);
      var drop = ((b - maxGroupBytes) / avg).ceil() + 50;
      if (drop > 5000) drop = 5000;
      _delete(db,
          'DELETE FROM packets WHERE id IN '
          '(SELECT id FROM packets WHERE toc = ? AND own = 0 '
          "AND type NOT IN ('identity', 'moderate') ORDER BY pts ASC LIMIT ?)",
          [toc, drop]);
      groupPruned += drop;
    }
  }

  /// Move rows between shelves when the follow list changes.
  ///
  /// Following somebody should protect what they already said, and unfollowing
  /// should let it age like anyone else's — otherwise the tier would only ever
  /// describe traffic heard after the decision. Rare and indexed: it runs when
  /// the operator follows or unfollows, not on any packet path.
  void retier({Set<String> promoted = const {}, Set<String> demoted = const {}}) {
    final db = _db;
    if (db == null) return;
    try {
      void move(String sql, String c, int from, int to) {
        for (final r in db.select(
            '$sql RETURNING type, toc, length(wire) b', [_base(c)])) {
          final b = (r['b'] as num).toInt();
          _bump(r['type'] as String, r['toc'] as String, from, -1, -b);
          _bump(r['type'] as String, r['toc'] as String, to, 1, b);
        }
      }

      db.transaction(() {
        for (final c in promoted) {
          move('UPDATE packets SET tier = 1 WHERE fromc = ? AND tier = 2', c, 2, 1);
        }
        for (final c in demoted) {
          move('UPDATE packets SET tier = 2 WHERE fromc = ? AND tier = 1', c, 1, 2);
        }
        _saveCounts(db);
      });
    } catch (e) {
      _loadCounts(db);
      LogService.instance.add('XPRS archive: retier failed: $e');
    }
  }

  /// How many rows sit on each shelf — what the Archiver screen shows, and the
  /// only honest answer to "what is this device keeping, and for whom".
  ///
  /// From the counters kept with the rows; read when the screen refreshes (the archive fires
  /// `core.archive` at most every 20 s), never per packet.
  ({int own, int followed, int stranger, int total}) countsByTier() {
    final db = _db;
    if (db == null) return (own: 0, followed: 0, stranger: 0, total: 0);
    var mine = 0, fol = 0, str = 0;
    _counts.forEach((k, c) {
      switch (k.substring(k.lastIndexOf('|') + 1)) {
        case '0':
          mine += c[0];
        case '1':
          fol += c[0];
        default:
          str += c[0];
      }
    });
    return (own: mine, followed: fol, stranger: str, total: mine + fol + str);
  }

  /// Drop everything this station holds about one closed group.
  ///
  /// Forgetting a group is not deleting it: the group goes on existing
  /// wherever anybody else holds its record, and 26.6 says as much about the
  /// key. This is only the local copy — and it has to include the archive,
  /// because the roster is replayed from these rows at startup and a group
  /// forgotten in memory alone comes straight back on the next launch.
  ///
  /// Rides `idx_pk_to(toc, pts)`, so it is a range delete rather than a scan.
  int forgetGroup(String group) {
    final db = _db;
    if (db == null) return 0;
    final g = _base(group.trim().toUpperCase());
    if (g.isEmpty) return 0;
    flush(); // anything still queued would be written back after the delete
    return db.transaction(() {
      final n = _delete(db, 'DELETE FROM packets WHERE toc = ?', [g]) +
          _delete(db, 'DELETE FROM packets WHERE fromc = ?', [g]);
      db.execute('DELETE FROM newest WHERE fromc = ?', [g]);
      _saveCounts(db);
      return n;
    });
  }

  /// What the spool occupies on disk, for the Archiver screen: the file,
  /// compressed by zx, with any superseded pages not yet compacted away.
  int get spoolBytes {
    final db = _db;
    return db == null ? 0 : db.stats().fileBytes;
  }

  // ── mailbox declarations (section 13.12) ─────────────────────────────────

  /// Act on a `t:mailbox` packet. Only a VERIFIED one is acted on — §13.12:
  /// "a receiver that cannot verify one must not act on it"; forging one is
  /// how an attacker collects somebody's mail. Returns true when the
  /// declaration (or cancellation) named us and was recorded.
  bool recordMailboxDecl(XprsPacket p, {int? nowMs}) {
    final db = _db;
    if (db == null || p.type != 'mailbox') return false;
    final fromc = _base(p['f'] ?? '');
    if (fromc.isEmpty) return false;
    final state = xprsVerify(p, keyResolver?.call(fromc));
    if (state != XprsSigState.verified) return false;

    if ((p['remove'] ?? '') == 'mailbox') {
      final r = (p['r'] ?? '').trim();
      if (r.isEmpty) return false;
      db.execute(
          'DELETE FROM mailbox_decl WHERE id=? AND fromc=?', [r, fromc]);
      return true;
    }
    final hold = (p['hold'] ?? '')
        .split(',')
        .map(_base)
        .where((c) => c.isNotEmpty)
        .toList();
    final pos = hold.indexOf(_selfBase);
    // A declaration NOT naming us is still recorded (pos -1): section 36.8.1
    // routes held mail by "who holds for X", and an archiver that only
    // remembered its own appointments could never answer it. The return
    // value keeps its old meaning -- "named us" -- because ingest admission
    // rides on it.
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    db.execute(
        'INSERT OR REPLACE INTO mailbox_decl(id,fromc,pos,since,until,ts,wire) '
        'VALUES(?,?,?,?,?,?,?)',
        [
          xprsIdentifier(p),
          fromc,
          pos,
          xprsParseTs(p['since']),
          xprsParseTs(p['until']),
          xprsParseTs(p['ts']) ?? now,
          p.encode(),
        ]);
    return pos >= 0;
  }

  /// L1 of the gossip layers (36.9.4): who [baseCallsign] declared as its
  /// mailboxes, in the declaration's own order of preference (13.12). The
  /// narrowest active window wins (13.12.1); windowed beats open-ended.
  ///
  /// A visitor this station serves through its page ([servesVisitor]) and
  /// who has not declared yet is held HERE: the answer is this station, so
  /// a holder of their mail anywhere routes it to the page that delivers
  /// it (12.8.1 consults exactly this). Their own declaration, once made,
  /// replaces that answer — the recipient's word beats the offer.
  List<String> holdersFor(String baseCallsign, {int? nowMs}) {
    final db = _db;
    if (db == null) return const [];
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final base = _base(baseCallsign);
    final rows = db.select(
        'SELECT wire FROM mailbox_decl WHERE fromc=? '
        'AND (since IS NULL OR since<=?) AND (until IS NULL OR until>=?) '
        'ORDER BY (until IS NULL) ASC, ts DESC LIMIT 1',
        [base, now, now]);
    if (rows.isEmpty) {
      return _served.contains(base) && _selfBase.isNotEmpty
          ? [_selfBase]
          : const [];
    }
    final p = XprsPacket.parse(rows.first['wire'] as String);
    if (p == null) return const [];
    return (p['hold'] ?? '')
        .split(',')
        .map(_base)
        .where((c) => c.isNotEmpty)
        .toList();
  }

  /// Whether [baseCallsign] currently has an active declaration naming us —
  /// the admission ticket for its Reticulum-borne traffic (§36.3). A visitor
  /// this station serves is declared by the offer it accepted
  /// ([servesVisitor]): its mail is admitted the same way.
  bool hasActiveDecl(String baseCallsign, {int? nowMs}) {
    final db = _db;
    if (db == null) return false;
    if (_served.contains(_base(baseCallsign))) return true;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    // pos>=0: only declarations that NAME US are an admission ticket --
    // the table now also holds everyone else's declarations for routing
    // (holdersFor above), and those must not open the door.
    return db.select(
        'SELECT 1 FROM mailbox_decl WHERE fromc=? AND pos>=0 '
        'AND (since IS NULL OR since<=?) AND (until IS NULL OR until>=?) '
        'LIMIT 1',
        [_base(baseCallsign), now, now]).isNotEmpty;
  }

  int get declCount {
    final db = _db;
    if (db == null) return 0;
    return db.select('SELECT COUNT(*) c FROM mailbox_decl').first['c'] as int;
  }

  /// How many stations are cared for here: distinct declarers with an active
  /// declaration that NAMES this station (12.9.5), plus the visitors this
  /// station serves through its page and who have not declared yet (one
  /// station counted once). This is the archiver's load, and what sets its
  /// `room:` (13.0.2).
  int caredFor({int? nowMs}) {
    final db = _db;
    if (db == null) return 0;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return db.select(
        'SELECT COUNT(*) c FROM ('
        'SELECT fromc c FROM mailbox_decl WHERE pos>=0 '
        'AND (since IS NULL OR since<=?) AND (until IS NULL OR until>=?) '
        'UNION SELECT call c FROM served_visitors)',
        [now, now]).first['c'] as int;
  }

  // ── served visitors (12.7, 12.8.3: the station as a visitor's mailbox) ───

  /// Callsigns in `served_visitors`, mirrored in RAM: the receive funnel asks
  /// [servesVisitor] per directed packet and must not pay a query for it.
  final Set<String> _served = {};

  /// This station offered itself as [call]'s mailbox (WebChatApi
  /// `/api/session`, `offer`), or [call] came back: insert, or refresh `last`.
  void noteServed(String call, {int? nowMs}) {
    final db = _db;
    final c = _base(call);
    if (db == null || c.isEmpty) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    db.execute(
        'INSERT INTO served_visitors(call,since,last) VALUES(?,?,?) '
        'ON CONFLICT(call) DO UPDATE SET last=excluded.last',
        [c, now, now]);
    _served.add(c);
  }

  /// [call] was heard again through the page: refresh `last` when it is a
  /// visitor this station serves; nothing otherwise (the offer is
  /// [noteServed]'s, made when the station has room).
  void touchServed(String call, {int? nowMs}) {
    final c = _base(call);
    if (!_served.contains(c)) return;
    _db?.execute('UPDATE served_visitors SET last=? WHERE call=?',
        [nowMs ?? DateTime.now().millisecondsSinceEpoch, c]);
  }

  /// Is [call] a visitor this station is the mailbox of? One set lookup.
  bool servesVisitor(String call) => _served.contains(_base(call));

  /// Every served visitor: callsign, when the offer was made, when last seen.
  List<({String call, int sinceMs, int lastMs})> servedVisitors(
      {int max = 10000}) {
    final db = _db;
    if (db == null) return const [];
    return [
      for (final r in db.select(
          'SELECT call,since,last FROM served_visitors ORDER BY last DESC '
          'LIMIT ?',
          [max]))
        (
          call: r['call'] as String,
          sinceMs: (r['since'] as num).toInt(),
          lastMs: (r['last'] as num).toInt(),
        ),
    ];
  }

  /// Forget [call] as a served visitor (its declaration now names somebody
  /// else, or the operator said so). Its archived mail stays where it is.
  void forgetServed(String call) {
    final c = _base(call);
    _db?.execute('DELETE FROM served_visitors WHERE call=?', [c]);
    _served.remove(c);
  }

  /// The lines of this station's directory (12.9): every callsign the spool
  /// holds a record from, with the freshest record's own `ts:`, and every
  /// served visitor with when it was last seen. Bounded by [limit]; one
  /// indexed GROUP BY, run by the announcer every ten minutes on a public
  /// archiver and nowhere else.
  List<XprsDirectoryEntry> directoryEntries({int limit = 10000}) {
    final db = _db;
    if (db == null) return const [];
    final out = <String, int>{};
    for (final r in db.select(
        'SELECT fromc, pts m FROM newest ORDER BY fromc LIMIT ?', [limit])) {
      out[r['fromc'] as String] = (r['m'] as num).toInt();
    }
    for (final v in servedVisitors(max: limit)) {
      final was = out[v.call];
      if (was == null || v.lastMs > was) out[v.call] = v.lastMs;
    }
    final calls = out.keys.toList()..sort();
    return [
      for (final c in calls.take(limit)) XprsDirectoryEntry(c, out[c]!),
    ];
  }

  // ── reading the spool ─────────────────────────────────────────────────────

  /// Archived packets, newest first by the packet's own timestamp — the order
  /// a `cmd:history` replay airs them in (§25.2.1). [only] matches sender or
  /// addressee. One row past [limit] is never returned; the responder asks
  /// for limit+1 itself to learn whether more exists.
  /// What counts as conversation: the default a radio replay serves when the
  /// asker named no `kind:`. A person catching up wants what was SAID, and a
  /// twelve-record page spent on presence beacons reaches none of it.
  static const Set<String> kXprsTalk = {
    'message', 'reaction', 'blog', 'event', 'warning', 'sos', 'info', 'status',
  };

/// How many records of [types] the archive holds, without building any.
  ///
  /// [query] materialises a Dart Map per row INCLUDING the wire, so asking it
  /// for a count means allocating the page to throw it away. A caller that
  /// wanted `.length` of a thousand-row page ran that once a minute on the
  /// main isolate, forever, on the device with the biggest archive -- which is
  /// megabytes of garbage a minute to learn one integer, and is what an
  /// out-of-memory on a busy archiver looks like from the inside
  /// (docs/performance.md 4.2: the drains are cheap calls in hot loops, not
  /// expensive algorithms).
  ///
  /// [undirected] counts only what carries no `d:` (publications), which is
  /// all a stranger on a hotspot may be told the size of.
  int countOf({List<String>? types, bool undirected = false}) {
    if (_db == null) return 0;
    final want = types == null || types.isEmpty ? null : types.toSet();
    var n = 0;
    _counts.forEach((k, c) {
      final parts = k.split('|');
      if (want != null && !want.contains(parts[0])) return;
      if (undirected && parts[1] != '1') return;
      n += c[0];
    });
    return n;
  }

    List<Map<String, dynamic>> query({
    int? sinceMs,
    int? untilMs,
    String? only,
    List<String>? types,
    List<String>? to,
    int limit = 200,
    String? rankFor,
    /// Answer only from this station's OWN traffic.
    ///
    /// What a private station serves a stranger (XPRS.md 12: it "serves its
    /// own publications to whoever asks over the radio"). Serving the followed
    /// shelf as well would publish the follow list, which 16.2 keeps on the
    /// device.
    bool ownOnly = false,
    /// Exactly this author, bare callsign, on idx_pk_from. [only] is the
    /// wider 12.6 question (author, addressee or a `hears:` list) and a scan;
    /// "what did this device say" is this one.
    String? from,
    /// Every author whose callsign says it is this kind (xprs_presence.dart),
    /// by the kind's prefix on the same index. A kind without one prefix (a
    /// station: X2, X3 or a licence) selects nothing.
    XprsKind? fromKind,
    /// Only what may be offered to this asker (XPRS.md 12.1): publications
    /// (no `d:`), mail to or from it, and group traffic, whose membership is
    /// the group's own business (10.9.3). Anybody else's mail is held for its
    /// addressee and "never offered to a third party".
    String? mailFor,
    /// One chat room (XPRS.md 9.11): `local`, `regional` or `global`, by the
    /// scope word its author wrote before `m:`. Global is everything that is
    /// neither local nor regional (no scope, `scope:global`, a country). The
    /// web chat asks a room at a time so that one busy room cannot fill the
    /// whole window (spec/API-HTTP.md, `room`). Combine with [to] = [''] for
    /// the undirected traffic a room shows.
    String? room,
    /// Exactly one packet, by its section 5 identifier: the primary key, so
    /// one row and no scan. What a message's Info page reads to say how that
    /// message travelled (its wire, `via:`, bearer, signal, when it was heard
    /// and how many copies collapsed onto it).
    String? id,
  }) {
    final db = _db;
    if (db == null) return const [];
    final where = StringBuffer('1=1');
    final args = <Object?>[];
    if (id != null && id.trim().isNotEmpty) {
      where.write(' AND id = ?');
      args.add(id.trim().toLowerCase());
    }
    if (room != null && room.isNotEmpty) {
      // The header is the wire up to ` m:`, padded so ` scope:local ` matches
      // at its end too; text after m: never decides the room.
      const head = "(substr(wire, 1, instr(wire || ' m:', ' m:')) || ' ')";
      const local = "instr($head, ' scope:local ') > 0";
      const regional = "instr($head, ' scope:regional ') > 0";
      switch (room) {
        case 'local':
          where.write(' AND $local');
        case 'regional':
          where.write(' AND $regional');
        case 'global':
          where.write(' AND NOT ($local) AND NOT ($regional)');
        default:
          return const [];
      }
    }
    if (ownOnly) where.write(' AND own = 1');
    if (from != null && from.trim().isNotEmpty) {
      where.write(' AND fromc = ?');
      args.add(_base(from));
    }
    if (mailFor != null && mailFor.trim().isNotEmpty) {
      final a = _base(mailFor);
      where.write(" AND (toc = '' OR toc = ? OR fromc = ? "
          "OR (toc >= 'X5' AND toc < 'X6'))");
      args
        ..add(a)
        ..add(a);
    }
    if (fromKind != null) {
      final prefix = xprsKindPrefix(fromKind);
      if (prefix == null) return const [];
      // A range, not GLOB: the same rows, and an index range scan whatever
      // the planner makes of a bound pattern. Callsigns are uppercase ASCII,
      // so 'X4' <= c < 'X5' is exactly the X4 prefix.
      final last = prefix.codeUnitAt(prefix.length - 1);
      where.write(' AND fromc >= ? AND fromc < ?');
      args
        ..add(prefix)
        ..add(prefix.substring(0, prefix.length - 1) +
            String.fromCharCode(last + 1));
    }
    // Ask for the rows you will render, not a page you will sieve.
    //
    // The chat rooms asked for "the newest 48 messages" and filtered on their
    // side, which is a lottery against whatever else the station is doing.
    // Measured on the C61 mid store-and-forward: the newest 48 message rows
    // were ALL this station's own custody re-airs to one absent peer — 343 of
    // the newest 371 spanning five minutes — so of 400 rows fetched, the
    // rooms could render zero, and a group post sat unrendered in the archive
    // for an hour. A destination list makes the window mean something: the
    // empty string is the undirected traffic a scope room reads, a group
    // callsign is that group's room, and idx_pk_to(toc, pts) serves both.
    if (to != null && to.isNotEmpty) {
      where.write(' AND toc IN (${List.filled(to.length, '?').join(',')})');
      args.addAll(to.map((d) => d.trim().isEmpty ? '' : _base(d)));
    }
    // A caller that only reads conversations (message + reaction) must not
    // have its window eaten by the observation chatter, which outnumbers
    // everything else on a busy bench.
    if (types != null && types.isNotEmpty) {
      where.write(' AND type IN (${List.filled(types.length, '?').join(',')})');
      args.addAll(types);
    }
    if (sinceMs != null) {
      where.write(' AND pts >= ?');
      args.add(sinceMs);
    }
    if (untilMs != null) {
      where.write(' AND pts < ?');
      args.add(untilMs);
    }
    if (only != null && only.trim().isNotEmpty) {
      final c = _base(only);
      // An observation ABOUT the named callsign has that callsign in its
      // `hears:` list and someone else in `f:` — matching sender/addressee
      // alone made `only:X kind:observation` (36.9.4's bulk-gossip ask, "the
      // signed sightings this station holds about X") return nothing, ever.
      // instr() over the wire is a scan, but one confined to observation
      // rows already narrowed by the type filter and the time window; a
      // substring hit beyond the hears: list adds at worst an extra record
      // to a page, and a sighting informs routing, never compels it
      // (10.6.3).
      where.write(" AND (fromc=? OR toc=? OR "
          "(type='observation' AND instr(wire, ?) > 0))");
      args
        ..add(c)
        ..add(c)
        ..add(c);
    }
    // Relevance bands, newest-first WITHIN each band (25.2.1 keeps newest
    // first; this only decides which newest).
    //
    // Measured on a bench station: the newest 200 records were 120 t:identity,
    // 69 t:observation, 11 t:service and no messages, so a strictly
    // chronological page of twelve is twelve beacons and the conversation is
    // never reached. Ordering by band first costs one CASE and uses the
    // (toc,pts) and (fromc,pts) indexes that already exist.
    var order = 'pts DESC';
    if (rankFor != null && rankFor.trim().isNotEmpty) {
      final me = _base(rankFor);
      final talk = kXprsTalk.map((t) => "'$t'").join(',');
      order = 'CASE '
          // 1. their own mail, either direction
          'WHEN toc=? OR fromc=? THEN 0 '
          // 2. what was said locally
          'WHEN type IN ($talk) THEN 1 '
          // 3. presence and service chatter, which a short page rarely reaches
          'ELSE 2 END, pts DESC';
      args
        ..add(me)
        ..add(me);
    }
    args.add(limit.clamp(1, 1000));
    final rows = db.select(
        'SELECT id,ts,pts,type,fromc,toc,bearer,rssi,mine,own,sig,heard,wire '
        'FROM packets WHERE $where ORDER BY $order LIMIT ?',
        args);
    return [
      for (final r in rows)
        {
          'id': r['id'],
          'ts': (r['pts'] as int) ~/ 1000,
          'heardTs': (r['ts'] as int) ~/ 1000,
          'bearer': r['bearer'],
          'rssi': r['rssi'],
          'from': r['fromc'],
          'to': r['toc'],
          'type': r['type'],
          'mine': (r['mine'] as int) != 0,
          'own': (r['own'] as int) != 0,
          'sig': XprsSigState.values[(r['sig'] as int)].name,
          'heard': r['heard'],
          'wire': r['wire'],
          ..._reachOf(r['wire'] as String, r['bearer'] as String? ?? '',
              (r['own'] as int) != 0),
        }
    ];
  }

  /// XPRS.md 9.11 for a stored row: its scope, normalised as the live delivery
  /// states it, and whether it was heard in range. Our own rows were sent in
  /// range; a row heard on a bearer wider than its scope is in no room.
  static Map<String, Object> _reachOf(String wire, String bearer, bool own) {
    final p = XprsPacket.parse(wire);
    if (p == null) return const {'scope': 'global', 'inRange': true};
    return {
      'scope': xprsScope(p).scope.name,
      'inRange': own || xprsReachAdmits(xprsScopeReach(p), xprsBearerReach(bearer)),
    };
  }

  /// The packet time (ms) of the newest row [fromc] authored among [types],
  /// or null when none is held. One indexed row: what a catch-up puts in
  /// `since:` so an archiver re-airs only what this station lacks.
  int? newestPts(String fromc, {List<String> types = const []}) {
    final db = _db;
    final c = _base(fromc);
    if (db == null || c.isEmpty) return null;
    final byType = types.isEmpty
        ? ''
        : ' AND type IN (${List.filled(types.length, '?').join(',')})';
    final rows = db.select(
        'SELECT pts FROM packets WHERE fromc = ?$byType '
        'ORDER BY pts DESC LIMIT 1',
        [c, ...types]);
    return rows.isEmpty ? null : rows.first['pts'] as int;
  }

  /// Counters for /api/status-style checks.
  Map<String, dynamic> statusJson() {
    return {
      'ready': ready,
      'rows': countOf(),
      'bytes': spoolBytes,
      'data': dataBytes,
      'declarations': declCount,
      'pending': _pending.length,
      'admitted': admitted,
      'forged': forged,
      'dropped': dropped,
    };
  }
}
