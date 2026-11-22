/*
 * xprs_people — who a person is, and every way this station knows to reach
 * or recognise them.
 *
 * The one thing that identifies a person is their key, the `npub` (XPRS.md
 * 6.3). Everything else is an IDENTITY that accumulates under it: the
 * callsign the key derives, the issued callsigns it bound (6.4.2), the
 * Reticulum identities and LXMF addresses of their devices, the static
 * Bluetooth and WLAN addresses of their boards, their node on another mesh
 * (3.2), an e-mail address. Each identity is kept with HOW it was learned,
 * because these are not equally trustworthy, and with when it was first and
 * last seen.
 *
 * Before this, each of those facts lived in a table of its own, keyed by
 * callsign and fed from one source: the Reticulum identity of a callsign was
 * only learned from a hub announce, so a station that had verified messages
 * from an archiver in hand could not open a file link to it until the hub
 * forwarded that announce, up to an hour later and not every time. One
 * record, fed from every source, answers "who is this" and "how do I reach
 * them" in one place.
 *
 *   note      an identity of a holder, with its evidence
 *   of        a holder's identities, best first
 *   holders   who has an identity (several when it is contested)
 *   claim     a key takes over a record that had no key
 *
 * A HOLDER is an npub, or, for something heard that has no key (a Meshtastic
 * node, an unsigned issued callsign), an unclaimed record named by its own
 * identity ([unclaimed]). Two keys may both hold one issued callsign and both
 * verify (6.4.2): both are kept, nothing is merged.
 *
 * Kept in `people.zx`, inside the profile (encrypted with it): it holds
 * addresses of people. In memory when there is no store. Bounded: so many
 * identities of a type per holder, so many holders. Writes are queued and
 * committed in batches; a re-sighting moves `last` in the store at most once
 * an hour.
 */
library;

import 'dart:async';

import '../../storage/store_db.dart';
import '../log_service.dart';

/// The kinds of identity. A plain word, so another network is another word.
abstract final class XprsIdType {
  /// The callsign the key derives (`X1` to `X5`, XPRS.md 3).
  static const String callsign = 'callsign';

  /// A callsign an authority issued, bound to the key by the holder (6.4.2).
  static const String licence = 'licence';

  /// A Reticulum identity (32 hex), one per device.
  static const String reticulum = 'reticulum';

  /// An LXMF delivery address (32 hex), one per device (`lx:`).
  static const String lxmf = 'lxmf';

  /// A Bluetooth address that does not rotate (a board's).
  static const String ble = 'ble';

  /// A WLAN address.
  static const String wlan = 'wlan';

  /// A Meshtastic node, as XPRS writes it: `MT` + eight hex (3.2).
  static const String meshtastic = 'meshtastic';

  /// A MeshCore node: `MC` + eight hex (3.2).
  static const String meshcore = 'meshcore';

  static const String email = 'email';

  /// The kinds a person may state of themselves (XPRS.md 6.3.3), in the
  /// order a form offers them. Issued callsigns are stated from the
  /// profile's own list and are not entered here. Any other word is a kind
  /// too: this is the documented list, not a limit.
  static const List<String> statable = [
    email,
    meshtastic,
    meshcore,
    ble,
    wlan,
    reticulum,
    lxmf,
  ];

  /// How far a kind is worth telling when its owner has not chosen: a
  /// board's radio address only helps somebody in range of it.
  static String defaultScope(String type) =>
      type == ble || type == wlan ? 'local' : 'global';

  /// [value] as this type is always written, or '' when it cannot be one.
  static String normalise(String type, String value) {
    final v = value.trim();
    if (v.isEmpty) return '';
    switch (type) {
      case callsign:
      case licence:
        // Whole and uppercase; a device suffix is not part of who it is.
        final up = v.toUpperCase();
        final dash = up.indexOf('-');
        return dash > 0 ? up.substring(0, dash) : up;
      case reticulum:
      case lxmf:
        final hex = v.toLowerCase();
        return _hex.hasMatch(hex) ? hex : '';
      case ble:
      case wlan:
        final m = v.toUpperCase().replaceAll('-', ':');
        return _mac.hasMatch(m) ? m : '';
      case meshtastic:
      case meshcore:
        final up = v.toUpperCase();
        return _foreign.hasMatch(up) ? up : '';
      case email:
        final e = v.toLowerCase();
        return e.contains('@') && !e.contains(' ') ? e : '';
      default:
        return v;
    }
  }

