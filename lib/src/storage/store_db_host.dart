/*
 * Where the stores' files live besides the disk (app/docs/web.md, "Stores
 * in the browser"). Natively: nothing to do. In a browser, zx keeps the
 * database files in memory (package:zx/zxdb_web.dart); this loads them from
 * IndexedDB at start ([initStoreDb], awaited by initStorageRoot before any
 * store opens) and writes their changes back after commits and on page
 * hide ([flushStoreDb]).
 */
export 'store_db_host_web.dart' if (dart.library.io) 'store_db_host_io.dart';
