/*
 * xprs_qos — sharing a constrained bearer's airtime (spec QoS.md).
 *
 * ../spec/QoS.md is the rulebook and this file implements it; where the two
 * disagree the document wins and this file is the bug. Section numbers below
 * are QoS.md's unless they say XPRS.md.
 *
 * A digipeater on a slow channel cannot repeat everything it hears. XPRS.md
 * fixes what MAY be relayed and in what order; QoS.md fixes what a station
 * ADMITS onto a constrained bearer and how it SPENDS the hour:
 *
 *   4.1  one budget per bearer, a rolling hour, every transmission charged;
 *   4.2  a tenth reserved, always, for the owner and for calls for help:
 *        third parties stop at 90%, the owner at 98%, sos/warning at 100%;
 *   4.3  the airing order: sos/warning, owner, first:, urg:, oldest ts:;
 *   4.4  admission by class: only what somebody on the bearer waits for;
 *   4.5  a periodic packet ("I am still here") no more often than the
 *        bearer's repeat interval, per author and type: 5 min on the short
 *        bearers, 30 on LoRa, 60 when the channel is crowded;
 *   4.6  max-min fair share among third parties;
 *   4.7  at most a tenth of the budget in any six minutes (L2-L6), and bulk
 *        only while more than 60% is unspent;
 *   4.8  expiry per class, eviction lowest class first.
 *
 * ── Shape ───────────────────────────────────────────────────────────────────
 *
 * Pure decisions with injected facts: no timer, no radio, no clock of its own
 * (the caller passes `nowMs` in [XprsQosContext]), no `dart:io`. So the same
 * code runs in the app, the server, the web build and the replay harness
 * (test/xprs_qos_replay_test.dart), and a day of traffic replays in a second.
 *
 * Three layers, take what you need:
 *
 *   [XprsQosProfile]  the numbers for one kind of bearer (section 6);
 *   [XprsQosGate]     admission (4.4, 4.5), the budget (4.1, 4.2, 4.6, 4.7)
 *                     and the record of what was aired — for a caller that
 *                     keeps its own queue (the digipeater, the publisher);
 *   [XprsQosQueue]    the gate plus a bounded queue in 4.3 order with 4.8's
 *                     expiry and eviction — for a bearer that needs the
 *                     component to decide what goes next (a metered radio).
 *
 * Memory is bounded (performance.md 8): every table has a cap and evicts its
 * least recently used rows.
 */
library;

import 'dart:math' as math;

import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_vocab.dart';

/// The admission classes of QoS.md 4.4, highest first. The index is the
/// eviction order: a higher index goes first.
enum XprsQosClass { life, owner, conversation, transaction, keys, presence, bulk }

/// Why a packet was not carried on a bearer (QoS.md 5), or [none].
enum XprsQosShed {
  none,

  /// scope:local, or a scope word nobody knows (XPRS.md 9.11).
  scope,

  /// A periodic packet sooner than the repeat interval (4.5).
  repeat,

  /// Addressed to somebody heard on a cheaper bearer (4.4).
  reached,

  /// A command/result/request for somebody not heard on this bearer (4.4).
  notHere,

  /// Older than the profile's freshness and no spare capacity for bulk.
  oldNews,

  /// Aired on this bearer in the last 30 minutes (4.4).
  aired,

  /// Its author is over its fair share (4.6).
  fairShare,

  /// The hour's budget, the reserve or the six-minute pace (4.2, 4.7).
  budget,

  /// Expired in the queue (4.8).
  expired,

  /// Pushed out of a full queue (4.8).
  evicted,
}

/// Seconds of a LoRa transmission (Semtech AN1200.13), for [bytes] of
/// physical payload, explicit header, CRC on.
int xprsLoraAirtimeMs(int bytes,
    {required int sf, required int bwHz, int cr = 5, int preamble = 8}) {
  final tSym = (1 << sf) / bwHz * 1000.0; // ms
  final de = tSym >= 16.0 ? 1 : 0; // low data rate optimisation
  final num = 8 * bytes - 4 * sf + 28 + 16;
  final den = 4 * (sf - 2 * de);
  final payloadSym = 8 + math.max((num / den).ceil() * cr, 0);
  return ((preamble + 4.25) * tSym + payloadSym * tSym).ceil();
}