  static final RegExp _hex = RegExp(r'^[0-9a-f]{16,64}$');
  static final RegExp _mac = RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$');
  static final RegExp _foreign = RegExp(r'^M[TC][0-9A-F]{8}$');
}

/// How an identity was learned, weakest first. A reader asks for a minimum.
enum XprsIdEvidence {
  /// Somebody else said it (a gateway's `via:`).
  relayed,

  /// Seen together on a transport: the address a verified packet came from,
  /// an announce that carried the callsign.
  observed,

  /// The owner of this device wrote it down.
  noted,

  /// The holder said it in a packet their key signed.
  signed,

  /// It follows from the key by arithmetic.
  derived,
}

/// One identity of a holder.
class XprsIdentity {
  XprsIdentity(this.type, this.value, this.evidence, this.firstMs, this.lastMs,
      {this.via = '', this.scope = ''})
      : savedMs = lastMs;

  /// The `last` the store holds, which trails [lastMs] by up to an hour.
  int savedMs;

  final String type;
  final String value;
  XprsIdEvidence evidence;
  final int firstMs;
  int lastMs;

  /// The bearer or the station it was learned through, where that is known.
  String via;

  /// How far the holder allows it to be told on (XPRS.md 9.11), where they
  /// said: `local`, `regional`, `global` or country codes. Empty: not to be
  /// told on at all, which is what an observed address is.
  String scope;

  Map<String, dynamic> toJson() => {
        'type': type,
        'value': value,
        'evidence': evidence.name,
        'first': firstMs,
        'last': lastMs,
        if (via.isNotEmpty) 'via': via,
        if (scope.isNotEmpty) 'scope': scope,
      };

  @override
  String toString() => '$type:$value (${evidence.name})';
}

/// Who holds an issued callsign: the key, when this station first heard it
/// claim the callsign, and when it last heard it use it.
class XprsLease {
  XprsLease(this.holder, this.sinceMs, this.lastMs);
  final String holder;
  int sinceMs;
  int lastMs;
}

/// What became of a key's claim to an issued callsign.
enum XprsClaim {
  /// Not an issued callsign: a key's own, by arithmetic, and not leased.
  derived,

  /// The callsign was free (never claimed here, or its holder silent for a
  /// year) and is this key's now.
  taken,

  /// This key holds it already.
  held,

  /// Another key holds it and was active within the year: an impostor.
  refused,
}

class XprsPeople {
  XprsPeople._();
  static final XprsPeople instance = XprsPeople._();

  /// Identities of one type kept per holder: the newest and best stay.
  static const int perType = 8;

  /// Holders kept. Past it the one touched longest ago leaves, with what it
  /// held; a holder with something signed or derived leaves last.
  static const int maxHolders = 4096;

  /// Rows read from the store at start: more than [maxHolders] people can
  /// hold between them in practice, and a bound whatever the file holds.
  static const int maxRows = 32768;

  /// How much later a re-sighting must be to be written to the store again.
  static const int _lastStepMs = 60 * 60 * 1000;

  /// How long queued writes wait for a batch.
  static const Duration flushAfter = Duration(minutes: 1);

  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  /// holder -> its identities. Insertion order is touch order: a touched
  /// holder is re-inserted, so the first key is the one touched longest ago.
  final Map<String, List<XprsIdentity>> _by = {};

  /// `type|value` -> holders.
  final Map<String, Set<String>> _index = {};

  ZxSqlDb? _db;
  final List<(String, List<Object?>)> _pending = [];
  Timer? _flushTimer;

  int noted = 0, evicted = 0;

  bool get ready => _db != null;
  int get holderCount => _by.length;

  /// The name of a record that has no key: its own identity.
  static String unclaimed(String type, String value) =>
      '~$type:${XprsIdType.normalise(type, value)}';

  static bool isUnclaimed(String holder) => holder.startsWith('~');

  static String _k(String type, String value) => '$type|$value';

  // ── The store ───────────────────────────────────────────────────────────

