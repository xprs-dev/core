/*
 * The QoS harness (spec QoS.md section 8): recorded bench traffic replayed
 * through XprsQosQueue onto a simulated LoRa LongFast channel, and the nine
 * pass criteria checked on the result.
 *
 * The station simulated stands where the T-Deck X3SEP2 stood on 2026-11-25:
 * among sixteen stations on Bluetooth, the LAN and ESP-NOW, a LoRa radio on
 * Meshtastic's LongFast. Everything it heard is offered to LoRa as
 * third-party traffic (a bridge from the short bearers, a digipeat from LoRa
 * itself); owner messages and calls for help are injected on top. The trace
 * is test/fixtures/qos_bench_2026-11-25.jsonl.gz, made by tool/qos_trace.py
 * from the T-Deck's console log (message text and signatures redacted).
 *
 * Two runs: the bench as it was, and the same hour compressed four times,
 * where the budget must bind and the rules must still hold.
 */
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_qos.dart';

const _fixture = 'test/fixtures/qos_bench_2026-11-25.jsonl.gz';
const _self = 'X3SEP2';

class _Heard {
  final int t;
  final String bearer;
  final String wire;
  _Heard(this.t, this.bearer, this.wire);
}

class _Tx {
  _Tx(this.t, this.e, this.air, this.injected, this.queuedAt);
  final int t;
  final XprsQosEntry e;
  final int air;
  final String injected; // '', 'owner' or 'sos'
  final int queuedAt;
}

Future<(int, List<_Heard>)> _load() async {
  final lines = File(_fixture)
      .openRead()
      .transform(gzip.decoder)
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  var start = 0;
  final out = <_Heard>[];
  await for (final l in lines) {
    final j = jsonDecode(l) as Map<String, dynamic>;
    if (j.containsKey('start_utc_ms')) {
      start = j['start_utc_ms'] as int;
      continue;
    }
    out.add(_Heard(j['t'] as int, j['bearer'] as String, j['wire'] as String));
  }
  return (start, out);
}

