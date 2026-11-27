// What one archiver hands the others as it arrives (XPRS.md 12.9.8).
//
// Public traffic crosses the internet because archivers hold it and others
// ask them (12.12.2): a pull, at the catch-up's pace, which between two
// always-on archivers is ten minutes. So a person at one archiver read what
// was said in the Global room at another up to ten minutes late, did not
// know for as long where somebody's mailbox is, and a moderator's removal
// (10.10.3) stood at one archiver and not at the next.
//
// So an always-on public archiver that takes such a packet FIRST-HAND (from
// its own visitor, its own radio, or a station that deposits with it) hands
// a copy to the other always-on archivers it knows, at once. The pull stays
// as the repair for whatever a push missed.
//
// What goes: publications (no `d:`) whose scope reaches the whole network,
// of the kinds a conversation and its upkeep are made of. Regional and
// Local talk never does: it belongs to the archiver it was said at (9.11).
// Mail never does either; it has its own custody (12.7).
//
// It cannot loop and it cannot flood. Archivers do not all know each other
// (a hub passes few of its clients' announces), so a hand-on is passed
// along: but each archiver hands a packet on ONCE (by its identifier),
// never to a station already in its `via:`, never past the hop budget every
// relay keeps (9.1), only while the packet is fresh (a replayed month of
// history is not news), and only a packet whose signature it checked.
//
// The class decides and counts; who the peers are and how a wire reaches
// one are injected (MeshService), so it runs in a test as in a station.
import 'dart:async';
import 'dart:collection';

import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_vocab.dart';

class XprsArchiverPush {
  XprsArchiverPush._();
  static final XprsArchiverPush instance = XprsArchiverPush._();

  /// The kinds handed on: the room's talk and reactions, a moderator's act
  /// (10.10.3), who chose which mailbox (12.9.5), and which files a station
  /// says it holds (12.9.2).
  static const Set<String> kinds = {
    'message', 'reaction', 'moderate', 'mailbox', 'file', 'identity',
  };

  /// A key binding (`t:identity`) is what lets the next archiver check
  /// everything else its author says, so it goes too; but a station airs
  /// one every few minutes, so one per author per this long.
  static const int identityEveryMs = 60 * 60 * 1000;

  /// At most this many peers per packet.
  static const int maxPeers = 16;

  /// A packet older than this is history, and history is asked for.
  static const int freshMs = 10 * 60 * 1000;
  static const int _remembered = 2048;

  /// True when this station is an always-on public archiver now.
  bool Function()? enabled;

  /// The other always-on archivers this station knows, best first.
  List<String> Function()? peers;

  /// This station's callsign, base form.
  String Function()? self;

  /// Hand [wire] to the station [call] on a directed lane.
  Future<bool> Function(String call, String wire)? sendTo;

  /// True when [p]'s signature verifies under its author's key.
  bool Function(XprsPacket p)? verified;

  int handed = 0, packets = 0;

  /// Why a packet that was this station's to hand on was not: the station
  /// is not an always-on public archiver, the signature did not verify, or
  /// no other archiver is known.
  int notArchiver = 0, unverified = 0, noPeer = 0;
  final LinkedHashSet<String> _done = LinkedHashSet<String>();
  final Map<String, int> _identityAt = <String, int>{};

  /// The stations that handed this one something, oldest first.
  final LinkedHashSet<String> _handers = LinkedHashSet<String>();
  List<String> get handers => _handers.toList();

  /// Is [p], arrived on [bearer], something to hand on? Says nothing about
  /// the signature (the costly part), and remembers nothing.
  static bool wants(XprsPacket p, {required String bearer, required int nowMs}) {
    if (!kinds.contains(p.type)) return false;
    if ((p['d'] ?? '').trim().isNotEmpty) return false;
    if (!p.has('sig')) return false;
    // A piece of a file (7.7.6) is bytes, not a statement about a file.
    if (p.type == 'file' && (p.has('off') || p.has('b'))) return false;
    if (!xprsReachAdmits(xprsScopeReach(p), XprsReach.global)) return false;
    // The hop budget every relay keeps (9.1): a hand-on that has crossed
    // its hops stops here.
    if (!xprsMayRelay(p)) return false;
    final ts = xprsParseTs(p['ts']);
    if (ts == null || (nowMs - ts).abs() > freshMs) return false;
    return true;
  }

  /// Feed one packet the funnel accepted. Returns how many peers it was
  /// handed to (0 for everything that is not this station's to hand on).
  int offer(XprsPacket p, {required String bearer, int? nowMs}) {
    final send = sendTo;
    if (send == null) return 0;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (!wants(p, bearer: bearer, nowMs: now)) return 0;
    if (!(enabled?.call() ?? false)) {
      notArchiver++;
      return 0;
    }
    final me = (self?.call() ?? '').trim().toUpperCase();
    final hops = [for (final h in xprsVia(p)) h.trim().toUpperCase()];
    // Whoever handed it to us hands on: it is an archiver like this one,
    // and is handed to before the stations only known by an announce.
    if (bearer == 'rns' && hops.isNotEmpty && hops.last != me) {
      _handers
        ..remove(hops.last)
        ..add(hops.last);
      if (_handers.length > 64) _handers.remove(_handers.first);
    }
    if (hops.contains(me)) return 0; // it has been through here
    final id = xprsIdentifier(p);
    if (_done.contains(id)) return 0;
    if (!(verified?.call(p) ?? false)) {
      unverified++;
      return 0;
    }
    if (p.type == 'identity') {
      final who = (p['f'] ?? '').split('-').first.trim().toUpperCase();
      final last = _identityAt[who];
      if (last != null && now - last < identityEveryMs) return 0;
      if (_identityAt.length >= _remembered) {
        _identityAt.remove(_identityAt.keys.first);
      }
      _identityAt[who] = now;
    }
    if (_done.length >= _remembered) _done.remove(_done.first);
    _done.add(id);
    final from = (p['f'] ?? '').split('-').first.trim().toUpperCase();
    final wire = _withVia(p, me);
    if (wire == null) return 0;
    var n = 0;
    final seen = <String>{};
    for (final call in [
      ..._handers.toList().reversed,
      ...peers?.call() ?? const <String>[],
    ]) {
      final c = call.trim().toUpperCase();
      if (c.isEmpty || c == me || c == from || hops.contains(c)) continue;
      if (!seen.add(c)) continue;
      if (n >= maxPeers) break;
      n++;
      unawaited(send(c, wire).catchError((_) => false));
    }
    if (n > 0) {
      packets++;
      handed += n;
    } else {
      noPeer++;
    }
    return n;
  }

  /// [p] as it leaves here: the same signed bytes with this station added to
  /// `via:` (4.9: outside the signature and the identifier). Null when it
  /// no longer fits one packet.
  static String? _withVia(XprsPacket p, String me) {
    if (me.isEmpty || xprsVia(p).any((c) => c.trim().toUpperCase() == me)) {
      return p.encode();
    }
    final carried = xprsAppendVia(p, me);
    // A packet with no room left for the name goes as it is: the peers
    // then take it for first-hand and each hands it on once more, which
    // the identifier collapses.
    return carried.fits ? carried.encode() : p.encode();
  }

  Map<String, dynamic> get json => {
        'packets': packets,
        'handed': handed,
        'notArchiver': notArchiver,
        'unverified': unverified,
        'noPeer': noPeer,
        'handers': _handers.length,
      };

  /// For tests.
  void reset() {
    _done.clear();
    _identityAt.clear();
    _handers.clear();
    handed = packets = notArchiver = unverified = noPeer = 0;
  }
}
