/*
 * xprs_names — Search's one question: who is there, by name?
 *
 * People, stations and groups, each known by a verified `t:identity`. The
 * table behind it is the archive's (XprsArchive.names), and what fills it is
 * not this device's ears alone: the identities its archivers hold arrive by
 * XprsCatchup's names pull (`cmd:history kind:identity`, XPRS.md 12.9.4: bulk
 * gossip is the history replay), so a group announced across the internet a
 * month ago is found by its name on a phone that never heard it.
 *
 * Asking is the caller's intent, deciding is the core's (core CLAUDE.md 3):
 * [find] with `ask` pokes the pull, which keeps its own floor, its one ask in
 * flight and every refusal; this file only bounds how often a screen can
 * poke it.
 */
library;

import 'xprs_archive.dart';
import 'xprs_catchup.dart';
import 'xprs_group_act.dart' show xprsGroupNickShown;
import 'xprs_presence.dart';

class XprsNames {
  XprsNames._();

  /// A Search box asks on every keystroke; the archivers are asked at most
  /// this often for it (the pull's own floor still applies after that).
  static const Duration askEvery = Duration(minutes: 1);
  static int _askedAtMs = 0;

  /// Test seam.
  static int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;
  static void Function() poke = () => XprsCatchup.instance.askNames();

  /// What a callsign is, for Search's tabs: `group` (`X5`), `user` (`X1`), or
  /// `station` (anything else that can be talked to: a mast, a vehicle, a
  /// device, a licensed callsign). Null for what is none of these.
  static String? tabOf(String call) {
    if (call.startsWith('X5')) return 'group';
    final k = xprsKindOf(call);
    return switch (k) {
      XprsKind.user => 'user',
      XprsKind.station || XprsKind.device => 'station',
      _ => null,
    };
  }

  /// Rows for [query] (a callsign or a name, any part, any case; empty lists
  /// the most recently announced), of [kind] (`group`, `user`, `station`, or
  /// empty for all), newest first, without [self]. Each row is
  /// `{call, nick, kind, ts}`, `ts` in epoch seconds: when that callsign last
  /// announced itself, as the archive holds it.
  static List<Map<String, Object>> find({
    String query = '',
    String kind = '',
    int limit = 60,
    String self = '',
    bool ask = false,
  }) {
    if (ask) {
      final now = nowMs();
      if (now - _askedAtMs >= askEvery.inMilliseconds) {
        _askedAtMs = now;
        poke();
      }
    }
    final n = limit.clamp(1, 200);
    final me = self.trim().toUpperCase().split('-').first;
    // A prefix narrows in the store; a station has none (X2, X3, X4, a
    // licence), so its page is read wider and narrowed here.
    final prefix = switch (kind) { 'group' => 'X5', 'user' => 'X1', _ => null };
    final rows = XprsArchive.instance.names(
        query: query, prefix: prefix, limit: prefix == null ? n * 3 : n + 1);
    final out = <Map<String, Object>>[];
    for (final r in rows) {
      if (r.call == me) continue;
      final tab = tabOf(r.call);
      if (tab == null || (kind.isNotEmpty && tab != kind)) continue;
      out.add({
        'call': r.call,
        'nick': tab == 'group' ? xprsGroupNickShown(r.nick) : r.nick,
        'kind': tab,
        'ts': r.tsMs ~/ 1000,
      });
      if (out.length >= n) break;
    }
    return out;
  }

  static void debugReset() {
    _askedAtMs = 0;
    nowMs = () => DateTime.now().millisecondsSinceEpoch;
    poke = () => XprsCatchup.instance.askNames();
  }
}
