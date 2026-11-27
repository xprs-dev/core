/*
 * xprs_catchup — the pocket device polls its archivers (XPRS 12.10.1).
 *
 * A phone cannot tell an absence from an afternoon in a pocket, so it does
 * not try: it keeps one persisted WATERMARK — the end of the last window an
 * archiver answered for — and, on a slow cadence, asks every archiver in
 * direct reach for what came after it:
 *
 *   t:command f:<us> d:<archiver> ts:<now> cmd:history since:<watermark>
 *
 * The ask is DIRECTED, so it reaches exactly one station on whatever lane can
 * carry it -- including the internet, where a peer on another network is
 * reachable and a scope:local ask (13.11.3) would have been refused before it
 * left. The watermark advances to the
 * ask's own ts: only when the station answers 200/206/404; a 429 or silence
 * leaves it, and the same window is asked for again next period.
 *
 * EVERY station in direct reach is asked, on whatever bearer heard it — not
 * only the ones advertising serve:archive. A station that holds a message for
 * us is worth asking whether or not it calls itself an archive, and a phone
 * that waits to be told there is mail never finds out when the beacon carrying
 * that news is the one advert it missed.
 *
 * The period is one minute. That is a battery setting, not a freshness setting
 * (docs/performance.md section 6.5): it costs one small frame per station per
 * minute inside an advertising window that already opens, no GATT link, no
 * crypto, no database. The expensive half — dialling a station to pull what it
 * holds — stays gated on a station actually saying it holds something.
 */
import '../../profile/device_identity.dart';
import 'dart:async';
import 'xprs_station_policy.dart';
import 'dart:math' as math;


import '../log_service.dart';
import '../preferences_service.dart';
import '../reticulum/rns_service.dart';
import 'xprs_archive.dart';
import 'xprs_cadence.dart';
import 'xprs_id.dart';
import 'xprs_groups.dart';
import 'xprs_ingest.dart';
import 'xprs_monitor.dart';
import 'xprs_owned_stations.dart';
import 'xprs_packet.dart';
import 'xprs_callsign.dart';
import 'xprs_presence.dart';
import 'xprs_publisher.dart';
import 'xprs_vocab.dart';
import 'package:xprs_core/src/platform/os.dart' as platform;
import 'package:meta/meta.dart';
import 'package:xprs_core/src/platform/core_host.dart';

class XprsCatchup {
  XprsCatchup._();
  static final XprsCatchup instance = XprsCatchup._();

  /// Test seams: fake clock and a captured send.
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;
  Future<Map<String, String>> Function(String wire)? sendOverride;

  /// The archivers announced on Reticulum, for a test (RnsService's
  /// announcedArchivers otherwise).
  @visibleForTesting
  List<String> Function()? announcedOverride;

  /// The stations heard over the internet, for a test (XprsMonitor.remote
  /// otherwise).
  @visibleForTesting
  List<String> Function()? remoteOverride;

  /// A station's callsign: shaped like one (a bare word such as `XPRS`, which
  /// some node announces as its name, is not), and a station rather than a
  /// person, a device or a group.
  static bool _isStationCall(String c) =>
      xprsIsCallsignShaped(c) && xprsKindOf(c) == XprsKind.station;

  /// How many archivers are asked for their directory, at most: one ask a
  /// sweep, each archiver once in [directoryEvery].
  static const int directoryArchivers = 6;

  /// The ask window never reaches further back than this (12.10.1 rule 4).
  static const Duration maxWindow = Duration(days: 7);

  /// How far back a FIRST-RUN backfill reaches, and how many messages is
  /// enough of a conversation to arrive with.
  ///
  /// 12.10.1 rule 4 bounds a background poll to seven days and says in the
  /// same breath that "anything older is fetched deliberately, not by a
  /// background poll". This is that deliberate fetch: it runs once, on a
  /// device whose archive holds no conversation at all, so a fresh install
  /// opens Global chat with something in it instead of a blank page. The poll
  /// keeps its week.
  static const Duration backfillWindow = Duration(days: 30);
  static const int backfillMessages = 1000;

  /// The archiver a backfill is currently draining, if any. One at a time:
  /// asking three archivers for the same month fetches the same conversation
  /// three times, and the responder meters each of them.
  String? _backfillStation;
  int _backfillFetched = 0;

  /// When each archiver was last asked for a NEW window: the clock the
  /// cadence runs on. A continuation of an open window does not reset it.
  final Map<String, int> _askedAtMs = {};

  /// When each archiver was last asked anything, continuation included: the
  /// floor between two asks is measured from here.
  final Map<String, int> _lastAskMs = {};

  /// Per station, the last `count:`/`mail:` its beacon claimed. An unchanged
  /// pair means there is nothing to fetch, so no replay is spent.
  final Map<String, String> _newsSeen = {};

  /// What is still owed per archiver: the windows not yet answered in full,
  /// NEWEST FIRST (see [_Window]). A new window opens ahead of an unfinished
  /// one, so fresh mail is never parked behind a week-deep backfill.
  final Map<String, List<_Window>> _windows = {};
  static const int _windowsMax = 3;

  /// The newest edge ever opened per archiver: where the next window starts,
  /// and the mark once every window is closed.
  final Map<String, int> _edgeMs = {};

  /// After a `429`, this archiver is not asked again before this moment,
  /// continuation or not (XPRS.md 12.10.2: "code:429 is the archiver's
  /// authority over the caller's cadence"). A continuation skipped the
  /// interval and so skipped the refusal too: the C61 was refused and asked
  /// again every 25 s (2026-09-15).
  final Map<String, int> _refusedUntilMs = {};

  /// Pending asks: section-5 id of the ask -> which archiver and window.
  final Map<String, _Ask> _pending = {};
  static const int _pendingMax = 8;

  /// Per archiver, the interval it has earned, in ms. Persisted with the
  /// watermarks: an in-memory-only cadence resets to "ask everybody now" on
  /// every restart, which is exactly how a crash loop blows through a
  /// station's hourly budget with nothing to stop it.
  final Map<String, int> _intervalMs = {};

  /// Per archiver, when it last gave us something new. Drives the ladder:
  /// quiet for a week is an hour, quiet for three months is six hours.
  final Map<String, int> _lastNewsMs = {};

  /// THE ask out, whoever it is to. One at a time per device: every replayed
  /// packet heard while it is out then belongs to it, so a page is counted at
  /// the receive door ([noteHeard]) instead of guessed at from who wrote what.
  /// The guess skipped a phone's only reply (2026-09-15).
  _Flight? _flight;

  /// How long an unanswered ask blocks the next one. Long enough for a full
  /// page to air (twelve records at the responder's pacing, plus slack), short
  /// enough that a peer that simply went away does not mute us for a period.
  static const Duration _inFlightGrace = Duration(seconds: 40);

  /// Injected so the tests are deterministic; 0..1.
  double Function() rand = math.Random().nextDouble;

  /// Another asker on this station with an ask out (XprsFetch): the poller
  /// waits for it, as it would for its own. Two asks from one requester to
  /// one archiver are not two replays: the second SUPERSEDES the first
  /// (XprsHistoryServer), which would cancel a page mid-air.
  bool Function()? externalBusy;

  /// Is an ask of ours out to [archiver] right now? The fetch asks before
  /// sending its own, for the reason above.
  bool busyWith(String archiver, {int? nowMs}) {
    final now = nowMs ?? this.nowMs();
    return _busy(now) && _flight?.archiver == _base(archiver);
  }

  /// Is an ask out? Forgets one that outlived its grace.
  bool _busy(int now) {
    if (externalBusy?.call() ?? false) return true;
    final f = _flight;
    if (f == null) return false;
    if (now - f.atMs > _inFlightGrace.inMilliseconds) {
      _flight = null;
      return false;
    }
    return true;
  }

  void _land(String base) {
    if (_flight?.archiver != base) return;
    _flight = null;
    // The slot is free: the directory ask that waited for it goes now.
    if (_directoryWanted.isNotEmpty && _directorySelf.isNotEmpty) {
      unawaited(_askDirectories(_directorySelf, _directoryWanted, nowMs()));
    }
  }

  /// The archivers to ask for their directory, and as whom, from the last
  /// sweep.
  List<String> _directoryWanted = const [];

  /// The archivers this station asks for their directory: whose answer it
  /// reads (XprsDirectoryConsumer.named).
  List<String> get directoryAsked => _directoryWanted;
  String _directorySelf = '';

  /// Is anybody looking? A fast cadence with the screen off spends somebody's
  /// battery on news no one is awake to read (docs/performance.md 6.5).
  bool get _visible => CoreHost.anyoneLooking();

  /// What this peer will tolerate. Only an always-on archiver's raised budgets
  /// (12.9.4) can serve a fast caller; our own other devices are not metered
  /// at all by the responder, so they count as fast too.
  XprsPeerClass _classOf(String base, String selfCallsign) {
    if (_operatorTrusted(base, selfCallsign)) return XprsPeerClass.fast;
    final st = XprsMonitor.instance.stations[base];
    if (st == null) return XprsPeerClass.ordinary;
    // Judged by 12.9.4's qualities, not by a word. This used to read
    // `serve:…,super`, which the specification's vocabulary (13) does not
    // contain: only this app aired it, so only this app could see it, and a
    // genuine always-on archiver from any other implementation was rated
    // ordinary however deep and however long awake.
    return xprsLooksAlwaysOn(
      callsign: base,
      services: st.services,
      bearer: st.bearer,
      count: st.count ?? 0,
      uptimeSeconds: xprsUptimeSeconds(st.uptime),
      named: const {},
    )
        ? XprsPeerClass.fast
        : XprsPeerClass.ordinary;
  }

