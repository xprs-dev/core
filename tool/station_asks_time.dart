// Time what OTHER STATIONS ask of an archive (cmd:history, the inline lane),
// against a real file (a copy: the archive is opened for writing):
//   dart tool/station_asks_time.dart <archive.zx> [asker] [station] [now, ms]
// Every ask twice, as a known station and as a stranger (own rows only).
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';

Future<void> main(List<String> a) async {
  final x = XprsArchive.instance..init(a.first);
  // A file from before the indexes: the writer thread builds them, once.
  final built = Stopwatch()..start();
  while (!(x.typeIndexReady && x.callTypeIndexReady) && built.elapsed.inSeconds < 120) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  print('indexes: by type ${x.typeIndexReady}, by callsign and type '
      '${x.callTypeIndexReady} (${built.elapsedMilliseconds} ms)');
  final asker = a.length > 1 ? a[1] : 'X1WATT';
  final station = a.length > 2 ? a[2] : 'X3PTZM';
  x.selfCallsign = station;
  final now = a.length > 3 ? int.parse(a[3]) : DateTime.now().millisecondsSinceEpoch;
  const day = 86400000;
  void t(String what, List<String> types, {String? only, int days = 7, bool own = false}) {
    final sw = Stopwatch()..start();
    final n = x.query(
        sinceMs: now - days * day,
        untilMs: now + 1,
        only: only,
        types: types,
        limit: 51,
        ownOnly: own,
        mailFor: asker).length;
    print('${sw.elapsedMilliseconds.toString().padLeft(6)} ms  '
        '${own ? 'stranger ' : ''}$what ($n rows)');
  }

  for (var i = 0; i < 2; i++) {
    print(i == 0 ? '-- first ask' : '-- asked again');
    for (final own in [false, true]) {
      t('talk, a week', XprsArchive.kXprsTalk.toList(), own: own);
      t('message, a week', const ['message'], own: own);
      t('message+mailbox, a week', const ['message', 'mailbox'], own: own);
      t('identity, a year', const ['identity'], days: 365, own: own);
      t('identity, a week', const ['identity'], own: own);
      t('service of the station, a day', const ['service'], only: station, days: 1, own: own);
      t('service of the station, a week', const ['service'], only: station, own: own);
      t('group X50404, a week', const ['identity', 'moderate', 'message', 'reaction'], only: 'X50404', own: own);
      t('identity+observation of X22, a week', const ['identity', 'observation'], only: 'X22', own: own);
      t('observation of the asker, a week', const ['observation'], only: asker, own: own);
      t('file, a year', const ['file'], days: 365, own: own);
      t('blog+status, a month', const ['blog', 'status'], days: 30, own: own);
    }
  }
  x.close();
}
