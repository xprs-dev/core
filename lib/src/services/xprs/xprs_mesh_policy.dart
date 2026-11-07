/*
 * xprs_mesh_policy — what a station keeps from afar, and from whom
 * (docs/plan-mesh-trust.md; XPRS.md 9.11, 12, 12.9.3, 13.3).
 *
 * Chat is digipeated and forgotten; an alert or a post is kept and read
 * later (18, 24, 10.10.2), so what arrives over the internet or from a rogue
 * relay in LoRa range stays on the noticeboard. The administrator decides,
 * per station, three things, and each is one rule here:
 *
 *   reach    how far away a kind may come from and still be kept: the
 *            bearer class (9.11) a kind is accepted from, `regional` for
 *            alerts and posts, `global` for chat, unless set otherwise;
 *   followed whose words are kept from anywhere (the followed tier of 12:
 *            the operator consented);
 *   peers    in `named` mode, an alert or a post heard on the air is kept
 *            only when its author or a station in its `via:` is a trusted
 *            peer, so a stranger's station cannot join the mesh of record by
 *            proximity alone.
 *
 * The verdict is one pure function of the packet, the bearer it arrived on
 * and an immutable snapshot of the settings, as the archive policy is, so it
 * is tested without a radio and reads no preference store on the receive
 * path (performance.md 4.2). Three callers ask it: the receive funnel (keep
 * or not), the digipeater (relay or not) and the history server (serve or
 * not). A packet that answered this station's own ask (`askedFor`) is
 * always kept: the ask went to a station we named.
 *
 * What the rule never touches: a packet addressed to somebody (12.7's
 * business, delivered whatever), a call for help (10.7), a group act or an
 * identity (the record of a room), and this station's own words.
 */
library;

import 'xprs_packet.dart';
import 'xprs_vocab.dart';

enum XprsMeshVerdict { keep, drop }

class XprsMeshPolicy {
  const XprsMeshPolicy({
    this.reachAlerts = XprsReach.regional,
    this.reachPosts = XprsReach.regional,
    this.reachChat = XprsReach.global,
    this.followed = const {},
    this.named = false,
    this.peers = const {},
  });

  final XprsReach reachAlerts;
  final XprsReach reachPosts;
  final XprsReach reachChat;

  /// Base callsigns whose words are kept from anywhere.
  final Set<String> followed;

  /// `peers_mode: named`: the mesh of record is [peers] and nobody else.
  final bool named;

  /// Base callsigns of the stations this one exchanges records with.
  final Set<String> peers;

  static const kinds = {'local', 'regional', 'global'};

  static XprsReach parseReach(Object? v, XprsReach fallback) =>
      switch ('$v') {
        'local' => XprsReach.local,
        'regional' => XprsReach.regional,
        'global' => XprsReach.global,
        _ => fallback,
      };

  /// The snapshot from the administrator's settings (API-HTTP.md,
  /// `reach_alerts`, `reach_posts`, `reach_chat`, `peers_mode`, `peers`,
  /// `follow`). [followed] is given resolved: an `npub` in `follow` is the
  /// host's to turn into a callsign.
  factory XprsMeshPolicy.fromSettings(Map<String, Object?> s,
      {Set<String> followed = const {}}) {
    return XprsMeshPolicy(
      reachAlerts: parseReach(s['reach_alerts'], XprsReach.regional),
      reachPosts: parseReach(s['reach_posts'], XprsReach.regional),
      reachChat: parseReach(s['reach_chat'], XprsReach.global),
      followed: {for (final c in followed) _base(c)},
      named: '${s['peers_mode']}' == 'named',
      peers: {for (final c in xprsCallsignList(s['peers'])) _base(c)},
    );
  }

  static String _base(String c) => c.trim().toUpperCase().split('-').first;
}

/// The callsigns in a setting written as a space-separated list.
List<String> xprsCallsignList(Object? v) => [
      for (final t in '${v ?? ''}'.toUpperCase().split(RegExp(r'[\s,]+')))
        if (t.isNotEmpty) t
    ];

/// Which kind of community record [p] is, or null when the rule does not
/// apply to it: addressed to somebody, a call for help, a group's record.
String? xprsMeshKind(XprsPacket p) {
  final d = (p['d'] ?? '').trim();
  if (d.isNotEmpty) return null; // somebody's mail, or a room's (10.10.1)
  switch (p.type) {
    case 'warning':
    case 'info':
      return 'alerts';
    case 'blog':
      return 'posts';
    case 'message':
    case 'status':
    case 'reaction':
      return 'chat';
    default:
      return null;
  }
}

XprsMeshVerdict xprsMeshAdmits(
  XprsPacket p, {
  required String bearer,
  required XprsMeshPolicy policy,
  required String self,
  bool askedFor = false,
}) {
  final kind = xprsMeshKind(p);
  if (kind == null) return XprsMeshVerdict.keep;
  final from = XprsMeshPolicy._base(p['f'] ?? '');
  final me = XprsMeshPolicy._base(self);
  if (from.isEmpty || from == me) return XprsMeshVerdict.keep;
  if (askedFor || policy.followed.contains(from)) return XprsMeshVerdict.keep;
  final cap = switch (kind) {
    'alerts' => policy.reachAlerts,
    'posts' => policy.reachPosts,
    _ => policy.reachChat,
  };
  if (!xprsReachAdmits(cap, xprsBearerReach(bearer))) return XprsMeshVerdict.drop;
  // Named mode governs what comes from other stations, on the radio or the
  // internet; a visitor on this station's own network (its page, its LAN)
  // is this station's own community.
  if (policy.named && kind != 'chat' && xprsBearerReach(bearer) != XprsReach.local) {
    if (policy.peers.contains(from)) return XprsMeshVerdict.keep;
    for (final v in (p['via'] ?? '').split(',')) {
      if (policy.peers.contains(XprsMeshPolicy._base(v))) return XprsMeshVerdict.keep;
    }
    return XprsMeshVerdict.drop;
  }
  return XprsMeshVerdict.keep;
}