  /// An archiver this operator actually agreed to: our own other device, or
  /// one they NAMED. Kept apart from one we merely BELIEVE, because the two
  /// answer different questions and only this one may spend the battery
  /// without asking (see [_floorMsFor]).
  ///
  /// The named list is also the only way to learn an archiver reached solely over
  /// the internet: it is never heard on a radio, so it has no station record
  /// and no `serve:` list to read. Requiring the beacon meant the one archiver
  /// everybody pulls Global chat from was the one archiver nobody could poll
  /// quickly.
  bool _operatorTrusted(String base, String selfCallsign) {
    if (base == _base(selfCallsign)) return true;
    final chosen =
        PreferencesService.instanceSync?.xprsNamedArchivers ?? const <String>[];
    for (final c in chosen) {
      if (_base(c) == base) return true;
    }
    return false;
  }

  /// The fastest this archiver may be asked, right now.
  int _floorMsFor(String base, PreferencesService prefs) {
    final peer = _classOf(base, _selfCallsign);
    var floor = XprsCadence.floorFor(peer, visible: _visible).inMilliseconds;
    // The operator's own knob still applies, in the direction that is always
    // safe: xprsCatchupMinutes may make this station poll SLOWER than the
    // section 12.10.1 floor, never faster. Somebody minding their battery can
    // ask for less; nobody gets to ask an ordinary archiver for more than its
    // six replays an hour.
    //
    // The knob is waived only for an archiver this operator CHOSE. Always-on
    // is an inference, not a fact -- anything in earshot can beacon `archive`
    // and claim a deep `count:` -- so honouring a stranger's numbers here would
    // let one beacon override the battery setting and turn a once-a-minute poll
    // into four. An archiver that merely looks always-on still earns the raised
    // floor, it just never gets asked faster than its own operator allowed.
    final chosen = prefs.xprsCatchupMinutes * 60000;
    final trusted = _operatorTrusted(base, _selfCallsign);
    if (!trusted && chosen > floor) floor = chosen;
    return floor;
  }

  /// The interval this archiver has earned, clamped to the bounds that apply
  /// right now (they move with visibility and with how long it has been quiet).
  int _intervalFor(String base, PreferencesService prefs, int now) {
    final stored = _intervalMs[base] ??
        (prefs.xprsCatchupIntervals[base] ?? XprsCadence.initial.inMilliseconds);
    _intervalMs[base] ??= stored;
    final lastNews = _lastNewsMs[base] ?? prefs.xprsCatchupNews[base] ?? now;
    final silent = Duration(milliseconds: now - lastNews);
    final floor = _floorMsFor(base, prefs);
    final ceiling = XprsCadence.ceilingFor(silent).inMilliseconds;
    var ms = stored;
    if (ms > ceiling) ms = ceiling;
    if (ms < floor) ms = floor > ceiling ? ceiling : floor;
    return XprsCadence.jitter(Duration(milliseconds: ms), rand()).inMilliseconds;
  }

  /// Fold an answer into this archiver's cadence and persist it.
  void _noteAnswer(String base, XprsAnswer answer) {
    final prefs = PreferencesService.instanceSync;
    final now = nowMs();
    _land(base);
    if (answer == XprsAnswer.news) {
      _lastNewsMs[base] = now;
      prefs?.setXprsCatchupNews(base, now);
    }
    final silent = Duration(milliseconds: now - (_lastNewsMs[base] ?? now));
    final current = Duration(
        milliseconds: _intervalMs[base] ?? XprsCadence.initial.inMilliseconds);
    final next = XprsCadence.next(
      current: current,
      answer: answer,
      peer: _classOf(base, _selfCallsign),
      visible: _visible,
      silentFor: silent,
    );
    _intervalMs[base] = next.inMilliseconds;
    prefs?.setXprsCatchupInterval(base, next.inMilliseconds);
  }

  /// The user opened a room: an event beats a clock. Ask this archiver now,
  /// once, whatever the interval says -- the same escape hatch the mesh
  /// scheduler has in pokeFor.
  /// Groups a person just joined or opened, asked for on the next pass past
  /// the archiver's floor (once each).
  final Set<String> _urgent = {};

  /// Ask for [group]'s history now: somebody joined it or opened it to read,
  /// and is looking at an empty room.
  void askNow(String group) {
    final g = group.trim().replaceFirst('#', '').toUpperCase();
    if (g.isEmpty) return;
    _urgent.add(g);
    _followAskedAtMs.remove(g);
    _followAskedAtMs.removeWhere((k, _) => k.startsWith('$g@'));
    if (_selfCallsign.isNotEmpty) unawaited(tick(_selfCallsign));
  }

  /// Somebody is searching: ask the archivers for the names they hold now
  /// rather than at the next period (12.10.2: a fast tier exists to put words
  /// on a screen somebody is looking at). A refusal still stands.
  void askNames() {
    _urgent.add(namesTarget);
    _followAskedAtMs.removeWhere((k, _) => k.startsWith('$namesTarget@'));
    if (_selfCallsign.isNotEmpty) unawaited(tick(_selfCallsign));
  }

  void pokeFor(String archiver) {
    final base = _base(archiver);
    if (base.isEmpty) return;
    _askedAtMs.remove(base);
    _lastAskMs.remove(base);
    _refusedUntilMs.remove(base);
    _land(base);
    if (_selfCallsign.isNotEmpty) unawaited(tick(_selfCallsign));
  }

  int get watermarkSec =>
      PreferencesService.instanceSync?.xprsCatchupWatermark ?? 0;

  /// How many stations we remember a mark for. Evicted oldest-mark-first, so a
  /// busy channel cannot grow this without bound.
  static const int _marksMax = 32;

  /// This station's own mark, or the shared seed for one never asked before.
  int _markFor(String station, PreferencesService prefs) =>
      prefs.xprsCatchupMarks[station] ?? prefs.xprsCatchupWatermark;

  void _setMark(String station, int sec, PreferencesService prefs) {
    final marks = prefs.xprsCatchupMarks;
    if (marks.length >= _marksMax && !marks.containsKey(station)) {
      var oldest = marks.keys.first;
      for (final e in marks.entries) {
        if (e.value < marks[oldest]!) oldest = e.key;
      }
      marks.remove(oldest);
    }
    marks[station] = sec;
    prefs.xprsCatchupMarks = marks;
  }

  // ── Cadence ───────────────────────────────────────────────────────────────
  //
  // Driven from BgService's 2 s native heartbeat, NOT a Dart Timer.periodic: a
  // Dart timer is throttled to near-nothing once Android backgrounds the app
  // (docs/performance.md section 8.2), which is precisely the pocket this poll
  // exists for. MeshService's own 60 s sweep is a bare Timer and used to be
  // what called us, so the poll it drove stopped the moment the screen did.
  String _selfCallsign = '';
  int _lastTickMs = 0;
  bool _ticking = false;
  bool _armed = false;

  /// How often the key binding goes back on air. Section 18.1: "every 30
  /// minutes is a reasonable interval on a quiet channel", because a receiver
  /// that never heard the announcement cannot check a signature. A fresh `ts:`
  /// each period matters — a station dedups an identical wire by its
  /// identifier, so re-airing the same bytes is not a second chance.
  static const Duration identityEvery = Duration(minutes: 30);

  /// Re-announce the chosen archivers (t:mailbox, 13.12) once a day. Unlike
  /// identity this is not urgent (12.4 — publishing waits for a cheap link),
  /// and mail routing changes on the scale of days, not minutes.
  static const Duration mailboxEvery = Duration(hours: 24);
  int _mailboxAtMs = 0;

  /// The decoration (6.3.2: a name, a picture, a line) goes back on air once
  /// a day. "The decoration is larger and changes once a year, so it goes out
  /// rarely"; a change airs it at once, from the profiles service.
  static const Duration decorationEvery = Duration(hours: 24);
  int _decorationAtMs = 0;

  /// The longest this device will go without asking a station it can hear.
  ///
  /// Ten minutes is section 12.10.1's own catch-up cadence and it lands exactly
  /// on section 31.2's ceiling for a caller whose key the station knows -- six
  /// replays an hour. We publish `t:identity` on every bearer, so we are that
  /// caller rather than a stranger metered at two.
  static const Duration askAtLeastEvery = Duration(minutes: 10);
  int _identityAtMs = 0;

  /// Begin polling for [selfCallsign]. Fires once immediately, then settles
  /// into the period — a timer-only poll means a silent first minute
  /// (docs/performance.md section 6.5).
  void start(String selfCallsign) {
    _selfCallsign = selfCallsign;
    if (selfCallsign.isEmpty) return;
    final owned = XprsOwnedStations.instance;
    owned.load = () => PreferencesService.instanceSync?.xprsOwnedStations ?? const [];
    owned.save = (v) => PreferencesService.instanceSync?.xprsOwnedStations = v;
    // A card that just became ours is the first mailbox to declare: say so
    // on the next tick rather than at tomorrow's period.
    owned.onChanged = () => _mailboxAtMs = 0;
    unawaited(_airIdentity());
    unawaited(_airMailbox());
    unawaited(_airDecoration());
    unawaited(tick(selfCallsign));
    // Armed on any host that delivers a heartbeat: Android's native one, the
    // server's. Without this a server polled once at start, and on a fresh
    // install that one tick only sets the watermark (12.10.1 rule 2), so it
    // never asked anybody for the history it was missing.
    if (_armed || !CoreHost.keepAlive.ticks) return;
    _armed = true;
    CoreHost.keepAlive.addTickListener(_onNativeTick);
  }

