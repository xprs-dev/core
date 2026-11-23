/*
 * The archive's writer thread: where the heard-packet spool is written,
 * checked and pruned, so the isolate that draws the screen never is.
 *
 * Natively a long-lived isolate (xprs_archive_writer_io.dart); on the web,
 * where there are no isolates, nothing, and the archive writes inline as it
 * always did (xprs_archive_writer_web.dart). docs/performance.md 8.1 and
 * 8.27: the write was on the main isolate, sliced, and a slice still took
 * two seconds on a phone.
 */
export 'xprs_archive_writer_web.dart'
    if (dart.library.io) 'xprs_archive_writer_io.dart';
