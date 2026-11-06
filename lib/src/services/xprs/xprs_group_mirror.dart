/*
 * xprs_group_mirror — a shared hosted room, kept in step between stations
 * (XPRS.md 10.10.1, the paragraph on sharing; docs/plan-forum.md Phase 3).
 *
 * Two stations that hold one group's record ask each other, on their own
 * watermarks, for what the other filed since:
 *
 *   t:command f:<us> d:<peer> ts:<now> cmd:history only:<X5> kind:blog,message,reaction,moderate,identity since:<mark>
 *
 * That is section 12.9.3's standing neighbour ask narrowed to one group
 * (12.10.1's per-peer watermark, 11.2's `only:`). The answer re-airs
 * ORIGINALS, each verifying on its author's key or the group's, entering
 * this station through the one receive door and its own admission; nothing
 * is imported on the peer's authority and the stores are never compared.
 * A page is twelve records; `206` is continued before the oldest record it
 * brought (11.2.1), `200` or `404` closes the window and the mark moves to
 * the ask's own ts; `429` is the peer's authority over our cadence.
 *
 * The group's key comes first: until this station holds the `X5`'s
 * `t:identity` nothing signed by the group verifies, so a room whose key is
 * not yet known is asked for its identity alone, and the mark does not move
 * until the record can be read.
 *
 * Every send and clock is injected, so the exchange runs in a unit test.
 * The pairs to keep in step come from the host (the web chat API's rooms:
 * a mirrored room and its owner; a shared room and the peers it lists or
 * has seen asking). Cadence: a minute after news, doubling to ten minutes
 * while quiet (performance.md section 8: never a sub-minute poll).
 */
library;

import 'dart:async';

import '../../platform/key_value_store.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';
import 'xprs_vocab.dart' show xprsParseTs, xprsNowTs;

/// One group kept in step with one peer station.
class MirrorPair {
  const MirrorPair({required this.group, required this.peer});
  final String group;
  final String peer;
  String get key => '$peer|$group';
}

class _State {
  String? askId;
  int askedAtMs = 0;

  /// The ts of the ask that opened the current window: the mark it moves to.
  int windowTsMs = 0;
  int? untilMs;
  int? oldestMs;
  int rowsThisAsk = 0;
  int rowsWindow = 0;
  int pages = 0;
  int intervalMs = XprsGroupMirror.interval.inMilliseconds;
  int nextAtMs = 0;
  bool identityOnly = false;
}

class XprsGroupMirror {
  XprsGroupMirror._();
  static final XprsGroupMirror instance = XprsGroupMirror._();

  static const Duration interval = Duration(minutes: 1);
  static const Duration quietCeiling = Duration(minutes: 10);
  static const Duration refusedFor = Duration(minutes: 10);
  static const Duration askGrace = Duration(seconds: 40);
  static const Duration firstWindow = Duration(days: 30);
  static const Duration identityWindow = Duration(days: 400);
  static const int maxPagesPerTick = 10;
  static const String kinds = 'blog,message,reaction,moderate,identity';
  static const String _markPrefix = 'mirror.mark.';

  // ── seams ──────────────────────────────────────────────────────────────
  Future<void> Function(String wire)? send;
  String Function()? selfCallsign;
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;
  KeyValueStore? store;
  List<MirrorPair> Function() pairs = () => const [];
  bool Function(String group)? haveKey;

  final Map<String, _State> _state = {};
  final Map<String, String> _pending = {}; // ask id -> pair key
  Set<String> _groups = {};

  int asks = 0, pagesIn = 0, rows = 0, refused = 0, closed = 0, keyAsks = 0;

  /// How often one callsign's key is asked for, at most.
  static const Duration keyAskEvery = Duration(minutes: 10);
  final Map<String, int> _keyAskedMs = {};