/// The numbers for one kind of bearer (QoS.md section 6). The rules are the
/// same for every profile; only these differ.
class XprsQosProfile {
  const XprsQosProfile({
    required this.name,
    required this.bearer,
    this.budgetMsHour = 0,
    this.reserve = 0.10,
    this.lifeSlice = 0.02,
    this.repeatOrdinary = const Duration(minutes: 30),
    this.repeatCrowded = const Duration(minutes: 60),
    this.crowdedStations = 8,
    this.crowdedUtilisation = 0.25,
    this.freshTransaction = const Duration(minutes: 30),
    this.freshBulk = const Duration(minutes: 30),
    this.bulkOn = true,
    this.fairMinDivisor = 4,
    this.paceShare = 0.10,
    this.paceWindow = const Duration(minutes: 6),
    this.bulkMinFree = 0.60,
    this.backgroundPace = 0.5,
    this.queueMax = 16,
    this.airtimeMs,
  });

  final String name;

  /// The lane this profile describes, by the names `xprsBearerReach` reads
  /// (its 9.11 class decides what scopes it may carry).
  final String bearer;

  /// Transmit milliseconds per rolling hour; 0 is unmetered, which is a real
  /// answer: such a bearer is subject to scope, duplicates and repeats only.
  final int budgetMsHour;

  /// 4.2: the owner's reserve, and the final slice only sos/warning spend.
  final double reserve, lifeSlice;

  /// 4.5: the repeat interval, ordinary and crowded, and what "crowded" is.
  final Duration repeatOrdinary, repeatCrowded;
  final int crowdedStations;
  final double crowdedUtilisation;

  /// 4.4: how old a ts: may be before the packet is news nobody waits for.
  final Duration freshTransaction, freshBulk;

  /// Whether bulk (history, file chunks, catch-up, old news) is ever carried.
  final bool bulkOn;

  /// 4.6: the fair-share divisor never goes below this.
  final int fairMinDivisor;

  /// 4.7: at most [paceShare] of the budget in any [paceWindow] for L2-L6,
  /// and bulk only while more than [bulkMinFree] of it is unspent.
  final double paceShare;
  final Duration paceWindow;
  final double bulkMinFree;

  /// 4.7: the share of the pace keys, presence and bulk may use.
  final double backgroundPace;

  /// 4.8: the queue's size, for [XprsQosQueue].
  final int queueMax;

  /// Transmit time of a wire of this many bytes; null = unmetered.
  final int Function(int bytes)? airtimeMs;

  bool get metered => budgetMsHour > 0 && airtimeMs != null;

  /// Bluetooth, LAN, ESP-NOW: no budget, 5-minute repeats (section 6).
  const XprsQosProfile.unmetered(String bearer)
      : this(
            name: bearer,
            bearer: bearer,
            repeatOrdinary: const Duration(minutes: 5),
            repeatCrowded: const Duration(minutes: 5));

  /// LoRa on Meshtastic's EU LongFast (869.525 MHz, SF11, 250 kHz, CR 4/5,
  /// preamble 16), XPRS inside Meshtastic frames: a 16-byte header each, a
  /// wire over 220 bytes in two frames (mt_xprs_wrap). 360 s an hour, the
  /// 10% of the 869.4-869.65 MHz sub-band.
  static final loraLongFast = XprsQosProfile(
      name: 'lora-meshtastic',
      bearer: 'lora',
      budgetMsHour: 360000,
      airtimeMs: (n) {
        int frame(int b) =>
            xprsLoraAirtimeMs(b + 16, sf: 11, bwHz: 250000, preamble: 16);
        return n <= 220 ? frame(n) : frame(220) + frame(n - 220);
      });

  /// LoRa on XPRS's own channel (869.5 MHz, SF7, 125 kHz, preamble 8).
  static final loraXprs = XprsQosProfile(
      name: 'lora-xprs',
      bearer: 'lora',
      budgetMsHour: 360000,
      airtimeMs: (n) => xprsLoraAirtimeMs(n, sf: 7, bwHz: 125000));

  /// LoRa on a 1% sub-band: 36 s an hour, longer repeats, no bulk.
  static final lora1pct = XprsQosProfile(
      name: 'lora-1pct',
      bearer: 'lora',
      budgetMsHour: 36000,
      repeatOrdinary: const Duration(minutes: 60),
      repeatCrowded: const Duration(minutes: 120),
      bulkOn: false,
      airtimeMs: (n) => xprsLoraAirtimeMs(n, sf: 11, bwHz: 125000));

  /// APRS on VHF/UHF at 1200 bd, 300 ms of TX delay per frame; the budget is
  /// the local band plan's, 10% until an operator says otherwise.
  static final aprs1200 = XprsQosProfile(
      name: 'aprs-1200',
      bearer: 'vhf',
      budgetMsHour: 360000,
      bulkOn: false,
      airtimeMs: (n) => 300 + (n + 20) * 8 * 1000 ~/ 1200);

