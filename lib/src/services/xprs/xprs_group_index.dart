/*
 * xprs_group_index — ranking public groups (XPRS.md 12.9.7).
 *
 * An archiver counts, per public group and per week, the posts it admitted,
 * their distinct authors and (closed groups) the members who joined, each as
 * a 64-register HyperLogLog sketch, plus the group's member count with the
 * newest act it was counted from. It publishes them as an XGRP1 file named
 * on a line of its directory (12.9). A reader fetches the index of each
 * archiver it chose and puts them together: members from the most recent
 * record, everything else by combining sketches, so a post two archivers
 * both hold counts once. Weeks are counted from each post's own `ts:`, so an
 * archiver never needs to know today's date.
 *
 *   XprsSketch          the HyperLogLog: add, combine, estimate, 64 chars.
 *   XprsGroupIndexFile  compose / parse the XGRP1 listing, pure.
 *   XprsGroupIndex      the archiver's side: counts what it files, keeps the
 *                       four newest weeks per group, composes the file.
 *   XprsGroupRanking    the reader's side: the indexes of its archivers,
 *                       combined and ranked for a screen.
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../storage/store_db.dart';
import '../log_service.dart';
import '../receive/core_state.dart';
import 'xprs_callsign.dart';
import 'xprs_groups.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart' show xprsNowTs, xprsParseTs;

/// The week a moment falls in: whole weeks of 604 800 s since 1970 (12.9.7).
int xprsWeekOf(int epochMs) => (epochMs ~/ 1000) ~/ 604800;

/// Is [d] the name of an open group (7.3)? Uppercase, 1 to 16 characters,
/// and not shaped like a self-generated, another network's or an issued
/// callsign: that is how a station tells a group from a person.
bool xprsIsOpenGroupName(String d) {
  final c = d.trim().toUpperCase();
  if (c.isEmpty || c.length > 16) return false;
  if (!RegExp(r'^[A-Z0-9][A-Z0-9_-]*$').hasMatch(c)) return false;
  if (xprsIsSelfGenerated(c) || xprsIsForeignNodeNumber(c)) return false;
  if (xprsLooksIssued(c)) return false;
  return true;
}

/// A 64-register HyperLogLog (12.9.7): how many distinct things were added,
/// to within about 13%, in 64 characters.
class XprsSketch {
  XprsSketch() : r = Uint8List(m);
  XprsSketch._(this.r);

  static const int m = 64;
  static const String _b64 =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

  final Uint8List r;

  bool get isEmpty => r.every((v) => v == 0);

  /// Add [item] (an identifier, a callsign). True when a register moved.
  bool add(String item) {
    final h = crypto.sha256.convert(utf8.encode(item)).bytes;
    final idx = h[0] >> 2; // the top six bits
    // The remaining 58 bits: two from the first byte, then seven bytes.
    var lead = 0;
    var found = false;
    for (var bit = 1; bit >= 0 && !found; bit--) {
      if ((h[0] >> bit) & 1 == 1) {
        found = true;
      } else {
        lead++;
      }
    }
    for (var i = 1; i < 8 && !found; i++) {
      for (var bit = 7; bit >= 0; bit--) {
        if ((h[i] >> bit) & 1 == 1) {
          found = true;
          break;
        }
        lead++;
      }
    }
    final v = math.min(lead + 1, 59);
    if (v <= r[idx]) return false;
    r[idx] = v;
    return true;
  }

  /// Keep, register by register, the larger: the sketch of both. True when
  /// a register moved.
  bool merge(XprsSketch o) {
    var moved = false;
    for (var i = 0; i < m; i++) {
      if (o.r[i] > r[i]) {
        r[i] = o.r[i];
        moved = true;
      }
    }
    return moved;
  }

  /// How many distinct things were added (approximate).
  int estimate() {
    var sum = 0.0;
    var zeros = 0;
    for (final v in r) {
      sum += math.pow(2, -v);
      if (v == 0) zeros++;
    }
    var e = 0.709 * m * m / sum;
    if (e <= 2.5 * m && zeros > 0) e = m * math.log(m / zeros);
    return e.round();
  }

  String encode() => String.fromCharCodes([for (final v in r) _b64.codeUnitAt(v)]);

  static XprsSketch? decode(String s) {
    if (s.length != m) return null;
    final out = Uint8List(m);
    for (var i = 0; i < m; i++) {
      final v = _b64.indexOf(s[i]);
      if (v < 0 || v > 59) return null;
      out[i] = v;
    }
    return XprsSketch._(out);
  }

  XprsSketch copy() => XprsSketch._(Uint8List.fromList(r));
}

/// One week of a group: posts, posters and joins.
class XprsGroupWeek {
  XprsGroupWeek(this.week);
  final int week;
  final Map<String, XprsSketch> kinds = {}; // 'p', 's', 'j'
}

/// One group as an index states it.
class XprsGroupStats {
  XprsGroupStats(this.group);
  final String group;

  /// Members of a closed group, the `ts:` (epoch ms) and identifier of the
  /// newest act counted. Null for an open group, or a record not verified.
  int? members;
  int membersTs = 0;
  String membersId = '';
  final Map<int, XprsGroupWeek> weeks = {};

  XprsGroupWeek week(int w) => weeks.putIfAbsent(w, () => XprsGroupWeek(w));
}

class XprsGroupIndexFile {
  XprsGroupIndexFile._();
  static const String magic = 'XGRP1';
  static const String ext = 'xgrp';

  /// The largest index a reader takes: a thousand busy groups are some
  /// 400 kB (12.9.7).
  static const int maxBytes = 2 << 20;

  static String compose(Iterable<XprsGroupStats> groups) {
    final list = groups.toList()..sort((a, b) => a.group.compareTo(b.group));
    final b = StringBuffer('$magic\n');
    for (final g in list) {
      if (g.members != null) {
        b.write('${g.group} m ${g.members} ${xprsNowTs(g.membersTs)} '
            '${g.membersId.isEmpty ? '-' : g.membersId}\n');
      }
      for (final w in g.weeks.keys.toList()..sort()) {
        final kinds = g.weeks[w]!.kinds;
        final parts = <String>[];
        for (final k in const ['p', 's', 'j']) {
          final sk = kinds[k];
          if (sk != null && !sk.isEmpty) parts.add('$k ${sk.encode()}');
        }
        if (parts.isEmpty) continue;
        b.write('${g.group} w $w ${parts.join(' ')}\n');
      }
    }
    return b.toString();
  }

  /// The groups of an index, or null when the text is not one. A line that
  /// does not parse is skipped.
  static Map<String, XprsGroupStats>? parse(String text) {
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty || lines.first.trim() != magic) return null;
    final out = <String, XprsGroupStats>{};
    for (final raw in lines.skip(1)) {
      final t = raw.trim().split(RegExp(r'\s+'));
      if (t.length < 3) continue;
      final g = t[0].toUpperCase();
      if (!(g.startsWith('X5') || xprsIsOpenGroupName(g))) continue;
      if (t[1] == 'm' && t.length >= 4) {
        final n = int.tryParse(t[2]);
        final ts = xprsParseTs(t[3]);
        if (n == null || n < 0 || ts == null) continue;
        final s = out.putIfAbsent(g, () => XprsGroupStats(g));
        s.members = n;
        s.membersTs = ts;
        s.membersId = t.length > 4 && t[4] != '-' ? t[4] : '';
      } else if (t[1] == 'w') {
        final w = int.tryParse(t[2]);
        if (w == null || w < 0) continue;
        final s = out.putIfAbsent(g, () => XprsGroupStats(g));
        for (var i = 3; i + 1 < t.length; i += 2) {
          final k = t[i];
          if (k != 'p' && k != 's' && k != 'j') continue;
          final sk = XprsSketch.decode(t[i + 1]);
          if (sk != null) s.week(w).kinds[k] = sk;
        }
      }
    }
    return out;
  }

  static String shaOf(String text) =>
      crypto.sha256.convert(utf8.encode(text)).toString();
}

/// The archiver's side (12.9.7): count what it files, keep four weeks per
/// group, and compose the index when asked.
class XprsGroupIndex {
  XprsGroupIndex._();
  static final XprsGroupIndex instance = XprsGroupIndex._();

  /// Weeks kept per group, the newest it has counted (12.9.7).
  static const int weeksKept = 4;

  /// Groups kept at most: the one with the oldest newest week goes first.
  static const int maxGroups = 4096;

  /// A post dated further ahead than this is not counted (12.9.7: an
  /// archiver that keeps time refuses it).
  static const Duration ahead = Duration(minutes: 10);

  ZxSqlDb? _db;
  final Map<String, Map<int, Map<String, XprsSketch>>> _counts = {};

  /// Whether a closed group's newest post the archiver holds is sealed, and
  /// when it was written: a sealed newest post means private (10.7.1).
  final Map<String, ({bool sealed, int ts})> _mode = {};

  /// The clock, for the post-dated refusal. Null: no clock, no refusal.
  int Function()? now = () => DateTime.now().millisecondsSinceEpoch;

  /// A room this station hosts and keeps private (10.10.1): its posts are
  /// in the clear on this station, and it is still never listed. Set by the
  /// host's web chat API, which owns the rooms.
  bool Function(String group)? hostedPrivate;

  /// Writes waiting for [commit]: one transaction per archive flush, not
  /// one per post (architecture.md, zx stores: frequent writers batch).
  final Map<String, ({String g, int w, String k, String regs})> _dirtyWeeks = {};
  final Map<String, ({bool sealed, int ts})> _dirtyModes = {};
  final List<(String, List<Object?>)> _deletes = [];

  /// A replay of a closed group's record is asked per post only when the
  /// post is older than the newest act: the cached roster answers the rest.
  int replays = 0, cheap = 0;

  int counted = 0, refusedAhead = 0, dirty = 0;
  String? _text, _sha;

  bool get ready => _db != null;

  void init(String path) {
    close();
    final db = openStoreDb(path);
    db.execute('''
      CREATE TABLE IF NOT EXISTS gi_week(
        grp  TEXT NOT NULL,
        week INTEGER NOT NULL,
        kind TEXT NOT NULL,
        regs TEXT NOT NULL,
        PRIMARY KEY(grp, week, kind)
      )''');
    // Which index each archiver last named (12.9.7), so a reader that
    // restarts reads it again at once rather than after the next directory.
    db.execute('''
      CREATE TABLE IF NOT EXISTS gi_source(
        archiver TEXT PRIMARY KEY,
        sha      TEXT NOT NULL
      )''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS gi_mode(
        grp    TEXT PRIMARY KEY,
        sealed INTEGER NOT NULL,
        ts     INTEGER NOT NULL
      )''');
    // Bounded by what the index keeps: groups x weeks x three kinds.
    for (final row in db.select(
        'SELECT grp, week, kind, regs FROM gi_week LIMIT ?',
        [maxGroups * weeksKept * 3])) {
      final sk = XprsSketch.decode('${row['regs']}');
      if (sk == null) continue;
      _counts
          .putIfAbsent('${row['grp']}', () => {})
          .putIfAbsent(row['week'] as int, () => {})['${row['kind']}'] = sk;
    }
    for (final row in db.select(
        'SELECT grp, sealed, ts FROM gi_mode LIMIT ?', [maxGroups])) {
      _mode['${row['grp']}'] =
          (sealed: row['sealed'] == 1, ts: row['ts'] as int);
    }
    _db = db;
  }

  void close() {
    commit();
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
    _counts.clear();
    _mode.clear();
    _text = _sha = null;
  }

  /// A packet the archive just filed (XprsArchive.onFiled), with its
  /// identifier and signature verdict. Cheap for anything that is not a
  /// post to a group or an acceptance into one.
  void offer(XprsPacket p, String id, XprsSigState sig) {
    if (p.type == 'message') {
      final g = (p['d'] ?? '').trim().toUpperCase();
      final closed = g.startsWith('X5');
      if (!closed && !xprsIsOpenGroupName(g)) return;
      final ts = xprsParseTs(p['ts']);
      if (ts == null) return;
      final author = (p['f'] ?? '').trim().toUpperCase().split('-').first;
      if (author.isEmpty) return;
      if (!_okAt(ts)) return;
      if (closed) {
        // A member's post, at its moment, while the group took posts (10.4,
        // 10.4.2). A record this station cannot verify decides nothing (10.7).
        final r = XprsGroups.instance.rosterOf(g);
        if (r.verified) {
          final newest = XprsGroups.instance.newestAct(g);
          final bool stands;
          if (newest == null || ts >= newest.ts) {
            // Nothing in the record has changed since this post was written:
            // the current roster is the one at its moment, and it is cached.
            cheap++;
            final role = r.roles[author] ?? XprsRole.none;
            stands = role == XprsRole.mod ||
                role == XprsRole.admin ||
                (role == XprsRole.member && !r.closed);
          } else {
            replays++;
            stands = XprsGroups.instance.postStands(g, author, ts);
          }
          if (!stands) return;
        }
        // Public or private by its newest post that COUNTS (10.7.1): a
        // stranger's post, or one dated ahead, decides nothing.
        final was = _mode[g];
        if (was == null || ts >= was.ts) {
          final sealed = p.has('x');
          _mode[g] = (sealed: sealed, ts: ts);
          _dirtyModes[g] = (sealed: sealed, ts: ts);
        }
      }
      final w = xprsWeekOf(ts);
      _add(g, w, 'p', id);
      _add(g, w, 's', author);
      counted++;
    } else if (p.type == 'moderate' && sig == XprsSigState.verified) {
      final acc = (p['accept'] ?? '').trim().toLowerCase();
      if (acc != 'member' && acc != 'mod') return;
      final g = (p['d'] ?? '').trim().toUpperCase();
      if (!g.startsWith('X5')) return;
      final ts = xprsParseTs(p['ts']);
      if (ts == null || !_okAt(ts)) return;
      final who = (p['f'] ?? '').trim().toUpperCase().split('-').first;
      if (who.isEmpty) return;
      _add(g, xprsWeekOf(ts), 'j', who);
    }
  }

  bool _okAt(int ts) {
    final n = now?.call();
    if (n != null && ts > n + ahead.inMilliseconds) {
      refusedAhead++;
      return false;
    }
    return true;
  }

  void _add(String g, int w, String kind, String item) {
    final weeks = _counts[g];
    if (weeks == null && _counts.length >= maxGroups) _evictGroup();
    final ws = _counts.putIfAbsent(g, () => {});
    if (!ws.containsKey(w)) {
      // The four newest weeks it has counted; an older one is not kept.
      final kept = ws.keys.toList()..sort();
      if (kept.length >= weeksKept && w < kept.first) return;
      ws[w] = {};
      while (ws.length > weeksKept) {
        final oldest = (ws.keys.toList()..sort()).first;
        ws.remove(oldest);
        _dirtyWeeks.removeWhere((k, v) => v.g == g && v.w == oldest);
        _deletes.add(
            ('DELETE FROM gi_week WHERE grp = ? AND week = ?', [g, oldest]));
      }
    }
    final sk = ws[w]!.putIfAbsent(kind, () => XprsSketch());
    if (!sk.add(item)) return; // most adds move no register: nothing to write
    dirty++;
    _dirtyWeeks['$g|$w|$kind'] = (g: g, w: w, k: kind, regs: sk.encode());
  }

  /// Write what the last packets moved, in one transaction. Called after
  /// each archive flush (XprsArchive.onFiledDone) and after a backfill page.
  void commit() {
    final db = _db;
    if (db == null) {
      _dirtyWeeks.clear();
      _dirtyModes.clear();
      _deletes.clear();
      return;
    }
    if (_dirtyWeeks.isEmpty && _dirtyModes.isEmpty && _deletes.isEmpty) return;
    try {
      db.execute('BEGIN');
      for (final d in _deletes) {
        db.execute(d.$1, d.$2);
      }
      for (final v in _dirtyWeeks.values) {
        db.execute(
            'INSERT INTO gi_week(grp, week, kind, regs) VALUES(?,?,?,?) '
            'ON CONFLICT(grp, week, kind) DO UPDATE SET regs = excluded.regs',
            [v.g, v.w, v.k, v.regs]);
      }
      _dirtyModes.forEach((g, m) => db.execute(
          'INSERT INTO gi_mode(grp, sealed, ts) VALUES(?,?,?) '
          'ON CONFLICT(grp) DO UPDATE SET sealed = excluded.sealed, '
          'ts = excluded.ts',
          [g, m.sealed ? 1 : 0, m.ts]));
      db.execute('COMMIT');
    } catch (e) {
      try {
        db.execute('ROLLBACK');
      } catch (_) {}
      LogService.instance.add('XPRS: groups index write failed: $e');
    }
    _dirtyWeeks.clear();
    _dirtyModes.clear();
    _deletes.clear();
  }

  void _evictGroup() {
    String? worst;
    var worstWeek = 1 << 30;
    _counts.forEach((g, ws) {
      final newest = ws.keys.fold<int>(0, math.max);
      if (newest < worstWeek) {
        worstWeek = newest;
        worst = g;
      }
    });
    final g = worst;
    if (g == null) return;
    _counts.remove(g);
    _mode.remove(g);
    _dirtyWeeks.removeWhere((k, v) => v.g == g);
    _dirtyModes.remove(g);
    _deletes
      ..add(('DELETE FROM gi_week WHERE grp = ?', [g]))
      ..add(('DELETE FROM gi_mode WHERE grp = ?', [g]));
  }

  /// Count, once, what the archive already holds from the last four weeks
  /// (12.9.7): pages of rows from [page], newest first, each continued
  /// before the oldest it brought, a slice at a time. A marker in the store
  /// says it was done, so a restart does not count anything twice.
  Future<int> backfill(
      List<Map<String, dynamic>> Function({int? untilMs}) page) async {
    final db = _db;
    if (db == null) return 0;
    db.execute('CREATE TABLE IF NOT EXISTS gi_meta(k TEXT PRIMARY KEY, v TEXT)');
    final done = db.select(
        "SELECT COUNT(*) AS n FROM gi_meta WHERE k = 'backfilled'");
    if ((done.first['n'] as int? ?? 0) > 0) return 0;
    var n = 0;
    int? until;
    for (var pages = 0; pages < 400; pages++) {
      final rows = page(untilMs: until);
      if (rows.isEmpty) break;
      var oldest = until ?? (1 << 62);
      for (final r in rows) {
        final wire = r['wire'];
        final id = r['id'];
        if (wire is! String || id is! String) continue;
        final p = XprsPacket.parse(wire);
        if (p == null) continue;
        final sig = XprsSigState.values
            .firstWhere((s) => s.name == r['sig'], orElse: () => XprsSigState.unsigned);
        offer(p, id, sig);
        n++;
        final ts = ((r['ts'] as num?)?.toInt() ?? 0) * 1000;
        if (ts > 0 && ts < oldest) oldest = ts;
      }
      // `untilMs` is exclusive and a row's `ts` is whole seconds, so the
      // next page starts at the end of the oldest second seen. Counting is
      // idempotent (a sketch keeps the largest), so the overlap costs
      // nothing; a page that did not move the window ends the walk.
      commit();
      final next = oldest + 1000;
      if (rows.length < 2 || (until != null && next >= until)) break;
      until = next;
      await Future<void>.delayed(Duration.zero); // a slice at a time
    }
    db.execute("INSERT OR REPLACE INTO gi_meta(k, v) VALUES('backfilled', ?)",
        ['$n']);
    if (n > 0) {
      LogService.instance.add('XPRS: groups index counted $n held packet(s) '
          '(12.9.7)');
    }
    return n;
  }

  /// The index [archiver] named, remembered for the next start.
  void noteSource(String archiver, String sha) => _db?.execute(
      'INSERT INTO gi_source(archiver, sha) VALUES(?, ?) '
      'ON CONFLICT(archiver) DO UPDATE SET sha = excluded.sha',
      [archiver, sha]);

  /// Every archiver's index named before this start (bounded: one row per
  /// archiver this station chose).
  List<({String archiver, String sha})> sources() => [
        for (final r in _db?.select(
                'SELECT archiver, sha FROM gi_source LIMIT 256') ??
            const <Map<String, Object?>>[])
          (archiver: '${r['archiver']}', sha: '${r['sha']}')
      ];

  /// Whether [g] is listed: an open group, or a closed one whose newest
  /// post here is in the clear (10.7.1).
  bool isPublic(String g) {
    if (hostedPrivate?.call(g) ?? false) return false;
    if (!g.startsWith('X5')) return true;
    final m = _mode[g];
    return m != null && !m.sealed;
  }

  /// The groups this archiver lists, as the index states them.
  List<XprsGroupStats> stats() {
    final out = <XprsGroupStats>[];
    _counts.forEach((g, ws) {
      if (!isPublic(g)) return;
      final s = XprsGroupStats(g);
      ws.forEach((w, kinds) {
        kinds.forEach((k, sk) {
          if (!sk.isEmpty) s.week(w).kinds[k] = sk.copy();
        });
      });
      if (g.startsWith('X5')) {
        final r = XprsGroups.instance.rosterOf(g);
        final newest = XprsGroups.instance.newestAct(g);
        if (r.verified && newest != null) {
          // People: the group's own callsign is its key, not a member.
          s.members = r.roles.entries
              .where((e) =>
                  e.key != g &&
                  (e.value == XprsRole.member ||
                      e.value == XprsRole.mod ||
                      e.value == XprsRole.admin))
              .length;
          s.membersTs = newest.ts;
          s.membersId = newest.id;
        }
      }
      if (s.weeks.isNotEmpty || s.members != null) out.add(s);
    });
    return out;
  }

  /// The index as it is now: its text and digest, recomposed only when
  /// something was counted since. Null when there is nothing to list.
  ({String text, String sha})? current() {
    if (_text == null || dirty > 0) {
      final list = stats();
      _text = list.isEmpty ? null : XprsGroupIndexFile.compose(list);
      _sha = _text == null ? null : XprsGroupIndexFile.shaOf(_text!);
      dirty = 0;
    }
    final t = _text, s = _sha;
    return t == null || s == null ? null : (text: t, sha: s);
  }

  /// Something outside the counts changed what the index says (a roster,
  /// a group gone private): recompose it on the next [current].
  void touch() => dirty++;

  void debugReset() {
    _counts.clear();
    _mode.clear();
    _text = _sha = null;
    counted = refusedAhead = dirty = replays = cheap = 0;
    _dirtyWeeks.clear();
    _dirtyModes.clear();
    _deletes.clear();
    hostedPrivate = null;
    now = () => DateTime.now().millisecondsSinceEpoch;
  }
}

/// One group, combined across archivers and ready to rank.
class XprsGroupRank {
  XprsGroupRank(this.group);
  final String group;
  bool get open => !group.startsWith('X5');
  int? members;
  int posts = 0; // this week and the last
  int posters = 0;
  int joins = 0; // the last four weeks
}

/// The reader's side (12.9.7): the indexes of the archivers this station
/// chose, combined, and ranked for a screen.
class XprsGroupRanking {
  XprsGroupRanking._();
  static final XprsGroupRanking instance = XprsGroupRanking._();

  /// Fetch an index's text from [archiver] by its digest. Injected.
  Future<String?> Function(String archiver, String shaHex)? fetchText;

  /// The archivers this station chose (12.3): only their indexes are read.
  List<String> Function()? named;

  /// An index an archiver named, to remember across a restart.
  void Function(String archiver, String sha)? onNoted;

  final Map<String, String> _wanted = {}; // archiver -> sha named
  final Map<String, ({String sha, Map<String, XprsGroupStats> groups})>
      _have = {};
  int _mergedWeek = -1;

  /// This station's own archiver name: its own index is always counted.
  String self = '';
  int _lastRefreshMs = 0;
  bool _busy = false;
  List<XprsGroupRank>? _merged;

  int fetched = 0, failed = 0;

  /// An archiver's directory named its index (XprsDirectoryConsumer).
  void noteIndex(String archiver, String sha) {
    final a = archiver.trim().toUpperCase().split('-').first;
    if (a.isEmpty || _wanted[a] == sha) return;
    _wanted[a] = sha;
    onNoted?.call(a, sha);
  }

  /// When the index named now has not been read yet, read it, at most once
  /// a minute (12.9.6's bound on what a screen may poke). The screen hears
  /// the answer on [CoreState.groups].
  void refresh({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (_busy || now - _lastRefreshMs < 60000) return;
    final fetch = fetchText;
    if (fetch == null) return;
    final mine = {
      for (final c in named?.call() ?? const <String>[])
        c.trim().toUpperCase().split('-').first
    };
    // An archiver no longer chosen no longer counts (and is not kept).
    final gone = [
      for (final a in _have.keys)
        if (!mine.contains(a) && a != self) a
    ];
    if (gone.isNotEmpty) {
      for (final a in gone) {
        _have.remove(a);
        _wanted.remove(a);
      }
      _merged = null;
    }
    final todo = [
      for (final e in _wanted.entries)
        if (mine.contains(e.key) && _have[e.key]?.sha != e.value) e
    ];
    if (todo.isEmpty) return;
    _lastRefreshMs = now;
    _busy = true;
    unawaited(() async {
      var any = false;
      for (final e in todo) {
        try {
          final text = await fetch(e.key, e.value);
          if (text == null || XprsGroupIndexFile.shaOf(text) != e.value) {
            failed++;
            continue;
          }
          final groups = XprsGroupIndexFile.parse(text);
          if (groups == null) {
            failed++;
            continue;
          }
          _have[e.key] = (sha: e.value, groups: groups);
          fetched++;
          any = true;
          LogService.instance.add('XPRS: groups index of ${e.key} read '
              '(${groups.length} group(s)) — 12.9.7');
        } catch (err) {
          failed++;
          LogService.instance.add('XPRS: groups index of ${e.key} failed: $err');
        }
      }
      _busy = false;
      if (any) {
        _merged = null;
        CoreState.instance.changed(CoreState.groups);
      }
    }());
  }

  /// Put in an index directly (a station's own, or a test).
  void put(String archiver, String sha, Map<String, XprsGroupStats> groups) {
    _have[archiver.trim().toUpperCase()] = (sha: sha, groups: groups);
    _merged = null;
  }

  /// How many archivers' indexes the ranking is built from.
  int get sources => _have.length;

  /// Every group, combined across archivers (12.9.7), for weeks counted
  /// from [nowMs].
  List<XprsGroupRank> merged({int? nowMs}) {
    final w = xprsWeekOf(nowMs ?? DateTime.now().millisecondsSinceEpoch);
    final cached = _merged;
    if (cached != null && _mergedWeek == w) return cached;
    _mergedWeek = w;
    final members = <String, ({int n, int ts})>{};
    final sketches = <String, Map<String, XprsSketch>>{}; // group -> key
    for (final idx in _have.values) {
      idx.groups.forEach((g, s) {
        final m = s.members;
        if (m != null) {
          final was = members[g];
          // The record that saw the newest act is the most complete; on a
          // tie the larger count.
          if (was == null ||
              s.membersTs > was.ts ||
              (s.membersTs == was.ts && m > was.n)) {
            members[g] = (n: m, ts: s.membersTs);
          }
        }
        final into = sketches.putIfAbsent(g, () => {});
        s.weeks.forEach((week, wk) {
          if (week > w) return; // after the reader's own week
          wk.kinds.forEach((k, sk) {
            final inPosts = (k == 'p' || k == 's') && week >= w - 1;
            final inJoins = k == 'j' && week >= w - 3;
            if (!inPosts && !inJoins) return;
            into.putIfAbsent(k, () => XprsSketch()).merge(sk);
          });
        });
      });
    }
    final out = <XprsGroupRank>[];
    final groups = {...members.keys, ...sketches.keys};
    for (final g in groups) {
      final r = XprsGroupRank(g)..members = members[g]?.n;
      final k = sketches[g] ?? const {};
      r.posts = k['p']?.estimate() ?? 0;
      r.posters = k['s']?.estimate() ?? 0;
      r.joins = r.open ? 0 : (k['j']?.estimate() ?? 0);
      out.add(r);
    }
    return _merged = out;
  }

  /// Ranked by `active` (posts, then posters), `members` or `growing`
  /// (joins). An open group has no members and no joins, so it appears
  /// under `active` only.
  List<XprsGroupRank> ranked(String by, {int? nowMs}) {
    final all = merged(nowMs: nowMs);
    final list = switch (by) {
      'members' => [for (final r in all) if (!r.open && (r.members ?? 0) > 0) r]
        ..sort((a, b) => (b.members ?? 0).compareTo(a.members ?? 0)),
      'growing' => [for (final r in all) if (!r.open && r.joins > 0) r]
        ..sort((a, b) => b.joins != a.joins
            ? b.joins.compareTo(a.joins)
            : (b.members ?? 0).compareTo(a.members ?? 0)),
      _ => [for (final r in all) if (r.posts > 0) r]
        ..sort((a, b) => b.posts != a.posts
            ? b.posts.compareTo(a.posts)
            : b.posters.compareTo(a.posters)),
    };
    return list;
  }

  void debugReset() {
    _wanted.clear();
    _have.clear();
    _merged = null;
    _lastRefreshMs = 0;
    _busy = false;
    fetched = failed = 0;
    fetchText = null;
    named = null;
    onNoted = null;
  }
}
