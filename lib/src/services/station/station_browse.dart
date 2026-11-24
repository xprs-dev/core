/*
 * What a screen reads about another station: its rooms, a room's folders, a
 * folder's items. A read answers at once from what the last visit learned
 * and starts a visit when it has nothing (or nothing recent); the reader is
 * told on `core.station` when the answer moved and reads again. Nobody waits
 * on the network, and nobody polls.
 *
 * Kept: the newest [_cap] answers, each for [fresh]. A station's listing is
 * the station's, never filed in this device's archive: closing the screen
 * forgets it. Only what each listed file is (size, name, the original behind
 * a preview) goes to the media index, as it does for any file a message names.
 */
import 'dart:async';
import 'dart:math' as math;

import 'package:reticulum/reticulum.dart' show MediaRef;

import '../log_service.dart';
import '../media/media_fetch.dart';
import '../media/media_ref_index.dart';
import '../receive/core_state.dart';
import '../reticulum/rns_service.dart';
import '../xprs/xprs_monitor.dart';
import '../xprs/xprs_presence.dart';
import '../xprs/xprs_shared_position.dart';
import '../xprs/xprs_vocab.dart' show XprsReach, xprsBearerReach;
import 'station_api.dart';
import 'station_visits.dart';

class _Entry {
  String state = 'loading';
  String why = '';
  int atMs = 0;
  bool busy = false;
  Map<String, dynamic> data = const {};
  StationCollection? collection;
  List<StationTopic> topics = const [];
}

class StationBrowse {
  StationBrowse._();
  static final StationBrowse instance = StationBrowse._();

  /// An answer is read again from the station after this long.
  static const Duration fresh = Duration(minutes: 2);
  static const int _cap = 48;

  /// The most items one read carries; the reader asks from `offset` for more.
  static const int pageMax = 60;

  final Map<String, _Entry> _entries = {};

  /// Test seam: where a visit comes from.
  Future<StationVisit?> Function(String call) visit = StationVisits.instance.to;
  String Function(String call) faultOf = StationVisits.instance.faultOf;

  _Entry _entry(String key) {
    final e = _entries.remove(key) ?? _Entry();
    if (_entries.length >= _cap) _entries.remove(_entries.keys.first);
    return _entries[key] = e;
  }

  bool _stale(_Entry e) =>
      !e.busy &&
      (e.atMs == 0 ||
          DateTime.now().millisecondsSinceEpoch - e.atMs > fresh.inMilliseconds);

  void _load(_Entry e, String call, Future<void> Function(StationVisit v) read) {
    if (!_stale(e)) return;
    e.busy = true;
    () async {
      try {
        final v = await visit(call);
        if (v == null) {
          e.state = 'failed';
          e.why = faultOf(call);
        } else {
          await read(v);
        }
      } catch (err) {
        LogService.instance.add('visit: $call: reading failed: ${err.runtimeType}');
        e.state = 'failed';
        e.why = 'unreached';
      } finally {
        e.busy = false;
        e.atMs = DateTime.now().millisecondsSinceEpoch;
        CoreState.instance.changed(CoreState.station);
      }
    }();
  }

  Map<String, dynamic> _answer(_Entry e) => {
        'state': e.state,
        if (e.why.isNotEmpty) 'why': e.why,
        'busy': e.busy,
        ...e.data,
      };

  static String _bare(String c) => c.toUpperCase().split('-').first;

  /// What [call] offers: `serve`, the page's `tabs`, and its `rooms` (the
  /// private ones this profile belongs to included).
  Map<String, dynamic> offers(String call) {
    final c = _bare(call);
    final e = _entry('$c|offers');
    _load(e, c, (v) async {
      final s = await v.services();
      if (s == null) {
        e.state = 'failed';
        e.why = 'unreached';
        return;
      }
      final page = s['page'];
      Map<String, dynamic> data(bool known, List<StationRoom> rooms) => {
            'call': c,
            'serve': s['serve'] is List ? s['serve'] : const [],
            'tabs': page is Map && page['tabs'] is List ? page['tabs'] : const [],
            'known': known,
            'rooms': [for (final r in rooms) r.toJson()],
          };
      // What everybody may see first, at once; then the same as this
      // profile, which adds the private rooms it belongs to. A station slow
      // to take the session does not hold the public listing back.
      if (e.state != 'ready') {
        final open = await v.call('GET', '/api/rooms');
        final list = open?.json['rooms'];
        if (open != null && open.ok && list is List) {
          e.data = data(false,
              [for (final j in list) if (j is Map<String, dynamic>) StationRoom(j)]);
          e.state = 'ready';
          e.why = '';
          CoreState.instance.changed(CoreState.station);
        }
      }
      final session = await v.session();
      var rooms = await v.rooms();
      // A shared album this profile was added to: opening the station is
      // the person saying yes, so the place is taken and the list read again.
      var joined = false;
      for (final r in rooms ?? const <StationRoom>[]) {
        if (r.role == 'invited' && r.isCollection && await v.accept(r)) joined = true;
      }
      if (joined) rooms = await v.rooms() ?? rooms;
      if (rooms != null || e.state != 'ready') {
        e.data = data(session != null, rooms ?? const []);
      }
      e.state = 'ready';
      e.why = '';
      // A person's phone says it shares only by answering: remembered, so
      // the list can mark it like a station that announced.
      if (_answered.length >= 256) _answered.remove(_answered.first);
      _answered.add(c);
    });
    return _answer(e);
  }