  /// The profile for a lane this core transmits on, or null for one QoS does
  /// not govern (Reticulum and the line lane: directed internet links, not a
  /// shared broadcast medium).
  static XprsQosProfile? forBearer(String bearer) {
    switch (bearer.trim().toLowerCase()) {
      case 'ble':
      case 'ble5':
        return const XprsQosProfile.unmetered('ble5');
      case 'lan':
        return const XprsQosProfile.unmetered('lan');
      case 'espnow':
        return const XprsQosProfile.unmetered('espnow');
      case 'lora':
        return loraLongFast;
      case 'vhf':
      case 'uhf':
        return aprs1200;
      default:
        return null;
    }
  }
}

/// What the caller knows about a packet and the bearer right now. The
/// component asks nothing else and reads no clock.
class XprsQosContext {
  const XprsQosContext({
    required this.nowMs,
    this.heardOn,
    this.own = false,
    this.fromOwner = false,
    this.first = const {},
    this.reachedCheaper,
    this.heardHere,
    this.clockEpochS,
    this.stationsHeard = 0,
    this.utilisation = 0,
  });

  final int nowMs;

  /// The bearer it arrived on; null for a packet this station originates.
  final String? heardOn;

  /// Signed by this station (QoS.md 2: owner traffic).
  final bool own;

  /// From one of this station's owners, handed to it directly (no `via:`,
  /// a short-range bearer). A relayed packet claiming an owner's `f:` is
  /// third-party traffic, which is the caller's to decide.
  final bool fromOwner;

  /// The policy's `first:` (XPRS.md 11.10), base callsigns, upper case.
  final Set<String> first;

  /// Was [call] heard directly on a CHEAPER bearer lately? Then a packet
  /// addressed to it reached it already (4.4).
  final bool Function(String call)? reachedCheaper;

  /// Was [call] heard directly on THIS bearer lately? A transaction goes on
  /// a metered bearer only for such a destination (4.4).
  final bool Function(String call)? heardHere;

  /// UTC seconds now, or null for a station with no clock (then "now" is the
  /// newest `ts:` the gate has seen lately).
  final int? clockEpochS;

  /// 4.5's crowding inputs: stations heard directly on this bearer in the
  /// last ten minutes, and the channel's utilisation, 0..1.
  final int stationsHeard;
  final double utilisation;
}

/// The verdict on one packet for one bearer.
class XprsQosDecision {
  const XprsQosDecision(this.cls, this.shed);
  final XprsQosClass cls;
  final XprsQosShed shed;
  bool get admitted => shed == XprsQosShed.none;
  @override
  String toString() => admitted ? 'admit ${cls.name}' : 'shed ${shed.name}';
}

/// The periodic types of QoS.md 2: content that is mostly "I am still here".
/// Not `status`: it carries a person's words and every one is new.
const Set<String> kXprsQosPeriodic = {'observation', 'service', 'identity', 'track'};

const Set<String> _transaction = {'command', 'result', 'request'};
const Set<String> _bulkTypes = {'mailbox'};

/// QoS.md 4.4: the class of [p] as [c] sees it. Old news (4.4) is decided
/// by the gate, which knows the clock; this is the packet alone.
XprsQosClass xprsQosClassify(XprsPacket p, XprsQosContext c) {
  final t = p.type;
  if (t == 'sos' || t == 'warning') return XprsQosClass.life;
  if (c.own || c.fromOwner) return XprsQosClass.owner;
  if (t == 'identity') return XprsQosClass.keys;
  if (t == 'observation' || t == 'service' || t == 'track') {
    return XprsQosClass.presence;
  }
  // An ask (cmd:history included) is a transaction: somebody waits for the
  // answer. What it brings back is bulk by its age -- a replay is the
  // original packets, old ts: and all -- which the gate decides (4.4).
  if (_transaction.contains(t)) return XprsQosClass.transaction;
  if (_bulkTypes.contains(t)) return XprsQosClass.bulk;
  return XprsQosClass.conversation;
}

/// Rank of an `urg:` value for 4.3, lower first; a stranger's counted no
/// higher than `high` (XPRS.md 9.5).
int xprsQosUrgRank(String? urg, {required bool stranger}) {
  switch (urg) {
    case 'urgent':
      return stranger ? 1 : 0;
    case 'high':
      return 1;
    case 'low':
      return 3;
    default:
      return 2;
  }
}