String _ts(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}_${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

class _Run {
  _Run(this.start, this.trace, {this.speed = 1});
  final int start;
  final List<_Heard> trace;
  final int speed;

  final queue = XprsQosQueue(XprsQosGate(XprsQosProfile.loraLongFast));
  XprsQosGate get gate => queue.gate;
  final txs = <_Tx>[];
  final violations = <String>[];
  final injectedAt = <String, int>{}; // wire -> when offered
  final injectedKind = <String, String>{};
  final queuedAt = <String, int>{};

  // Who is heard directly, per bearer: call -> last ms.
  final heard = <String, Map<String, int>>{'short': {}, 'lora': {}};

  bool _heardOn(String side, String call, int now) {
    final at = heard[side]![call];
    return at != null && now - at <= 600000;
  }

  int _stationsOnLora(int now) =>
      heard['lora']!.values.where((at) => now - at <= 600000).length;

  void _note(XprsPacket p, String bearer, int now) {
    if (p.has('via')) return;
    final f = (p['f'] ?? '').toUpperCase();
    if (f.isEmpty) return;
    heard[bearer == 'lora' ? 'lora' : 'short']![f] = now;
  }

  XprsQosContext _ctx(int now, {bool own = false, String? heardOn}) => XprsQosContext(
        nowMs: now,
        heardOn: heardOn,
        own: own,
        clockEpochS: now ~/ 1000,
        reachedCheaper: heardOn == null ? null : (c) => _heardOn('short', c, now),
        heardHere: (c) => _heardOn('lora', c, now),
        stationsHeard: _stationsOnLora(now),
        utilisation: _utilisation(now),
      );

  // Our own share of the last minute plus a steady 10% of foreign traffic
  // (the Heltec reported 24% on a busier stretch; 10% keeps the run out of
  // "crowded" on its own account).
  double _utilisation(int now) {
    var ms = 0;
    for (final tx in txs.reversed) {
      if (now - tx.t > 60000) break;
      ms += tx.air;
    }
    return 0.10 + ms / 60000;
  }

  void _offer(String wire, XprsQosContext c, {String injected = ''}) {
    final d = queue.offer(wire, c);
    if (injected.isNotEmpty) {
      injectedAt[wire] = c.nowMs;
      injectedKind[wire] = injected;
      if (!d.admitted) violations.add('injected $injected shed: ${d.shed.name}');
    }
    if (d.admitted) queuedAt[wire] = c.nowMs;
  }

  void run() {
    final span = trace.last.t ~/ speed;
    final end = span + 10 * 60000;
    var i = 0;
    var busyUntil = 0;
    var nextOwner = 3 * 60000, ownerN = 0;
    final sosAt = [span ~/ 5, span ~/ 2, span * 4 ~/ 5];
    var sosN = 0;
    final air = XprsQosProfile.loraLongFast.airtimeMs!;
    for (var rel = 0; rel <= end; rel += 250) {
      final now = start + rel;
      while (i < trace.length && trace[i].t ~/ speed <= rel) {
        final h = trace[i++];
        final p = XprsPacket.parse(h.wire);
        if (p == null) continue;
        _note(p, h.bearer, now);
        if ((p['f'] ?? '').toUpperCase() == _self) continue;
        _offer(h.wire, _ctx(now, heardOn: h.bearer), injected: '');
      }
      if (rel >= nextOwner && rel <= span) {
        _offer('t:message f:$_self ts:${_ts(now)} scope:regional m:owner ${ownerN++}',
            _ctx(now, own: true),
            injected: 'owner');
        nextOwner += 7 * 60000;
      }
      if (sosN < sosAt.length && rel >= sosAt[sosN]) {
        _offer('t:sos f:X1HELP ts:${_ts(now)} m:help ${sosN++}', _ctx(now, heardOn: 'ble'),
            injected: 'sos');
      }
      if (now < busyUntil) continue;
      final e = queue.next(now);
      if (e == null) continue;
      // Criterion 9: nothing ahead of it in 4.3 order could have gone.
      for (final w in queue.waiting) {
        if (w.compareTo(e) < 0 &&
            gate.mayAir(w.cls, w.author, w.bytes, now) == XprsQosShed.none) {
          violations.add('order: ${w.cls.name} ${w.author} waited behind ${e.cls.name} ${e.author}');
        }
      }
      final ms = air(e.bytes);
      queue.aired(e, now);
      busyUntil = now + ms;
      txs.add(_Tx(now, e, ms, injectedKind[e.wire] ?? '', queuedAt[e.wire] ?? now));
    }
  }

  // ── The pass criteria (QoS.md 8) ─────────────────────────────────────────
  void check() {
    const budget = 360000;
    // 1, 2, 8: sliding windows over what was transmitted.
    for (var k = 0; k < txs.length; k++) {
      final t = txs[k].t;
      var hour = 0, six = 0;
      for (var j = k; j >= 0 && t - txs[j].t < 3600000; j--) {
        hour += txs[j].air;
        if (t - txs[j].t < 6 * 60000 && txs[j].e.cls.index >= XprsQosClass.conversation.index) {
          six += txs[j].air;
        }
      }
      if (hour > budget) violations.add('1: ${hour}ms in the hour ending ${txs[k].t - start}');
      final third = txs[k].e.cls.index >= XprsQosClass.conversation.index;
      if (third && hour > budget * 0.9) {
        violations.add('2: third party at ${hour}ms, past 90%');
      }
      // A packet that began in the window may finish just past it; a frame's
      // worth of slack, as the ledger charges whole transmissions.
      if (six > budget * 0.10 + 2000) violations.add('8: ${six}ms of L2-L6 in six minutes');
    }
    // 3: injected traffic got out in time.
    final airedInjected = {for (final tx in txs) if (tx.injected.isNotEmpty) tx.e.wire: tx};
    for (final e in injectedAt.entries) {
      final tx = airedInjected[e.key];
      final kind = injectedKind[e.key];
      final limit = kind == 'sos' ? 5000 : 30000;
      if (tx == null) {
        violations.add('3: $kind never aired');
      } else if (tx.t - e.value > limit) {
        violations.add('3: $kind took ${tx.t - e.value}ms');
      }
    }
    // 4: no call for help shed for anything but scope.
    final life = gate.json(start)['classes']['life'] as Map<String, dynamic>?;
    final lifeShed = (life?['shed'] as Map<String, dynamic>?) ?? {};
    for (final s in lifeShed.keys) {
      if (s != 'scope') violations.add('4: sos/warning shed: $s');
    }
    // 6: repeats.
    final last = <String, (int, String)>{};
    for (final tx in txs) {
      final p = tx.e.packet;
      if (!kXprsQosPeriodic.contains(p.type)) continue;
      final key = '${tx.e.author}|${p.type}';
      final prev = last[key];
      final k = p['k'] ?? '';
      if (prev != null && !(p.type == 'identity' && prev.$2 != k)) {
        if (tx.t - prev.$1 < 30 * 60000 * 0.95) {
          violations.add('6: $key again after ${(tx.t - prev.$1) ~/ 1000}s');
        }
      }
      last[key] = (tx.t, k);
    }
  }

  /// 5: every conversation packet admitted was aired (meaningful only when
  /// the run is not overloaded).
  List<String> conversationLost() {
    final c = gate.json(start)['classes']['conversation'] as Map<String, dynamic>?;
    final shed = (c?['shed'] as Map<String, dynamic>?) ?? {};
    return [
      for (final k in ['expired', 'evicted', 'budget', 'fairShare'])
        if ((shed[k] ?? 0) > 0) '$k=${shed[k]}'
    ];
  }

  String report() {
    final b = StringBuffer();
    final now = start + txs.last.t - start;
    var total = 0;
    for (final tx in txs) {
      total += tx.air;
    }
    var burst = 0;
    for (var k = 0; k < txs.length; k++) {
      var s = 0;
      for (var j = k; j >= 0 && txs[k].t - txs[j].t < 6 * 60000; j--) {
        s += txs[j].air;
      }
      if (s > burst) burst = s;
    }
    final mins = (trace.last.t ~/ speed) / 60000;
    b.writeln('speed x$speed: ${trace.length} heard in ${mins.toStringAsFixed(0)} min, '
        '${txs.length} aired, ${total ~/ 1000}s of LongFast '
        '(${(total / 1000 / mins * 60).toStringAsFixed(0)} s/h equivalent), '
        'largest 6-min burst ${burst ~/ 1000}s, reserve low-water '
        '${gate.reserveLowMs ~/ 1000}s');
    final byClass = <XprsQosClass, List<int>>{};
    for (final tx in txs) {
      (byClass[tx.e.cls] ??= []).add(tx.t - tx.queuedAt);
    }
    final cls = gate.json(now)['classes'] as Map<String, dynamic>;
    for (final c in XprsQosClass.values) {
      final j = cls[c.name] as Map<String, dynamic>?;
      if (j == null) continue;
      final d = byClass[c] ?? [];
      d.sort();
      final med = d.isEmpty ? 0 : d[d.length ~/ 2];
      final p95 = d.isEmpty ? 0 : d[(d.length * 95) ~/ 100];
      b.writeln('  ${c.name.padRight(12)} offered ${j['offered']} aired ${j['aired']} '
          'wait median ${med ~/ 1000}s p95 ${p95 ~/ 1000}s shed ${j['shed'] ?? {}}');
    }
    final byAuthor = <String, int>{};
    for (final tx in txs) {
      if (tx.e.cls.index >= XprsQosClass.conversation.index) {
        byAuthor[tx.e.author] = (byAuthor[tx.e.author] ?? 0) + tx.air;
      }
    }
    final top = byAuthor.entries.toList()..sort((a, c) => c.value - a.value);
    b.writeln('  third-party airtime by author: '
        '${top.take(5).map((e) => '${e.key} ${e.value ~/ 1000}s').join(', ')}');
    return b.toString();
  }
}

/// What lr_worth alone would have put on LoRa: every packet of a worthy type,
/// once per identifier a minute (the bearer's duplicate ring), no budget.
int _baselineMs(List<_Heard> trace) {
  const worthy = {
    'message', 'sos', 'warning', 'receipt', 'reaction', 'command', 'result',
    'identity', 'mailbox', 'file', 'request'
  };
  final air = XprsQosProfile.loraLongFast.airtimeMs!;
  final seen = <String, int>{};
  var ms = 0;
  for (final h in trace) {
    final p = XprsPacket.parse(h.wire);
    if (p == null || !worthy.contains(p.type)) continue;
    if ((p['f'] ?? '').toUpperCase() == _self) continue;
    final id = xprsQosIdOf(h.wire);
    final at = seen[id];
    if (at != null && h.t - at < 60000) continue;
    seen[id] = h.t;
    ms += air(h.wire.length);
  }
  return ms;
}

void main() {
  late int start;
  late List<_Heard> trace;
  setUpAll(() async {
    (start, trace) = await _load();
  });

  test('the bench as it was: every rule holds and no conversation is lost', () {
    final r = _Run(start, trace)..run();
    r.check();
    final base = _baselineMs(trace);
    final mins = trace.last.t / 60000;
    // ignore: avoid_print
    print('${r.report()}  lr_worth alone would have offered ${base ~/ 1000}s '
        '(${(base / 1000 / mins * 60).toStringAsFixed(0)} s/h)');
    expect(r.violations, isEmpty, reason: r.violations.take(10).join('\n'));
    expect(r.conversationLost(), isEmpty);
    expect(r.txs.where((t) => t.injected == 'owner'), isNotEmpty);
  });

  test('four times the load: the budget binds and every rule still holds', () {
    final r = _Run(start, trace, speed: 4)..run();
    r.check();
    // ignore: avoid_print
    print(r.report());
    expect(r.violations, isEmpty, reason: r.violations.take(10).join('\n'));
  });
}