  /// A group act was parked for want of its signer's key
  /// (XprsGroups.onUnknownSigner): a moderator's acceptance or removal
  /// replayed by a peer whose visitors this station never heard. Ask every
  /// peer this station keeps a room in step with for that callsign's
  /// identity (12.6's `only:` on `kind:identity`), once per callsign per
  /// [keyAskEvery]; the answer enters through the receive door and the
  /// record offers the parked acts again (XprsGroups.keyLearned).
  void unknownSigner(String signer) {
    final call = _base(signer);
    if (call.isEmpty || _self.isEmpty || call == _self) return;
    final now = nowMs();
    if (now - (_keyAskedMs[call] ?? 0) < keyAskEvery.inMilliseconds) return;
    _keyAskedMs[call] = now;
    if (_keyAskedMs.length > 64) _keyAskedMs.remove(_keyAskedMs.keys.first);
    final peers = {for (final p in pairs()) p.peer};
    final out = send ?? ((w) => XprsPublisher.instance.publishWire(w));
    for (final peer in peers) {
      keyAsks++;
      unawaited(out('t:command f:$_self d:$peer ts:${xprsNowTs(now)} '
          'cmd:history only:$call kind:identity '
          'since:${xprsNowTs(now - identityWindow.inMilliseconds)}'));
    }
  }

  String get _self => _base(selfCallsign?.call() ?? '');

  /// Every heard packet: is it a mirrored group's? The funnel's admission
  /// keeps such a row on the followed shelf (XprsIngest.askedFor), because
  /// this station asked for it: what you asked for, you keep.
  bool askedFor(XprsPacket p) {
    if (_groups.isEmpty) return false;
    return _groups.contains(_base(p['d'] ?? '')) ||
        _groups.contains(_base(p['f'] ?? ''));
  }

  /// Ask every pair that is due. Called once a minute by the host.
  Future<void> tick() async {
    final list = pairs();
    _groups = {for (final p in list) p.group};
    final keys = {for (final p in list) p.key};
    _state.removeWhere((k, _) => !keys.contains(k));
    if (_self.isEmpty) return;
    final now = nowMs();
    for (final pair in list) {
      final s = _state.putIfAbsent(pair.key, _State.new);
      if (s.askId != null) {
        if (now - s.askedAtMs < askGrace.inMilliseconds) continue;
        _pending.remove(s.askId); // outlived its grace: the peer is away
        s.askId = null;
      }
      if (now < s.nextAtMs) continue;
      s.pages = 0;
      await _ask(pair, s, now, continuation: s.untilMs != null);
    }
  }

  /// Ask [group]'s pairs now, whatever the cadence says (the administrator
  /// pressed Sync, or just mirrored it).
  void poke(String group) {
    final g = _base(group);
    for (final e in _state.entries) {
      if (e.key.endsWith('|$g')) e.value.nextAtMs = 0;
    }
    unawaited(tick());
  }

  Future<void> _ask(MirrorPair pair, _State s, int now,
      {required bool continuation}) async {
    final known = haveKey?.call(pair.group) ?? true;
    s.identityOnly = !known;
    if (!continuation) {
      s.windowTsMs = now;
      s.rowsWindow = 0;
      s.untilMs = null;
      s.oldestMs = null;
    }
    final since = known
        ? _mark(pair) ?? now - firstWindow.inMilliseconds
        : now - identityWindow.inMilliseconds;
    final wire = StringBuffer('t:command f:$_self d:${pair.peer} '
        'ts:${xprsNowTs(now)} cmd:history only:${pair.group} '
        'kind:${known ? kinds : 'identity'} since:${xprsNowTs(since)}');
    if (s.untilMs != null) wire.write(' until:${xprsNowTs(s.untilMs!)}');
    final p = XprsPacket.parse(wire.toString());
    if (p == null || !p.fits) return;
    final id = xprsIdentifier(p);
    s
      ..askId = id
      ..askedAtMs = now
      ..rowsThisAsk = 0
      ..nextAtMs = now + s.intervalMs;
    _pending[id] = pair.key;
    asks++;
    final out = send ?? ((w) => XprsPublisher.instance.publishWire(w));
    await out(wire.toString());
  }

