// A group's record reaches the archivers of whoever administers it
// (XPRS.md 10.9.2). Reported 2026-11-22: the archiver held one folder of a
// group whose admin's phone held them all, because over Reticulum an act is
// addressed to the group's members and the archiver is not one.
import 'package:test/test.dart';
import 'package:xprs_core/src/platform/key_value_store.dart';
import 'package:xprs_core/src/services/xprs/xprs_group_deposit.dart';

void main() {
  final d = XprsGroupDeposit.instance;
  late List<(String, String)> sent;
  late int clock;
  late Set<String> named;

  setUp(() {
    d.debugReset();
    sent = [];
    clock = 1000000;
    named = {'X3ARC', 'X3TWO'};
    d
      ..store = MemoryKeyValueStore()
      ..now = (() => clock)
      ..groups = (() => ['X5ROOT', 'X5FOLD'])
      ..archivers = (() => ['x3arc', 'X3TWO'])
      ..record = ((g) => ['t:identity f:$g', 't:moderate f:$g d:$g grant:X5FOLD role:sub'])
      ..send = ((call, wire) async {
        if (!named.contains(call)) return false;
        sent.add((call, wire));
        return true;
      });
  });
  tearDown(d.debugReset);

  Future<void> minutes(int n) async {
    for (var i = 0; i < n; i++) {
      clock += 60000;
      await d.tick();
    }
  }

  test('nothing before the lanes have settled', () async {
    expect(await d.tick(), 0);
    clock += 60000;
    expect(await d.tick(), 0);
    expect(sent, isEmpty);
  });

  test('every group to every archiver, one group a turn, then quiet for a week',
      () async {
    await d.tick();
    await minutes(3);
    expect(sent.length, 4, reason: 'the first group, to both, on the first turn after settling');
    expect(sent.first, ('X3ARC', 't:identity f:X5ROOT'));
    expect({for (final s in sent) s.$1}, {'X3ARC', 'X3TWO'});
    await minutes(1);
    expect(sent.length, 8);
    await minutes(30);
    expect(sent.length, 8, reason: 'handed over: not again within the week');
    clock += XprsGroupDeposit.every.inMilliseconds;
    await minutes(2);
    expect(sent.length, 16);
  });

  test('the costly question is asked only of a group that is due', () async {
    // Measured on a phone, 2026-11-23: asked of every known group at once,
    // "may I vouch for it" replayed every roster in one go.
    final asked = <String>[];
    d.vouches = (g) {
      asked.add(g);
      return g == 'X5FOLD';
    };
    await d.tick();
    await minutes(3);
    expect({for (final s in sent) s.$2.split(' ')[1]}, {'f:X5FOLD'},
        reason: 'only the group this station vouches for is handed over');
    asked.clear();
    await minutes(1);
    expect(asked, ['X5ROOT'],
        reason: 'X5FOLD is fresh at both archivers: not asked about again');
  });

  test('an archiver that cannot be named now is tried again later', () async {
    named = {'X3ARC'};
    await d.tick();
    await minutes(10);
    expect(sent.where((s) => s.$1 == 'X3TWO'), isEmpty);
    expect(sent.length, 4);
    named = {'X3ARC', 'X3TWO'};
    await minutes(5);
    expect(sent.where((s) => s.$1 == 'X3TWO'), isEmpty,
        reason: 'nothing was due: the groups are left alone for an hour');
    clock += XprsGroupDeposit.idleLook.inMilliseconds;
    await minutes(2);
    expect(sent.where((s) => s.$1 == 'X3TWO').length, 4);
  });

  test('a new act makes the record due again', () async {
    await d.tick();
    await minutes(4);
    expect(sent.length, 8);
    d.changed('x5root');
    await minutes(1);
    expect(sent.length, 12);
    expect(sent.skip(8).every((s) => s.$2.contains('X5ROOT')), isTrue);
  });

  test('group traffic is addressed to three archivers at most', () {
    d.archivers = () => ['a', 'b', ' ', 'c', 'd'];
    expect(d.targets(), ['A', 'B', 'C']);
  });
}
