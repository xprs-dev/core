// Time the archive's flush against an archive file:
//   dart tool/flush_time.dart <archive.zx> [rows]
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main(List<String> a) {
  final x = XprsArchive.instance..init(a.first);
  final n = a.length > 1 ? int.parse(a[1]) : 60;
  for (var round = 0; round < 3; round++) {
    for (var i = 0; i < n; i++) {
      final kind = i % 3 == 0 ? 'identity' : (i % 3 == 1 ? 'observation' : 'message');
      final body = kind == 'identity'
          ? 'k:npub1test$round$i'
          : (kind == 'observation' ? 'hears:X1AAAA,X1BBBB link:lan' : 'm:flush timing $round $i');
      x.admit(
          XprsPacket.parse('t:$kind f:X1T${round}Z${i.toRadixString(36).toUpperCase()} '
              'ts:2026-11-22_21:0$round:${(i % 60).toString().padLeft(2, '0')} $body')!,
          bearer: 'lan');
    }
    final sw = Stopwatch()..start();
    x.flush();
    print('flush of $n rows: ${sw.elapsedMilliseconds} ms');
  }
  x.close();
}
