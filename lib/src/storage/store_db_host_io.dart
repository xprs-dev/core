/*
 * Native half of the store files' host (store_db_host.dart): the stores are
 * real files, nothing to load or persist.
 */

/// Nothing to do natively.
Future<void> initStoreDb() async {}

/// Tests: nothing to reset natively.
void resetStoreDbHostForTest() {}

/// Nothing to do natively: every commit is in the file.
Future<void> flushStoreDb() async {}