  void stop() {
    if (!_armed) return;
    _armed = false;
    CoreHost.keepAlive.removeTickListener(_onNativeTick);
  }

  void _onNativeTick() {
    final now = nowMs();
    // The 2 s heartbeat is shared; this poll only wants a minute of it. tick()
    // enforces the real per-station period on top.
    // The gate below used to be thirty seconds, which quietly made any
    // interval under thirty seconds unreachable however busy a room was. The
    // sweep body is a walk over the stations in reach and returns immediately
    // for every one whose interval has not elapsed, so running it more often
    // costs almost nothing; what it buys is that the fast tier is actually
    // fast (docs/performance.md 4.2 -- cheap checks first, and this is one).
    if (now - _lastTickMs < 5000) return;
    _lastTickMs = now;
    if (_ticking || _selfCallsign.isEmpty) return;
    if (now - _identityAtMs >= identityEvery.inMilliseconds) {
      _identityAtMs = now;
      unawaited(_airIdentity());
    }
    if (now - _mailboxAtMs >= mailboxEvery.inMilliseconds) {
      _mailboxAtMs = now;
      unawaited(_airMailbox());
    }
    if (now - _decorationAtMs >= decorationEvery.inMilliseconds) {
      _decorationAtMs = now;
      unawaited(_airDecoration());
    }
    _ticking = true;
    unawaited(tick(_selfCallsign).whenComplete(() => _ticking = false));
  }

  /// When the last sweep ran, how many stations it could see, and when each
  /// was last asked. Reported by /api/status; never logged.
  int _lastSweepMs = 0;
  int _lastSweepSeen = 0;
  Map<String, dynamic> statusJson() => {
        'lastSweepAgoMs': _lastSweepMs == 0 ? null : nowMs() - _lastSweepMs,
        'stationsSeen': _lastSweepSeen,
        // What each archiver has earned, in seconds -- the observable that
        // says whether the cadence is following the room or stuck.
        'intervalS': {
          for (final e in _intervalMs.entries) e.key: e.value ~/ 1000,
        },
        'askedAgoMs': {
          for (final e in _askedAtMs.entries) e.key: nowMs() - e.value,
        },
        'resuming': [
          for (final e in _windows.entries)
            if (e.value.any((w) => w.untilMs != null)) e.key
        ],
        // What is still owed, per archiver, newest first, and where each
        // page stopped: the cursor the next continuation asks from.
        'windows': {
          for (final e in _windows.entries)
            e.key: [
              for (final w in e.value)
                {
                  'since': _ts(w.sinceMs),
                  'until': w.untilMs == null ? null : _ts(w.untilMs!),
                  'end': _ts(w.endMs),
                  if (w.stalled) 'stalled': true,
                }
            ],
        },
        'marks': PreferencesService.instanceSync?.xprsCatchupMarks ?? const {},
        'refusedForMs': {
          for (final e in _refusedUntilMs.entries)
            if (e.value > nowMs()) e.key: e.value - nowMs(),
        },
        // Followed stations fetched from the chosen archivers (12.12.2).
        'followed': {
          'asks': followAsks,
          'rows': followRows,
          'refused': followRefused,
          'askedAgoMs': {
            for (final e in _followAskedAtMs.entries) e.key: nowMs() - e.value,
          },
          'resuming': _followResume.keys.toList(),
        },
        // The first-run backfill, because a fresh install that quietly
        // fetches nothing must be readable without a debugger.
        'backfill': {
          'station': _backfillStation,
          'messages': _backfillFetched,
          'target': backfillMessages,
          'days': backfillWindow.inDays,
        },
      };

  /// Test seam: forget every station's news, ask history and pending page.
  /// Singleton, same reason as XprsMonitor.debugReset.
  void debugReset() {
    _directoryAskedAtMs.clear();
    _directoryPending.clear();
    _directoryAnswered.clear();
    _directoryWanted = const [];
    _directorySelf = '';
    directoryAsks = 0;
    _askedAtMs.clear();
    _lastAskMs.clear();
    _newsSeen.clear();
    _windows.clear();
    _edgeMs.clear();
    _refusedUntilMs.clear();
    _pending.clear();
    _intervalMs.clear();
    _lastNewsMs.clear();
    _flight = null;
    _identityAtMs = 0;
    _mailboxAtMs = 0;
    _backfillStation = null;
    _backfillFetched = 0;
    _backfillSettled = false;
    _followPending.clear();
    _followAskedAtMs.clear();
    _followArchiverAtMs.clear();
    _followResume.clear();
    _followOldest.clear();
    _followLastResume.clear();
    _groupMark.clear();
    _namesAnswered.clear();
    _urgent.clear();
    followAsks = followRows = followRefused = 0;
  }

  /// Announce which key this callsign signs with, on every active bearer.
  /// Section 18.1. Stamped so [start] and the heartbeat share one clock.
  ///
  /// Stamped only when a bearer actually TOOK it. The first tick after boot
  /// reliably beats the radios: on the bench the identity aired into
  /// "ble5:inactive, lan:inactive, reticulum:inactive, lora:inactive" and the
  /// next attempt was thirty minutes out -- half an hour during which nobody
  /// who had not met this station could verify a thing it signed, its mailbox
  /// declaration included. An airing nothing carried is not an airing.
  Future<void> _airIdentity() async {
    _identityAtMs = nowMs();
    try {
      final report = await XprsPublisher.instance.publishIdentity();
      if (!report.values.any((v) => v == 'sent')) {
        _identityAtMs = 0; // nothing took it: retry on the next tick
      }
    } catch (e) {
      LogService.instance.add('XPRS: identity airing failed: $e');
      _identityAtMs = 0;
    }
  }

  /// Put the decoration on air; retry on the next tick if no bearer took it,
  /// exactly like [_airIdentity].
  ///
  /// A desktop has no native heartbeat to retry on, and its bearers are
  /// rarely up at the first try (the LAN has found nobody yet), so there the
  /// retry is a one-shot timer: once a minute, twenty times at most.
  Future<void> _airDecoration() async {
    _decorationAtMs = nowMs();
    var carried = false;
    try {
      final report = await XprsPublisher.instance.publishDecoration();
      carried = report.values.any((v) => v == 'sent');
    } catch (e) {
      LogService.instance.add('XPRS: decoration airing failed: $e');
    }
    if (carried) {
      _decorationRetries = 0;
      return;
    }
    _decorationAtMs = 0;
    if (platform.isAndroid || _decorationRetries >= 20) return;
    _decorationRetries++;
    _decorationRetry?.cancel();
    _decorationRetry = Timer(const Duration(minutes: 1), () {
      unawaited(_airDecoration());
    });
  }

  int _decorationRetries = 0;
  Timer? _decorationRetry;

  /// Announce this station's chosen archiver devices as a signed `t:mailbox`
  /// (13.12) — the same stations it sends copies of its publications to (36),
  /// so others and those archivers know where this station can be reached.
  /// Aired on every bearer the station has (12.0), never internet-only. Zero
  /// archivers is a valid configuration (12.3): then there is nothing to
  /// announce. Fire-once at start then on the daily period; retry on the next
  /// tick if no bearer took it, exactly like [_airIdentity].
  /// Who holds mail for us, in order of preference (9.12), as the `hold:`
  /// list: our own movable stations first — a card in the owner's pocket
  /// meets the owner more often than any archiver, and holds mail for them
  /// because this declaration names it — then the chosen archivers. A card
  /// is NOT added to the archiver list: it cannot serve history (12.9.4),
  /// and that list is also where copies of our publications go. Empty when
  /// there is nobody to name (12.3: a valid configuration).
  String mailboxHoldCsv() {
    final cards = XprsOwnedStations.instance.portable;
    final chosen = PreferencesService.instanceSync?.xprsArchivers ?? const [];
    return [...cards, ...chosen.where((c) => !cards.contains(c))].join(',');
  }

  Future<void> _airMailbox() async {
    _mailboxAtMs = nowMs();
    final list = mailboxHoldCsv();
    if (list.isEmpty) return;
    try {
      final report = await XprsPublisher.instance.publishMailboxDecl(list);
      if (!report.values.any((v) => v == 'sent')) {
        _mailboxAtMs = 0; // nothing took it: retry on the next tick
      }
    } catch (e) {
      LogService.instance.add('XPRS: mailbox airing failed: $e');
      _mailboxAtMs = 0;
    }
  }