/// One transmission in the rolling hour (4.1): exact times, so the hour and
/// the six-minute pace are measured as QoS.md states them. Minute buckets
/// were tried first and the harness caught them: a six-minute check that
/// starts at a minute boundary misses up to a minute of earlier sends, and
/// the replay put 61 s of third-party airtime in six minutes against 36.
class _Tx {
  _Tx(this.t, this.ms, this.paced, this.author);
  final int t, ms;
  final bool paced; // L2-L6
  final String author; // third-party author, '' otherwise
}

/// The rolling hour. Bounded by the budget itself -- a bearer cannot fit
/// more than budget/shortest-frame transmissions in an hour -- and capped
/// besides.
class _Ledger {
  final List<_Tx> _log = [];
  static const int cap = 4096;

  void _prune(int nowMs) {
    var i = 0;
    while (i < _log.length && nowMs - _log[i].t >= 3600000) {
      i++;
    }
    if (i > 0) _log.removeRange(0, i);
    if (_log.length > cap) _log.removeRange(0, _log.length - cap);
  }

  void add(_Tx tx) {
    _log.add(tx);
    _prune(tx.t);
  }

  int total(int nowMs, {int windowMs = 3600000}) {
    _prune(nowMs);
    var s = 0;
    for (var i = _log.length - 1; i >= 0 && nowMs - _log[i].t < windowMs; i--) {
      s += _log[i].ms;
    }
    return s;
  }

  int paced(int nowMs, int windowMs) {
    _prune(nowMs);
    var s = 0;
    for (var i = _log.length - 1; i >= 0 && nowMs - _log[i].t < windowMs; i--) {
      if (_log[i].paced) s += _log[i].ms;
    }
    return s;
  }

  /// Third-party airtime this hour, per author.
  Map<String, int> byAuthor(int nowMs) {
    _prune(nowMs);
    final m = <String, int>{};
    for (final tx in _log) {
      if (tx.author.isNotEmpty) m[tx.author] = (m[tx.author] ?? 0) + tx.ms;
    }
    return m;
  }

  void clear() => _log.clear();
}

/// Bounded least-recently-used map.
class _Lru<V> {
  _Lru(this.cap);
  final int cap;
  final Map<String, V> _m = {};
  V? operator [](String k) {
    final v = _m.remove(k);
    if (v != null) _m[k] = v;
    return v;
  }

  void operator []=(String k, V v) {
    _m.remove(k);
    _m[k] = v;
    if (_m.length > cap) _m.remove(_m.keys.first);
  }

  Iterable<MapEntry<String, V>> get entries => _m.entries;
  int get length => _m.length;
  void clear() => _m.clear();
}

class _Last {
  _Last(this.ms, this.k);
  final int ms;
  final String k;
}

/// Counters per class (QoS.md 5).
class _ClassCount {
  int offered = 0, admitted = 0, aired = 0;
  final Map<XprsQosShed, int> shed = {};
  Map<String, dynamic> get json => {
        'offered': offered,
        'admitted': admitted,
        'aired': aired,
        if (shed.isNotEmpty) 'shed': {for (final e in shed.entries) e.key.name: e.value},
      };
}

/// Admission, budget and the record of what went out, for one bearer.
class XprsQosGate {
  XprsQosGate(this.profile);
  final XprsQosProfile profile;

  /// 4.4: "not twice in half an hour".
  static const int airedMs = 30 * 60000;

  /// A scheduler's own drift is not a repeat: a beacon on a 300 s timer must
  /// not be shed for firing at 299.8 s. 5% of the interval (QoS.md 4.5).
  static const double repeatSlack = 0.05;

  final _Ledger _ledger = _Ledger();
  final _Lru<_Last> _repeat = _Lru(256); // author|type -> last aired
  final _Lru<int> _airedIds = _Lru(256); // identifier -> when
  int _newestTs = 0, _newestTsAtMs = 0; // for a clockless "now"
  int reserveLowMs = -1; // the reserve's low-water mark, for the harness

  final Map<XprsQosClass, _ClassCount> _count = {
    for (final c in XprsQosClass.values) c: _ClassCount()
  };

  bool crowded(XprsQosContext c) =>
      c.stationsHeard >= profile.crowdedStations ||
      c.utilisation > profile.crowdedUtilisation;

  Duration repeatInterval(XprsQosContext c) =>
      crowded(c) ? profile.repeatCrowded : profile.repeatOrdinary;

  /// UTC seconds now, as well as this station can say (4.4: with no clock,
  /// "now" is the newest `ts:` heard lately).
  int? _nowS(XprsQosContext c) {
    if (c.clockEpochS != null) return c.clockEpochS;
    if (_newestTs == 0) return null;
    return _newestTs + (c.nowMs - _newestTsAtMs) ~/ 1000;
  }

