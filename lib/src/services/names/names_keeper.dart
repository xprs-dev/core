/*
 * The names keeper: `<callsign>.xprs.dev` for any station that proves its
 * key (XPRS.md 13.0.3, API-HTTP.md /api/names).
 *
 * A station's callsign is derived from its public key (section 3), so a
 * signed claim alone proves who may own the label; nobody registers
 * anything. The claim is a directed `t:service` (13.0.2 already makes
 * `dial:` "where this station answers a TCP connection"):
 *
 *   t:service f:X3PTZM d:X3KEEP ts:<now> dial:178.202.105.29 k:npub1... m:<nonce> sig:<..>
 *
 * The keeper checks, in this order and before any storage or network work:
 * the shape, the signature against `k:`, that `f:` derives from `k:`, the
 * nonce it issued, the timestamp (within five minutes, after the last one it
 * accepted from that key), and that `dial:` IS the address the request came
 * from, which proves the claimant can send from it and makes a replayed
 * claim useless anywhere else. Then the lock: a label stays with the first
 * key for at least six months after that key's last claim; another key is
 * refused with "held by another key" until then. Only then DNS.
 *
 * Nothing here touches dart:io: the store (NamesStore) and the DNS writer
 * (NamesDns) are the host's; MemoryNamesStore serves the tests.
 */
import 'dart:math';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart' show NostrCrypto;

import '../xprs/xprs_packet.dart';
import '../xprs/xprs_sig.dart';
import '../xprs/xprs_vocab.dart';

/// One label's record: who holds it, since when, and where it points.
class NamesRecord {
  NamesRecord({
    required this.label,
    required this.key,
    required this.first,
    required this.last,
    required this.lastTs,
    this.v4,
    this.v6,
    this.dnsDirty = false,
  });

  /// The lowercase label (`x3ptzm`).
  final String label;

  /// The holder's x-only public key, hex.
  final String key;

  /// When this key first took the label, and its last accepted claim (ms).
  final int first;
  int last;

  /// The `ts:` of the last accepted claim (ms), so an older one is replay.
  int lastTs;
  String? v4;
  String? v6;

  /// The DNS does not yet say what this record says (a failed write).
  bool dnsDirty;

  Map<String, Object?> toJson() => {
        'label': label,
        'key': key,
        'first': first,
        'last': last,
        'lastTs': lastTs,
        if (v4 != null) 'v4': v4,
        if (v6 != null) 'v6': v6,
        if (dnsDirty) 'dirty': true,
      };

  static NamesRecord fromJson(Map<String, dynamic> j) => NamesRecord(
        label: j['label'] as String,
        key: j['key'] as String,
        first: (j['first'] as num).toInt(),
        last: (j['last'] as num).toInt(),
        lastTs: (j['lastTs'] as num?)?.toInt() ?? 0,
        v4: j['v4'] as String?,
        v6: j['v6'] as String?,
        dnsDirty: j['dirty'] == true,
      );
}

/// Where the keeper keeps its records (the server: a zxdb KV store).
abstract class NamesStore {
  NamesRecord? get(String label);
  void put(NamesRecord r);
  void remove(String label);
  List<NamesRecord> all();
}

class MemoryNamesStore implements NamesStore {
  final Map<String, NamesRecord> _m = {};
  @override
  NamesRecord? get(String label) => _m[label];
  @override
  void put(NamesRecord r) => _m[r.label] = r;
  @override
  void remove(String label) => _m.remove(label);
  @override
  List<NamesRecord> all() => _m.values.toList();
}

/// The zone's records, as the keeper writes them: one label, its A and AAAA.
abstract class NamesDns {
  /// Sets the label's A and AAAA to exactly these (empty: none).
  Future<void> set(String label, {String? v4, String? v6});

  /// Removes the label's A and AAAA.
  Future<void> remove(String label);

  /// Puts the apex CAA record (only Let's Encrypt may issue) when missing.
  Future<void> ensureCaa();
}

/// The DNS said to wait (a 429): the record is kept, the write retried.
class NamesDnsBusy implements Exception {
  const NamesDnsBusy();
}

class NamesKeeper {
  NamesKeeper({
    required this.zone,
    required this.store,
    required this.dns,
    required this.ownCallsign,
    required this.ownKeyHex,
    this.reserved = const {},
    DateTime Function()? now,
    void Function(String)? log,
    Random? rng,
  })  : now = now ?? DateTime.now,
        log = log ?? print,
        _rng = rng ?? Random.secure();

  /// `xprs.dev`.
  final String zone;
  final NamesStore store;
  final NamesDns dns;

  /// The keeper's own station: its claims may point at its own address, and
  /// it keeps [ownLabel] pointing at itself.
  final String ownCallsign;
  final String ownKeyHex;

