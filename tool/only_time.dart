// Time history-shaped queries on a synthetic archive:
//   dart tool/only_time.dart <new-archive.zx> [rows]
import 'dart:io';

import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main(List<String> a) {
  final n = a.length > 1 ? int.parse(a[1]) : 60000;
  final x = XprsArchive.instance
    ..selfCallsign = 'X3SELF'
    ..init(a.first);
  final t0 = DateTime.utc(2026, 11, 20).millisecondsSinceEpoch;
  for (var i = 0; i < n; i++) {
    final at = DateTime.fromMillisecondsSinceEpoch(t0 + i * 6000, isUtc: true);
    final ts = '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}_'
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
    x.admit(XprsPacket.parse('t:message f:X1N${i % 300} ts:$ts m:noise $i')!,
        bearer: 'lan', nowMs: t0 + i * 6000);
    if (i % 500 == 499) x.flush();
  }
  x.flush();
  final since = DateTime.utc(2026, 11, 16).millisecondsSinceEpoch;
  void time(String what, List<Map<String, dynamic>> Function() q) {
    final sw = Stopwatch()..start();
    final r = q();
    print('$what: ${r.length} rows in ${sw.elapsedMilliseconds} ms');
  }
  const kinds = ['identity', 'moderate', 'message', 'reaction'];
  time('only a group, stranger', () => x.query(sinceMs: since, only: 'X5GRUP', types: kinds, ownOnly: true, mailFor: 'X1ASKR', limit: 13));
  time('only a group, member', () => x.query(sinceMs: since, only: 'X5GRUP', types: kinds, mailFor: 'X1ASKR', limit: 13));
  time('stranger, no only', () => x.query(sinceMs: since, types: kinds, ownOnly: true, mailFor: 'X1ASKR', limit: 13));
  x.close();
  exit(0);
}
