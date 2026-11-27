// The moderators of the public rooms (XPRS.md 10.10.3).
//
// Regional and Global belong to no station and no group, so section 10 has
// nobody to give authority in them. These binaries take it from a list: the
// npubs in https://xprs.dev/moderators.json, read from there and from nowhere
// else (no key is written into the program). A listed key signs the act
// section 10.4.1 already has, addressed to nobody,
//
//   t:moderate f:X1WATT ts:... r:89a9c8 remove:message sig:...
//
// and a station honouring the list drops that message from what it keeps,
// serves and shows. Removal only: nobody is sent away, nothing is corrected.
// Another implementation, or an operator who turns the switch off, ignores
// the acts; they are ordinary signed packets either way.
//
// This class is the list and the verdict, and nothing else: no store, no
// socket, no clock of its own. The archive deletes ([onRemoved]), the host
// fetches ([refresh] takes the text), the caller says when.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';

import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart' show xprsParseTs;

/// One listed key, and the days it is listed for.
class XprsPublicModerator {
  const XprsPublicModerator(this.npub, this.key, this.sinceMs, this.untilMs);
  final String npub;
  final Uint8List key;

  /// Acts dated before this are not this moderator's; 0 for always.
  final int sinceMs;

  /// Acts dated at or after this are not either; 0 for no end.
  final int untilMs;

  bool standsAt(int ts) =>
      ts >= sinceMs && (untilMs == 0 || ts < untilMs);
}

class XprsPublicModerators {
  XprsPublicModerators._();
  static final XprsPublicModerators instance = XprsPublicModerators._();

  /// Where the list is published.
  static const String url = 'https://xprs.dev/moderators.json';

  /// A list is a handful of people; a file with more than this is not one.
  static const int maxEntries = 64;
  static const int maxBytes = 32 * 1024;
  static const int _futureSlackMs = 5 * 60 * 1000;
  static const int _maxRemoved = 512;

  /// The operator's switch. Off: no act is honoured and nothing is listed.
  bool honoured = true;

  /// Nobody until the published list has been read once: no key is written
  /// into the program, so who moderates is decided at xprs.dev alone and a
  /// build cannot carry a different answer. The copy last read is kept by
  /// the host and stands while the site is out of reach.
  List<XprsPublicModerator> _list = const [];
  List<XprsPublicModerator> get list => honoured ? _list : const [];

  /// The identifiers removed, newest last, bounded: what a page already
  /// showing a message is told to take down.
  final Set<String> _removed = <String>{};
  Iterable<String> get removed => _removed;

  /// A removal was accepted: its target's identifier. The archive deletes on
  /// this; a screen redraws on it.
  Stream<String> get removals => _removals.stream;
  final StreamController<String> _removals =
      StreamController<String>.broadcast();

  int accepted = 0, refused = 0;

  static final RegExp _idRe = RegExp(r'^[0-9a-f]{6}$');

  /// Take a published list. False, and the list held stays, when [text] is
  /// not one: a captive portal's page or half a download must not leave the
  /// rooms with no moderators, or with anybody's.
  bool refresh(String text) {
    if (text.length > maxBytes) return false;
    final l = _parse(text);
    if (l == null) return false;
    _list = l;
    return true;
  }

