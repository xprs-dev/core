// Time the page's asks against an archive file: dart tool/room_time.dart <archive.zx> [index]
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';

void main(List<String> a) {
  final x = XprsArchive.instance..init(a.first);
  void t(String what, int Function() f) {
    final sw = Stopwatch()..start();
    final n = f();
    print('$what: ${sw.elapsedMilliseconds} ms ($n)');
  }
  if (a.length > 1) {
    t('index', () {
      x.debugExec(a[1]);
      return 0;
    });
  }
  const talk = ['message', 'reaction', 'status'];
  for (var i = 0; i < 2; i++) {
    t('talk 40', () => archivePublicRows(types: talk, limit: 40).length);
    t('talk 200', () => archivePublicRows(types: talk, limit: 200).length);
    t('blog 200', () => archivePublicRows(types: const ['blog'], limit: 200).length);
    t('identity of one', () => archivePublicRows(types: const ['identity'], from: 'X106QR', limit: 3).length);
    t('local', () => archivePublicRows(types: const ['message', 'reaction'], room: 'local', limit: 100).length);
  }
  t('rows', () => x.debugCount());
  x.close();
}