  void _noteTs(XprsPacket p, XprsQosContext c) {
    final ts = xprsTsEpoch(p['ts']);
    if (ts == null) return;
    if (_newestTs == 0 || ts > _newestTs || c.nowMs - _newestTsAtMs > 600000) {
      _newestTs = ts;
      _newestTsAtMs = c.nowMs;
    }
  }

  /// QoS.md 4.4 and 4.5: may [p] enter this bearer at all? No state changes
  /// but the counters and the clockless "now" (a packet heard is evidence of
  /// the time whether or not it is carried).
  XprsQosDecision admit(XprsPacket p, XprsQosContext c, {bool count = true}) {
    _noteTs(p, c);
    final d = _decide(p, c, xprsQosClassify(p, c));
    if (count) {
      final k = _count[d.cls]!;
      k.offered++;
      if (d.admitted) {
        k.admitted++;
      } else {
        k.shed[d.shed] = (k.shed[d.shed] ?? 0) + 1;
      }
    }
    return d;
  }

  XprsQosDecision _decide(XprsPacket p, XprsQosContext c, XprsQosClass cls) {
    XprsQosDecision shed(XprsQosShed why) => XprsQosDecision(cls, why);
    const ok = XprsQosShed.none;

    // Scope binds every bearer and every class, sos included: a local call
    // for help is for the room (XPRS.md 9.11).
    if (!xprsReachAdmits(xprsScopeReach(p), xprsBearerReach(profile.bearer))) {
      return shed(XprsQosShed.scope);
    }
    if (cls == XprsQosClass.life) return XprsQosDecision(cls, ok);

    // 4.5, owner traffic included: our own beacon is a beacon.
    if (kXprsQosPeriodic.contains(p.type) && !_repeatDue(p, c)) {
      return shed(XprsQosShed.repeat);
    }
    if (cls == XprsQosClass.owner) return XprsQosDecision(cls, ok);

    final dest = (p['d'] ?? '').trim().toUpperCase();
    if (dest.isNotEmpty && (c.reachedCheaper?.call(dest) ?? false)) {
      return shed(XprsQosShed.reached);
    }
    if (!profile.metered) return XprsQosDecision(cls, ok);

    // ── Constrained bearers only from here ───────────────────────────────
    if (cls == XprsQosClass.transaction &&
        !(dest.isNotEmpty && (c.heardHere?.call(dest) ?? false))) {
      return shed(XprsQosShed.notHere);
    }
    final id = xprsIdentifier(p);
    final at = _airedIds[id];
    if (id.isNotEmpty && at != null && c.nowMs - at < airedMs) {
      return shed(XprsQosShed.aired);
    }
    // Old news is bulk; bulk only on spare capacity (4.4, 4.7).
    final now = _nowS(c);
    final ts = xprsTsEpoch(p['ts']);
    var bulk = cls == XprsQosClass.bulk;
    if (!bulk && now != null && ts != null) {
      final fresh = cls == XprsQosClass.transaction
          ? profile.freshTransaction
          : profile.freshBulk;
      if (now - ts > fresh.inSeconds) bulk = true;
    }
    if (bulk) {
      final free = 1 - _ledger.total(c.nowMs) / profile.budgetMsHour;
      if (!profile.bulkOn || crowded(c) || free <= profile.bulkMinFree) {
        return XprsQosDecision(XprsQosClass.bulk, XprsQosShed.oldNews);
      }
      return const XprsQosDecision(XprsQosClass.bulk, XprsQosShed.none);
    }
    return XprsQosDecision(cls, ok);
  }

  bool _repeatDue(XprsPacket p, XprsQosContext c) {
    final author = (p['f'] ?? '').trim().toUpperCase();
    final last = _repeat['$author|${p.type}'];
    if (last == null) return true;
    // A real change is not a repeat: an identity with another key (XPRS.md
    // 29.1) goes out at once.
    if (p.type == 'identity' && (p['k'] ?? '') != last.k) return true;
    final need = repeatInterval(c).inMilliseconds * (1 - repeatSlack);
    return c.nowMs - last.ms >= need;
  }

