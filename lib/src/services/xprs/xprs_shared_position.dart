/*
 * xprs_shared_position — where this station says it is, and to whom how
 * precisely.
 *
 * Nothing about a station's position goes out unless its owner shares it
 * (Settings > Location). When shared, the beacon (XPRS.md 15.6) carries
 * `pos:` and `acc:` (15.1), and the position is written twice in one value,
 * as 6.2.1 has it:
 *
 *   pos:38((.7077)),-9((.1365))   ->   pos:38█████,-9█████  xr:<blob>
 *
 *   - what stays OUTSIDE the parentheses is what everyone reads: a reader
 *     drops the bars and gets `38,-9`, a valid position that says "somewhere
 *     in this square". The owner's range picks how many decimals stay out:
 *     none for 100 km, one for 10 km, two for 1 km, three for 100 m;
 *   - what goes INSIDE is the rest of the fix, to four decimals (11 m), for
 *     whoever holds the owner's code: the passphrase of the `xr:` blob.
 *
 * So the public value is a PREFIX of the true digits, never a rounding of
 * them: the square is the one the digits name, the same on every airing,
 * and averaging a day of beacons recovers nothing. `acc:` states the
 * square's size, so a reader knows how far to trust the point.
 *
 * WHAT COSTS WHAT (app/docs/performance.md 8.1, 8.15). Hiding is one
 * PBKDF2 of 100000 rounds (6.2.1; not negotiable), a quarter of a second on
 * a phone. It is paid on a worker (offThread), once per (position, code),
 * and the beacon reuses the answer: a station that has not moved 11 m airs
 * the same `pos:` and `xr:` for as long as it stands. Until the answer is
 * in, [current] gives the bars without the blob, which is always safe to air.
 * Opening a friend's position ([XprsPosUnlock]) is the same derivation, paid
 * once per blob and only for a station whose code this reader was given.
 *
 * Where the position comes from: a GPS fix when the host has one, asked for
 * only while the app is in the FOREGROUND and at most every five minutes,
 * never prompting (CoreHost.locationFix); else the fixed position the owner
 * set for a station with no GPS. No source, no `pos:`.
 *
 * Pure parts ([xprsPosAuthored], [xprsPosCell], [xprsPosStrip]) are tested
 * without a clock or a radio.
 */
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:reticulum/reticulum.dart' show XprsCrypto;
import 'package:xprs_core/src/platform/off_thread.dart';

import '../../platform/core_host.dart';
import '../power_state.dart';
import '../preferences_service.dart';
import 'xprs_passphrases.dart';
import 'xprs_publisher.dart';

/// Metres per degree of latitude (and of longitude at the equator).
const double _mPerDeg = 111320;

/// The ranges an owner picks from, in metres, coarsest first: each is one
/// more decimal left readable (15.1). 100 km is the default.
const List<int> kXprsPosRangesM = [100000, 10000, 1000, 100, 10];

/// The redaction bar (6.2.1), U+2588.
const String _bar = '\u2588';

/// How many decimals everyone may read for a range of [radiusM] metres: the
/// coarsest step that still covers it, so a range from an older version
/// (50 m, 500 m, 5 km) is never made finer than its owner chose.
int xprsPosDecimals(int radiusM) => radiusM <= 10
    ? 4
    : radiusM <= 100
        ? 3
        : radiusM <= 1000
            ? 2
            : radiusM <= 10000
                ? 1
                : 0;