  /// Driven from the native BgService heartbeat (see [start]) so it keeps
  /// polling with the screen off. Enforces its own period.
  Future<void> tick(String selfCallsign) async {
    final prefs = PreferencesService.instanceSync;
    if (prefs == null || !prefs.xprsCatchup) return;
    if (selfCallsign.isEmpty) return;

    final now = nowMs();

    // A fresh install has no hole: start keeping from now (12.10.1 rule 2).
    if (prefs.xprsCatchupWatermark == 0) {
      prefs.xprsCatchupWatermark = now ~/ 1000;
      return;
    }

    var anyLocal = false;
    for (final b in XprsPublisher.instance.bearers) {
      if (b.shortRange && await b.active) {
        anyLocal = true;
        break;
      }
    }

    // Every station in DIRECT reach (no via:), fresh within the monitor's own
    // staleness window — a list is a claim about now. No serve:archive filter:
    // any station in earshot may be holding something for us.
    final selfBase = _base(selfCallsign);
    final fresh = anyLocal
        ? (XprsMonitor.instance
            .directlyHeard(nowMs: now)
            .map((c) => XprsMonitor.instance.stations[c])
            .whereType<XprsStation>()
            .where((s) => _base(s.callsign) != selfBase)
            .where((s) => !DeviceIdentity.instance.isDevice(s.callsign))
            .toList(growable: false))
        : const <XprsStation>[];

    // ── The always-on archivers (12.9.4) ────────────────────────────────────
    // A station in earshot holds what IT heard, which is the neighbourhood.
    // Global chat is not a neighbourhood: it is everything everybody said,
    // and the place that holds all of it is an always-on archiver on the internet
    // (12.9.4's deep memory). It is asked whether or not any radio is up --
    // that is the whole point of it -- and it is asked the same metered
    // question, on the addressed lane, which is the one the public hubs
    // actually carry (12.12.1).
    //
    // Without this the sweep returned early on a phone with no short-range
    // bearer, and even with one it only ever asked stations it could HEAR --
    // so a network reachable only over the internet was never asked anything,
    // and Global chat arrived from nowhere.
    // The operator's list and the ones heard on the air, in that order. A
    // fresh install has nothing in the first -- which is why it used to ask
    // nobody and show an empty Global chat -- and the second fills itself from
    // whatever looked always-on (12.9.4) while this device was listening.
    final knownAlwaysOn = <String>[];
    for (final c in [
      ...prefs.xprsNamedArchivers,
      // Every station this node has learned from a Reticulum ANNOUNCE.
      //
      // This is the list that makes a fresh install work, and the one that was
      // missing: a phone with no radio neighbour and nothing configured has no
      // heard stations and no named archivers, so the sweep returned before
      // asking anybody and Global chat stayed empty with nothing to read
      // anywhere.
      //
      // An announcement is one of only two things a shared transport is
      // guaranteed to carry (12.12.1), and a directed ask is the other -- so
      // between them there is always a way through. Measured on the bench:
      // tank2, installed minutes earlier on a different network, already
      // resolved X3ARK to an LXMF destination two hops away through a public
      // hub. It could have asked at any moment; it just never knew it should.
      ...RnsService.instance.announcedCallsigns(prefix: 'X2'),
      ...RnsService.instance.announcedCallsigns(prefix: 'X3'),
    ]) {
      final base = _base(c);
      if (base.isEmpty || base == selfBase) continue;
      if (DeviceIdentity.instance.isDevice(base)) continue;
      if (!knownAlwaysOn.contains(base)) knownAlwaysOn.add(base);
    }
    // For the ask loop, drop the ones already coming through `fresh` so they
    // are not asked twice. The backfill below uses the FULL list: whether a
    // archiver also happens to be in earshot says nothing about whether this
    // device is missing a month of what it holds.
    final deep = [
      for (final base in knownAlwaysOn)
        if (!fresh.any((s) => _base(s.callsign) == base)) base
    ];

    // Followed stations first: they are few, the person asked for them by
    // name, and the in-flight gate below keeps the conversation's ask from
    // landing on the same archiver while theirs is being answered.
    final named = [
      for (final c in prefs.xprsNamedArchivers)
        if (_base(c).isNotEmpty && _base(c) != selfBase) _base(c)
    ];

    await _pullFollowed(selfCallsign, named, now, prefs);
    // A group's talk is held by its members and by whoever kept it, not only
    // by archivers the person named: those in earshot are asked too, and the
    // always-on ones known to this station. A person who names no archiver
    // (most) otherwise never asked anybody, and joined to an empty room.
    // Somebody looking at an empty room is waiting: the stations in earshot
    // answer in a second, a named archiver across the internet may take the
    // whole in-flight grace, so for them the near ones go first.
    final near = [for (final s in fresh) _base(s.callsign)];
    await _pullFollowed(
        selfCallsign,
        (_urgent.isEmpty
                ? {...named, ...near, ...deep}
                : {...near, ...named, ...deep})
            .toList(),
        now,
        prefs,
        groups: true);
    // Who exists, by name: the identities the archivers hold (12.9.4, "bulk
    // gossip is the history replay"). The archivers this station leans on
    // are where people and groups it never heard announced themselves, and
    // where the federation's identities meet (12.9.1); a station in earshot
    // holds only the neighbourhood the air already brought.
    // One ask is out at a time, so the order is who gets asked first: the
    // ones the operator named, then those that look always-on (deep, awake:
    // 12.9.4), then the rest -- a board that announced on Reticulum holds
    // little and may not answer, and must not keep Search waiting.
    final alwaysOn = [
      for (final c in knownAlwaysOn)
        if (_classOf(c, selfCallsign) == XprsPeerClass.fast) c
    ];
    await _pullFollowed(
        selfCallsign, {...named, ...alwaysOn, ...knownAlwaysOn}.toList(), now,
        prefs,
        names: true);
    // Where each chosen archiver's directory and groups index are (12.9,
    // 12.9.7): its own newest `t:service`, asked for when the air does not
    // bring it.
    // The chosen ones first, then the others that announced themselves as
    // archivers on Reticulum. The one this station adopted is the first it
    // heard, kept for its mail (12.3); it may be many hops away and never
    // answer, and asked alone it left Search and the groups ranking empty
    // while a reachable archiver stood on the same hub (12.9.1: discovery is
    // the federation's, not one archiver's).
    final announced = announcedOverride?.call() ??
        [for (final a in RnsService.instance.announcedArchivers()) a.callsign];
    // And the stations that reached us over the internet themselves, newest
    // first. A hub forwards an announce when it is sent, at most hourly, and
    // not always: a fresh station missed X3PTZM's 19:57 announce while
    // X3PTZM was asking it for history, so it knew the archiver and never
    // asked it where its directory was. Whoever answers with a `t:service
    // serve:archive` is an archiver (XprsDirectoryConsumer.archiveClaimMs);
    // whoever does not costs one ask.
    final heard = remoteOverride?.call() ??
        (XprsMonitor.instance.remote.entries.toList()
              ..sort((x, y) => y.value.compareTo(x.value)))
            .map((e) => e.key)
            .toList();
    // Remembered, because at this point of the sweep the one ask slot is
    // usually taken by the history ask sent a moment ago: the directory ask
    // then goes out when that one is answered ([_land]). Asked only here, it
    // found the slot busy every sweep and was never sent: a fresh station
    // asked a reachable archiver for messages for 40 minutes and never once
    // for its directory, and its groups ranking stayed empty.
    _directorySelf = selfCallsign;
    _directoryWanted = {
      ...named,
      ...[...announced, ...heard].map(_base).where(_isStationCall),
    }
        .where((c) => c.isNotEmpty && c != _base(selfCallsign))
        .take(directoryArchivers)
        .toList();
    await _askDirectories(selfCallsign, _directoryWanted, now);

    if (fresh.isEmpty && deep.isEmpty) return;

    // ── The first-run backfill (12.10.1 rule 4's "fetched deliberately") ──
    // A device whose archive holds no conversation has nothing to show in
    // Global chat, and the seven-day poll would fill it a week at a time only
    // as new traffic arrived. Reach back a month instead, once, against one
    // known archiver, and stop as soon as there is enough to read.
    _updateBackfill(knownAlwaysOn, fresh);

    final asked = <String>[];
    for (final st in [
      ...fresh,
      // An always-on archiver we have never heard on the air has no station record
      // and so no count:/mail: to compare -- which the news check below reads
      // as "no news", leaving the every-period backstop to carry it.
      for (final c in deep) XprsStation(c, 'rns', now),
    ]) {
      // One ask out at a time (see [_flight]); the next station is the next
      // tick's, five seconds on.
      if (_busy(now)) break;
      final base = _base(st.callsign);
      if ((_refusedUntilMs[base] ?? 0) > now) continue;
      // THE NEWS CHECK, and it costs nothing on air: the station's own beacon
      // already says how much it holds (`count:`) and how much mail it is
      // carrying (`mail:`). A replay is metered — six an hour for a caller
      // whose key the station knows, two for a stranger (section 31.2) — so
      // spending one to be told nothing changed is the one thing this poll
      // must not do.
      final news = '${st.count ?? -1}/${st.mail ?? -1}';
      final seen = _newsSeen[base];
      // A page the station could not finish is asked for again at once
      // (12.10.2: "code:206 ... ask the continuation IMMEDIATELY"), unless the
      // chain stopped moving, in which case it waits for the next window.
      final pending = _windows[base]
          ?.where((w) => w.untilMs != null && !w.stalled)
          .firstOrNull;
      // The interval this archiver has EARNED. One clock for everybody meant a
      // room silent for three months cost the same metered replay as one with
      // a conversation running; the cadence now follows what the archiver
      // actually returns (xprs_cadence.dart), bounded below by what that peer
      // permits and above by how long it has had nothing to say.
      final wait = _intervalFor(base, prefs, now);
      final quietFor = now - (_askedAtMs[base] ?? 0);
      final overdue = !_askedAtMs.containsKey(base) || quietFor >= wait;

      // The news check ACCELERATES the ask; it must never be the only thing
      // that permits one. A station whose count: we can see is asked the
      // moment it moves; every station is asked at least once a period
      // whatever we think we know.
      //
      // The first version of this made the fallback conditional on the station
      // never having published a count, and that was subtly wrong in exactly
      // the way that matters here: the phone spent twenty minutes on WiFi,
      // learned a count over the LAN, and then went back to BLE where nothing
      // can ever refresh it. `count` was no longer null, so the fallback
      // switched itself off, and the comparison went on succeeding against a
      // number frozen in the past. Stale knowledge is worse than none, because
      // it looks like knowledge. A backstop that is always armed cannot be
      // reasoned out of existence by state going stale.
      // News accelerates, but never past the floor: the floor is the peer's
      // budget, and a count: that moves every minute does not buy us the right
      // to ask an ordinary archiver every minute. Whoever asked last, the
      // conversation or a followed station. A continuation is the one ask the
      // floor does not hold back (12.10.2).
      var openNew = false;
      if (overdue || seen != news) {
        final last =
            math.max(_lastAskMs[base] ?? 0, _followArchiverAtMs[base] ?? 0);
        openNew = last == 0 || now - last >= _floorMsFor(base, prefs);
      }
      if (!openNew && pending == null) continue;
      final _Window w;
      if (openNew) {
        // The news is consumed by the window it opens, never by a
        // continuation, or a count that moved during a chain is forgotten.
        _newsSeen[base] = news;
        // Newest first (11.2.1: "somebody back from four days at sea wants
        // last night before last Tuesday"): a new window opens AHEAD of any
        // unfinished one, which resumes once this is answered.
        w = _openWindow(base, now, prefs);
        _askedAtMs[base] = now;
      } else {
        w = pending!;
      }
      await _ask(selfCallsign, base, w, now);
      asked.add(base);
    }
    // One line per sweep, never one per station: this runs every minute for as
    // long as the app lives, into a 2000-line ring (docs/performance.md 3.3).
    if (asked.isNotEmpty) {
      LogService.instance.add('XPRS: polled ${asked.length} station(s) — '
          '${asked.join(", ")}');
    }
    // Silence and "not running" looked identical from outside, which cost an
    // afternoon: a sweep that considers stations and asks none logs nothing,
    // so a stalled poller and a quiet one read the same. This is state, not a
    // log line -- /api/status can answer "when did you last try" without
    // spending a ring entry every thirty seconds.
    _lastSweepMs = now;
    _lastSweepSeen = fresh.length;
  }