  final Set<String> _answered = <String>{};

  /// Whether [call] can be browsed as far as is known: its API announced, or
  /// it answered a visit this session.
  bool browsable(String call) => _answered.contains(_bare(call)) || offersApi(call);

  /// The folders of collection [room] on [call] (events, albums, shelves),
  /// each with its item count and a cover.
  Map<String, dynamic> folders(String call, String room) {
    final c = _bare(call);
    final e = _entry('$c|room|$room');
    _load(e, c, (v) => _readRoom(e, v, c, room));
    return _answer(e);
  }

  Future<void> _readRoom(_Entry e, StationVisit v, String c, String room) async {
    final topics = await v.topics(room);
    var col = await v.collection(room);
    if (topics == null || col == null) {
      e.state = 'failed';
      e.why = 'refused';
      return;
    }
    // Read on while the station has older rows, within reason: a folder's
    // count is wrong until its last page is in.
    for (var i = 0; i < 9 && col!.more; i++) {
      col = await v.collection(room, into: col);
    }
    // What each file is (its size, its name, the original a preview stands
    // for), so the viewer that opens a preview offers the file itself.
    for (final n in col!.named) {
      MediaRefIndex.instance.note(n.$1, msgId: n.$2);
    }
    col.named.clear();
    for (final it in col.items.values) {
      for (final r in [it.preview, it.ref]) {
        final ref = r.isEmpty ? null : MediaRef.parse('file:$r');
        if (ref != null) MediaFetch.instance.noteStationFile(ref.sha256, c);
      }
    }
    e.collection = col;
    e.topics = topics;
    e.data = {
      'call': c,
      'room': room,
      'folders': [
        for (final t in topics)
          {
            'id': t.id,
            'title': t.title,
            'count': col.byFolder[t.id]?.length ?? 0,
            'cover': _token(col.inFolder(t.id).map((i) => i.preview).firstWhere(
                (p) => p.isNotEmpty, orElse: () => '')),
          },
      ],
    };
    e.state = 'ready';
    e.why = '';
  }

  /// The items of [folder], [pageMax] at most from [offset]. Read after
  /// [folders] of the same room; each item's `preview` and `file` are tokens
  /// for the media door.
  Map<String, dynamic> items(String call, String room, String folder, {int offset = 0}) {
    final c = _bare(call);
    final e = _entry('$c|room|$room');
    _load(e, c, (v) => _readRoom(e, v, c, room));
    final col = e.collection;
    if (col == null) return _answer(e)..remove('folders');
    final all = col.inFolder(folder);
    final from = offset < 0 ? 0 : offset;
    return {
      'state': e.state,
      'busy': e.busy,
      'call': c,
      'room': room,
      'folder': folder,
      'total': all.length,
      'offset': from,
      'items': [
        for (final it in all.skip(from).take(pageMax))
          {
            'id': it.id,
            'caption': it.caption,
            'name': it.name,
            'size': it.size,
            'from': it.from,
            'ts': it.ts,
            'likes': it.likes,
            'liked': it.liked,
            'preview': _token(it.preview),
            'file': _token(it.ref.isEmpty ? it.preview : it.ref),
          },
      ],
    };
  }

  // ---- the stations themselves, a page at a time -------------------------
  //
  // One row per device the presence rule counts (xprs_presence.dart), classed
  // by the nearest bearer it is heard on (9.11: local, regional, global), so
  // a list of hundreds across Reticulum is read by scope and by page, never
  // whole. The rule and the class are the core's; a screen draws rows.