/// [lat],[lon] as its owner writes it for a range of [radiusM] metres: the
/// fix to four decimals, the digits past the range in `((...))` (6.2.1), and
/// the accuracy to state with it. `barred` is the same value as it travels,
/// a bar for every marked character (no key needed to write the bars, only
/// to fill them), and `public` what a reader is left with once they are
/// dropped.
({String authored, String barred, String public, int acc}) xprsPosAuthored(
    double lat, double lon, int radiusM) {
  final keep = xprsPosDecimals(radiusM);
  ({String shown, String hidden}) cut(double v) {
    final t = v.toStringAsFixed(4);
    final dot = t.indexOf('.');
    final at = keep == 0 ? dot : dot + 1 + keep;
    return (shown: t.substring(0, at), hidden: t.substring(at));
  }

  final la = cut(lat.clamp(-90.0, 90.0));
  final lo = cut(lon.clamp(-180.0, 180.0));
  String mark(({String shown, String hidden}) c) =>
      c.hidden.isEmpty ? c.shown : '${c.shown}((${c.hidden}))';
  String bars(({String shown, String hidden}) c) =>
      c.shown + _bar * c.hidden.length;
  return (
    authored: '${mark(la)},${mark(lo)}',
    barred: '${bars(la)},${bars(lo)}',
    public: '${la.shown},${lo.shown}',
    acc: kXprsPosRangesM[keep],
  );
}

/// A value with its bars dropped, as every parser reads it (6.2.1: "a
/// reader removes the block characters first").
String xprsPosStrip(String v) => v.replaceAll(_bar, '');

/// Where a `pos:` value says its station is, bars and all: the point for a
/// plain value; for a barred one the MIDDLE of the square its readable
/// digits name, with that square's half-width in metres. `38█████,-9█████`
/// is anywhere from 38 to 39 north and 9 to 10 west, so its fair point is
/// 38.5,-9.5, not the corner the stripped digits spell.
({double lat, double lon, int halfM})? xprsPosCell(String wire) {
  final parts = wire.split(',');
  if (parts.length != 2) return null;
  var half = 0.0;
  double? mid(String raw) {
    final v = raw.trim();
    final shown = xprsPosStrip(v);
    final n = double.tryParse(shown);
    if (n == null) return null;
    if (!v.contains(_bar)) return n;
    final dot = shown.indexOf('.');
    final decimals = dot < 0 ? 0 : shown.length - dot - 1;
    final unit = math.pow(10, -decimals).toDouble();
    if (unit / 2 > half) half = unit / 2;
    return shown.startsWith('-') ? n - unit / 2 : n + unit / 2;
  }

  final lat = mid(parts[0]);
  final lon = mid(parts[1]);
  if (lat == null || lon == null) return null;
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  return (lat: lat, lon: lon, halfM: (half * _mPerDeg).round());
}

/// A code for the hidden digits: sixteen characters from an alphabet with no
/// look-alikes (no 0/O, 1/I/L), 80 bits, in four groups to read aloud.
String xprsNewPosCode([math.Random? rng]) {
  const abc = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  final r = rng ?? math.Random.secure();
  final b = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i > 0 && i % 4 == 0) b.write('-');
    b.write(abc[r.nextInt(abc.length)]);
  }
  return b.toString();
}

/// The worker's half of hiding: `{"text","pass"}` to `{"barred","xr"}`, or
/// empty when nothing was marked. Pure, so it runs on any isolate.
String xprsPosRedactCompute(Map<String, String> a) {
  final red = XprsCrypto.redact(a['text']!, passphrase: a['pass']!);
  return red == null ? '' : jsonEncode({'barred': red.$1, 'xr': red.$2});
}

/// The worker's half of opening: `{"barred","xr","pass"}` to the restored
/// value, or empty when the code is not the one (6.2.1: restored only when
/// every piece fits its run).
String xprsPosRestoreCompute(Map<String, String> a) =>
    XprsCrypto.restore(a['barred']!, a['xr']!, a['pass']!) ?? '';

/// "lat,lon" read back, bars dropped (6.2.1), or null when it is not a
/// position.
({double lat, double lon})? xprsParseLatLon(String s) {
  final parts = xprsPosStrip(s).split(',');
  if (parts.length != 2) return null;
  final lat = double.tryParse(parts[0].trim());
  final lon = double.tryParse(parts[1].trim());
  if (lat == null || lon == null) return null;
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  return (lat: lat, lon: lon);
}

class XprsSharedPosition {
  XprsSharedPosition._();
  static final XprsSharedPosition instance = XprsSharedPosition._();