  /// How many conversation records the archive holds. The stop condition is
  /// measured from the ARCHIVE, not from the pages served, so a backfill
  /// interrupted by a restart resumes where the device actually is rather
  /// than starting the month again.
  /// Test seam: what the archive holds, when there is no archive to ask.
  @visibleForTesting
  int Function()? messagesHeldOverride;

  int _messagesHeld() {
    final o = messagesHeldOverride;
    if (o != null) return o();
    try {
      // `ready` FIRST: query() answers `const []` when there is no database
      // open, which is indistinguishable from a genuinely empty archive and
      // would arm a month-deep ask on every device that had not finished
      // opening its store yet.
      if (!XprsArchive.instance.ready) return -1;
      // COUNT, not a page. This asked query() for a thousand rows and took
      // their .length -- once a minute, on the main isolate, on a device whose
      // archive is the biggest on the network. See XprsArchive.countOf.
      return XprsArchive.instance.countOf(types: const ['message']);
    } catch (_) {
      // UNKNOWN, which is not the same as empty and must not be treated as
      // it: a month-deep ask is the heaviest thing this poller does, and
      // launching one because the archive happened to be unreadable for a
      // moment spends a peer's metered replay on a question we could not
      // establish we needed to ask. -1 means "do not backfill".
      return -1;
    }
  }

  /// Start, continue or finish the first-run backfill.
  ///
  /// Re-armable on purpose: a first launch that hears no archiver is not a
  /// permanent verdict, and the next sweep that knows one will pick it up.
  /// Set once this device is known to hold a conversation. The backfill is a
  /// FIRST-RUN job: after that the answer cannot change back, so there is
  /// nothing to re-establish every minute for the life of the process.
  bool _backfillSettled = false;

  void _updateBackfill(List<String> deep, List<XprsStation> fresh) {
    if (_backfillSettled) return;
    final held = _messagesHeld();
    if (held < 0) {
      _backfillStation = null; // cannot read the archive: do not guess
      return;
    }
    _backfillFetched = held;
    if (held >= backfillMessages) {
      _backfillStation = null;
      _backfillSettled = true;
      return;
    }
    if (_backfillStation != null) {
      // Still draining. Keep going while the station is still one we know.
      if (deep.contains(_backfillStation)) return;
      _backfillStation = null;
    }
    // Only a device with NO conversation at all backfills. One that has some
    // is a device the ordinary poll is already serving, and a month-wide ask
    // there is a metered replay spent on records it mostly has.
    if (held > 0) {
      _backfillSettled = true;
      return;
    }
    // A deep one first -- it holds everything everybody said.
    // Failing that, a STATION in earshot: `X3` is a station, relay or
    // unattended equipment (section 3), so it keeps a spool worth a month-deep
    // ask. A person's phone is not, which is why the prefix decides rather
    // than mere presence -- asking every neighbour for a month of history
    // would spend somebody's metered replay on a device that has no archive
    // to give.
    if (deep.isNotEmpty) {
      _backfillStation = deep.first;
    } else {
      final station = fresh
          .map((s) => _base(s.callsign))
          .where(_looksLikeStation)
          .firstOrNull;
      if (station == null) return;
      _backfillStation = station;
    }
    LogService.instance.add(
        'XPRS catch-up: first-run backfill from $_backfillStation — '
        'up to $backfillMessages messages or '
        '${backfillWindow.inDays} days');
  }

  /// Is this callsign a station worth asking for history?
  ///
  /// Section 3: `X1` is a person, `X3` is a station, relay or unattended
  /// equipment, `X4` an automated device, `X5` a group. The prefix IS the
  /// indicator -- a station says what it is by its name, so no configuration,
  /// no lookup and no extra round trip is needed to decide it is worth asking.
  /// Whether it is ALWAYS ON is a further inference, drawn from its numbers or
  /// answered when asked directly; not knowing that yet is no reason not to
  /// ask, because an archiver with nothing for us answers 404 and costs one
  /// metered packet.
  /// Stations in earshot worth asking for a file, nearest-heard first.
  ///
  /// Same rule as history: `X3` is a station (section 3) and the prefix IS the
  /// indicator. Exposed so the file fetch can reuse the station list this
  /// service already maintains instead of building a second one.
  List<String> stationsInEarshot({int max = 4}) {
    final out = <String>[];
    for (final s in XprsMonitor.instance.stations.values) {
      final base = _base(s.callsign);
      if (base.isEmpty || !_looksLikeStation(base)) continue;
      if (out.contains(base)) continue;
      out.add(base);
      if (out.length >= max) break;
    }
    return out;
  }

  /// Is this callsign a STATION, by the core's one rule?
  ///
  /// This used to be `startsWith('X2') || startsWith('X3')`, which is a
  /// prefix test wearing the name of a kind test, and it had the defect every
  /// such test has here: a station running under its operator's licensed
  /// callsign (`CT1ABC`, XPRS.md 6.4.1) is a station by every definition the
  /// rest of the core uses, and this one never asked it for anything. The
  /// archive it holds was unreachable for the sake of two string prefixes.
  ///
  /// [xprsKindOf] is that rule, and it already answers `station` for a licence
  /// as well as for `X2` and `X3` (xprs_presence.dart:190, pinned by
  /// test/xprs_presence_test.dart).
  static bool _looksLikeStation(String call) =>
      xprsKindOf(call.trim().toUpperCase()) == XprsKind.station;

  /// Open a new window for [archiver], newest first: from the newest edge
  /// already opened (or the mark) to now.
  _Window _openWindow(String archiver, int now, PreferencesService prefs) {
    final wins = _windows.putIfAbsent(archiver, () => []);
    final backfilling = archiver == _backfillStation;
    final window = backfilling ? backfillWindow : maxWindow;
    final floorMs = now - window.inMilliseconds;
    int sinceMs;
    if (backfilling && wins.isEmpty) {
      // The mark is IGNORED here, and that is the point of the backfill.
      //
      // A fresh install plants its watermark at the moment it first ticks --
      // "a fresh install has no hole", above -- which is true of this device's
      // own log and false of the conversation. Every later ask then said
      // `since:<the minute it was installed>`, so a new phone could only ever
      // fetch what was said AFTER it arrived, and Global chat opened empty and
      // stayed that way with nothing anywhere reporting a failure. Flooring at
      // the month would not have helped: the mark is NEWER than the floor, so
      // the floor never applied.
      sinceMs = floorMs;
    } else if (wins.isNotEmpty && !wins.first.answered) {
      // The newest window was never answered at all (silence is evidence about
      // the path, 12.10.2): ask it again, up to now, rather than leave it
      // behind a newer one that nothing would ever go back for.
      sinceMs = wins.removeAt(0).sinceMs;
    } else {
      // since: = THIS station's mark, or the edge of the newest window already
      // open, floored at a week (12.10.1 rule 4). Windows are contiguous, so
      // nothing between two of them goes unasked.
      sinceMs = _edgeMs[archiver] ?? _markFor(archiver, prefs) * 1000;
      if (sinceMs < floorMs) sinceMs = floorMs;
    }
    final w = _Window(sinceMs, endMs: now);
    wins.insert(0, w);
    _edgeMs[archiver] = now;
    // Bounded: the two oldest merge into one window covering both, which
    // re-asks what the newer of them had already been given. Duplicates
    // collapse on their identifiers (11.2.1); a gap would not.
    while (wins.length > _windowsMax) {
      final older = wins.removeLast();
      final newer = wins.removeLast();
      wins.add(_Window(older.sinceMs,
          endMs: newer.endMs, untilMs: newer.untilMs ?? newer.endMs));
    }
    return w;
  }

