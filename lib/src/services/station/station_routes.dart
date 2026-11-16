/*
 * How a message from here gets to a station, for a screen that shows it.
 * A DIAGNOSTIC: nothing routes on what this file says, and no wapp decides
 * anything from it (docs/architecture.md, "the test for misplacement").
 *
 * Every hop "A to B over <bearer>" is B hearing A, and each one says how it
 * is known, strongest first:
 *
 *   heard  this device heard it itself, on that bearer
 *   asked  B answered when asked who it hears (`/api/xprs/devices`, the
 *          station API every deployment serves)
 *   said   B disclosed it in its own beacon (`hears:` with `link:`, 15.6)
 *   guess  nobody said it: the hop is inferred (a Reticulum announce counts
 *          its hops and names only the last relay; what lies between is
 *          not on the wire)
 *
 * A read answers at once from what is held and, for the hops that are only
 * `said` or `guess`, asks the hearing station in the background; the reader
 * is told on `core.station` and reads again.
 */
import 'dart:async';

import '../mesh/mesh_service.dart';
import '../receive/core_state.dart';
import '../reticulum/rns_service.dart';
import '../xprs/xprs_gossip.dart';
import '../xprs/xprs_graph.dart';
import '../xprs/xprs_monitor.dart';
import '../xprs/xprs_vocab.dart' show xprsBearerReach;
import 'station_api.dart';
import 'station_visits.dart';

/// What one station answered about one it hears.
class _Told {
  _Told(this.bearer, this.hops, this.ageS, this.rssi, this.atMs);
  final String bearer;
  final int hops, ageS, rssi, atMs;
}

class StationRoutes {
  StationRoutes._();
  static final StationRoutes instance = StationRoutes._();

  /// An answer from a station is believed for this long, and it is not asked
  /// again sooner (answered or not).
  static const Duration fresh = Duration(minutes: 3);
  static const int _cap = 256;

  /// `"<hearer>|<heard>"` to what the hearer answered.
  final Map<String, _Told?> _told = {};
  final Map<String, int> _askedMs = {};
  final Set<String> _asking = {};
  int asked = 0, answered = 0;

  /// Test seams.
  Future<StationVisit?> Function(String call) visit = StationVisits.instance.to;
  String Function() self = () => MeshService.instance.tableCallsign.toUpperCase();
  List<GossipEdge> Function(String self, int nowMs) edges = (self, now) =>
      XprsGossip.instance.edges(max: 512, selfCallsign: self, nowMs: now);
  Map<String, dynamic>? Function(String call) heardHere =
      (c) => XprsMonitor.instance.stationJson(c);
  Map<String, dynamic>? Function(String call) announced =
      (c) => RnsService.instance.announcedVia(c);

  static String _bare(String c) => c.toUpperCase().split('-').first;

  Map<String, dynamic> _hop(String from, String to, String bearer, String know,
          {int? ageS, int? rssi}) =>
      {
        'from': from,
        'to': to,
        'bearer': bearer,
        'reach': bearer.isEmpty ? '' : xprsBearerReach(bearer).name,
        'know': know,
        if (ageS != null) 'age_s': ageS,
        if (rssi != null && rssi != 0) 'rssi': rssi,
      };