  static List<XprsPublicModerator>? _parse(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map || j['moderators'] is! List) return null;
      final out = <XprsPublicModerator>[];
      for (final e in (j['moderators'] as List).take(maxEntries)) {
        if (e is! Map) continue;
        final npub = '${e['npub'] ?? ''}'.trim().toLowerCase();
        if (!npub.startsWith('npub1')) continue;
        final Uint8List key;
        try {
          key = Uint8List.fromList(HEX.decode(NostrCrypto.decodeNpub(npub)));
        } catch (_) {
          continue;
        }
        if (key.length != 32) continue;
        out.add(XprsPublicModerator(
            npub, key, _day(e['since']) ?? 0, _day(e['until']) ?? 0));
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// `2026-11-27`, or a full XPRS timestamp, as UTC milliseconds.
  static int? _day(Object? v) {
    final s = '${v ?? ''}'.trim();
    if (s.isEmpty) return null;
    final full = xprsParseTs(s);
    if (full != null) return full;
    final d = DateTime.tryParse('${s}T00:00:00Z');
    return d?.millisecondsSinceEpoch;
  }

  /// True when [key] (32 bytes, x-only) is listed now.
  bool lists(Uint8List key, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    for (final m in list) {
      if (m.standsAt(now) && _same(m.key, key)) return true;
    }
    return false;
  }

  /// True when [p] has the shape of an act about the public rooms: a removal
  /// addressed to nobody. Cheap, and says nothing about who signed it.
  static bool shaped(XprsPacket p) =>
      p.type == 'moderate' &&
      !p.has('d') &&
      (p['remove'] ?? '').trim().toLowerCase() == 'message' &&
      _idRe.hasMatch((p['r'] ?? '').trim().toLowerCase());

  /// The identifier [p] removes, when [p] is a listed moderator's removal
  /// standing at its own date; null otherwise. Does not record anything.
  String? judge(XprsPacket p, {int? nowMs}) {
    if (!honoured || !shaped(p)) return null;
    final ts = xprsParseTs(p['ts']);
    if (ts == null) return null;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (ts > now + _futureSlackMs) return null;
    for (final m in _list) {
      if (!m.standsAt(ts)) continue;
      if (xprsVerifyUnder(p, m.key) == XprsSigState.verified) {
        return p['r']!.trim().toLowerCase();
      }
    }
    return null;
  }

  /// Feed one packet from the funnel. True when it was a listed moderator's
  /// removal: its target is remembered and [removals] says so.
  bool offer(XprsPacket p, {int? nowMs}) {
    if (!shaped(p)) return false;
    final id = judge(p, nowMs: nowMs);
    if (id == null) {
      refused++;
      return false;
    }
    accepted++;
    if (_removed.remove(id) || _removed.length < _maxRemoved) {
      _removed.add(id);
    } else {
      _removed
        ..remove(_removed.first)
        ..add(id);
    }
    _removals.add(id);
    return true;
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---- keeping the list current ------------------------------------------

  /// How often the published list is asked for. It changes a few times a
  /// year; a station that restarts hourly must not ask hourly.
  static const Duration refreshEvery = Duration(hours: 12);

  /// After an ask that failed, the next one waits this long, so a site that
  /// is down is not asked at every uplink that comes up.
  static const Duration retryAfter = Duration(minutes: 10);

  bool _asking = false;
  int _failedMs = 0;

  /// Read the switch and the list last kept, then ask xprs.dev when the last
  /// ask is older than [refreshEvery]. Called at start and whenever an
  /// uplink comes up (the event that says the site may be reachable now);
  /// never on a clock. [fetch] returns the file's text, or null.
  Future<void> sync({
    required bool Function() honour,
    required String Function() kept,
    required int Function() askedMs,
    required Future<void> Function({String? json, required int askedMs}) keep,
    required Future<String?> Function(Uri url) fetch,
    int? nowMs,
  }) async {
    honoured = honour();
    final k = kept();
    if (k.isNotEmpty) refresh(k);
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (!honoured || _asking) return;
    if (now - askedMs() < refreshEvery.inMilliseconds) return;
    if (now - _failedMs < retryAfter.inMilliseconds) return;
    _asking = true;
    try {
      final text = await fetch(Uri.parse(url));
      if (text != null && refresh(text)) {
        await keep(json: text, askedMs: now);
      } else {
        _failedMs = now; // not a list: the one held stands, asked again later
      }
    } catch (_) {
      _failedMs = now; // unreachable: the same
    } finally {
      _asking = false;
    }
  }

  /// For tests: nobody listed, nothing remembered.
  void reset() {
    _list = const [];
    _failedMs = 0;
    _removed.clear();
    honoured = true;
    accepted = refused = 0;
  }
}