  /// 4.2, 4.6, 4.7: may a packet of [cls] by [author], [bytes] long, go out
  /// now? [XprsQosShed.none] when it may.
  XprsQosShed mayAir(XprsQosClass cls, String author, int bytes, int nowMs) {
    if (!profile.metered) return XprsQosShed.none;
    final air = profile.airtimeMs!(bytes);
    final budget = profile.budgetMsHour;
    final spent = _ledger.total(nowMs);
    switch (cls) {
      case XprsQosClass.life:
        return spent + air <= budget ? XprsQosShed.none : XprsQosShed.budget;
      case XprsQosClass.owner:
        return spent + air <= budget * (1 - profile.lifeSlice)
            ? XprsQosShed.none
            : XprsQosShed.budget;
      default:
        if (spent + air > budget * (1 - profile.reserve)) {
          return XprsQosShed.budget;
        }
        // Background traffic (keys, presence, bulk) has only the first half
        // of the pace, so the second half is always there for conversation
        // and transactions. The order of 4.3 is not touched -- it is XPRS.md
        // 11.10's -- but an old-ts: replay sorts ahead of a fresh message by
        // that order, and the harness measured messages waiting 5 minutes
        // behind history pages until this was added.
        final pace = budget *
            profile.paceShare *
            (cls.index >= XprsQosClass.keys.index ? profile.backgroundPace : 1);
        if (_ledger.paced(nowMs, profile.paceWindow.inMilliseconds) + air > pace) {
          return XprsQosShed.budget;
        }
        if (author.isNotEmpty && _authorSpent(author, nowMs) + air > fairCap(author, nowMs)) {
          return XprsQosShed.fairShare;
        }
        return XprsQosShed.none;
    }
  }

  int _authorSpent(String a, int nowMs) => _ledger.byAuthor(nowMs)[a] ?? 0;

  /// 4.6: [author]'s cap this hour. Max-min fair and work-conserving: the
  /// third-party budget divided among the authors who used at least an equal
  /// share, after what the lighter ones used, never by fewer than the
  /// profile's minimum divisor.
  int fairCap(String author, int nowMs) {
    final third = (profile.budgetMsHour * (1 - profile.reserve)).floor();
    final spends = _ledger.byAuthor(nowMs);
    spends.putIfAbsent(author, () => 0);
    final n = math.max(spends.length, profile.fairMinDivisor);
    final equal = third / n;
    var light = 0, lightCount = 0;
    for (final e in spends.entries) {
      if (e.key != author && e.value < equal) {
        light += e.value;
        lightCount++;
      }
    }
    final heavy = math.max(spends.length - lightCount, profile.fairMinDivisor - lightCount);
    return ((third - light) / math.max(heavy, 1)).floor();
  }

  /// Record a transmission: the ledger (every class), the author's share,
  /// the repeat table and the aired ring. Call once per airing, a retry
  /// included (XPRS.md 30.1).
  void aired(XprsPacket p, XprsQosClass cls, int bytes, int nowMs) {
    final air = profile.metered ? profile.airtimeMs!(bytes) : 0;
    if (air > 0) {
      final third = cls.index >= XprsQosClass.conversation.index;
      final author = (p['f'] ?? '').trim().toUpperCase();
      _ledger.add(_Tx(nowMs, air, third, third ? author : ''));
      final left = profile.budgetMsHour - _ledger.total(nowMs);
      if (reserveLowMs < 0 || left < reserveLowMs) reserveLowMs = left;
    }
    if (kXprsQosPeriodic.contains(p.type)) {
      final author = (p['f'] ?? '').trim().toUpperCase();
      _repeat['$author|${p.type}'] = _Last(nowMs, p['k'] ?? '');
    }
    final id = xprsIdentifier(p);
    if (id.isNotEmpty) _airedIds[id] = nowMs;
    _count[cls]!.aired++;
  }

  /// A packet admitted a moment ago that the queue then refused (a copy
  /// already waiting, a full queue): counted as shed, not as admitted.
  void revoke(XprsQosClass cls, XprsQosShed why) {
    _count[cls]!.admitted--;
    countShed(cls, why);
  }

  /// Count a shed decided after admission (the queue's budget, expiry,
  /// eviction).
  void countShed(XprsQosClass cls, XprsQosShed why) {
    final k = _count[cls]!;
    k.shed[why] = (k.shed[why] ?? 0) + 1;
  }

  int spentMs(int nowMs, [int minutes = 60]) =>
      _ledger.total(nowMs, windowMs: minutes * 60000);
  int authorSpentMs(String author, int nowMs) => _authorSpent(author, nowMs);

  Map<String, dynamic> json(int nowMs) => {
        'profile': profile.name,
        if (profile.metered) ...{
          'budgetMs': profile.budgetMsHour,
          'spentMs': _ledger.total(nowMs),
          'reserveMs': (profile.budgetMsHour * profile.reserve).round(),
        },
        'classes': {
          for (final e in _count.entries)
            if (e.value.offered > 0 || e.value.aired > 0) e.key.name: e.value.json
        },
      };