  /// Labels never claimable beside [alwaysReserved] (what the zone already
  /// serves: `www`, verification records).
  final Set<String> reserved;
  final DateTime Function() now;
  final void Function(String) log;
  final Random _rng;

  /// The keeper's own name in the zone, the one stations dial for claims.
  static const ownLabel = 'names';
  static const alwaysReserved = {'', 'www', ownLabel};

  /// A label is a bare callsign: a prefix digit and 2 to 5 characters.
  static final RegExp labelRe = RegExp(r'^x[1-5][0-9a-z]{2,5}$');

  /// The lock: a label stays with its key this long after the key's last
  /// claim; DNS for a silent label goes after [dnsLife].
  static const Duration lock = Duration(days: 183);
  static const Duration dnsLife = Duration(days: 90);
  static const Duration nonceLife = Duration(minutes: 5);
  static const Duration tsWindow = Duration(minutes: 5);
  static const int maxBody = 2048;

  /// Rate limits: claims and challenges per address, writes per key unless
  /// the address changed, new labels a day.
  static const int perPeerPerMinute = 10;
  static const Duration perKeyWrite = Duration(minutes: 10);
  static const int newLabelsPerDay = 200;

  /// GitHub Pages, where the apex points: never a station.
  static const githubPages = {
    '185.199.108.153', '185.199.109.153', '185.199.110.153', '185.199.111.153',
    '2606:50c0:8000::153', '2606:50c0:8001::153',
    '2606:50c0:8002::153', '2606:50c0:8003::153',
  };

  final Map<String, DateTime> _nonces = {};
  final Map<String, List<int>> _peerLog = {};
  final List<int> _newLabels = [];
  String? _ownV4, _ownV6;
  bool _caaDone = false;

  /// The reply shape of the HTTP API: a status and a JSON body.
  (int, Map<String, Object?>) _no(int status, String why,
          [Map<String, Object?> more = const {}]) =>
      (status, {'ok': false, 'error': why, ...more});

  String _token(int bytes) => [
        for (var i = 0; i < bytes; i++)
          _rng.nextInt(256).toRadixString(16).padLeft(2, '0')
      ].join();

  bool _allowed(String peer) {
    final t = now().millisecondsSinceEpoch;
    final l = _peerLog.putIfAbsent(peer, () => []);
    l.removeWhere((x) => t - x > 60000);
    if (_peerLog.length > 4096) _peerLog.clear();
    if (l.length >= perPeerPerMinute) return false;
    l.add(t);
    return true;
  }

  /// `GET /api/names`: a nonce for the next five minutes, and the address
  /// the keeper sees the asker at, which is what a claim must name.
  (int, Map<String, Object?>) challenge(String peer) {
    final p = normalizeAddress(peer);
    if (!_allowed(p)) return _no(429, 'slow down');
    final t = now();
    _nonces.removeWhere((_, until) => t.isAfter(until));
    if (_nonces.length > 1024) _nonces.clear();
    final nonce = _token(8);
    _nonces[nonce] = t.add(nonceLife);
    return (
      200,
      {
        'ok': true,
        'zone': zone,
        'station': ownCallsign,
        'nonce': nonce,
        'you': p,
      }
    );
  }

