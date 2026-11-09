// The stores in a browser (dart2wasm): zx files in memory, persisted to
// IndexedDB by store_db_host_web.dart, read back after a "reload".
//   CHROME_EXECUTABLE=/usr/bin/chromium dart test -p chrome -c dart2wasm test/browser
@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:xprs_core/src/storage/store_db.dart';
import 'package:xprs_core/src/storage/store_db_host.dart'
    show resetStoreDbHostForTest;

void main() {
  test('a store survives a reload through IndexedDB', () async {
    await initStoreDb();
    final path = '/xprs/devices/P/data/web_${DateTime.now().microsecondsSinceEpoch}.zx';
    var db = openStoreDb(path);
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT) WITH (compression = 'fast')");
    db.transaction(() {
      for (var i = 0; i < 2000; i++) {
        db.execute('INSERT INTO t VALUES (?, ?)', [i, 'row $i ${'x' * 40}']);
      }
    });
    db.kv('k').putString('a', 'kv-value');
    db.dispose();
    await flushStoreDb();

    resetStoreDbHostForTest(); // memory gone, as after a reload
    await initStoreDb();
    db = openStoreDb(path);
    expect(db.select('SELECT COUNT(*) c FROM t').single['c'], 2000);
    expect(db.select('SELECT v FROM t WHERE id = 1999').single['v'], startsWith('row 1999'));
    expect(db.kv('k').getString('a'), 'kv-value');
    // a change after the reload persists too
    db.execute("UPDATE t SET v = 'changed' WHERE id = 5");
    db.dispose();
    await flushStoreDb();
    resetStoreDbHostForTest();
    await initStoreDb();
    db = openStoreDb(path);
    expect(db.select('SELECT v FROM t WHERE id = 5').single['v'], 'changed');
    db.dispose();
  });
}
