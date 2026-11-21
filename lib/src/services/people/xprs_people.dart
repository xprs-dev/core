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
enum XprsEvidence {
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
  XprsEvidence evidence;
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

class XprsPeople {
  XprsPeople._();
  static final XprsPeople instance = XprsPeople._();

  /// Identities of one type kept per holder: the newest and best stay.
  static const int perType = 8;

  /// Holders kept. Past it the one touched longest ago leaves, with what it
  /// held; a holder with something signed or derived leaves last.
  static const int maxHolders = 4096;

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
      _db = db;
      _by.clear();
      _index.clear();
      for (final r in db.select(
        'SELECT holder,type,value,evidence,first_ms,last_ms,via,scope '
        'FROM identities ORDER BY last_ms ASC',
      )) {
        final e = (r['evidence'] as int).clamp(0, XprsEvidence.values.length - 1);
        final id = XprsIdentity(
          r['type'] as String,
          r['value'] as String,
          XprsEvidence.values[e],
          r['first_ms'] as int,
          r['last_ms'] as int,
          via: r['via'] as String? ?? '',
          scope: r['scope'] as String? ?? '',
        );
        final holder = r['holder'] as String;
        _by.putIfAbsent(holder, () => []).add(id);
        _index.putIfAbsent(_k(id.type, id.value), () => {}).add(holder);
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
      {required XprsEvidence evidence, String via = '', String? scope}) {
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
        if (!e.value.any((i) => i.evidence.index >= XprsEvidence.signed.index)) {
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
      {XprsEvidence evidence = XprsEvidence.signed}) {
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

  // ── Reading ─────────────────────────────────────────────────────────────

  /// What [holder] has, the strongest evidence first and, within it, the
  /// one seen last. [type] narrows it; [min] leaves out weaker evidence.
  List<XprsIdentity> of(String holder,
      {String? type, XprsEvidence min = XprsEvidence.relayed}) {
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
          {XprsEvidence min = XprsEvidence.relayed}) =>
      [for (final e in of(holder, type: type, min: min)) e.value];

  /// Who has [type]:[value], the strongest claim first. Several when it is
  /// contested; a caller that needs one takes the first and knows it may be
  /// one of several.
  List<String> holders(String type, String value,
      {XprsEvidence min = XprsEvidence.relayed, bool people = false}) {
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
      {XprsEvidence min = XprsEvidence.relayed}) {
    final hs = holders(type, value, min: min, people: true);
    return hs.isEmpty ? null : hs.first;
  }

  /// More than one key holds [type]:[value] (6.4.2: an issued callsign has
  /// no arithmetic tie to any key, so two may announce it and both verify).
  bool contested(String type, String value) =>
      holders(type, value, people: true).length > 1;

  /// Another identity of whoever has [type]:[value]: "the Reticulum identity
  /// of the station whose callsign is X3PTZM". Through the person when there
  /// is one, else through the keyless record. Best first.
  List<String> reach(String type, String value, String wanted,
      {XprsEvidence min = XprsEvidence.relayed}) {
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
    noted = evicted = 0;
    nowMs = () => DateTime.now().millisecondsSinceEpoch;
  }
}
