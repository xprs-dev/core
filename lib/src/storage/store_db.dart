/*
 * The one way a store opens its database: a zxdb file (`.zx`, package
 * zx/zxdb.dart) through [openStoreDb]. app/docs/architecture.md, "Storage".
 *
 * - One file per store (one writer per file: stores never wait on each
 *   other's commits, a compaction rewrites one store).
 * - Inside an encrypted profile the store is encrypted with its own secret,
 *   HKDF(profile master key, "xprs-zx-v1:" + its path in the profile)
 *   (profile_crypto.dart storeSecret), opened without password stretching
 *   (the secret is random at full strength). A locked profile throws
 *   [ProfileLockedException]. Plain profiles and paths outside a profile
 *   give a plain file.
 * - Several isolates may open one file (the app's UI engine and its
 *   headless twin; a worker): writes wait up to four seconds for each
 *   other, reads see the other side's commits at once.
 * - Writes outside a transaction are a commit each: about 6 to 12 KB of
 *   file and several milliseconds, whatever the row (measured on the Pi;
 *   50 rows in one transaction cost about 1 KB each). A store that writes
 *   per event queues its writes and commits them in batches; a store of
 *   rare writes may commit each.
 * - Tables are created `WITH (compression = 'fast')` by default.
 */

import 'package:zx/zxdb.dart';

import '../profile/profile_keyring.dart';

export 'package:zx/zxdb.dart'
    show ZxSqlDb, ZxRow, ZxRows, ZxSqlDbStatement, ZxSqlDbStats, ZxKvStore,
        ZxKvEntry, ZxDbException, ZxDbError;
export '../profile/profile_keyring.dart' show ProfileLockedException;
export 'store_db_host.dart' show initStoreDb, flushStoreDb;

/// Whether a store is encrypted with its profile.
enum StoreKind {
  /// Encrypted inside an encrypted profile (the default).
  profile,

  /// Never encrypted: written by code that may run while the profile is
  /// locked (the headless engine before unlock).
  plain,
}

/// How long a write waits for another writer of the same file.
const int storeLockWaitMs = 4000;

/// The secret of the store at [absPath], or null when it is not inside an
/// encrypted profile. Throws [ProfileLockedException] when the profile is
/// encrypted and locked. An isolate that cannot reach the keyring gets this
/// in its spawn message and opens with [openStoreDbWithSecret].
String? storeSecretFor(String absPath) {
  final loc = locateProfileDb(absPath);
  if (loc == null ||
      !ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) {
    return null;
  }
  final keys = ProfileKeyring.instance.keysFor(loc.profileId);
  if (keys == null) throw ProfileLockedException(loc.profileId, absPath);
  return keys.storeSecret(loc.relPath);
}

/// Opens (creating it when missing) the store at [absPath].
///
/// [pageSize] 4096 suits a store of many small commits (a commit rewrites
/// the pages it touches); the default 16384 suits scans.
///
/// [autoCompact]: the store rewrites its file by itself once it has doubled
/// (zx's ZxDb). Right for the small stores; a store that can grow large
/// (the packet archive, the media archive) passes false and calls
/// `maybeCompact` where a pause costs nothing.
ZxSqlDb openStoreDb(String absPath,
    {StoreKind kind = StoreKind.profile,
    bool durable = false,
    int pageSize = 16384,
    bool autoCompact = true}) {
  final secret = kind == StoreKind.plain ? null : storeSecretFor(absPath);
  return openStoreDbWithSecret(absPath, secret,
      durable: durable, pageSize: pageSize, autoCompact: autoCompact);
}

/// True in the dart2js build of the web page (a browser without WebAssembly
/// GC gets it as Flutter's fallback): numbers are JavaScript doubles there,
/// and zxdb needs 64-bit integers. False natively and under dart2wasm.
const bool storesUnavailable = identical(0, 0.0);

/// Opens the store at [absPath] with a secret from [storeSecretFor] (null:
/// plain), for isolates without the keyring.
ZxSqlDb openStoreDbWithSecret(String absPath, String? secret,
    {bool durable = false, int pageSize = 16384, bool autoCompact = true}) {
  if (storesUnavailable) {
    // Every store degrades to no persistence on an open failure.
    throw UnsupportedError('stores need the WebAssembly build of the page '
        '(a browser with WebAssembly GC: Chrome 119, Firefox 120, Safari 18.2)');
  }
  return ZxSqlDb.open(absPath,
        password: secret,
        scryptLog2N: 1,
        durable: durable,
      lockWaitMs: storeLockWaitMs,
      pageSize: pageSize,
      autoCompact: autoCompact);
}

/// A store in memory (tests; a store without a path).
ZxSqlDb openMemoryStoreDb() => ZxSqlDb.memory();
