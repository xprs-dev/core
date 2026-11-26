// What zx's planner makes of the archive's asks, on a real file:
//   dart tool/plan_probe.dart <archive.zx> [station callsign]
// Each statement: its plan (EXPLAIN QUERY PLAN) and its time, run twice.
import 'package:xprs_core/src/storage/store_db.dart';

void main(List<String> a) {
  final db = openStoreDb(a.first, autoCompact: false, pageCacheBytes: 8 << 20);
  final call = a.length > 1 ? a[1] : 'X3PTZM';
  const cols = 'SELECT id,ts,pts,type,fromc,toc,bearer,rssi,mine,own,sig,heard,wire FROM packets ';
  void q(String what, String where, List<Object?> p) {
    final sql = '$cols$where';
    String plan;
    try {
      plan = db.select('EXPLAIN QUERY PLAN $sql', p).map((r) => r.values.join(' ')).join(' / ');
    } catch (e) {
      plan = 'no plan: $e';
    }
    final times = <int>[];
    var n = 0;
    for (var i = 0; i < 2; i++) {
      final sw = Stopwatch()..start();
      try {
        n = db.select(sql, p).length;
      } catch (e) {
        print('$what: FAILED $e');
        return;
      }
      times.add(sw.elapsedMilliseconds);
    }
    print('${times.join('/').padLeft(12)} ms  $what ($n rows)\n              $where\n              plan: $plan');
  }

  q('blog, toc IN', "WHERE 1=1 AND toc IN (?) AND type = ? ORDER BY pts DESC LIMIT ?", ['', 'blog', 200]);
  q('blog, toc =', "WHERE toc = ? AND type = ? ORDER BY pts DESC LIMIT ?", ['', 'blog', 200]);
  q('blog, type only', "WHERE type = ? ORDER BY pts DESC LIMIT ?", ['blog', 200]);
  q('blog, type first', "WHERE type = ? AND toc = ? ORDER BY pts DESC LIMIT ?", ['blog', '', 200]);
  q('blog, INDEXED BY', "INDEXED BY idx_pk_type WHERE type = ? AND toc = ? ORDER BY pts DESC LIMIT ?", ['blog', '', 200]);
  q('blog, +toc', "WHERE type = ? AND +toc = ? ORDER BY pts DESC LIMIT ?", ['blog', '', 200]);
  q('file of one, type IN', "WHERE 1=1 AND fromc = ? AND toc IN (?) AND type IN (?) ORDER BY pts DESC LIMIT ?", [call, '', 'file', 100]);
  q('file of one, type only', "WHERE type = ? AND fromc = ? ORDER BY pts DESC LIMIT ?", ['file', call, 100]);
  q('file of one, INDEXED BY type', "INDEXED BY idx_pk_type WHERE type = ? AND fromc = ? AND toc = ? ORDER BY pts DESC LIMIT ?", ['file', call, '', 100]);
  q('rows of one', "WHERE fromc = ? ORDER BY pts DESC LIMIT ?", [call, 1000000]);
  q('count', "WHERE pts < 0", const []);
  db.dispose();
}
