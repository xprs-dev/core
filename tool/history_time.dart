// Time what a page asks of a station's archive, against a real file (a copy:
// the archive is opened for writing):
//   dart tool/history_time.dart <archive.zx> [station callsign]
// Every ask twice: the first is what a new visitor pays, the second what the
// kept answers save. Also the per-type row counts, which say why.
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';

void main(List<String> a) {
  final x = XprsArchive.instance..init(a.first);
  final call = a.length > 1 ? a[1] : 'X3PTZM';
  void t(String what, int Function() f) {
    final sw = Stopwatch()..start();
    final n = f();
    print('${sw.elapsedMilliseconds.toString().padLeft(6)} ms  $what ($n rows)');
  }

  final all = WebChatApi.readable.toList();
  const talk = ['message', 'reaction', 'status'];
  for (var i = 0; i < 2; i++) {
    print(i == 0 ? '-- first ask' : '-- asked again');
    t('file of $call, 100', () => archivePublicRows(types: const ['file'], from: call, limit: 100).length);
    t('file of $call, 1', () => archivePublicRows(types: const ['file'], from: call, limit: 1).length);
    t('message of $call, 100', () => archivePublicRows(types: const ['message'], from: call, limit: 100).length);
    t('identity+service, 200', () => archivePublicRows(types: const ['identity', 'service'], limit: 200).length);
    t('everything readable, 200', () => archivePublicRows(types: all, limit: 200).length);
    t('talk, 200', () => archivePublicRows(types: talk, limit: 200).length);
    t('talk, 200, a visitor', () => archivePublicRows(types: talk, visitor: 'X1ZZZZ', limit: 200).length);
    t('status, 100, a visitor', () => archivePublicRows(types: const ['status'], visitor: 'X1ZZZZ', limit: 100).length);
    t('warning+info, 100', () => archivePublicRows(types: const ['warning', 'info'], limit: 100).length);
    t('blog, 200', () => archivePublicRows(types: const ['blog'], limit: 200).length);
    t('local room, 100', () => archivePublicRows(types: const ['message'], room: 'local', limit: 100).length);
    t('global room, 100', () => archivePublicRows(types: const ['message'], room: 'global', limit: 100).length);
  }
  print('-- the file');
  t('rows', () => x.debugCount());
  for (final ty in [...all, 'service', 'observation']) {
    print('${x.countOf(types: [ty]).toString().padLeft(8)} $ty '
        '(${x.countOf(types: [ty], undirected: true)} undirected)');
  }
  print('type index: ${x.typeIndexReady}');
  x.close();
}
