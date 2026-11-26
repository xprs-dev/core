/*
 * xprs_archivers_known — the archivers this station knows of, from the cache
 * every station keeps (XPRS.md 13.0.5).
 *
 * Each archiver says what it offers on `t:service` (`serve:`, `count:`,
 * `room:`, `size:`) and what keeps it going on its own `t:observation`
 * (`source:`, `backup:`, `uplink:`, `plan:`, `uptime:`, `lifetime:`, `bw:`).
 * Every station keeps the newest of each per archiver (kXprsCoreFollowedKinds,
 * xprsIsArchiverObservation), and an answer to `cmd:history kind:service`
 * carries both, so this list is read from the archive, never asked of each
 * archiver in turn.
 *
 * [XprsKnownArchiver.from] and [xprsCompareArchivers] are pure, so the order a
 * station chooses in (13.0.4, 13.0.5) is tested without a store.
 */
library;

import 'xprs_archive.dart';
import 'xprs_archive_policy.dart';
import 'xprs_conditions.dart';
import 'xprs_packet.dart';
import 'xprs_vocab.dart';

/// An announcement older than this is stale (13.0.5: three missed hourly
/// announcements).
const Duration kXprsArchiverStaleAfter = Duration(hours: 3);

class XprsKnownArchiver {
  const XprsKnownArchiver({
    required this.callsign,
    required this.announcedMs,
    this.serve = const [],
    this.count,
    this.room = true,
    this.sizeBytes,
    this.source,
    this.backup,
    this.uplink,
    this.plan,
    this.uptime,
    this.lifetime,
    this.bwBytesPerS,
    this.stale = false,
  });

  final String callsign;

  /// The newest `ts:` of its two packets.
  final int announcedMs;
  final List<String> serve;
  final int? count;

  /// False only on `room:no` (13.0.2).
  final bool room;

  /// `size:`: free space it still offers (13.0.5).
  final int? sizeBytes;
  final String? source, backup, uplink, plan;
  final String? uptime, lifetime;

  /// `bw:` as bytes per second, measured by the archiver.
  final int? bwBytesPerS;
  final bool stale;

  /// Keeps running when the grid fails: a source other than the grid, or a
  /// backup other than none (13.0.4). Unknown is not a yes.
  bool get survivesOutage =>
      (source != null && source != 'grid') ||
      (backup != null && backup != 'none');

  /// 13.0.4's uplink order: satellite, then a wired or Wi-Fi line, then
  /// cellular; anything else or unstated last.
  int get uplinkRank => switch (uplink) {
        'satellite' => 3,
        'lan' || 'wifi' => 2,
        'cellular' => 1,
        _ => 0,
      };

  /// 13.0.4's order as one number for a choice that keeps its archiver:
  /// surviving an outage, then the uplink, then an unlimited plan. Free
  /// space and speed are left to [xprsCompareArchivers], for a person
  /// comparing; a station does not swap archivers over a gigabyte.
  int get rank =>
      (survivesOutage ? 100 : 0) + uplinkRank * 10 + (plan == 'unlimited' ? 1 : 0);

  /// The newest [service] and [observation] of one station, read together.
  /// Null when [service] does not claim `serve:archive`.
  static XprsKnownArchiver? from(XprsPacket service, XprsPacket? observation,
      {required int nowMs}) {
    if (service.type != 'service') return null;
    final serve = xprsServices(service);
    if (!serve.contains('archive')) return null;
    final call = (service['f'] ?? '').trim().toUpperCase();
    if (call.isEmpty) return null;
    final obs = observation != null &&
            (observation['f'] ?? '').trim().toUpperCase() == call &&
            xprsIsArchiverObservation(observation)
        ? observation
        : null;
    final sMs = xprsParseTs(service['ts']) ?? 0;
    final oMs = obs == null ? 0 : xprsParseTs(obs['ts']) ?? 0;
    final at = sMs > oMs ? sMs : oMs;
    String? o(String k) {
      final v = obs?[k]?.trim();
      return v == null || v.isEmpty ? null : v;
    }

    return XprsKnownArchiver(
      callsign: call,
      announcedMs: at,
      serve: serve,
      count: int.tryParse(service['count'] ?? ''),
      room: (service['room'] ?? obs?['room'] ?? '').trim() != 'no',
      sizeBytes: xprsParseBytes(service['size']),
      source: o('source'),
      backup: o('backup'),
      uplink: o('uplink'),
      plan: o('plan'),
      uptime: o('uptime'),
      lifetime: o('lifetime'),
      // Only a data rate: a radio's `bw:125kHz` is not an internet speed.
      bwBytesPerS: (o('bw') ?? '').endsWith('/s') ? xprsParseBytes(o('bw')) : null,
      stale: nowMs - at > kXprsArchiverStaleAfter.inMilliseconds,
    );
  }
}

/// The order a station chooses archivers in (13.0.4, 13.0.5), best first:
/// fresh before stale, room before `room:no`, then surviving an outage, the
/// uplink, an unlimited plan, free space, speed, and the newest announcement.
int xprsCompareArchivers(XprsKnownArchiver a, XprsKnownArchiver b) {
  int by<T extends Comparable<T>>(T x, T y) => y.compareTo(x);
  int flag(bool x, bool y) => x == y ? 0 : (x ? -1 : 1);
  final checks = [
    flag(!a.stale, !b.stale),
    flag(a.room, b.room),
    flag(a.survivesOutage, b.survivesOutage),
    by(a.uplinkRank, b.uplinkRank),
    flag(a.plan == 'unlimited', b.plan == 'unlimited'),
    by(a.sizeBytes ?? 0, b.sizeBytes ?? 0),
    by(a.bwBytesPerS ?? 0, b.bwBytesPerS ?? 0),
    by(a.announcedMs, b.announcedMs),
  ];
  for (final c in checks) {
    if (c != 0) return c;
  }
  return a.callsign.compareTo(b.callsign);
}

/// Every archiver in this station's cache, best first. [limit] bounds the
/// announcements read; each archiver costs one more indexed read for its
/// observation. Cheap enough for a page that opens, not for a hot path.
List<XprsKnownArchiver> xprsKnownArchivers({int? nowMs, int limit = 500}) {
  final archive = XprsArchive.instance;
  if (!archive.ready) return const [];
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final out = <XprsKnownArchiver>[];
  final seen = <String>{};
  for (final r in archive.query(types: const ['service'], limit: limit)) {
    final s = XprsPacket.parse(r['wire'] as String? ?? '');
    if (s == null) continue;
    final f = (s['f'] ?? '').trim().toUpperCase();
    if (f.isEmpty || !seen.add(f)) continue; // newest first: the first wins
    final o = archive.query(from: f, types: const ['observation'], limit: 1);
    final op = o.isEmpty ? null : XprsPacket.parse(o.first['wire'] as String);
    final k = XprsKnownArchiver.from(s, op, nowMs: now);
    if (k != null) out.add(k);
  }
  out.sort(xprsCompareArchivers);
  return out;
}
