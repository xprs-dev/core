/*
 * Copyright (c) Max Brito and XPRS contributors
 * License: BSD-3-Clause
 *
 * Materialise one file out of the content-addressed archive so the OS can open
 * it (a PDF in a reader, an APK in the installer, a photo in the gallery).
 *
 * The file lives in the media archive (a zx store) and can be tens or hundreds
 * of MB. Reading it through MediaArchive.get() would pull all of that through
 * the isolate that draws the UI (docs/performance.md §4.1, rule 10). So the
 * read and the write both happen on a WORKER isolate, one piece at a time:
 * one Isolate.run per user-initiated open — never per item, never on a hot
 * path (§3.1).
 */

import 'dart:io';
import 'dart:isolate';

import 'package:reticulum/reticulum.dart' show MediaArchive;

import '../../storage/store_db.dart';

/// Arguments for the worker (must be a plain, sendable value).
class _ExportJob {
  final String dbPath;
  final String key; // MediaArchive storage key (b64u), already normalised
  final String outPath;
  final String? secret; // the store's secret (encrypted profile), else null
  const _ExportJob(this.dbPath, this.key, this.outPath, this.secret);
}

/// Copy the blob for [storageKey] out of the media archive at [dbPath] into
/// [outPath], and return the path (null when the archive does not hold it).
///
/// Runs entirely off the calling isolate. Reuses an existing export when it is
/// already there and non-empty — a second tap on the same file must not rewrite
/// 300 MB.
Future<String?> exportArchiveFile({
  required String dbPath,
  required String storageKey,
  required String outPath,
}) async {
  final existing = File(outPath);
  if (existing.existsSync() && existing.lengthSync() > 0) return outPath;
  if (!File(dbPath).existsSync()) return null;
  // The worker has no keyring: the secret is looked up here.
  final job = _ExportJob(dbPath, storageKey, outPath, storeSecretFor(dbPath));
  return Isolate.run(() => _export(job));
}

String? _export(_ExportJob job) {
  ZxSqlDb? db;
  File? tmp;
  try {
    db = openStoreDbWithSecret(job.dbPath, job.secret);
    final out = File(job.outPath);
    out.parent.createSync(recursive: true);
    // Write to a temp sibling and rename: a killed export must never leave a
    // half-written file behind that a later open would hand to the OS as if it
    // were whole.
    tmp = File('${job.outPath}.part');
    final sink = tmp.openSync(mode: FileMode.write);
    var wrote = 0;
    try {
      for (final part in MediaArchive.partsOf(db, job.key)) {
        sink.writeFromSync(part);
        wrote += part.length;
      }
      sink.flushSync();
    } finally {
      sink.closeSync();
    }
    if (wrote == 0) {
      tmp.deleteSync();
      return null;
    }
    tmp.renameSync(job.outPath);
    return job.outPath;
  } catch (_) {
    try {
      if (tmp != null && tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
    return null;
  } finally {
    db?.dispose();
  }
}
