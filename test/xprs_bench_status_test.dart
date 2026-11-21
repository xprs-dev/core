// The readings a test takes of a station's archiver and file machinery: one
// shape on every host (the app's remote API and the server edition both
// answer from here), numbers and names only.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_bench_status.dart';

void main() {
  test('the two readings are answered, anything else is not', () {
    expect(xprsBenchStatus('/api/xprs/archiver'), isNotNull);
    expect(xprsBenchStatus('/api/xprs/files'), isNotNull);
    expect(xprsBenchStatus('/api/xprs/history'), isNull);
    expect(xprsBenchStatus('/api/admin'), isNull);
  });

  test('the archiver reading carries what a conformance run reads', () {
    final a = xprsArchiverStatusMap();
    for (final k in [
      'archiver', 'public', 'alwaysOn', 'archivers', 'adopted', 'records',
      'deposited', 'depositNoDest', 'catchup', 'gossip', 'line',
    ]) {
      expect(a.containsKey(k), isTrue, reason: k);
    }
    expect((a['catchup'] as Map).containsKey('directoryAsks'), isTrue);
    // It must go on the wire as JSON as it is.
    expect(() => jsonEncode(a), returnsNormally);
  });

  test('the files reading names both ends and the holders of a fetch', () {
    final f = xprsFilesStatusMap();
    expect(f.keys, containsAll(['server', 'fetch', 'spool']));
    expect((f['fetch'] as Map).containsKey('holders'), isTrue);
    expect(() => jsonEncode(f), returnsNormally);
  });
}