  void reset() {
    _ledger.clear();
    _repeat.clear();
    _airedIds.clear();
    _newestTs = _newestTsAtMs = 0;
    reserveLowMs = -1;
    for (final k in _count.values) {
      k.offered = k.admitted = k.aired = 0;
      k.shed.clear();
    }
  }
}

/// One packet waiting in an [XprsQosQueue].
class XprsQosEntry {
  XprsQosEntry._(this.wire, this.packet, this.cls, this.author, this.rank,
      this.urg, this.ts, this.arrivedMs, this.expiresMs, this.bytes);
  final String wire;
  final XprsPacket packet;
  final XprsQosClass cls;
  final String author;

  /// 4.3's rank: 0 sos/warning, 1 owner, 2 first:, 3 everybody else.
  final int rank;
  final int urg;

  /// `ts:` in UTC seconds, or the arrival when there is none.
  final int ts;
  final int arrivedMs;
  final int expiresMs;
  final int bytes;

  /// 4.3, as a comparison: negative when [this] goes before [o].
  int compareTo(XprsQosEntry o) {
    if (rank != o.rank) return rank - o.rank;
    if (urg != o.urg) return urg - o.urg;
    if (ts != o.ts) return ts - o.ts;
    return arrivedMs - o.arrivedMs;
  }
}

/// The gate plus a bounded queue in QoS.md 4.3 order, with 4.8's expiry and
/// eviction: for a bearer that lets the component decide what goes next.
class XprsQosQueue {
  XprsQosQueue(this.gate);
  final XprsQosGate gate;
  XprsQosProfile get profile => gate.profile;

  final List<XprsQosEntry> _q = [];
  int get length => _q.length;
  List<XprsQosEntry> get waiting => List.unmodifiable(_q);

  /// 4.8: how long a class may wait, or until its `until:`.
  Duration _limit(XprsQosClass cls, XprsQosContext c) => switch (cls) {
        XprsQosClass.life => const Duration(minutes: 10),
        XprsQosClass.owner => const Duration(minutes: 30),
        XprsQosClass.conversation => const Duration(minutes: 30),
        XprsQosClass.transaction => const Duration(minutes: 2),
        XprsQosClass.keys || XprsQosClass.presence => gate.repeatInterval(c),
        XprsQosClass.bulk => const Duration(minutes: 1),
      };

  /// Offer one wire. The decision says whether it was queued.
  XprsQosDecision offer(String wire, XprsQosContext c, {XprsPacket? packet}) {
    final p = packet ?? XprsPacket.parse(wire);
    if (p == null) {
      return const XprsQosDecision(XprsQosClass.bulk, XprsQosShed.scope);
    }
    final d = gate.admit(p, c);
    if (!d.admitted) return d;
    final author = (p['f'] ?? '').trim().toUpperCase();
    // The gate records a repeat and an airing only when the packet goes out,
    // so two copies heard before the first airs would both pass it. The
    // harness caught exactly that (an identity aired twice a second apart,
    // heard over two relays). One copy of a packet in the queue, and one
    // periodic packet per author and type.
    final id = xprsIdentifier(p);
    final periodic = kXprsQosPeriodic.contains(p.type);
    for (final w in _q) {
      if (xprsIdentifier(w.packet) == id) {
        gate.revoke(d.cls, XprsQosShed.aired);
        return XprsQosDecision(d.cls, XprsQosShed.aired);
      }
      if (periodic && w.author == author && w.packet.type == p.type &&
          !(p.type == 'identity' && (p['k'] ?? '') != (w.packet['k'] ?? ''))) {
        gate.revoke(d.cls, XprsQosShed.repeat);
        return XprsQosDecision(d.cls, XprsQosShed.repeat);
      }
    }
    final rank = switch (d.cls) {
      XprsQosClass.life => 0,
      XprsQosClass.owner => 1,
      _ => c.first.contains(author) ? 2 : 3,
    };
    final stranger = d.cls != XprsQosClass.owner && !c.first.contains(author);
    var expires = c.nowMs + _limit(d.cls, c).inMilliseconds;
    final until = xprsTsEpoch(p['until']);
    final now = c.clockEpochS;
    if (until != null && now != null) {
      expires = math.min(expires, c.nowMs + (until - now) * 1000);
    }
    final bytes = wire.length;
    final e = XprsQosEntry._(
        wire,
        p,
        d.cls,
        author,
        rank,
        xprsQosUrgRank(p['urg'], stranger: stranger),
        xprsTsEpoch(p['ts']) ?? (c.nowMs ~/ 1000),
        c.nowMs,
        expires,
        bytes);
    if (_q.length >= profile.queueMax) {
      final victim = _victim(e);
      if (victim == null) {
        gate.revoke(e.cls, XprsQosShed.evicted);
        return XprsQosDecision(d.cls, XprsQosShed.evicted);
      }
      _q.remove(victim);
      gate.countShed(victim.cls, XprsQosShed.evicted);
    }
    _q.add(e);
    _q.sort((a, b) => a.compareTo(b));
    return d;
  }

