// The observed-node store writes and counts on its own thread (store_worker,
// performance.md 8.29): measured on the C61 as 1.8 to 2.1 s of the main
// isolate every twenty seconds. What the thread writes is read here.
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/reticulum/observed_store.dart';

Map<String, Object?> _node(int i, {bool xprs = false}) => {
      'id': 'id$i',
      'pubkey': 'pk$i',
      'callsign': xprs ? 'X1N$i' : '',
      'services': xprs ? 'xprs' : 'lxmf',
      'xprs': xprs ? 1 : 0,
      'svcXprs': xprs ? 1 : 0,
      'hops': 1,
      'via': 'lan',
      'uptime': 0,
      'firstSeen': 1000 + i,
      'lastSeen': DateTime.now().millisecondsSinceEpoch,
    };

void main() {
  late Directory dir;
  late ObservedStore st;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xprs-observed');
    st = ObservedStore('${dir.path}/observed.zx');
    expect(st.open(), isTrue);
  });
  tearDown(() {
    st.close();
    dir.deleteSync(recursive: true);
  });

  test('written on its thread, read here, counted there', () async {
    await st.startWorker();
    st.upsertMany([for (var i = 0; i < 300; i++) _node(i, xprs: i % 3 == 0)]);
    // A call answers after everything posted before it.
    final s = await st.statsSoon();
    expect(s['total'], 300);
    expect(s['xprs'], 100);
    expect(st.pubkeyOf('id42'), 'pk42', reason: 'the thread\'s rows, read on this isolate');
    expect(st.namedPeers(limit: 500).length, 100);
  });

  test('without the thread it works as before', () async {
    st.upsertMany([for (var i = 0; i < 10; i++) _node(i)]);
    final s = await st.statsSoon();
    expect(s['total'], 10);
  });
}