  /// `POST /api/names` with the signed claim as the body.
  Future<(int, Map<String, Object?>)> claim(String body, String peer) async {
    final addr = normalizeAddress(peer);
    if (!_allowed(addr)) return _no(429, 'slow down');
    if (body.length > maxBody) return _no(413, 'too long');
    final p = XprsPacket.parse(body.trim());
    if (p == null || p.type != 'service') return _no(400, 'malformed');
    final from = (p['f'] ?? '').trim().toUpperCase();
    final npub = (p['k'] ?? '').trim();
    final dial = (p['dial'] ?? '').trim();
    final nonce = (p['m'] ?? '').trim();
    if (from.isEmpty || npub.isEmpty || dial.isEmpty || nonce.isEmpty) {
      return _no(400, 'a claim needs f:, k:, dial: and m:');
    }
    final String keyHex;
    try {
      keyHex = NostrCrypto.decodeNpub(npub.toLowerCase()).toLowerCase();
    } catch (_) {
      return _no(400, 'k: is not an npub');
    }
    // The signature first: nothing below runs for a forgery.
    if (xprsVerify(p, _bytes(keyHex)) != XprsSigState.verified) {
      return _no(403, 'not signed by k:');
    }
    final call = from.split('-').first;
    if (!NostrCrypto.callsignMatchesKey(call, keyHex)) {
      return _no(403, 'f: is not derived from k:');
    }
    final label = call.toLowerCase();
    if (!labelRe.hasMatch(label) || isReserved(label)) {
      return _no(400, 'not a claimable label');
    }
    final t = now();
    final until = _nonces[nonce];
    if (until == null || t.isAfter(until)) return _no(403, 'no such challenge');
    final ts = xprsParseTs(p['ts']);
    if (ts == null ||
        (ts - t.millisecondsSinceEpoch).abs() > tsWindow.inMilliseconds) {
      return _no(403, 'ts: is not now');
    }
    if (normalizeAddress(dial) != addr) {
      return _no(403, 'dial: is not where this request came from',
          {'you': addr});
    }
    if (!isClaimableAddress(addr) ||
        (addr == _ownV4 || addr == _ownV6) && keyHex != ownKeyHex) {
      return _no(403, 'that address cannot be a station here');
    }

    final existing = store.get(label);
    final nowMs = t.millisecondsSinceEpoch;
    if (existing != null && existing.key != keyHex) {
      final free = existing.last + lock.inMilliseconds;
      if (nowMs < free) {
        return _no(409, 'held by another key', {
          'until': DateTime.fromMillisecondsSinceEpoch(free, isUtc: true)
              .toIso8601String(),
        });
      }
      log('names: $label passes to a new key after silence');
    }
    if (existing != null && existing.key == keyHex && ts <= existing.lastTs) {
      return _no(403, 'ts: is not after the last claim');
    }
    final isV6 = addr.contains(':');
    final same = existing != null &&
        existing.key == keyHex &&
        (isV6 ? existing.v6 : existing.v4) == addr;
    if (same && nowMs - existing.last < perKeyWrite.inMilliseconds) {
      _nonces.remove(nonce);
      return (200, {'ok': true, 'name': '$label.$zone', 'next': _nextSecs()});
    }
    final fresh = existing == null || existing.key != keyHex;
    if (fresh) {
      _newLabels.removeWhere((x) => nowMs - x > 86400000);
      if (_newLabels.length >= newLabelsPerDay) {
        log('names: the day\'s new-label cap is reached');
        return _no(429, 'no new names today');
      }
      _newLabels.add(nowMs);
    }
    _nonces.remove(nonce);
    final r = fresh
        ? NamesRecord(
            label: label, key: keyHex, first: nowMs, last: nowMs, lastTs: ts)
        : existing;
    r.last = nowMs;
    r.lastTs = ts;
    if (isV6) {
      r.v6 = addr;
    } else {
      r.v4 = addr;
    }
    r.dnsDirty = true;
    store.put(r);
    final written = await _write(r);
    log('names: $label -> ${r.v4 ?? ''} ${r.v6 ?? ''}'
        '${written ? '' : ' (DNS pending)'}');
    return (
      200,
      {
        'ok': true,
        'name': '$label.$zone',
        'next': _nextSecs(),
        if (!written) 'dns': 'pending',
      }
    );
  }

  int _nextSecs() => const Duration(days: 7).inSeconds;

  Future<bool> _write(NamesRecord r) async {
    try {
      await dns.set(r.label, v4: r.v4, v6: r.v6);
      r.dnsDirty = false;
      store.put(r);
      return true;
    } on NamesDnsBusy {
      log('names: the zone\'s API asked to wait; ${r.label} is written from the sweep');
      return false;
    } catch (e) {
      log('names: DNS write for ${r.label} failed: $e');
      return false;
    }
  }

  /// The keeper's own addresses: `names` and its own callsign point here.
  /// Called by the host whenever it learns its public addresses; writes
  /// only when something changed. Returns the names to certify and serve:
  /// the station's own first (its published link), then `names.<zone>`,
  /// which every station dials over HTTPS to claim.
  Future<List<String>> keepOwn({String? v4, String? v6}) async {
    _ownV4 = v4;
    _ownV6 = v6;
    if (!_caaDone) {
      try {
        await dns.ensureCaa();
        _caaDone = true;
      } catch (e) {
        log('names: CAA not set yet: $e');
      }
    }
    final nowMs = now().millisecondsSinceEpoch;
    for (final label in [ownLabel, ownCallsign.toLowerCase()]) {
      var r = store.get(label);
      if (r != null && r.key != ownKeyHex) {
        // A former key of this very station: ours now.
        r = null;
      }
      final changed = r == null || r.v4 != v4 || r.v6 != v6 || r.dnsDirty;
      r ??= NamesRecord(
          label: label, key: ownKeyHex, first: nowMs, last: nowMs, lastTs: 0);
      r.last = nowMs;
      if (changed) {
        r.v4 = v4;
        r.v6 = v6;
        r.dnsDirty = true;
        store.put(r);
        await _write(r);
      } else {
        store.put(r);
      }
    }
    return ['${ownCallsign.toLowerCase()}.$zone', '$ownLabel.$zone'];
  }

