// How a message from here gets to a station (services/station/station_routes):
// every hop says how it is known, and a hop a station only SAID is asked of
// that station through the API every deployment serves.
import 'package:test/test.dart';
import 'package:xprs_core/src/services/station/station_api.dart';
import 'package:xprs_core/src/services/station/station_routes.dart';
import 'package:xprs_core/src/services/xprs/xprs_gossip.dart';

void main() {
  final r = StationRoutes.instance;
  late int now;
  late List<String> asked;

  setUp(() {
    now = DateTime.now().millisecondsSinceEpoch;
    asked = [];
    r
      ..self = (() => 'X1ME')
      ..heardHere = ((_) => null)
      ..announced = ((_) => null)
      ..edges = ((_, __) => const [])
      ..visit = ((c) async {
        asked.add(c);
        return null;
      });
  });

  List hops(Map<String, dynamic> a, [int i = 0]) => (a['routes'] as List)[i]['hops'] as List;

  test('heard here on two radios: two ways, each one hop, each heard', () {
    r.heardHere = (_) => {
          'bearers': ['ble', 'lan'],
          'lastDirectMs': now - 5000,
          'rssi': -70,
        };
    final a = r.read('X3NEAR');
    expect(a['routes'], hasLength(2));
    expect(hops(a).single, containsPair('know', 'heard'));
    expect(hops(a).single, containsPair('bearer', 'ble'));
    expect(hops(a).single, containsPair('reach', 'local'));
    expect(hops(a, 1).single, containsPair('bearer', 'lan'));
    expect((a['routes'] as List).every((x) => x['sure'] == true), isTrue);
  });

  test('through two stations: Bluetooth, then LoRa, then LAN, as each said', () async {
    // observer hears heard: A hears me on ble (we saw that ourselves), B
    // hears A on lora, the target hears B on lan.
    r.edges = (_, __) => [
          GossipEdge('X3AAAA', 'X1ME', 'ble', now - 1000, direct: true),
          GossipEdge('X3BBBB', 'X3AAAA', 'lora', now - 2000),
          GossipEdge('X1FAR', 'X3BBBB', 'lan', now - 3000),
        ];
    r.visit = (c) async {
      asked.add(c);
      if (c != 'X3BBBB') return null;
      return StationVisit(c, (m, p, q, b, {headers = const {}}) async {
        expect(p, '/api/xprs/devices');
        return const StationReply(200, json: {
          'ok': true,
          'devices': [
            {'call': 'X3AAAA', 'bearer': 'lora', 'rssi': -101, 'hops': 0, 'age_s': 7},
          ],
        });
      });
    };
    var a = r.read('X1FAR');
    expect([for (final h in hops(a)) '${h['from']}>${h['to']}:${h['bearer']}:${h['know']}'], [
      'X1ME>X3AAAA:ble:heard',
      'X3AAAA>X3BBBB:lora:said',
      'X3BBBB>X1FAR:lan:said',
    ]);
    expect((a['routes'] as List).single['sure'], isTrue, reason: 'said is a claim, not a guess');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(asked, containsAll(['X3BBBB', 'X1FAR']), reason: 'each hearer is asked how it hears');
    a = r.read('X1FAR');
    expect(hops(a)[1], containsPair('know', 'asked'));
    expect(hops(a)[1], containsPair('rssi', -101));
    expect(hops(a)[2], containsPair('know', 'said'), reason: 'the phone did not answer');
    final before = asked.length;
    r.read('X1FAR');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(asked.length, before, reason: 'not asked again within minutes');
  });

  test('over Reticulum, three hops away: the middle is a guess and says so', () {
    r.announced = (_) => {'hops': 3, 'kind': 'internet', 'relayer': 'X3HUB', 'ageMs': 9000};
    final a = r.read('X1AWAY');
    expect([for (final h in hops(a)) '${h['from']}>${h['to']}:${h['know']}'],
        ['X1ME>X3HUB:heard', 'X3HUB>?:guess', '?>X1AWAY:guess']);
    expect((a['routes'] as List).single['sure'], isFalse);
    expect(hops(a).first, containsPair('reach', 'global'));
  });

  test('nothing known: no way is invented', () {
    expect(r.read('X1NONE')['routes'], isEmpty);
  });
}