  Future<void> _ask(String self, String archiver, _Window w, int now) async {
    // An older window is bounded by where the newer one begins; the newest
    // window's first page needs no until:, the station's own now is the edge.
    final untilMs = w.untilMs ?? (w.endMs < now - 1000 ? w.endMs : null);

    // `kind:message` because the archive keeps EVERYTHING heard, beacons
    // included, and a page is twelve records newest-first. Measured on the
    // bench: the newest 200 records of a station's archive were 120 t:identity,
    // 69 t:observation, 11 t:service and no messages at all, so an unfiltered
    // page is twelve identity announcements and the conversation is below the
    // fold — one metered replay spent on nothing.
    //
    // NOT `only:`. That is a CALLSIGN (section 12.6), and an earlier version of
    // this line sent a type in it. Against a station that reads only: as a type
    // it happened to work; against one that reads the spec it matched a callsign
    // named MESSAGE, answered 404, and the watermark advanced as though the
    // window were finished.
    // NOT scope:local. It was, and that pinned the ask to the short-range
    // bearers -- which is right for a station across the room and silently
    // wrong for one across the internet: the reticulum bearer refuses a
    // scope:local packet by design (13.11.3), so the peer was never actually
    // asked and its Global chat never arrived. The ask is DIRECTED (d:), so
    // it costs one packet to one station whichever lane carries it, and the
    // answer comes back on the directed lane too (12.12.1).
    // An archiver asking another archiver also asks for the declarations
    // (12.9.5, `kind:mailbox`): who is cared for by whom is what lets it
    // read its own load, point a newcomer at a peer with room, and route
    // 12.8.1 across the federation. A pocket device asks for messages only.
    // And `moderate`: a removal in the public rooms (10.10.3) is the room's
    // record, and a station that asked only for the messages would keep
    // showing what every station nearer the moderator had taken down.
    // And `file`, between archivers: the records of which files each holds
    // (12.9.2), for the ones a hand-on (12.9.8) missed.
    final kinds = (PreferencesService.instanceSync?.xprsPublicArchiver ?? false)
        ? 'message,moderate,mailbox,file'
        : 'message,moderate';
    final wire = StringBuffer('t:command f:$self d:$archiver ts:${_ts(now)} '
        'cmd:history kind:$kinds since:${_ts(w.sinceMs)}');
    if (untilMs != null) wire.write(' until:${_ts(untilMs)}');
    final p = XprsPacket.parse(wire.toString());
    if (p == null || !p.fits) return;

    // Remember the ask so its result can be judged. The id is computed BEFORE
    // signing (section 5 removes sig: anyway, so it is the same id the
    // archiver derives from the signed wire).
    final id = xprsIdentifier(p);
    if (_pending.length >= _pendingMax) _pending.remove(_pending.keys.first);
    _pending[id] = _Ask(archiver, now, w);
    // This page's count starts empty: the cursor is per ASK, not per chain.
    w.pageOldestMs = null;
    w.pageRows = 0;
    _flight = _Flight(archiver, now, window: w);
    _lastAskMs[archiver] = now;

    final send = sendOverride ?? XprsPublisher.instance.publishWire;
    await send(wire.toString());
  }

  /// Fed every heard t:result (XprsIngest.onResult). Judges the page the
  /// result closes and moves the window, the cursor and the mark.
  void onResult(XprsPacket p) {
    final r = p['r'] ?? '';
    final dirAsk = _directoryPending[r];
    if (dirAsk != null) {
      final code = int.tryParse(p['code'] ?? '') ?? 0;
      if (code == 200 || code == 206 || code == 404 || code == 429) {
        _directoryPending.remove(r);
        _directoryAnswered.add(dirAsk);
      }
    }
    final followAsk = _followPending[r];
    if (followAsk != null) {
      _onFollowResult(r, followAsk, int.tryParse(p['code'] ?? '') ?? 0);
      return;
    }
    final ask = _pending[r];
    if (ask == null) return;
    final code = int.tryParse(p['code'] ?? '') ?? 0;
    final st = ask.station;
    final w = ask.window;

    // 429 does not answer the window -- it stays exactly where it was -- but
    // it is NOT nothing, and treating it as silence is what made a refusal
    // free. The archiver is the authority on how often it will answer, so its
    // refusal is the one answer that must always slow this station down,
    // continuation or not.
    if (code == 429) {
      _pending.remove(r);
      _noteAnswer(st, XprsAnswer.refused);
      final backoff = _intervalMs[st] ?? XprsCadence.initial.inMilliseconds;
      _refusedUntilMs[st] = nowMs() + backoff;
      LogService.instance.add(
          'XPRS catch-up: $st refused (429) — not asked again for '
          '${backoff ~/ 1000}s');
      return;
    }
    if (code != 200 && code != 206 && code != 404) return; // 202: page follows
    _pending.remove(r);

    final rows = w.pageRows;
    final wins = _windows[st];
    w.answered = true;

    if (code == 206) {
      // MORE WAS HELD THAN WAS SERVED. Ask again for what came before the
      // oldest packet this page brought (11.2.1), whoever wrote it, plus the
      // second it sits in: parts of one message share a ts:, and a page that
      // ended inside a set would otherwise lose the rest of it ("repeating a
      // boundary packet is free"). A continuation that reaches back no
      // further than the last one is a loop: the window waits for the next
      // one instead of asking again every few seconds.
      final oldest = w.pageOldestMs;
      final next = oldest == null ? null : (oldest ~/ 1000) * 1000 + 1000;
      final prev = w.untilMs;
      final progressed = next != null && (prev == null || next < prev);
      if (progressed) {
        w.untilMs = next;
        w.stalled = false;
      } else {
        w.stalled = true;
        LogService.instance.add(
            'XPRS catch-up: $st 206 made no progress'
            '${prev == null ? "" : " at ${_ts(prev)}"} — back to the ordinary '
            'cadence');
      }
      _noteAnswer(st, rows > 0 && progressed ? XprsAnswer.news : XprsAnswer.quiet);
      return;
    }

    // 200/404: this window is finished.
    _noteAnswer(st, rows > 0 ? XprsAnswer.news : XprsAnswer.quiet);
    wins?.remove(w);
    if (st == _backfillStation) {
      // The window is finished, which for a backfill means the month is
      // exhausted -- there is no more to have, however few records it was.
      LogService.instance.add(
          'XPRS catch-up: backfill from $st finished with '
          '$_backfillFetched message(s)');
      _backfillStation = null;
    }
    // Only now may the mark move: to the start of the oldest window still
    // open, or, with none open, to the newest edge. Everything before it has
    // been answered for.
    final prefs = PreferencesService.instanceSync;
    if (prefs == null) return;
    final done = (wins == null || wins.isEmpty)
        ? (_edgeMs[st] ?? ask.atMs)
        : wins.map((x) => x.sinceMs).reduce(math.min);
    final sec = done ~/ 1000;
    if (sec > _markFor(st, prefs)) _setMark(st, sec, prefs);
  }

  /// How old a packet must be to count as HISTORY rather than live traffic.
  static const Duration _replayAge = Duration(minutes: 1);

  /// Every packet that came through the receive door, on any lane
  /// (XprsIngest.onHeardAny). While an ask is out, this is how its page is
  /// counted: a replay is the ORIGINAL packets (11.2.1), so a `t:message`
  /// with no `via:`, older than a minute, inside the ask's window, heard
  /// while the ask is out, is one of its rows -- whoever wrote it. The
  /// earlier count used only rows written by the archiver itself, and an old
  /// one of those heard mid-ask moved the cursor hours back over the gap
  /// that held a phone's only reply (the C61, 2026-09-15). A relay or a
  /// custody re-air carries `via:` and is not a replay.
  void noteHeard(XprsPacket p) {
    final f = _flight;
    if (f == null) return;
    final now = nowMs();
    if (now - f.atMs > _inFlightGrace.inMilliseconds) return;
    final ts = xprsParseTs(p['ts']);
    if (ts == null || now - ts < _replayAge.inMilliseconds) return;
    final w = f.window;
    if (w != null) {
      if ((p.type != 'message' && p.type != 'moderate') || p.has('via')) return;
      final top = w.untilMs ?? (w.endMs + 1000);
      if (ts < w.sinceMs - 1000 || ts >= top) return;
      w.pageRows++;
      final o = w.pageOldestMs;
      if (o == null || ts < o) w.pageOldestMs = ts;
      return;
    }
    final station = f.followStation;
    // What counts as the page is what the archiver replayed: an original
    // (no via:) inside the window asked for. Anything else heard meanwhile
    // -- a neighbour's relayed identity, a clockless board's announcement
    // stamped years ago -- is not part of it, and taking its time for "the
    // oldest row" sent the continuation asking for an empty window: the
    // names pull stopped after one page and the groups below it never came.
    if (station != null &&
        (p.has('via') ||
            ts < (f.followSinceMs ?? 0) - 1000 ||
            ts >= (f.followUntilMs ?? now + 1000))) {
      return;
    }
    if (station != null &&
        (_isKind(station)
            ? p.type == station.substring(_kindTarget.length)
            : _isGroup(station)
                // A group's rows are written by its members TO it (`d:`).
                ? (p['d'] ?? '').toUpperCase() == station
                : _base(p['f'] ?? '') == station)) {
      followRows++;
      final k = _fk(station, f.archiver);
      final o = _followOldest[k];
      if (o == null || ts < o) _followOldest[k] = ts;
    }
  }

