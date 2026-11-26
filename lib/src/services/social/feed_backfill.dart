/*
 * FeedBackfill — recovers posts a device missed, by asking Reticulum peers
 * for NOSTR notes (kind 1) of a topic since the last sweep.
 *
 * Two kinds of topic:
 *  - `activity`, the Activity feed: notes go straight into the wapp's
 *    [ActivityArchive], deduplicated on content, like [NomadnetPoller].
 *  - each group the person has open (`#NAME`): notes are handed to
 *    [onGroupNotes], since a conversation is the host's view to merge into.
 *
 * When to fetch is decided here, not by the screen that shows the result
 * (architecture.md §3.1): every [cadence], and, until the first sweep that
 * returns anything, whenever an uplink comes up or a new relay peer is heard
 * (a device that just joined usually starts before either). No sub-minute
 * timer: those two events are what used to be polled for every 15 seconds.
 */
import 'dart:async';

import 'package:reticulum/reticulum.dart' show NostrCrypto;

import '../log_service.dart';
import '../reticulum/rns_service.dart';
import '../storage/activity_archive.dart';

/// One recovered note, read: who wrote it (as a callsign), what, and when.
class BackfillNote {
  const BackfillNote({
    required this.from,
    required this.text,
    required this.mid,
    required this.tsSec,
    this.parent = '',
    this.meta = '',
  });

  /// `X1` + the callsign derived from the author's key.
  final String from;
  final String text;

  /// [activityMid] of [from] and [text].
  final String mid;
  final int tsSec;
  final String parent;

  /// NIP-92 media metadata (poster, blurhash, size) for a feed card.
  final String meta;

  /// The note as a chat row, the shape both the Activity archive and a
  /// conversation keep (`via: RET`, Reticulum over the internet).
  Map<String, dynamic> toRow() {
    final dt = DateTime.fromMillisecondsSinceEpoch(tsSec * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return {
      'dir': 'in',
      'from': from,
      'text': text,
      'time': '${two(dt.hour)}:${two(dt.minute)}',
      'via': 'RET',
      'mid': mid,
      'parent': parent,
      't': tsSec * 1000,
    };
  }

  /// Reads one note of [RnsService.fetchFeedBackfill]; null for an empty one,
  /// one of our own ([selfPub]), or a key no callsign can be derived from.
  static BackfillNote? read(Map<String, dynamic> n,
      {String? selfPub, required int nowSec}) {
    final pub = (n['pub'] ?? '').toString();
    final text = (n['text'] ?? '').toString();
    if (pub.isEmpty || text.isEmpty) return null;
    if (selfPub != null && pub.toLowerCase() == selfPub.toLowerCase()) {
      return null; // our own posts were never missed
    }
    final String from;
    try {
      from = 'X1${NostrCrypto.deriveCallsign(pub)}';
    } catch (_) {
      return null;
    }
    return BackfillNote(
      from: from,
      text: text,
      mid: activityMid(from, text),
      tsSec: (n['ts'] as int?) ?? nowSec,
      parent: (n['parent'] ?? '').toString(),
      meta: (n['meta'] ?? '').toString(),
    );
  }
}

class FeedBackfill {
  FeedBackfill({
    required this.archive,
    required this.groupTopics,
    required this.onGroupNotes,
    required this.onChanged,
  });

  /// The Activity archive to fill, or null when this wapp has none (now).
  final ActivityArchive? Function() archive;

  /// The group topics (`NAME` of `#NAME` / `#NAME*`) the person has open.
  final Set<String> Function() groupTopics;

  /// Notes recovered for one group, oldest first.
  final void Function(String topic, List<BackfillNote> notes) onGroupNotes;

  /// The Activity archive gained posts.
  final void Function() onChanged;

  static const Duration cadence = Duration(minutes: 3);

  /// How far back a first sweep reaches.
  static const Duration window = Duration(days: 7);

  Timer? _timer;
  final List<StreamSubscription<void>> _subs = [];
  bool _busy = false;
  bool _again = false;
  bool _disposed = false;

  /// The newest sweep that returned Activity notes (seconds); 0 until one has.
  int _lastSec = 0;

  /// A sweep has returned something: the early triggers are no longer needed.
  bool _pulled = false;

  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(cadence, (_) => unawaited(sweep()));
    final rns = RnsService.instance;
    for (final s in [rns.uplinkUps, rns.relayPeerFound]) {
      _subs.add(s.listen((_) {
        if (!_pulled) unawaited(sweep());
      }));
    }
    unawaited(sweep());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
  }

  /// One sweep of the Activity feed and every open group. Never two at once
  /// (each asks several peers); a trigger during a sweep runs one more after.
  /// Returns the notes peers answered with, new or not: any answer means a
  /// peer is reachable, which ends the early triggers.
  Future<int> sweep() async {
    if (_disposed || !RnsService.instance.isUp) return 0;
    if (_busy) {
      _again = true;
      return 0;
    }
    _busy = true;
    var got = 0;
    try {
      got = await _activity() + await _groups();
      if (got > 0) _pulled = true;
    } finally {
      _busy = false;
    }
    if (_again && !_disposed) {
      _again = false;
      if (!_pulled) unawaited(sweep());
    }
    return got;
  }

  Future<int> _activity() async {
    final arch = archive();
    if (arch == null) return 0;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // A small overlap so nothing slips between two sweeps.
    final since = _lastSec == 0 ? nowSec - window.inSeconds : _lastSec - 300;
    final List<Map<String, dynamic>> notes;
    try {
      notes = await RnsService.instance.fetchFeedBackfill(since);
    } catch (_) {
      return 0;
    }
    if (_disposed) return 0;
    final self = RnsService.instance.selfPubHex;
    var added = 0;
    for (final raw in notes) {
      final n = BackfillNote.read(raw, selfPub: self, nowSec: nowSec);
      if (n == null || arch.hasContent(n.from, n.text)) continue;
      // Media is not fetched here: the card shows its size and a download
      // button, or a week of history could be gigabytes.
      arch.add({...n.toRow(), 'meta': n.meta});
      added++;
    }
    // Only an answer moves the mark: advancing it on an empty sweep (a node
    // up before any peer is known) would never fetch the week again.
    if (notes.isNotEmpty) _lastSec = nowSec;
    if (added > 0) onChanged();
    return notes.length;
  }

  Future<int> _groups() async {
    final topics = groupTopics();
    if (topics.isEmpty) return 0;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final since = nowSec - window.inSeconds;
    final self = RnsService.instance.selfPubHex;
    var got = 0;
    for (final topic in topics) {
      final List<Map<String, dynamic>> notes;
      try {
        notes = await RnsService.instance.fetchFeedBackfill(since, topic: topic);
      } catch (_) {
        continue;
      }
      if (_disposed) return got;
      // fetchFeedBackfill answers newest first; a conversation appends.
      final read = <BackfillNote>[];
      for (final raw in notes.reversed) {
        final n = BackfillNote.read(raw, selfPub: self, nowSec: nowSec);
        if (n != null) read.add(n);
      }
      if (read.isEmpty) continue;
      got += read.length;
      onGroupNotes(topic, read);
    }
    if (got > 0) {
      LogService.instance.add('feed-backfill: $got group note(s)');
    }
    return got;
  }
}
