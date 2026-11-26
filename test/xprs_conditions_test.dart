import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_conditions.dart';
import 'package:xprs_core/src/services/xprs/xprs_observation.dart';

String wire(List<MapEntry<String, String>> c) =>
    c.map((e) => '${e.key}:${e.value}').join(' ');

void main() {
  test('defaults: grid, a phone on its battery, a capped mobile plan', () {
    expect(
        wire(xprsConditions(platform: 'android', seenUplink: 'cellular')),
        'source:grid backup:battery uplink:cellular plan:limited');
    expect(wire(xprsConditions(platform: 'linux', seenUplink: 'lan')),
        'source:grid backup:none uplink:lan plan:unlimited');
  });

  test('what the owner states wins, and no plan beside uplink:none', () {
    expect(
        wire(xprsConditions(
            platform: 'linux',
            seenUplink: 'lan',
            source: 'solar',
            backup: 'ups',
            uplink: 'none',
            planFor: (_) => 'unlimited')),
        'source:solar backup:ups uplink:none');
  });

  test('the plan follows the link: each kind keeps its own', () {
    final plans = {'cellular': 'unlimited'};
    String air(String seen) => wire(xprsConditions(
        platform: 'android', seenUplink: seen, planFor: (u) => plans[u]));
    expect(air('wifi'), endsWith('uplink:wifi plan:unlimited'));
    expect(air('cellular'), endsWith('uplink:cellular plan:unlimited'));
    plans.clear();
    expect(air('cellular'), endsWith('uplink:cellular plan:limited'));
  });

  test('a satellite link is only ever stated', () {
    expect(xprsSeenUplink('ethernet'), 'lan');
    expect(xprsSeenUplink('other'), 'other');
  });

  test('the observation carries them (13.0.4)', () {
    final p = xprsComposeObservation(
        self: 'X1QZ3N',
        link: 'lan',
        heard: const [],
        budget: 250,
        conditions:
            xprsConditions(platform: 'android', seenUplink: 'cellular'),
        ts: '2026-11-26_09:00:00')!;
    expect(p.encode(),
        't:observation f:X1QZ3N link:lan source:grid backup:battery '
        'uplink:cellular plan:limited ts:2026-11-26_09:00:00 peers:0');
  });
}