  // ── Followed stations, fetched from the chosen archivers ─────────────────
  //
  // XPRS.md 12.12.2: on a transport nobody owns there is no broadcast to hear.
  // A device followed by callsign (RnsService.followStation) reaches a station
  // that is out of its earshot only because its controller deposited its
  // observations with an archiver (12.3) and somebody asks that archiver for
  // them, with 12.6's question: `only:` the device, `kind:identity,
  // observation`, `since:` the newest observation already held. What comes
  // back enters through the one receive door like any replay and is kept on
  // the followed shelf (xprsAdmitTier `followedStation`), so no wapp is told
  // any of this happened; it reads what the store holds.

  /// How often one followed station is fetched while somebody is looking at
  /// the screen, and while nobody is (12.10.2: nobody awake, nobody polled
  /// fast). Never faster than the archiver's own floor, which is separate.
  static const Duration followEveryVisible = Duration(minutes: 2);
  static const Duration followEveryHidden = Duration(minutes: 15);

  /// A station never fetched before is fetched this far back; after that,
  /// `since:` is the newest reading held for it.
  static const Duration followFirstWindow = Duration(hours: 24);

  final Map<String, _FollowAsk> _followPending = {};
  final Map<String, int> _followAskedAtMs = {};
  final Map<String, int> _followArchiverAtMs = {};
  final Map<String, int> _followResume = {};
  final Map<String, int> _followOldest = {};
  final Map<String, int> _followLastResume = {};

  /// Counters on /api/status: asks sent, rows they brought, refusals.
  int followAsks = 0, followRows = 0, followRefused = 0;

  /// Is an ask for [key] still out? One past the in-flight grace is not: it
  /// was lost on the way, and treating it as outstanding held that target
  /// back until the pending table happened to overflow -- hours, for a
  /// station that asks little. Its late answer is still taken if it comes.
  bool _followAsking(String key) {
    final now = nowMs();
    for (final a in _followPending.values) {
      if (now - a.atMs > _inFlightGrace.inMilliseconds) continue;
      if (_fk(a.station, a.archiver) == key) return true;
    }
    return false;
  }

  /// The key a fetch's state is kept under. A station's or a type's is the
  /// target alone: whoever answers, the newest held is the newest held. A
  /// group's is per archiver: its talk is spread over the members and
  /// keepers who heard it, and one station's answer says nothing about what
  /// another holds -- the window one closed is still open at the next.
  static String _fk(String target, String archiver) =>
      (_isGroup(target) && !_isKind(target)) || target == namesTarget
          ? '$target@$archiver'
          : target;

  // ── An archiver's directory, asked for when it is not heard (12.9) ───────
  //
  // An archiver names its directory, and in it its groups index (12.9.7), in
  // the `t:service` it airs every ten minutes. Its radio and its LAN carry
  // that; Reticulum and the internet do not, so a station that reaches its
  // archiver only over the internet never read a directory or an index, and
  // the groups ranking stayed empty. The ask is the history replay 12.9.6
  // already uses, for one type from one station: the archiver's own
  // `t:service` of the last hour. The answer enters through the one receive
  // door, where XprsDirectoryConsumer reads a chosen archiver's announcement.

  /// How often one archiver is asked for its directory announcement. Its
  /// index is rebuilt at most every thirty minutes, so a faster ask finds
  /// the same file.
  static const Duration directoryEvery = Duration(minutes: 30);

  /// How soon a directory ask nobody answered is asked again.
  static const Duration directoryRetry = Duration(minutes: 5);

  /// Directory asks in flight, by the ask's identifier, and the archivers
  /// whose last one was answered (200/206/404). Bounded.
  final Map<String, String> _directoryPending = {};
  final Set<String> _directoryAnswered = {};

  /// How far back the ask reaches: a few of its announcements, the newest
  /// of which names the current files.
  static const Duration directoryWindow = Duration(hours: 1);

  final Map<String, int> _directoryAskedAtMs = {};

  /// Directory asks sent (on /api/status with the other counters).
  int directoryAsks = 0;

  static const Set<String> _localBearers = {'ble', 'ble5', 'lan', 'lora'};

  /// Heard lately on a radio or the LAN, where a `t:service` travels.
  bool _inEarshot(String a, int now) {
    if (!XprsMonitor.instance.heardDirectly(a, nowMs: now)) return false;
    final st = XprsMonitor.instance.stations[a];
    return st != null && _localBearers.contains(st.bearer);
  }

  Future<void> _askDirectories(
      String self, List<String> archivers, int now) async {
    // The one asked longest ago first (never asked: first of all, in the
    // order given). One ask goes out a sweep and the first in the list comes
    // due again every half hour, so taken in order it was asked for ever and
    // the third never.
    final order = [...archivers];
    int at(String a) => _directoryAskedAtMs[a] ?? 0;
    order.sort((x, y) {
      final c = at(x).compareTo(at(y));
      return c != 0 ? c : archivers.indexOf(x).compareTo(archivers.indexOf(y));
    });
    for (final a in order) {
      if (_busy(now)) return;
      if ((_refusedUntilMs[a] ?? 0) > now) continue;
      // In earshot, the air already brings its announcement: it rides the
      // archiver's radio and LAN only. Heard over the internet is not
      // earshot. Counted as such, an archiver that had just answered an ask
      // over Reticulum was never asked for its directory at all, and the
      // groups ranking of a station far from it stayed empty.
      if (_inEarshot(a, now)) continue;
      // Answered: not again for the half hour. Not answered: again after
      // [directoryRetry]. An answer can be lost on the way (12.10.2: silence
      // is evidence about the path), and waiting the half hour for one that
      // never came is how a fresh station's groups stayed empty for the
      // length of a test while the archiver had answered.
      final wait = _directoryAnswered.contains(a) ? directoryEvery : directoryRetry;
      if (now - (_directoryAskedAtMs[a] ?? 0) < wait.inMilliseconds) {
        continue;
      }
      _directoryAskedAtMs[a] = now;
      _directoryAnswered.remove(a);
      directoryAsks++;
      final wire = 't:command f:$self d:$a ts:${_ts(now)} '
          'cmd:history kind:service only:$a '
          'since:${_ts(now - directoryWindow.inMilliseconds)}';
      final asked = XprsPacket.parse(wire);
      if (asked != null) {
        if (_directoryPending.length >= 32) {
          _directoryPending.remove(_directoryPending.keys.first);
        }
        _directoryPending[xprsIdentifier(asked)] = a;
      }
      final send = sendOverride ?? XprsPublisher.instance.publishWire;
      await send(wire);
      LogService.instance.add('XPRS: asked $a for its directory (12.9)');
      // One ask per sweep: the archivers are few and the period is long.
      return;
    }
  }

  // ── Names: every identity an archiver holds, asked of each archiver from
  // where its last answer ended (a mark per archiver, persisted: a restart
  // must not ask a big archiver for every name it holds again). What Search
  // shows of people, stations and groups this station never heard.
  static const String namesTarget = 'kind:identity';

  /// A names pull is a background refresh: identities are re-announced every
  /// half hour (29.1) and a group's once a day, so a faster ask finds nothing.
  static const Duration namesEvery = Duration(minutes: 30);

  /// How far back the first names ask of an archiver reaches. A station's
  /// identity is re-announced and a group's is announced when it is made, so
  /// a group made last spring is only found by reaching back to it; the
  /// archive keeps at most four identity rows per callsign, so the answer is
  /// bounded by how many callsigns the archiver knows, not by time.
  static const Duration namesFirstWindow = Duration(days: 365);

  static String _namesMarkKey(String archiver) => 'names@$archiver';

  /// Names asks the archiver answered (200/206/404), by [_fk]. Only an
  /// answered ask earns the half-hour period: one lost on the way is asked
  /// again at the followed pace, or a person who opened Search waits half an
  /// hour for a packet that never arrived (12.10.2: silence is evidence about
  /// the path, not the room).
  final Set<String> _namesAnswered = {};

  // ── Followed types (hal_xprs_follow_kind): the same fetch, for a packet
  // TYPE rather than a station. A target is a callsign or `kind:<type>`; a
  // type's ask is `cmd:history kind:<type> since:<newest of it held>`, from
  // anyone, and what comes back joins what this station heard itself in the
  // one archive (xprsAdmitTier `followedKind`), one row per packet.
  static const String _kindTarget = 'kind:';
  static bool _isKind(String target) => target.startsWith(_kindTarget);