  /// Test seams.
  List<XprsDevice> Function() presence = () => RnsService.instance.xprsPresence();
  Map<String, dynamic>? Function(String call) heardHere =
      (c) => XprsMonitor.instance.stationJson(c);
  bool Function(String call) offersApi = (c) => RnsService.instance.offersApi(c);
  Map<String, dynamic>? Function(String call) announced =
      (c) => RnsService.instance.announcedVia(c);
  ({double lat, double lon})? Function() here = () {
    // Worked out here and sent nowhere, so the device's own fix serves; a
    // station placed by its administrator has only that value.
    final sp = XprsSharedPosition.instance;
    final at = sp.current();
    return sp.own() ?? (at == null ? null : _cell(at.pos));
  };

  List<(XprsDevice, XprsReach)>? _listed;
  int _listedMs = 0;

  static XprsReach _reachOf(XprsDevice d) {
    var best = XprsReach.global;
    for (final b in d.bearers) {
      final r = xprsBearerReach(b);
      if (r.index < best.index) best = r;
    }
    return best;
  }

  /// Metres between two positions (a sphere is plenty for "how far").
  static int _metres(({double lat, double lon}) a, ({double lat, double lon}) b) {
    const r = 6371000.0, k = math.pi / 180;
    final dLat = (b.lat - a.lat) * k, dLon = (b.lon - a.lon) * k;
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(a.lat * k) * math.cos(b.lat * k) * math.pow(math.sin(dLon / 2), 2);
    return (2 * r * math.asin(math.sqrt(h))).round();
  }

  /// The stations in [scope] (`local`, `regional`, `global` or `all`) whose
  /// callsign contains [search], nearest class first then by callsign, [pageMax]
  /// from [offset]: `{counts:{local,regional,global,all}, total, offset,
  /// rows:[{call, kind, reach, bearers, age_s, api, hops?, dist_m?}]}`.
  Map<String, dynamic> list({String scope = 'all', String search = '', int offset = 0}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var all = _listed;
    if (all == null || now - _listedMs > 2000) {
      all = [for (final d in presence()) (d, _reachOf(d))]
        // Nearest class, then what can be browsed, stations, people; by
        // callsign within each, so a row stays where it was while the list
        // is being read (newest-first reshuffled it at every packet).
        ..sort((a, b) {
          var c = a.$2.index.compareTo(b.$2.index);
          if (c != 0) return c;
          c = (browsable(b.$1.callsign) ? 1 : 0) - (browsable(a.$1.callsign) ? 1 : 0);
          if (c != 0) return c;
          if (a.$1.kind != b.$1.kind) {
            return (b.$1.kind == XprsKind.station ? 1 : 0) - (a.$1.kind == XprsKind.station ? 1 : 0);
          }
          return a.$1.callsign.compareTo(b.$1.callsign);
        });
      _listed = all;
      _listedMs = now;
    }
    final counts = {'local': 0, 'regional': 0, 'global': 0, 'all': all.length};
    for (final e in all) {
      counts[e.$2.name] = counts[e.$2.name]! + 1;
    }
    final q = search.trim().toUpperCase();
    final rows = [
      for (final e in all)
        if ((scope == 'all' || e.$2.name == scope) &&
            (q.isEmpty || e.$1.callsign.contains(q)))
          e,
    ];
    final from = offset < 0 ? 0 : offset;
    final me = here();
    return {
      'counts': counts,
      'scope': scope,
      'total': rows.length,
      'offset': from,
      'rows': [
        for (final e in rows.skip(from).take(pageMax))
          () {
            final d = e.$1;
            final h = heardHere(d.callsign);
            final at = me == null || h == null ? null : _cell('${h['pos'] ?? ''}');
            final a = announced(d.callsign);
            return {
              'call': d.callsign,
              'kind': d.kindWord,
              'reach': e.$2.name,
              'bearers': d.bearers,
              'age_s': (now - d.lastSeenMs) ~/ 1000,
              'api': browsable(d.callsign),
              if (a != null && a['hops'] is int) 'hops': a['hops'],
              if (at != null) 'dist_m': _metres(me!, at),
            };
          }(),
      ],
    };
  }

  static String _token(String ref) {
    if (ref.isEmpty) return '';
    return MediaRef.parse('file:$ref')?.token ?? '';
  }

  /// Forget what was read about [call] (the screen closed).
  void forget(String call) {
    final c = _bare(call);
    _entries.removeWhere((k, _) => k.startsWith('$c|'));
    StationVisits.instance.leave(c);
  }
}

/// Where a heard `pos:` is for a distance: the middle of its square when
/// digits are hidden (15.1), the point itself otherwise.
({double lat, double lon})? _cell(String pos) {
  final c = xprsPosCell(pos);
  return c == null ? null : (lat: c.lat, lon: c.lon);
}
