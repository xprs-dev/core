/*
 * Visits to stations by callsign: the one door a screen (through the HAL)
 * uses to browse what a station offers. Opens the Reticulum link, makes the
 * station prove it is the callsign asked for, and keeps the visit (its link,
 * its session) while it is used; an unused one is closed after a few minutes.
 *
 * Which path the link takes is the transport's business. Nothing here, and
 * nothing above it, names a bearer.
 */
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../log_service.dart';
import '../../profile/profile_service.dart';
import '../reticulum/rns_service.dart';
import '../xprs/xprs_packet.dart';
import '../xprs/xprs_publisher.dart';
import '../xprs/xprs_sig.dart';
import 'station_api.dart';

class StationVisits {
  StationVisits._();
  static final StationVisits instance = StationVisits._();

  /// An unused visit is closed after this long.
  static const Duration idle = Duration(minutes: 5);

  final Map<String, StationVisit> _open = {};
  final Map<String, Future<StationVisit?>> _opening = {};
  final Map<String, String> _fault = {};
  Timer? _sweep;

  /// Visits opened, refused by a proof that did not hold, and not reached.
  int opened = 0, refused = 0, unreached = 0;

  /// Why the last [to] for [call] gave nothing: `unknown` (never announced
  /// its API), `unreached`, or the proof's fault. Empty when it worked.
  String faultOf(String call) => _fault[_bare(call)] ?? '';

  static String _bare(String c) => c.toUpperCase().split('-').first;

  /// The active profile as a visitor, or null when it holds no key.
  StationVisitor? _me() {
    final call = (ProfileService.instance.activeProfile?.wireCallsign ?? '').trim();
    final d = xprsProfileScalar();
    if (call.isEmpty || d == null) return null;
    return StationVisitor(
      call: call,
      identityWire: XprsPublisher.instance.ownIdentityWire,
      sign: (w) {
        final p = XprsPacket.parse(w);
        return p == null ? null : xprsSign(p, d).encode();
      },
    );
  }

  /// The visit to [call], opening and proving it when there is none.
  Future<StationVisit?> to(String call) {
    final c = _bare(call);
    final have = _open[c];
    if (have != null) return Future.value(have);
    return _opening[c] ??= _visit(c).whenComplete(() => _opening.remove(c));
  }

  Future<StationVisit?> _visit(String c) async {
    final rns = RnsService.instance;
    final link = rns.stationRequests(c);
    if (link == null) {
      _fault[c] = 'unknown';
      return null;
    }
    if (!await link.open()) {
      unreached++;
      _fault[c] = 'unreached';
      rns.dropStationRequests(c);
      return null;
    }
    final nonce = _nonce();
    final proof = await link.request('/xprs/prove', nonce,
        timeout: const Duration(seconds: 30));
    final fault = proof == null
        ? 'unreached'
        : stationProofFault(proof, c, nonce, _hex(link.linkId));
    if (fault != null) {
      proof == null ? unreached++ : refused++;
      _fault[c] = fault;
      if (proof != null) LogService.instance.add('visit: $c refused: $fault');
      rns.dropStationRequests(c);
      return null;
    }
    opened++;
    _fault.remove(c);
    final v = StationVisit(c, stationLinkCarrier(link), visitor: _me())
      ..lastUsedMs = DateTime.now().millisecondsSinceEpoch;
    _open[c] = v;
    _sweep ??= Timer(idle, _closeIdle);
    return v;
  }

  void _closeIdle() {
    _sweep = null;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final c in _open.keys.toList()) {
      if (now - _open[c]!.lastUsedMs >= idle.inMilliseconds) leave(c);
    }
    if (_open.isNotEmpty) _sweep = Timer(idle, _closeIdle);
  }

  /// Close the visit to [call] (its link and its session with it).
  void leave(String call) {
    final c = _bare(call);
    if (_open.remove(c) != null) RnsService.instance.dropStationRequests(c);
  }

  static final Random _rng = Random.secure();
  static String _nonce() {
    const a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return String.fromCharCodes(
        [for (var i = 0; i < 20; i++) a.codeUnitAt(_rng.nextInt(a.length))]);
  }

  static String _hex(Uint8List? b) =>
      b == null ? '' : b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
