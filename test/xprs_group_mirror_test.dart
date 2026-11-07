// A shared room kept in step with a peer (XPRS.md 10.10.1, 12.9.3): the
// standing ask, its pages, the mark, and the cadence.
import 'package:test/test.dart';
import 'package:xprs_core/src/platform/key_value_store.dart';
import 'package:xprs_core/src/services/xprs/xprs_group_mirror.dart';
import 'package:xprs_core/src/services/xprs/xprs_id.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart' show xprsNowTs;

void main() {
  final m = XprsGroupMirror.instance;
  late List<String> sent;
  late int now;
  late MemoryKeyValueStore store;
  var key = true;
  const group = 'X5F0RM', owner = 'X3OWNR';

  setUp(() {
    m.clear();
    sent = [];
    now = DateTime.utc(2026, 11, 6, 12).millisecondsSinceEpoch;
    store = MemoryKeyValueStore();
    key = true;
    m.send = (w) async => sent.add(w);
    m.selfCallsign = () => 'X3MIRR';
    m.nowMs = () => now;
    m.store = store;
    m.haveKey = (_) => key;
    m.pairs = () => const [MirrorPair(group: group, peer: owner)];
  });

  String askId() => xprsIdentifier(XprsPacket.parse(sent.last)!);
  void result(int code, {String? m_}) => m.onResult(XprsPacket.parse(
      't:result f:$owner d:X3MIRR ts:${xprsNowTs(now)} r:${askId()} code:$code${m_ == null ? '' : ' m:$m_'}')!);
  void heard(String ts) => m.noteHeard(XprsPacket.parse(
      't:blog f:X1RD89 d:$group ts:$ts title:t m:x')!);

  test('the ask: only the group, the kinds, since a month back the first time', () async {
    await m.tick();
    expect(sent, hasLength(1));
    final p = XprsPacket.parse(sent.single)!;
    expect(p['d'], owner);
    expect(p['cmd'], 'history');
    expect(p['only'], group);
    expect(p['kind'], XprsGroupMirror.kinds);
    expect(p['since'], xprsNowTs(now - XprsGroupMirror.firstWindow.inMilliseconds));
    expect(p.has('until'), false);
    // Out, so not asked again until it is answered or its grace is over.
    await m.tick();
    expect(sent, hasLength(1));
  });

  test('without the group\'s key only its identity is asked, and the mark stays', () async {
    key = false;
    await m.tick();
    expect(XprsPacket.parse(sent.single)!['kind'], 'identity');
    result(200);
    expect(store.getString('mirror.mark.$owner|$group'), isNull);
    key = true;
    now += XprsGroupMirror.interval.inMilliseconds;
    await m.tick();
    expect(XprsPacket.parse(sent.last)!['kind'], XprsGroupMirror.kinds);
  });

  test('200 closes the window and moves the mark to the ask\'s own time', () async {
    await m.tick();
    final askedAt = now;
    heard('2026-11-06_11:30:00');
    result(200);
    expect(store.getString('mirror.mark.$owner|$group'), '$askedAt');
    // The next ask starts where this one did.
    now += XprsGroupMirror.interval.inMilliseconds;
    await m.tick();
    expect(XprsPacket.parse(sent.last)!['since'], xprsNowTs(askedAt));
  });

  test('206 is continued before the oldest row it brought (11.2.1)', () async {
    await m.tick();
    heard('2026-11-06_11:30:00');
    heard('2026-11-06_11:10:05');
    result(206);
    expect(sent, hasLength(2), reason: 'continued at once');
    final c = XprsPacket.parse(sent.last)!;
    expect(c['until'], '2026-11-06_11:10:06');
    expect(c['since'], XprsPacket.parse(sent.first)!['since'], reason: 'the same window');
    heard('2026-11-06_11:00:00');
    result(200);
    expect(store.getString('mirror.mark.$owner|$group'), '$now');
    expect(m.rows, 3);
  });

  test('a 206 that brought nothing is not continued', () async {
    await m.tick();
    result(206);
    expect(sent, hasLength(1));
  });

  test('quiet doubles the interval to ten minutes; news brings it back to one', () async {
    await m.tick();
    result(200); // nothing heard: quiet
    now += XprsGroupMirror.interval.inMilliseconds;
    await m.tick();
    expect(sent, hasLength(1), reason: 'two minutes now');
    now += XprsGroupMirror.interval.inMilliseconds;
    await m.tick();
    expect(sent, hasLength(2));
    heard('2026-11-06_11:59:00');
    result(200);
    now += XprsGroupMirror.interval.inMilliseconds;
    await m.tick();
    expect(sent, hasLength(3), reason: 'news: a minute again');
    for (var i = 0; i < 6; i++) {
      result(200);
      now += XprsGroupMirror.quietCeiling.inMilliseconds;
      await m.tick();
    }
    expect(m.statusJson().single['interval_s'], XprsGroupMirror.quietCeiling.inSeconds);
  });

  test('429 is the peer\'s authority: not before ten minutes; poke asks now', () async {
    await m.tick();
    result(429);
    now += XprsGroupMirror.interval.inMilliseconds * 5;
    await m.tick();
    expect(sent, hasLength(1));
    m.poke(group);
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(2));
  });

  test('429 m:busy is a moment: asked again a minute later', () async {
    await m.tick();
    result(429, m_: 'busy');
    now += XprsGroupMirror.interval.inMilliseconds;
    await m.tick();
    expect(sent, hasLength(2));
  });

  test('an ask nobody answered is given up after its grace, and asked again', () async {
    await m.tick();
    now += XprsGroupMirror.askGrace.inMilliseconds + XprsGroupMirror.interval.inMilliseconds;
    await m.tick();
    expect(sent, hasLength(2));
  });

  test('an act parked for want of its signer\'s key asks each peer for that identity', () async {
    m.unknownSigner('X1ALIC');
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(1));
    final p = XprsPacket.parse(sent.single)!;
    expect(p['d'], owner);
    expect(p['only'], 'X1ALIC');
    expect(p['kind'], 'identity');
    m.unknownSigner('X1ALIC');
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(1), reason: 'once per ten minutes');
    now += XprsGroupMirror.keyAskEvery.inMilliseconds;
    m.unknownSigner('x1alic');
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(2));
    m.unknownSigner('X3MIRR');
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(2), reason: 'never our own');
  });

  test('a neighbour (12.9.3): the noticeboard asked for without only:, its answer asked-for, its rooms met', () async {
    m.pairs = () => const [MirrorPair(peer: owner, kinds: XprsGroupMirror.neighbourKinds)];
    final met = <String>[];
    m.onMeshRoom = (room, peer, nick) => met.add('$room $peer $nick');
    await m.tick();
    final p = XprsPacket.parse(sent.single)!;
    expect(p.has('only'), false);
    expect(p['kind'], 'info,warning,blog,identity');
    expect(p['d'], owner);
    // While the ask is out, an alert, a post or an identity is its answer.
    expect(m.askedFor(XprsPacket.parse('t:warning f:X1RD89 ts:2026-11-06_11:59:00 kind:fire m:x')!), true);
    expect(m.askedFor(XprsPacket.parse('t:message f:X1RD89 ts:2026-11-06_11:59:00 m:x')!), false);
    m.noteHeard(XprsPacket.parse('t:identity f:X5MESH ts:2026-11-06_11:50:00 k:npub1x nick:antennas')!);
    m.noteHeard(XprsPacket.parse('t:blog f:X1RD89 d:X5POST ts:2026-11-06_11:51:00 title:t m:x')!);
    expect(met, ['X5MESH $owner antennas', 'X5POST $owner ']);
    result(200);
    expect(m.rows, 2);
    expect(m.askedFor(XprsPacket.parse('t:warning f:X1RD89 ts:2026-11-06_11:59:00 kind:fire m:x')!), false,
        reason: 'answered: nothing more is attributed');
    m.onMeshRoom = null;
  });

  test('a mirrored group\'s packets are asked-for rows, whoever wrote them', () async {
    await m.tick();
    expect(m.askedFor(XprsPacket.parse('t:blog f:X1RD89 d:$group ts:2026-11-06_11:00:00 title:t m:x')!), true);
    expect(m.askedFor(XprsPacket.parse('t:identity f:$group ts:2026-11-06_11:00:00 k:npub1x')!), true);
    expect(m.askedFor(XprsPacket.parse('t:message f:X1RD89 d:X5OTHR ts:2026-11-06_11:00:00 m:x')!), false);
  });
}