  /// Open `people.zx` at [path] and read what it holds. Without it (a locked
  /// profile, a platform with no stores) everything works in memory.
  void init(String path) {
    close();
    try {
      final db = openStoreDb(path, pageSize: 4096);
      db.execute(
        'CREATE TABLE IF NOT EXISTS identities('
        'holder TEXT NOT NULL, type TEXT NOT NULL, value TEXT NOT NULL,'
        'evidence INTEGER NOT NULL, first_ms INTEGER NOT NULL,'
        'last_ms INTEGER NOT NULL, via TEXT NOT NULL, scope TEXT NOT NULL,'
        'PRIMARY KEY(holder, type, value))',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS idx_id_value ON identities(type, value)',
      );
      // What a holder SAID of a kind (XPRS.md 6.3.3): the time of the
      // newest packet that stated it, so an older one cannot bring a
      // withdrawn identity back.
      db.execute(
        'CREATE TABLE IF NOT EXISTS said('
        'holder TEXT NOT NULL, type TEXT NOT NULL, ts INTEGER NOT NULL,'
        'PRIMARY KEY(holder, type))',
      );
      _db = db;
      _by.clear();
      _index.clear();
      // The newest [maxRows], read newest first and filed oldest first, so
      // a holder's place in the map is its touch order again.
      final rows = db.select(
        'SELECT holder,type,value,evidence,first_ms,last_ms,via,scope '
        'FROM identities ORDER BY last_ms DESC LIMIT ?',
        [maxRows],
      ).toList();
      for (final r in rows.reversed) {
        final e = (r['evidence'] as int).clamp(0, XprsIdEvidence.values.length - 1);
        final id = XprsIdentity(
          r['type'] as String,
          r['value'] as String,
          XprsIdEvidence.values[e],
          r['first_ms'] as int,
          r['last_ms'] as int,
          via: r['via'] as String? ?? '',
          scope: r['scope'] as String? ?? '',
        );
        final holder = r['holder'] as String;
        _by.putIfAbsent(holder, () => []).add(id);
        _index.putIfAbsent(_k(id.type, id.value), () => {}).add(holder);
      }
      // Who holds each issued callsign, since when and until when (6.4.2).
      db.execute(
        'CREATE TABLE IF NOT EXISTS leases('
        'callsign TEXT PRIMARY KEY, holder TEXT NOT NULL,'
        'since_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL)',
      );
      _leases.clear();
      for (final r in db.select(
          'SELECT callsign,holder,since_ms,last_ms FROM leases '
          'ORDER BY last_ms DESC LIMIT ?',
          [maxRows])) {
        _leases[r['callsign'] as String] = XprsLease(r['holder'] as String,
            r['since_ms'] as int, r['last_ms'] as int);
      }
      _saidTs.clear();
      for (final r in db.select(
          'SELECT holder,type,ts FROM said ORDER BY ts DESC LIMIT ?',
          [maxRows])) {
        _saidTs[_k(r['holder'] as String, r['type'] as String)] =
            r['ts'] as int;
      }
    } on ProfileLockedException {
      LogService.instance.add('People: profile locked, kept in memory');
    } catch (e) {
      LogService.instance.add('People: store failed to open: $e');
    }
  }

  void _write(String sql, List<Object?> params) {
    if (_db == null) return;
    _pending.add((sql, params));
    if (_pending.length >= 200) {
      flush();
    } else {
      _flushTimer ??= Timer(flushAfter, flush);
    }
  }