  /// A heard `t:result`: ours when `r:` names an ask of ours.
  void onResult(XprsPacket p) {
    final key = _pending[p['r'] ?? ''];
    if (key == null) return;
    final s = _state[key];
    if (s == null) {
      _pending.remove(p['r']);
      return;
    }
    final code = int.tryParse(p['code'] ?? '') ?? 0;
    if (code == 202) return; // the page follows
    _pending.remove(p['r']);
    s.askId = null;
    final pair = _pairOf(key);
    final now = nowMs();
    switch (code) {
      case 429:
        refused++;
        s.nextAtMs = now + refusedFor.inMilliseconds;
        return;
      case 206:
        pagesIn++;
        final oldest = s.oldestMs;
        final next = oldest == null ? null : (oldest ~/ 1000) * 1000 + 1000;
        if (s.rowsThisAsk > 0 && next != null && (s.untilMs == null || next < s.untilMs!)) {
          s.untilMs = next;
          if (++s.pages < maxPagesPerTick) {
            unawaited(_ask(pair, s, now, continuation: true));
          } else {
            s.nextAtMs = now; // the rest next tick, cursor kept
          }
          return;
        }
        _close(pair, s, now, news: s.rowsWindow > 0);
        return;
      case 200:
      case 404:
        if (code == 200) pagesIn++;
        _close(pair, s, now, news: s.rowsWindow > 0);
        return;
      default:
        return;
    }
  }

  void _close(MirrorPair pair, _State s, int now, {required bool news}) {
    closed++;
    s.untilMs = null;
    s.oldestMs = null;
    // The mark moves only when the record could be read (the key is held);
    // until it is, the room is asked again at the base cadence.
    if (!s.identityOnly) _setMark(pair, s.windowTsMs);
    s.intervalMs = news || s.identityOnly
        ? interval.inMilliseconds
        : (s.intervalMs * 2).clamp(interval.inMilliseconds, quietCeiling.inMilliseconds);
    s.nextAtMs = now + s.intervalMs;
  }

  /// Every packet off every lane while an ask is out: the page's rows and
  /// the cursor a continuation moves to (11.2.1).
  void noteHeard(XprsPacket p) {
    if (_pending.isEmpty) return;
    final from = _base(p['f'] ?? ''), to = _base(p['d'] ?? '');
    final now = nowMs();
    for (final key in _pending.values) {
      final s = _state[key];
      if (s == null || now - s.askedAtMs > askGrace.inMilliseconds) continue;
      final group = key.split('|').last;
      if (from != group && to != group) continue;
      s.rowsThisAsk++;
      s.rowsWindow++;
      rows++;
      final ts = xprsParseTs(p['ts']);
      if (ts != null && (s.oldestMs == null || ts < s.oldestMs!)) s.oldestMs = ts;
    }
  }

  MirrorPair _pairOf(String key) {
    final i = key.indexOf('|');
    return MirrorPair(peer: key.substring(0, i), group: key.substring(i + 1));
  }

  int? _mark(MirrorPair pair) {
    final v = store?.getString('$_markPrefix${pair.key}');
    return v == null ? null : int.tryParse(v);
  }

  void _setMark(MirrorPair pair, int ms) {
    unawaited(store?.setString('$_markPrefix${pair.key}', '$ms') ?? Future.value());
  }

  /// For a status page: each pair, its mark and its cadence.
  List<Map<String, dynamic>> statusJson() => [
        for (final e in _state.entries)
          {
            'peer': _pairOf(e.key).peer,
            'group': _pairOf(e.key).group,
            'mark': _mark(_pairOf(e.key)),
            'interval_s': e.value.intervalMs ~/ 1000,
            'asking': e.value.askId != null,
          }
      ];

  void clear() {
    _state.clear();
    _pending.clear();
    _groups = {};
    _keyAskedMs.clear();
    asks = pagesIn = rows = refused = closed = keyAsks = 0;
  }

  static String _base(String c) => c.trim().toUpperCase().split('-').first;
}
