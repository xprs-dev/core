/*
 * xprs_group_deposit — a group's record, handed to this station's archivers
 * (XPRS.md 10.9.2: "any member may hand a group's packets to an archiver ...
 * addressed, never broadcast ... metered").
 *
 * Why it exists (2026-11-22): over Reticulum a group's acts are addressed to
 * its members and to nobody else, so the archiver that keeps a group for
 * everybody else learned its record only when it happened to overhear the
 * radio copy of an act. A group made at home reached the archiver with one
 * of its folders and without the others; a link to it then showed a group
 * with one folder.
 *
 * Two halves:
 *   - what a station publishes to a group from now on goes to its archivers
 *     as it goes to the members (XprsPublisher, the Reticulum lane);
 *   - the record made before, and whatever was lost on the way, is handed
 *     over again here: the group's identity rows and its acts, for the
 *     groups this station administers or moderates, one group and one
 *     archiver a turn, each pair at most once in [every].
 *
 * The packets are originals, signed by the group or by their authors: the
 * archiver trusts the depositor for nothing. Every seam is injected, so the
 * schedule runs in a unit test. Driven from the core's minute sweep; never a
 * timer of its own (performance.md section 8).
 */
library;

import '../../platform/key_value_store.dart';
import '../log_service.dart';

class XprsGroupDeposit {
  XprsGroupDeposit._();
  static final XprsGroupDeposit instance = XprsGroupDeposit._();

  /// A group and an archiver are brought up to date at most this often.
  static const Duration every = Duration(days: 7);

  /// The first deposit waits this long after start: the lanes are up by
  /// then and the archivers have announced.
  static const Duration settle = Duration(minutes: 3);

  /// How many archivers one station deposits with.
  static const int maxArchivers = 3;

  /// The groups whose record this station is in a position to vouch for
  /// being complete: the ones it administers or moderates.
  List<String> Function()? groups;

  /// Whether this station is in a position to vouch for [group]'s record,
  /// asked only of a group that is due somewhere. Left out, every group
  /// [groups] names counts. Separate from [groups] because the answer may
  /// cost a roster replay (a signature check per act): asked of every
  /// known group in one go it was 1.5 s of the one isolate three minutes
  /// after start (C61, 2026-11-23).
  bool Function(String group)? vouches;

  /// A group whose record must be handed over again now, whatever the
  /// week says (its identity changed). Asked once per group per start.
  bool Function(String group)? stale;
  final Set<String> _staleAsked = {};

  /// This station's archivers, in preference order.
  List<String> Function()? archivers;

  /// The record of [group] as this station holds it: the wires of its
  /// identity rows and of its acts, oldest first.
  List<String> Function(String group)? record;

  /// One wire, addressed to station [call]. False when it cannot be named
  /// now (no destination known for it).
  Future<bool> Function(String call, String wire)? send;

  KeyValueStore? store;
  int Function() now = () => DateTime.now().millisecondsSinceEpoch;

  /// Deposits made, and packets handed over, since start.
  int deposits = 0;
  int packets = 0;

  int? _startedMs;
  bool _busy = false;

  /// How long the groups are left alone after a look that found nothing due.
  static const Duration idleLook = Duration(hours: 1);
  int _nextLookMs = 0;

  /// Never handed over, or made due again by a new act: 0.
  static bool _fresh(int last, int t) =>
      last > 0 && t - last < every.inMilliseconds;

  static String _key(String group, String archiver) =>
      // `2`: the first version read the acts from the archive alone, which
      // may have let them go, and marked such a group as handed over.
      'xprs.groupDeposit2.$archiver.$group';

  /// The archivers a group's traffic is also addressed to.
  List<String> targets() => [
        for (final a in (archivers?.call() ?? const <String>[]))
          if (a.trim().isNotEmpty) a.trim().toUpperCase(),
      ].take(maxArchivers).toList();

  /// One turn: the first group and archiver that are due, if any. Returns
  /// how many packets were handed over.
  Future<int> tick() async {
    final st = store, rec = record, out = send;
    if (_busy || st == null || rec == null || out == null) return 0;
    final t = now();
    _startedMs ??= t;
    if (t - _startedMs! < settle.inMilliseconds) return 0;
    // Nothing was due on the last full look: the answer cannot change until
    // a record is a week old or an act is made ([changed]), so the groups
    // are not walked again every minute for the life of the process
    // (performance.md 8.7: a question re-asked after the answer stopped
    // changing). An hour, because an archiver that could not be named may
    // have announced itself since.
    if (t < _nextLookMs) return 0;
    final to = targets();
    if (to.isEmpty) {
      _nextLookMs = t + idleLook.inMilliseconds;
      return 0;
    }
    _busy = true;
    try {
      final turn = Stopwatch()..start();
      for (final g in groups?.call() ?? const <String>[]) {
        // The cheap test first (performance.md 8.26): a key read per
        // archiver, in memory.
        // Asked again on later looks until it has been handed over: the
        // address it waits for may not be known at the first one.
        final again = !_staleAsked.contains(g) && (stale?.call(g) ?? false);
        if (again) _staleAsked.add(g);
        final due = [
          for (final a in to)
            if (again || !_fresh(st.getInt(_key(g, a)) ?? 0, t)) a,
        ];
        if (due.isEmpty) continue;
        // The event loop gets a turn between groups that cost something.
        if (turn.elapsedMilliseconds >= 8) {
          await Future<void>.delayed(Duration.zero);
          turn.reset();
        }
        if (!(vouches?.call(g) ?? true)) continue;
        // One group a turn, to every archiver it is due at: a person with
        // thirty groups and three archivers is done in half an hour, not in
        // an hour and a half.
        List<String>? wires;
        var total = 0;
        for (final a in due) {
          wires ??= rec(g);
          if (wires.isEmpty) break;
          var sent = 0;
          for (final w in wires) {
            if (await out(a, w)) sent++;
          }
          // An archiver that could not be named now is asked again on a
          // later turn; one that took the record is left alone for [every].
          if (sent == 0) continue;
          await st.setInt(_key(g, a), t);
          deposits++;
          packets += sent;
          total += sent;
          LogService.instance.add(
              'XPRS: record of $g handed to archiver $a ($sent packet(s), 10.9.2)');
        }
        if (total > 0) return total;
      }
      _nextLookMs = t + idleLook.inMilliseconds;
      return 0;
    } finally {
      _busy = false;
    }
  }

  /// [group] has a new act: its record is due again, so an archiver that
  /// missed the act itself is brought up to date on a following turn.
  void changed(String group) {
    final st = store;
    if (st == null) return;
    _nextLookMs = 0;
    for (final a in targets()) {
      st.setInt(_key(group.trim().toUpperCase(), a), 0);
    }
  }

  void debugReset() {
    groups = null;
    vouches = null;
    stale = null;
    _staleAsked.clear();
    archivers = null;
    record = null;
    send = null;
    store = null;
    now = () => DateTime.now().millisecondsSinceEpoch;
    deposits = 0;
    packets = 0;
    _startedMs = null;
    _busy = false;
    _nextLookMs = 0;
  }
}