  // Seams; the defaults read the owner's settings and the host's GPS.
  bool Function() enabled =
      () => PreferencesService.instanceSync?.positionShare ?? false;
  int Function() radiusM =
      () => PreferencesService.instanceSync?.positionRadiusM ?? 100000;
  String Function() fixed =
      () => PreferencesService.instanceSync?.positionFixed ?? '';
  String Function() code =
      () => PreferencesService.instanceSync?.positionCode ?? '';
  bool Function() foreground = () => PowerState.instance.foreground;
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;
  Future<String> Function(Map<String, String> job) redact =
      (job) => offThread(xprsPosRedactCompute, job);

  /// Where the station's IDENTITY says it is (6.3.2 `pos:` with `acc:`): a
  /// map places a station from the identities a gateway keeps, which is the
  /// one thing a visitor of a gateway is served. It carries the bars and not
  /// the blob: the square changes when the owner crosses into another one,
  /// the blob with every eleven metres, and a decoration is aired on a
  /// change. Empty withdraws it.
  void Function(String pos, int acc) announce =
      (pos, acc) => XprsPublisher.instance.setPlace(pos, acc);

  /// The position the station's administrator set from its page (the web
  /// chat's `pos` and `acc` settings), already as the beacon carries it.
  /// It comes first: the administrator chose to say it, and how precisely.
  ({String pos, int acc})? Function() station = () => null;

  /// How often the host is asked for a fix. A station that moves is
  /// described by its owner's range, not by a fresh fix every beacon.
  static const Duration refreshEvery = Duration(minutes: 5);

  /// Derivations paid to hide a position, for the `perf:` line: one per
  /// move of 11 m or change of code, never one per beacon.
  static int redactions = 0;

  ({double lat, double lon})? _gps;
  int _askedMs = 0;
  bool _asking = false;

  // The one hidden form worked out so far, and what it was worked out from.
  String _hidKey = '';
  String _hidPos = '';
  String _hidXr = '';
  String _hiding = '';

  /// Before a beacon: ask the host for a fix when one is due, then make sure
  /// the hidden form of where we are is worked out. A fix is asked for only
  /// while the app is in the foreground (the owner is looking at it), at most
  /// every [refreshEvery], and never prompts; a host with no location answers
  /// null and the fixed position is used.
  Future<void> refresh() async {
    if (!enabled()) {
      _say('', 0);
      return;
    }
    final now = nowMs();
    final due = _askedMs == 0 || now - _askedMs >= refreshEvery.inMilliseconds;
    if (due && !_asking && foreground()) {
      _askedMs = now;
      _asking = true;
      try {
        final f = await CoreHost.locationFix(
            maxAge: refreshEvery, timeLimit: const Duration(seconds: 20));
        if (f != null) _gps = (lat: f.lat, lon: f.lon);
      } catch (_) {
        // No fix is not an error: the fixed position, or nothing.
      } finally {
        _asking = false;
      }
    }
    final a = _authored();
    _say(a?.barred ?? '', a?.acc ?? 0);
    await _hide();
  }

  String? _said;

  /// Tell the identity where we are, when that changed. The administrator's
  /// own place (the station's page) is theirs to state and is left alone.
  void _say(String pos, int acc) {
    if (station() != null) return;
    final next = '$pos|$acc';
    if (next == (_said ?? '|0')) return;
    _said = next;
    announce(pos, acc);
  }

  ({String authored, String barred, String public, int acc})? _authored() {
    final at = _gps ?? xprsParseLatLon(fixed());
    return at == null ? null : xprsPosAuthored(at.lat, at.lon, radiusM());
  }

