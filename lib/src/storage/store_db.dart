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
 * - Writes outside a transaction are a commit each (a millisecond and some
 *   file): stores batch them in [ZxSqlDb.transaction].
 * - Tables are created `WITH (compression = 'fast')` by default.
 */

import 'package:zx/zxdb.dart';

import '../profile/profile_db_common.dart';

export 'package:zx/zxdb.dart'
    show ZxSqlDb, ZxRow, ZxRows, ZxSqlDbStatement, ZxSqlDbStats, ZxKvStore,
        ZxKvEntry, ZxDbException, ZxDbError;
export '../profile/profile_db_common.dart' show ProfileLockedException;

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
ZxSqlDb openStoreDb(String absPath,
    {StoreKind kind = StoreKind.profile, bool durable = false}) {
  final secret = kind == StoreKind.plain ? null : storeSecretFor(absPath);
  return openStoreDbWithSecret(absPath, secret, durable: durable);
}

/// Opens the store at [absPath] with a secret from [storeSecretFor] (null:
/// plain), for isolates without the keyring.
ZxSqlDb openStoreDbWithSecret(String absPath, String? secret,
        {bool durable = false}) =>
    ZxSqlDb.open(absPath,
        password: secret,
        scryptLog2N: 1,
        durable: durable,
        lockWaitMs: storeLockWaitMs);

/// A store in memory (tests; a store without a path).
ZxSqlDb openMemoryStoreDb() => ZxSqlDb.memory();
