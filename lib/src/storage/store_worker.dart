/*
 * store_worker — a store's writes and heavy reads on a thread of their own.
 *
 * The shape the archive writer proved (xprs_archive_writer_io.dart,
 * performance.md 8.28), made reusable: a long-lived isolate opens the same
 * zx file and runs named operations against it, while the main isolate keeps
 * reading it directly (zx shows each isolate the other's commits on its next
 * statement). Operations go in order: a `post` is fire and forget, a `call`
 * answers. What crosses is data (maps, lists, numbers, strings, bytes).
 *
 * The store side is a [StoreWorkerTarget], made in the worker by a factory
 * that must be a top-level or static function (it is sent to the isolate).
 * On the web there are no isolates: [startStoreWorker] returns null and the
 * caller does the work inline, as before.
 */
export 'store_worker_web.dart' if (dart.library.io) 'store_worker_io.dart';