  /// 4.8: the lowest class, then the lowest urg:, then the one that would go
  /// last; never L0 by anything else, never L1 by a third party.
  XprsQosEntry? _victim(XprsQosEntry incoming) {
    XprsQosEntry? worst;
    for (final x in _q) {
      if (x.cls == XprsQosClass.life && incoming.cls != XprsQosClass.life) continue;
      if (x.cls == XprsQosClass.owner && incoming.cls.index > XprsQosClass.owner.index) {
        continue;
      }
      if (worst == null ||
          x.cls.index > worst.cls.index ||
          (x.cls == worst.cls && x.urg > worst.urg) ||
          (x.cls == worst.cls && x.urg == worst.urg && x.compareTo(worst) > 0)) {
        worst = x;
      }
    }
    if (worst == null) return null;
    // The incoming packet must outrank what it pushes out.
    final keepIncoming = incoming.cls.index < worst.cls.index ||
        (incoming.cls == worst.cls && incoming.urg < worst.urg);
    return keepIncoming ? worst : null;
  }

  /// The packet to air now, removed from the queue, or null. The first in
  /// 4.3 order the budget allows; expired entries are dropped on the way.
  XprsQosEntry? next(int nowMs) {
    _q.removeWhere((e) {
      if (e.expiresMs > nowMs) return false;
      gate.countShed(e.cls, XprsQosShed.expired);
      return true;
    });
    for (final e in _q) {
      if (gate.mayAir(e.cls, e.author, e.bytes, nowMs) == XprsQosShed.none) {
        _q.remove(e);
        return e;
      }
    }
    return null;
  }

  /// XPRS.md 9.2.1: another station aired it first.
  bool cancel(String id) {
    final before = _q.length;
    _q.removeWhere((e) => xprsIdentifier(e.packet) == id);
    return _q.length != before;
  }

  /// After the bearer accepted [e]'s wire.
  void aired(XprsQosEntry e, int nowMs) =>
      gate.aired(e.packet, e.cls, e.bytes, nowMs);
}

/// One gate per lane this core transmits on, for the doors that air (the
/// digipeater, the bridge, the publisher). Null for a lane QoS does not
/// govern.
class XprsQos {
  XprsQos._();
  static final Map<String, XprsQosGate> _gates = {};

  /// The context for a packet now: [heardOn] the lane it arrived on (null
  /// for one this station originates), [own] whether this station signed
  /// it. The host may replace it with one that knows who was heard where
  /// (`reachedCheaper`, `heardHere`) and how crowded a radio is; the default
  /// knows the clock and nothing else, which is all the unmetered lanes
  /// need (scope, repeats).
  static XprsQosContext Function(String? heardOn, {bool own}) contextFor =
      (heardOn, {own = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return XprsQosContext(
        nowMs: now, heardOn: heardOn, own: own, clockEpochS: now ~/ 1000);
  };

  static XprsQosGate? of(String bearer) {
    final key = bearer == 'ble' ? 'ble5' : bearer;
    final g = _gates[key];
    if (g != null) return g;
    final profile = XprsQosProfile.forBearer(key);
    if (profile == null) return null;
    return _gates[key] = XprsQosGate(profile);
  }

  /// Replace a lane's profile (an operator's band, a test).
  static void use(String bearer, XprsQosProfile profile) =>
      _gates[bearer] = XprsQosGate(profile);

  static Map<String, dynamic> json(int nowMs) =>
      {for (final e in _gates.entries) e.key: e.value.json(nowMs)};

  static void reset() => _gates.clear();
}

/// `YYYY-MM-DD_hh:mm:ss` UTC as epoch seconds, or null.
int? xprsTsEpoch(String? ts) {
  if (ts == null || ts.length != 19) return null;
  final iso = '${ts.substring(0, 10)}T${ts.substring(11)}Z';
  final d = DateTime.tryParse(iso);
  return d == null ? null : d.millisecondsSinceEpoch ~/ 1000;
}

/// The XPRS.md 5 identifier of a wire, or '' when it does not parse: what a
/// caller hands [XprsQosQueue.cancel] when it hears another station's copy.
String xprsQosIdOf(String wire) {
  final p = XprsPacket.parse(wire);
  return p == null ? '' : xprsIdentifier(p);
}
