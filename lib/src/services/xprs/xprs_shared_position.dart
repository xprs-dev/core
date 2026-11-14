/*
 * xprs_shared_position — where this station says it is, and how precisely.
 *
 * Nothing about a station's position goes out unless its owner turned
 * sharing on (Settings > Privacy). When on, the beacon (XPRS.md 15.6) carries
 * `pos:` and `acc:` (15.1, 15.2), coarsened to the owner's radius:
 *
 *   - the position is SNAPPED to the centre of a fixed grid cell that size,
 *     the same cell every time. A random offset would be re-drawn per beacon
 *     and anyone averaging a day of them would recover the true spot; a
 *     fixed cell gives away nothing more on the hundredth airing than on the
 *     first;
 *   - `pos:` carries only the decimals that cell supports (15.1: the number
 *     of decimals IS the precision claimed), and `acc:` the radius, so a
 *     reader knows how far to trust it.
 *
 * Where the position comes from: a GPS fix when the host has one (asked at
 * most every five minutes, never prompting: CoreHost.locationFix), else the
 * fixed position the owner set for a station with no GPS. No source, no
 * `pos:`.
 *
 * Pure parts ([xprsCoarsePos]) are tested without a clock or a radio.
 */
library;

import 'dart:math' as math;

import '../../platform/core_host.dart';
import '../preferences_service.dart';

/// Metres per degree of latitude (and of longitude at the equator).
const double _mPerDeg = 111320;

/// [lat],[lon] snapped to the centre of the grid cell of [radiusM] metres
/// that holds it, written with the decimals that cell supports, and the
/// accuracy to state with it. The cell's longitude width follows the snapped
/// latitude, so one place always lands in one cell.
({String pos, int acc}) xprsCoarsePos(double lat, double lon, int radiusM) {
  final r = radiusM < 1 ? 1 : radiusM;
  final dLat = r / _mPerDeg;
  final cLat = ((lat / dLat).floor() + 0.5) * dLat;
  final cos = math.cos(cLat * math.pi / 180).abs().clamp(0.01, 1.0);
  final dLon = r / (_mPerDeg * cos);
  final cLon = ((lon / dLon).floor() + 0.5) * dLon;
  // 15.1: 4 decimals is about 11 m, 3 about 110 m, 2 about 1.1 km.
  final decimals =
      (math.log(_mPerDeg / r) / math.ln10).round().clamp(1, 5);
  String fmt(double v) => v.toStringAsFixed(decimals);
  final la = cLat.clamp(-90.0, 90.0);
  var lo = cLon;
  if (lo > 180) lo -= 360;
  if (lo < -180) lo += 360;
  return (pos: '${fmt(la)},${fmt(lo)}', acc: r);
}

/// "lat,lon" read back, or null when it is not a position.
({double lat, double lon})? xprsParseLatLon(String s) {
  final parts = s.split(',');
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
      () => PreferencesService.instanceSync?.positionRadiusM ?? 10;
  String Function() fixed =
      () => PreferencesService.instanceSync?.positionFixed ?? '';
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  /// The position the station's administrator set from its page (the web
  /// chat's `pos` and `acc` settings), already as the beacon carries it.
  /// It comes first: the administrator chose to say it, and how precisely.
  ({String pos, int acc})? Function() station = () => null;

  /// How often the host is asked for a fix. A station that moves is
  /// described by its owner's radius, not by a fresh fix every beacon.
  static const Duration refreshEvery = Duration(minutes: 5);

  ({double lat, double lon})? _gps;
  int _askedMs = 0;
  bool _asking = false;

  /// Ask the host for a fix if the last ask is older than [refreshEvery].
  /// Never prompts; a host with no location answers null and the fixed
  /// position is used.
  Future<void> refresh() async {
    if (!enabled() || _asking) return;
    final now = nowMs();
    if (_askedMs != 0 && now - _askedMs < refreshEvery.inMilliseconds) return;
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

  /// What the beacon carries now, or null when sharing is off or there is
  /// no position to share.
  ({String pos, int acc})? current() {
    final set = station();
    if (set != null) return set;
    if (!enabled()) return null;
    final at = _gps ?? xprsParseLatLon(fixed());
    if (at == null) return null;
    return xprsCoarsePos(at.lat, at.lon, radiusM());
  }

  void debugReset() {
    _gps = null;
    _askedMs = 0;
    _asking = false;
  }

  /// Test seam: a fix as if the host had answered.
  void debugSetFix(double lat, double lon) => _gps = (lat: lat, lon: lon);
}