  /// The ways from here to [call], best known first:
  /// `{call, self, busy, routes:[{sure, hops:[{from,to,bearer,reach,know,
  /// age_s?,rssi?}]}]}`. `sure` when no hop is a guess. Empty `routes` when
  /// nothing is known about how to get there.
  Map<String, dynamic> read(String call) {
    final to = _bare(call), me = _bare(self());
    final now = DateTime.now().millisecondsSinceEpoch;
    final routes = <List<Map<String, dynamic>>>[];
    final wanted = <(String hearer, String heard)>[];

    // 1. Heard here, with nobody in between: one hop per bearer.
    final h = heardHere(to);
    final direct = h == null ? 0 : (h['lastDirectMs'] is int ? h['lastDirectMs'] as int : 0);
    if (h != null && direct > 0 && now - direct < 3600000) {
      final bearers = h['bearers'] is List ? (h['bearers'] as List) : [h['bearer']];
      for (final b in bearers) {
        if (b == null || '$b'.isEmpty) continue;
        routes.add([
          _hop(me, to, '$b', 'heard',
              ageS: (now - direct) ~/ 1000, rssi: h['rssi'] is int ? h['rssi'] as int : null)
        ]);
      }
    }

    // 2. Through stations, from what each said it hears.
    final p = me.isEmpty
        ? null
        : XprsGraph(edges(me, now), nowMs: now).pathTo(to, from: me);
    if (p != null && p.hops.length > 1) {
      final hops = <Map<String, dynamic>>[];
      var from = me;
      for (final x in p.hops) {
        final t = _told['${x.to}|$from'];
        if (t != null && now - t.atMs < fresh.inMilliseconds * 2) {
          hops.add(_hop(from, x.to, t.bearer, 'asked', ageS: t.ageS, rssi: t.rssi));
        } else {
          hops.add(_hop(from, x.to, x.bearer, x.direct ? 'heard' : 'said',
              ageS: x.ageMs ~/ 1000));
          if (!x.direct) wanted.add((x.to, from));
        }
        from = x.to;
      }
      routes.add(hops);
    }

    // 2b. Heard here only as carried by others, and nobody said they hear it:
    // the packet named who handed it to us and counted the carriers. The last
    // hand is heard; who heard the station itself is asked, a guess until told.
    final via = h == null ? '' : _bare('${h['via'] ?? ''}');
    final carriers = h != null && h['hops'] is int ? h['hops'] as int : 0;
    final lastMs = h != null && h['lastMs'] is int ? h['lastMs'] as int : 0;
    if (routes.isEmpty && via.isNotEmpty && via != me && via != to && carriers > 0 &&
        now - lastMs < 3600000) {
      final hops = <Map<String, dynamic>>[
        _hop(me, via, '${h!['bearer'] ?? ''}', 'heard', ageS: (now - lastMs) ~/ 1000)
      ];
      for (var i = 1; i < carriers; i++) {
        hops.add(_hop(i == 1 ? via : '?', '?', '', 'guess'));
      }
      final told = carriers == 1 ? _told['$via|$to'] : null;
      if (told != null && now - told.atMs < fresh.inMilliseconds * 2) {
        hops.add(_hop(via, to, told.bearer, 'asked', ageS: told.ageS, rssi: told.rssi));
      } else {
        hops.add(_hop(carriers == 1 ? via : '?', to, '', 'guess'));
        if (carriers == 1) wanted.add((via, to));
      }
      routes.add(hops);
    }

    // 3. Over Reticulum: the announce counts hops and names the last relay.
    final a = announced(to);
    if (a != null) {
      final n = a['hops'] is int ? a['hops'] as int : 0;
      final kind = '${a['kind'] ?? ''}';
      final relay = '${a['relayer'] ?? ''}';
      final age = (a['ageMs'] is int ? a['ageMs'] as int : 0) ~/ 1000;
      if (n <= 1) {
        // `rns` (the monitor's word) and `internet` (the interface's) are
        // one way, and a LAN announce is the LAN hop already listed.
        String lane(Object? b) => b == 'rns' || b == 'internet' ? 'internet' : '$b';
        if (!routes.any((r) => r.length == 1 && lane(r.first['bearer']) == lane(kind))) {
          routes.add([_hop(me, to, kind, 'heard', ageS: age)]);
        }
      } else {
        final first = relay.isEmpty ? '?' : relay;
        final hops = <Map<String, dynamic>>[_hop(me, first, kind, 'heard', ageS: age)];
        // What lies between the relay and the station is counted, not named.
        for (var i = 2; i < n; i++) {
          hops.add(_hop(i == 2 ? first : '?', '?', '', 'guess'));
        }
        final told = relay.isEmpty ? null : _told['$to|$relay'];
        if (n == 2 && told != null) {
          hops.add(_hop(first, to, told.bearer, 'asked', ageS: told.ageS, rssi: told.rssi));
        } else {
          hops.add(_hop(n == 2 ? first : '?', to, '', 'guess'));
          if (n == 2 && relay.isNotEmpty) wanted.add((to, relay));
        }
        routes.add(hops);
      }
    }

    for (final w in wanted.take(3)) {
      _ask(w.$1, w.$2);
    }
    return {
      'call': to,
      'self': me,
      'busy': _asking.isNotEmpty,
      'routes': [
        for (final r in routes)
          {'sure': r.every((x) => x['know'] != 'guess'), 'hops': r},
      ],
    };
  }

  /// Ask [hearer] how it hears [heard], once per [fresh].
  void _ask(String hearer, String heard) {
    final key = '$hearer|$heard';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_asking.contains(hearer) ||
        now - (_askedMs[key] ?? 0) < fresh.inMilliseconds) {
      return;
    }
    if (_askedMs.length >= _cap) {
      final k = _askedMs.keys.first;
      _askedMs.remove(k);
      _told.remove(k);
    }
    _askedMs[key] = now;
    _asking.add(hearer);
    asked++;
    () async {
      try {
        final v = await visit(hearer);
        final r = await v?.call('GET', '/api/xprs/devices');
        final list = r?.json['devices'];
        if (r == null || !r.ok || list is! List) return;
        answered++;
        final at = DateTime.now().millisecondsSinceEpoch;
        // One answer says how it hears everybody: keep them all.
        for (final d in list) {
          if (d is! Map) continue;
          final c = _bare('${d['call'] ?? ''}');
          if (c.isEmpty) continue;
          int n(String k) => d[k] is int ? d[k] as int : 0;
          final k2 = '$hearer|$c';
          if (c == heard || _told.containsKey(k2) || _told.length < _cap) {
            _told[k2] = _Told('${d['bearer'] ?? ''}', n('hops'), n('age_s'), n('rssi'), at);
          }
        }
      } catch (_) {
        // Not answered: the hop stays as it was known.
      } finally {
        _asking.remove(hearer);
        CoreState.instance.changed(CoreState.station);
      }
    }();
  }
}