  /// Commit the queued writes in one transaction.
  void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final db = _db;
    if (db == null || _pending.isEmpty) return;
    final work = List.of(_pending);
    _pending.clear();
    try {
      db.transaction(() {
        for (final (sql, params) in work) {
          db.execute(sql, params);
        }
      });
    } catch (e) {
      LogService.instance.add('People: commit of ${work.length} writes failed: $e');
    }
  }

  void close() {
    flush();
    _flushTimer?.cancel();
    _flushTimer = null;
    _db?.dispose();
    _db = null;
  }

  void _put(String holder, XprsIdentity id) {
    id.savedMs = id.lastMs;
    _write(
      'INSERT INTO identities(holder,type,value,evidence,first_ms,last_ms,'
      'via,scope) VALUES(?,?,?,?,?,?,?,?) '
      'ON CONFLICT(holder,type,value) DO UPDATE SET '
      'evidence=excluded.evidence, last_ms=excluded.last_ms, '
      'via=excluded.via, scope=excluded.scope',
      [
        holder,
        id.type,
        id.value,
        id.evidence.index,
        id.firstMs,
        id.lastMs,
        id.via,
        id.scope,
      ],
    );
  }

  // ── Writing ─────────────────────────────────────────────────────────────

  /// [holder] (an npub, or an [unclaimed] name) has the identity
  /// [type]:[value], learned as [evidence]. Returns whether anything new was
  /// learned: a new identity, or stronger evidence for a known one.
  ///
  /// Evidence only ever rises: a callsign the key signed for is not made
  /// "observed" again by the next announce that carries it. [scope] is the
  /// holder's own word and replaces the one held when given.
  bool note(String holder, String type, String value,
      {required XprsIdEvidence evidence, String via = '', String? scope}) {
    final h = holder.trim();
    final v = XprsIdType.normalise(type, value);
    if (h.isEmpty || type.isEmpty || v.isEmpty) return false;
    final now = nowMs();
    noted++;

    var list = _by.remove(h); // re-insert: touched now
    list ??= [];
    _by[h] = list;

    XprsIdentity? id;
    for (final e in list) {
      if (e.type == type && e.value == v) {
        id = e;
        break;
      }
    }
    if (id != null) {
      final stronger = evidence.index > id.evidence.index;
      final rescoped = scope != null && scope != id.scope;
      final later = now - id.savedMs >= _lastStepMs;
      if (stronger) id.evidence = evidence;
      if (rescoped) id.scope = scope;
      if (via.isNotEmpty && (stronger || id.via.isEmpty)) id.via = via;
      id.lastMs = now;
      // Seen again within the hour: memory has the new time, the store
      // keeps the older one. A write per packet heard is what the cost
      // rules forbid.
      if (stronger || rescoped || later) _put(h, id);
      return stronger || rescoped;
    }

    id = XprsIdentity(type, v, evidence, now, now, via: via, scope: scope ?? '');
    list.add(id);
    _index.putIfAbsent(_k(type, v), () => {}).add(h);
    _put(h, id);
    _trimType(h, list, type);
    _trimHolders();
    return true;
  }

  void _trimType(String holder, List<XprsIdentity> list, String type) {
    final same = [for (final e in list) if (e.type == type) e];
    if (same.length <= perType) return;
    // The weakest evidence, then the one seen longest ago, leaves.
    same.sort((a, b) {
      final c = a.evidence.index.compareTo(b.evidence.index);
      return c != 0 ? c : a.lastMs.compareTo(b.lastMs);
    });
    for (final drop in same.take(same.length - perType)) {
      _drop(holder, list, drop);
    }
  }

  void _drop(String holder, List<XprsIdentity> list, XprsIdentity id) {
    list.remove(id);
    final k = _k(id.type, id.value);
    final hs = _index[k];
    hs?.remove(holder);
    if (hs != null && hs.isEmpty) _index.remove(k);
    _write('DELETE FROM identities WHERE holder=? AND type=? AND value=?',
        [holder, id.type, id.value]);
  }

  void _trimHolders() {
    while (_by.length > maxHolders) {
      // The one touched longest ago that holds nothing signed or derived;
      // failing that, simply the one touched longest ago.
      String? victim;
      for (final e in _by.entries) {
        if (!e.value.any((i) => i.evidence.index >= XprsIdEvidence.signed.index)) {
          victim = e.key;
          break;
        }
      }
      victim ??= _by.keys.first;
      forget(victim);
      evicted++;
    }
  }

  /// Forget [holder] and everything it held.
  void forget(String holder) {
    final list = _by.remove(holder);
    if (list == null) return;
    for (final id in list) {
      final k = _k(id.type, id.value);
      final hs = _index[k];
      hs?.remove(holder);
      if (hs != null && hs.isEmpty) _index.remove(k);
    }
    _write('DELETE FROM identities WHERE holder=?', [holder]);
    _saidTs.removeWhere((k, _) => k.startsWith('$holder|'));
    _write('DELETE FROM said WHERE holder=?', [holder]);
  }

  /// The holder withdrew [type]:[value] (a `-` on the wire), or the owner of
  /// this device removed a note.
  bool remove(String holder, String type, String value) {
    final list = _by[holder];
    final v = XprsIdType.normalise(type, value);
    if (list == null || v.isEmpty) return false;
    for (final id in list) {
      if (id.type == type && id.value == v) {
        _drop(holder, list, id);
        if (list.isEmpty) _by.remove(holder);
        return true;
      }
    }
    return false;
  }

  /// The key [npub] proved it is who the keyless record [type]:[value] was
  /// about: what that record held becomes the person's, as [evidence] at
  /// most (what was only observed of a stranger stays observed), and the
  /// record is gone. A record that does not exist costs nothing.
  void claim(String npub, String type, String value,
      {XprsIdEvidence evidence = XprsIdEvidence.signed}) {
    final from = unclaimed(type, value);
    final list = _by[from];
    note(npub, type, value, evidence: evidence);
    if (list == null) return;
    for (final id in List.of(list)) {
      if (id.type == type && id.value == XprsIdType.normalise(type, value)) {
        continue;
      }
      note(npub, id.type, id.value,
          evidence: id.evidence.index < evidence.index ? id.evidence : evidence,
          via: id.via,
          scope: id.scope.isEmpty ? null : id.scope);
    }
    forget(from);
  }

  /// The identity type of a callsign: the derived kind for `X1` to `X5`,
  /// an issued one for anything else (XPRS.md 3, 6.4.2).
  static String callType(String callsign) {
    final c = callsign.trim().toUpperCase();
    return c.length >= 2 &&
            c.codeUnitAt(0) == 0x58 /* X */ &&
            c.codeUnitAt(1) >= 0x31 &&
            c.codeUnitAt(1) <= 0x35
        ? XprsIdType.callsign
        : XprsIdType.licence;
  }

  /// Whoever goes by [callsign]: the person when a key is known for it,
  /// else the keyless record of that callsign. Never empty for a callsign.
  String holderOfCall(String callsign) {
    final t = callType(callsign);
    return personWith(t, callsign) ?? unclaimed(t, callsign);
  }

  /// [callsign] has the identity [type]:[value], filed under the person
  /// when the key is known and under the callsign's keyless record until
  /// then ([claim] folds it in when the key arrives).
  bool noteForCall(String callsign, String type, String value,
      {required XprsIdEvidence evidence, String via = ''}) {
    final c = XprsIdType.normalise(callType(callsign), callsign);
    if (c.isEmpty) return false;
    final holder = holderOfCall(c);
    if (isUnclaimed(holder) && (_by[holder]?.isEmpty ?? true)) {
      // The record names itself: its callsign is its first identity.
      note(holder, callType(c), c, evidence: XprsIdEvidence.observed, via: via);
    }
    return note(holder, type, value, evidence: evidence, via: via);
  }

  /// How long the same address must keep answering for one callsign before
  /// it is taken as that station's own. A phone's Bluetooth address rotates
  /// about every quarter of an hour; a board's never does.
  static const Duration stableAfter = Duration(minutes: 30);

  /// `callsign|type|value` -> when it was first seen. Bounded, oldest out.
  final Map<String, int> _seenSince = {};
  static const int _seenMax = 256;

  /// [callsign] was heard directly from the hardware address [value] (a
  /// Bluetooth or WLAN address). Filed as observed only once the same
  /// address has gone on answering for [stableAfter]: an address that
  /// rotates never gets there, so nothing has to guess from its bits which
  /// kind it is. Returns whether it was filed now.
  bool noteAddress(String callsign, String type, String value) {
    final c = XprsIdType.normalise(callType(callsign), callsign);
    final v = XprsIdType.normalise(type, value);
    if (c.isEmpty || v.isEmpty) return false;
    final holder = holderOfCall(c);
    if ((_by[holder] ?? const <XprsIdentity>[])
        .any((e) => e.type == type && e.value == v)) {
      // Known already: only the time moves.
      return note(holder, type, v, evidence: XprsIdEvidence.observed);
    }
    final key = '$c|$type|$v';
    final now = nowMs();
    final since = _seenSince[key];
    if (since == null) {
      if (_seenSince.length >= _seenMax) {
        _seenSince.remove(_seenSince.keys.first);
      }
      _seenSince[key] = now;
      return false;
    }
    if (now - since < stableAfter.inMilliseconds) return false;
    _seenSince.remove(key);
    return noteForCall(c, type, v, evidence: XprsIdEvidence.observed, via: type);
  }

  /// Another identity of whoever goes by [callsign], best first.
  List<String> reachCall(String callsign, String wanted,
          {XprsIdEvidence min = XprsIdEvidence.relayed}) =>
      reach(callType(callsign), callsign, wanted, min: min);

  // ── What a person says of themselves (XPRS.md 6.3.3) ────────────────────

  /// The mark on an identity that came from the holder's own statement, as
  /// opposed to one this station worked out.
  static const String said = 'said';

  /// `holder|type` -> `ts` of the newest statement of that kind.
  final Map<String, int> _saidTs = {};

  /// [holder] stated, in a packet their key signed at [tsMs], that their
  /// identities of kind [idtype] are [data] (comma-separated; `-` withdraws
  /// the kind), to be told on as far as [scope].
  ///
  /// The newest statement of a kind replaces that kind: what an earlier one
  /// stated and this one does not is gone. What this station learned by
  /// itself (an address it saw, a derived callsign) is not the holder's to
  /// withdraw and stays. An older statement than the one held is ignored.
  /// A kind this station does not know is kept as written. Returns whether
  /// anything changed.
  bool stated(String holder, String idtype, String data,
      {required int tsMs, String scope = ''}) {
    final h = holder.trim();
    final type = idtype.trim().toLowerCase();
    if (h.isEmpty || isUnclaimed(h) || type.isEmpty) return false;
    final key = _k(h, type);
    if (tsMs <= (_saidTs[key] ?? 0)) return false;
    _saidTs[key] = tsMs;
    _write(
        'INSERT INTO said(holder,type,ts) VALUES(?,?,?) '
        'ON CONFLICT(holder,type) DO UPDATE SET ts=excluded.ts',
        [h, type, tsMs]);

    final want = <String>[];
    if (data.trim() != '-') {
      for (final raw in data.split(',')) {
        final v = XprsIdType.normalise(type, raw);
        if (v.isNotEmpty && !want.contains(v)) want.add(v);
        if (want.length >= perType) break;
      }
    }
    var changed = false;
    final list = _by[h];
    if (list != null) {
      for (final id in List.of(list)) {
        if (id.type == type && id.via == said && !want.contains(id.value)) {
          _drop(h, list, id);
          changed = true;
        }
      }
      if (list.isEmpty) _by.remove(h);
    }
    for (final v in want) {
      final was = of(h, type: type).where((e) => e.value == v).firstOrNull;
      if (was == null || was.via != said || was.scope != scope) changed = true;
      note(h, type, v,
          evidence: XprsIdEvidence.signed, via: said, scope: scope);
      // An identity already signed another way keeps its evidence; the mark
      // and the scope are the statement's.
      final now = of(h, type: type).where((e) => e.value == v).firstOrNull;
      if (now != null && now.via != said) {
        now.via = said;
        _put(h, now);
      }
    }
    return changed;
  }

  /// What whoever goes by [callsign] stated of themselves, by kind, in the
  /// order the kinds were first learned: for a screen on this device, which
  /// received each statement within its scope. Empty for somebody who
  /// stated nothing.
  Map<String, List<String>> saidByCall(String callsign) {
    final out = <String, List<String>>{};
    for (final e in of(holderOfCall(callsign))) {
      if (e.via == said) out.putIfAbsent(e.type, () => []).add(e.value);
    }
    return out;
  }

  /// What [holder] stated of themselves that may be told to somebody at
  /// [reach] (`local`, `regional` or `global`): the identities whose scope
  /// admits it. An identity nobody stated has no scope and is never told.
  List<XprsIdentity> tellable(String holder, {required String reach}) => [
        for (final e in of(holder))
          if (e.via == said && _admits(e.scope, reach)) e
      ];

  /// 9.11: no scope is global; `local` goes nowhere past earshot;
  /// `regional` or country codes stop short of the whole network.
  static bool _admits(String scope, String reach) {
    final s = scope.trim().toLowerCase();
    if (s.isEmpty || s == 'global') return true;
    if (reach == 'local') return true;
    if (reach == 'regional') return s != 'local';
    return false;
  }

  // ── Reading ─────────────────────────────────────────────────────────────

  /// What [holder] has, the strongest evidence first and, within it, the
  /// one seen last. [type] narrows it; [min] leaves out weaker evidence.
  List<XprsIdentity> of(String holder,
      {String? type, XprsIdEvidence min = XprsIdEvidence.relayed}) {
    final list = _by[holder.trim()];
    if (list == null) return const [];
    final out = [
      for (final e in list)
        if ((type == null || e.type == type) && e.evidence.index >= min.index)
          e
    ];
    out.sort((a, b) {
      final c = b.evidence.index.compareTo(a.evidence.index);
      return c != 0 ? c : b.lastMs.compareTo(a.lastMs);
    });
    return out;
  }

  /// The values of one type [holder] has, best first.
  List<String> valuesOf(String holder, String type,
          {XprsIdEvidence min = XprsIdEvidence.relayed}) =>
      [for (final e in of(holder, type: type, min: min)) e.value];

  /// Who has [type]:[value], the strongest claim first. Several when it is
  /// contested; a caller that needs one takes the first and knows it may be
  /// one of several.
  List<String> holders(String type, String value,
      {XprsIdEvidence min = XprsIdEvidence.relayed, bool people = false}) {
    final v = XprsIdType.normalise(type, value);
    final hs = _index[_k(type, v)];
    if (hs == null) return const [];
    final rows = <(String, XprsIdentity)>[];
    for (final h in hs) {
      if (people && isUnclaimed(h)) continue;
      for (final e in _by[h] ?? const <XprsIdentity>[]) {
        if (e.type == type && e.value == v && e.evidence.index >= min.index) {
          rows.add((h, e));
        }
      }
    }
    rows.sort((a, b) {
      final c = b.$2.evidence.index.compareTo(a.$2.evidence.index);
      return c != 0 ? c : b.$2.lastMs.compareTo(a.$2.lastMs);
    });
    return [for (final r in rows) r.$1];
  }

  /// The person (npub) who has [type]:[value], or null. The strongest claim
  /// when there are several.
  String? personWith(String type, String value,
      {XprsIdEvidence min = XprsIdEvidence.relayed}) {
    final hs = holders(type, value, min: min, people: true);
    return hs.isEmpty ? null : hs.first;
  }

  // ── Who holds an issued callsign (XPRS.md 6.4.2) ────────────────────────
  //
  // An issued callsign has no arithmetic tie to a key, so nothing in the
  // format stops a second key from announcing it. The rule that settles it:
  //
  //   A callsign belongs to ONE key, for a year after that key was last
  //   active under it. While that lease runs, any other key using the
  //   callsign is an impostor. After a year of silence the callsign is
  //   free, and the next key to claim it holds it.
  //
  // Every time here is when THIS STATION heard something, on its own clock.
  // The date a packet carries (`ts:`) is whatever its author wrote: a forger
  // can date a packet to before the real holder ever spoke, and counted, that
  // would buy seniority with a lie. A packet dated last year and first heard
  // today is a day old here.

  /// How long a callsign stays its holder's after the holder was last heard.
  static const Duration leaseFor = Duration(days: 365);

  /// How much later an activity must be to be written to the store again.
  static const int _leaseStepMs = 24 * 60 * 60 * 1000;

  final Map<String, XprsLease> _leases = {};
  final Map<String, int> _leaseSaved = {};

  int leasesTaken = 0, leasesRefused = 0, leasesExpired = 0;

  static String _licence(String callsign) =>
      XprsIdType.normalise(XprsIdType.licence, callsign);

  /// The key [npub] claims the issued callsign [callsign], in an identity
  /// packet it signed and this station heard NOW. Returns what became of
  /// the claim. A callsign a key derives is not leased: [XprsClaim.derived].
  XprsClaim claimLicence(String npub, String callsign) {
    if (callType(callsign) != XprsIdType.licence) return XprsClaim.derived;
    final c = _licence(callsign);
    final who = npub.trim();
    if (c.isEmpty || who.isEmpty) return XprsClaim.refused;
    final now = nowMs();
    final held = _leases[c];
    if (held != null && held.holder == who) {
      _touchLease(c, held, now);
      return XprsClaim.held;
    }
    if (held != null && now - held.lastMs <= leaseFor.inMilliseconds) {
      leasesRefused++;
      return XprsClaim.refused;
    }
    if (held != null) leasesExpired++;
    final lease = XprsLease(who, now, now);
    _leases[c] = lease;
    _saveLease(c, lease);
    leasesTaken++;
    return XprsClaim.taken;
  }

  /// The key that holds [callsign] now, or null when nobody does (never
  /// claimed here, or its holder has been silent for [leaseFor]).
  String? leaseHolder(String callsign) {
    final l = _leases[_licence(callsign)];
    if (l == null || nowMs() - l.lastMs > leaseFor.inMilliseconds) return null;
    return l.holder;
  }

  /// The lease on [callsign] as it stands, live or lapsed, or null.
  XprsLease? leaseOf(String callsign) => _leases[_licence(callsign)];

  /// The holder of [callsign] was heard using it (a packet of theirs
  /// verified): the year starts again. Nothing for anybody else's key.
  void licenceActive(String callsign, String npub) {
    final c = _licence(callsign);
    final l = _leases[c];
    if (l == null || l.holder != npub.trim()) return;
    _touchLease(c, l, nowMs());
  }

  void _touchLease(String c, XprsLease l, int now) {
    if (now <= l.lastMs) return;
    // A holder back after its lease lapsed, with nobody having taken the
    // callsign meanwhile, holds it afresh from now.
    if (now - l.lastMs > leaseFor.inMilliseconds) l.sinceMs = now;
    l.lastMs = now;
    // Memory has the time; the store gets it once a day at most.
    if (now - (_leaseSaved[c] ?? 0) >= _leaseStepMs) _saveLease(c, l);
  }

  void _saveLease(String c, XprsLease l) {
    _leaseSaved[c] = l.lastMs;
    _write(
        'INSERT INTO leases(callsign,holder,since_ms,last_ms) VALUES(?,?,?,?) '
        'ON CONFLICT(callsign) DO UPDATE SET holder=excluded.holder, '
        'since_ms=excluded.since_ms, last_ms=excluded.last_ms',
        [c, l.holder, l.sinceMs, l.lastMs]);
  }

  /// Every person whose key SIGNED for the issued callsign [callsign]
  /// (6.4.2), the first to do so first. Any of them may sign as it; none
  /// outranks another. Empty for a callsign a key derives: that has one
  /// key, by arithmetic.
  List<String> signersOfLicence(String callsign) {
    if (callType(callsign) != XprsIdType.licence) return const [];
    final v = XprsIdType.normalise(XprsIdType.licence, callsign);
    final hs = _index[_k(XprsIdType.licence, v)];
    if (hs == null) return const [];
    final rows = <(String, int)>[];
    for (final h in hs) {
      if (isUnclaimed(h)) continue;
      for (final e in _by[h] ?? const <XprsIdentity>[]) {
        if (e.type == XprsIdType.licence &&
            e.value == v &&
            e.evidence.index >= XprsIdEvidence.signed.index) {
          rows.add((h, e.firstMs));
        }
      }
    }
    rows.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final r in rows) r.$1];
  }

  /// More than one key holds [type]:[value] (6.4.2: an issued callsign has
  /// no arithmetic tie to any key, so two may announce it and both verify).
  bool contested(String type, String value) =>
      holders(type, value, people: true).length > 1;

  /// Another identity of whoever has [type]:[value]: "the Reticulum identity
  /// of the station whose callsign is X3PTZM". Through the person when there
  /// is one, else through the keyless record. Best first.
  List<String> reach(String type, String value, String wanted,
      {XprsIdEvidence min = XprsIdEvidence.relayed}) {
    final out = <String>[];
    for (final h in holders(type, value)) {
      for (final v in valuesOf(h, wanted, min: min)) {
        if (!out.contains(v)) out.add(v);
      }
    }
    return out;
  }

  Map<String, dynamic> statusJson() => {
        'holders': _by.length,
        'people': _by.keys.where((h) => !isUnclaimed(h)).length,
        'identities': _by.values.fold<int>(0, (n, l) => n + l.length),
        'noted': noted,
        'evicted': evicted,
        'stored': ready,
      };

  void debugReset() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
    _by.clear();
    _index.clear();
    _saidTs.clear();
    _seenSince.clear();
    _leases.clear();
    _leaseSaved.clear();
    leasesTaken = leasesRefused = leasesExpired = 0;
    noted = evicted = 0;
    nowMs = () => DateTime.now().millisecondsSinceEpoch;
  }
}