  Future<void> _pullFollowed(String self, List<String> archivers, int now,
      PreferencesService prefs, {bool groups = false, bool names = false}) async {
    final followed = names
        ? const <String>[namesTarget]
        : groups
        ? <String>[
            // The closed groups we are in: what was said while we were away,
            // or before we joined, is held by the other members (26.4).
            ...XprsGroups.instance.memberGroups(_base(self)),
            // And the open groups this station follows (7.3): somebody who
            // joins one sees what was said before they came.
            ...XprsArchive.instance.followedGroups,
          ]
        : <String>[
            ...XprsArchive.instance.followedStations,
            for (final k in XprsIngest.policy.followedKinds) '$_kindTarget$k',
          ];
    if (followed.isEmpty || archivers.isEmpty || _busy(now)) return;
    final followEvery =
        (_visible ? followEveryVisible : followEveryHidden).inMilliseconds;
    final asked = <String>[];
    for (final a in archivers) {
      // One ask out at a time (see [_flight]), and never faster than the
      // floor that archiver permits or before its refusal expires.
      if (_busy(now)) break;
      if ((_refusedUntilMs[a] ?? 0) > now) continue;
      // Due at this archiver: out of earshot (in earshot the air already
      // carries it) and either not fetched from it within the period or owed
      // the rest of a 206 page. The longest-waiting first, so one target
      // never starves behind another.
      final due = [
        for (final c in followed)
          // A type is never "in earshot": the air carries what is near, an
          // archiver what was said further away while we were not listening.
          if ((_isKind(c) ||
                  !XprsMonitor.instance.heardDirectly(c, nowMs: now)) &&
              !_followAsking(_fk(c, a)) &&
              (_followResume.containsKey(_fk(c, a)) ||
                  now - (_followAskedAtMs[_fk(c, a)] ?? 0) >=
                      (names && _namesAnswered.contains(_fk(c, a))
                          ? namesEvery.inMilliseconds
                          : followEvery)))
            c
      ]..sort((x, y) => (_followAskedAtMs[_fk(x, a)] ?? 0)
          .compareTo(_followAskedAtMs[_fk(y, a)] ?? 0));
      if (due.isEmpty) continue;
      // A person who just joined or opened a group is waiting for it: that
      // one ask is theirs, not the background's, and goes past the floor
      // once. A refusal still stands.
      final urgent = due.where(_urgent.contains).toList();
      final last = math.max(_lastAskMs[a] ?? 0, _followArchiverAtMs[a] ?? 0);
      if (urgent.isEmpty && last != 0 && now - last < _floorMsFor(a, prefs)) {
        continue;
      }
      final station = urgent.isNotEmpty ? urgent.first : due.first;
      if (await _askFollowed(self, a, station, now)) {
        asked.add('$station@$a');
        // A group is urgent until every station in the list was asked once:
        // the first to answer may hold only part of what was said.
        if ((!_isGroup(station) && station != namesTarget) ||
            archivers.every((b) => _followAskedAtMs.containsKey(_fk(station, b)))) {
          _urgent.remove(station);
        }
      }
    }
    if (asked.isNotEmpty) {
      LogService.instance
          .add('XPRS: fetching followed ${asked.join(", ")}');
    }
  }

  Future<bool> _askFollowed(
      String self, String archiver, String station, int now) async {
    final kind = _isKind(station) ? station.substring(_kindTarget.length) : null;
    final group = kind == null && _isGroup(station);
    final names = station == namesTarget;
    final k = _fk(station, archiver);
    final namesMark = names
        ? PreferencesService.instanceSync?.xprsCatchupMarks[
            _namesMarkKey(archiver)]
        : null;
    final held = names
        ? (namesMark == null ? null : namesMark * 1000)
        : group
            ? _groupMark[k]
            : kind != null
                ? XprsArchive.instance.newestPtsOfType(kind)
                : XprsArchive.instance.newestPts(station, types: const ['observation']);
    // Names reach back as far as [namesFirstWindow]: 12.10.1 rule 4's week is
    // for conversation, and this is the deliberate fetch it leaves room for.
    final floorMs = now -
        (names ? namesFirstWindow : maxWindow).inMilliseconds;
    // A type never fetched reaches back the whole background window: what
    // was announced this week is what a person opening the wapp wants.
    var sinceMs = held ??
        now -
            (names
                    ? namesFirstWindow
                    : kind != null || group
                        ? maxWindow
                        : followFirstWindow)
                .inMilliseconds;
    if (sinceMs < floorMs) sinceMs = floorMs;
    final untilMs = _followResume[k];
    // A station: identity first, since the observations verify against a key
    // that may ride the same page (the order XprsGossip.askAlwaysOn uses).
    final wire = StringBuffer('t:command f:$self d:$archiver ts:${_ts(now)} '
        '${kind != null ? 'cmd:history kind:$kind' : group ? 'cmd:history kind:$_groupKinds only:$station' : 'cmd:history kind:identity,observation only:$station'} '
        'since:${_ts(sinceMs)}');
    if (untilMs != null) wire.write(' until:${_ts(untilMs)}');
    final p = XprsPacket.parse(wire.toString());
    if (p == null || !p.fits) return false;
    final id = xprsIdentifier(p);
    if (_followPending.length >= _pendingMax) {
      _followPending.remove(_followPending.keys.first);
    }
    _followPending[id] = _FollowAsk(archiver, station, now);
    if (names) _namesAnswered.remove(k);
    _followAskedAtMs[k] = now;
    _followArchiverAtMs[archiver] = now;
    _flight = _Flight(archiver, now,
        followStation: station, followSinceMs: sinceMs, followUntilMs: untilMs);
    _followOldest.remove(k);
    followAsks++;
    final send = sendOverride ?? XprsPublisher.instance.publishWire;
    await send(wire.toString());
    return true;
  }

  void _onFollowResult(String r, _FollowAsk ask, int code) {
    if (code == 429) {
      _followPending.remove(r);
      followRefused++;
      // The archiver's authority over our cadence (12.10.2), whoever asked.
      _noteAnswer(ask.archiver, XprsAnswer.refused);
      _refusedUntilMs[ask.archiver] = nowMs() +
          (_intervalMs[ask.archiver] ?? XprsCadence.initial.inMilliseconds);
      return;
    }
    if (code != 200 && code != 206 && code != 404) return; // 202: page follows
    _followPending.remove(r);
    _land(ask.archiver);
    final k = _fk(ask.station, ask.archiver);
    if (ask.station == namesTarget) _namesAnswered.add(k);
    if (code == 206) {
      // More held than served: ask for what came before the oldest row this
      // page brought. A continuation that reaches back no further than the
      // last one is a loop, and is dropped back to the period.
      final oldest = _followOldest[k];
      if (oldest == null || oldest == _followLastResume[k]) {
        _followResume.remove(k);
        _followLastResume.remove(k);
      } else {
        _followResume[k] = oldest;
        _followLastResume[k] = oldest;
      }
      return;
    }
    _followResume.remove(k);
    _followLastResume.remove(k);
    // A group's window at THIS archiver is closed: the next ask of it starts
    // where this one did. Another archiver's window stays its own.
    if (_isGroup(ask.station) && ask.atMs > 0) {
      _groupMark[k] = ask.atMs;
    }
    final prefs = PreferencesService.instanceSync;
    if (ask.station == namesTarget && ask.atMs > 0 && prefs != null) {
      _setMark(_namesMarkKey(ask.archiver), ask.atMs ~/ 1000, prefs);
    }
  }

  // ── A closed group we belong to, fetched like a followed station: its
  // messages, reactions and acts (`only:<X5>`), from the members in reach,
  // who serve them to a fellow member (XprsHistoryServer._fellowMember). The
  // mark is the last answered ask; in memory, so a restart reaches back a
  // week again and the archive's dedup absorbs what is already held.
  static const String _groupKinds = 'identity,moderate,message,reaction';
  final Map<String, int> _groupMark = {};
  static bool _isGroup(String c) =>
      c.startsWith('X5') || XprsArchive.instance.followedGroups.contains(c);

  static String _base(String c) {
    final i = c.indexOf('-');
    return (i < 0 ? c : c.substring(0, i)).toUpperCase();
  }

  static String _ts(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}_'
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}


/// One outstanding ask: which archiver, when, and the window it pages.
class _Ask {
  const _Ask(this.station, this.atMs, this.window);
  final String station;
  final int atMs;
  final _Window window;
}

/// A span of an archiver's history this station still owes itself:
/// [sinceMs, endMs), paged newest first. [untilMs] is where the last page
/// stopped (null before the first page), and the next ask continues below it.
class _Window {
  _Window(this.sinceMs, {required this.endMs, this.untilMs});
  final int sinceMs;
  final int endMs;
  int? untilMs;
  bool stalled = false;

  /// Some page of it was answered (200, 206 or 404).
  bool answered = false;

  /// The page being answered now: how many of its rows arrived, and the
  /// oldest `ts:` among them.
  int pageRows = 0;
  int? pageOldestMs;
}

/// The ask that is out: to whom, since when, and what it asked for, a
/// window of messages or one followed station.
class _Flight {
  _Flight(this.archiver, this.atMs,
      {this.window, this.followStation, this.followSinceMs, this.followUntilMs});
  final String archiver;
  final int atMs;
  final _Window? window;
  final String? followStation;

  /// The window a followed ask named: a row outside it is not on its page.
  final int? followSinceMs;
  final int? followUntilMs;
}

/// One outstanding fetch of a followed station: which archiver, for whom.
class _FollowAsk {
  const _FollowAsk(this.archiver, this.station, [this.atMs = 0]);
  final String archiver;
  final String station;
  final int atMs;
}