  /// Housekeeping, once a minute or so: pending DNS writes, labels silent
  /// for 90 days lose their records in DNS, labels silent for six months are
  /// free again.
  Future<void> sweep() async {
    final nowMs = now().millisecondsSinceEpoch;
    for (final r in store.all()) {
      final silent = nowMs - r.last;
      if (silent > lock.inMilliseconds) {
        await _forget(r, 'free again after six months of silence');
      } else if (silent > dnsLife.inMilliseconds && (r.v4 != null || r.v6 != null)) {
        try {
          await dns.remove(r.label);
          r.v4 = null;
          r.v6 = null;
          r.dnsDirty = false;
          store.put(r);
          log('names: ${r.label} silent for 90 days, DNS records removed');
        } catch (e) {
          log('names: cannot remove ${r.label}: $e');
        }
      } else if (r.dnsDirty) {
        await _write(r);
      }
    }
  }

  /// The operator frees a label whose key was lost (a local command, never
  /// the network). Returns false when there was nothing to free.
  Future<bool> release(String callsign) async {
    final label = callsign.trim().toLowerCase().split('-').first;
    final r = store.get(label);
    if (r == null) return false;
    await _forget(r, 'released by the operator');
    return true;
  }

  Future<void> _forget(NamesRecord r, String why) async {
    try {
      if (r.v4 != null || r.v6 != null) await dns.remove(r.label);
    } catch (e) {
      log('names: cannot remove ${r.label} from DNS: $e');
      return;
    }
    store.remove(r.label);
    log('names: ${r.label} $why');
  }

  bool isReserved(String label) =>
      alwaysReserved.contains(label) ||
      reserved.contains(label) ||
      label.startsWith('_') ||
      label.startsWith('xn--');

  /// An IPv4-mapped IPv6 peer (`::ffff:1.2.3.4`) is the IPv4; everything
  /// lower case, no zone id.
  static String normalizeAddress(String a) {
    var s = a.trim().toLowerCase();
    if (s.startsWith('[') && s.endsWith(']')) s = s.substring(1, s.length - 1);
    final zone = s.indexOf('%');
    if (zone > 0) s = s.substring(0, zone);
    if (s.startsWith('::ffff:') && s.contains('.')) s = s.substring(7);
    return s;
  }

  /// A public unicast address that may be a station: not private, loopback,
  /// link-local, multicast, documentation or reserved space, and not GitHub
  /// Pages (where the apex points).
  static bool isClaimableAddress(String a) {
    final s = normalizeAddress(a);
    if (githubPages.contains(s)) return false;
    if (s.contains(':')) return _publicV6(s);
    final parts = s.split('.');
    if (parts.length != 4) return false;
    final o = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255 || p.length > 3) return false;
      o.add(n);
    }
    if (o[0] == 0 || o[0] == 10 || o[0] == 127 || o[0] >= 224) return false;
    if (o[0] == 100 && o[1] >= 64 && o[1] <= 127) return false;
    if (o[0] == 169 && o[1] == 254) return false;
    if (o[0] == 172 && o[1] >= 16 && o[1] <= 31) return false;
    if (o[0] == 192 && o[1] == 168) return false;
    if (o[0] == 192 && o[1] == 0 && (o[2] == 0 || o[2] == 2)) return false;
    if (o[0] == 198 && (o[1] == 18 || o[1] == 19)) return false;
    if (o[0] == 198 && o[1] == 51 && o[2] == 100) return false;
    if (o[0] == 203 && o[1] == 0 && o[2] == 113) return false;
    return true;
  }

  static bool _publicV6(String s) {
    final groups = _v6Groups(s);
    if (groups == null) return false;
    final g0 = groups[0];
    // Global unicast only: 2000::/3.
    if ((g0 & 0xe000) != 0x2000) return false;
    // Documentation 2001:db8::/32, Teredo 2001::/32, 6to4 2002::/16.
    if (g0 == 0x2001 && (groups[1] == 0x0db8 || groups[1] == 0)) return false;
    if (g0 == 0x2002) return false;
    return true;
  }

  static List<int>? _v6Groups(String s) {
    final halves = s.split('::');
    if (halves.length > 2) return null;
    List<int>? parse(String h) {
      if (h.isEmpty) return [];
      final out = <int>[];
      for (final g in h.split(':')) {
        if (g.isEmpty || g.length > 4) return null;
        final n = int.tryParse(g, radix: 16);
        if (n == null) return null;
        out.add(n);
      }
      return out;
    }

    final head = parse(halves[0]);
    final tail = halves.length == 2 ? parse(halves[1]) : <int>[];
    if (head == null || tail == null) return null;
    final fill = 8 - head.length - tail.length;
    if (halves.length == 2 ? fill < 1 : fill != 0) return null;
    return [...head, ...List.filled(fill, 0), ...tail];
  }

  static Uint8List _bytes(String hex) => Uint8List.fromList(HEX.decode(hex));
}