  /// Work out the bars and the blob for where we are now, once: the same
  /// position under the same code is the same answer (performance.md 8.15).
  Future<void> _hide() async {
    final a = _authored();
    final pass = code();
    if (a == null || a.authored == a.public || pass.isEmpty) return;
    final key = '${a.authored}|$pass';
    if (key == _hidKey || key == _hiding) return;
    _hiding = key;
    try {
      final res = await redact({'text': a.authored, 'pass': pass});
      redactions++;
      if (res.isEmpty) return;
      final m = jsonDecode(res) as Map<String, dynamic>;
      _hidPos = m['barred'] as String;
      _hidXr = m['xr'] as String;
      _hidKey = key;
    } catch (_) {
      // Not hidden this time: the public digits go out alone.
    } finally {
      if (_hiding == key) _hiding = '';
    }
  }

  /// What the beacon carries now, or null when sharing is off or there is
  /// no position to share. `xr` is the blob of the hidden digits, null when
  /// nothing can be opened: the administrator's own position, a range of
  /// 10 m, or the moment before the hidden form is worked out (the bars are
  /// there already; what fills them follows).
  ({String pos, int acc, String? xr})? current() {
    final set = station();
    if (set != null) return (pos: set.pos, acc: set.acc, xr: null);
    if (!enabled()) return null;
    final a = _authored();
    if (a == null) return null;
    if ('${a.authored}|${code()}' == _hidKey) {
      return (pos: _hidPos, acc: a.acc, xr: _hidXr);
    }
    return (pos: a.barred, acc: a.acc, xr: null);
  }

  /// Where this station is as its owner knows it, for the owner's own
  /// screen: the fix behind what is aired. Never sent anywhere.
  ({double lat, double lon})? own() =>
      enabled() ? (_gps ?? xprsParseLatLon(fixed())) : null;

  void debugReset() {
    _gps = null;
    _askedMs = 0;
    _asking = false;
    _hidKey = _hidPos = _hidXr = _hiding = '';
    _said = null;
  }

  /// Test seam: a fix as if the host had answered.
  void debugSetFix(double lat, double lon) => _gps = (lat: lat, lon: lon);
}

/// A friend's position, opened with the code they gave.
///
/// A station that hides part of its `pos:` gives its code to whom it likes;
/// the reader keeps it against that callsign (the passphrase hints of
/// xprs_passphrases.dart, in the profile's encrypted store) and this opens
/// what that station airs. Nothing is tried for a station with no code kept:
/// a stranger's bars cost this reader nothing. One derivation per blob, on a
/// worker; a station that has not moved airs the same blob, so it is opened
/// once (performance.md 8.15).
class XprsPosUnlock {
  XprsPosUnlock._();
  static final XprsPosUnlock instance = XprsPosUnlock._();

  String? Function(String peer) codeFor =
      (peer) => XprsPassphrases.instance.hintFor(peer);
  Future<String> Function(Map<String, String> job) restore =
      (job) => offThread(xprsPosRestoreCompute, job);

  /// Derivations paid to open positions, for the `perf:` line.
  static int derivations = 0;

  static const int _cap = 256;
  final Map<String, String> _memo = {}; // "<xr>|<code>" -> value, '' = not it
  final Set<String> _busy = {};

  /// The restored `pos:` of [call] if it is already worked out, else null;
  /// when it is not, the work is started and [then] is called with the
  /// answer once, if the code opens it.
  String? open(String call, String barred, String xr,
      {void Function(String fine)? then}) {
    final pass = codeFor(call);
    if (pass == null || pass.isEmpty || xr.isEmpty) return null;
    final key = '$xr|$pass';
    final known = _memo[key];
    if (known != null) return known.isEmpty ? null : known;
    if (!_busy.add(key)) return null;
    () async {
      var fine = '';
      try {
        fine = await restore({'barred': barred, 'xr': xr, 'pass': pass});
        derivations++;
        if (xprsParseLatLon(fine) == null) fine = '';
      } catch (_) {
        fine = '';
      } finally {
        _busy.remove(key);
      }
      if (_memo.length >= _cap) _memo.remove(_memo.keys.first);
      _memo[key] = fine;
      if (fine.isNotEmpty) then?.call(fine);
    }();
    return null;
  }

  void debugReset() {
    _memo.clear();
    _busy.clear();
  }
}
