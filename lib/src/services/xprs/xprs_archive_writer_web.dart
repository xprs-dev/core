/// See xprs_archive_writer.dart. No isolates on the web: no writer thread.
library;

/// The archive's writer thread, as the archive sees it.
abstract class XprsArchiveWriterPort {
  bool get alive;

  /// One batch written; the reply, or null when the thread is gone.
  Future<Map<String, Object?>?> write(Map<String, Object?> batch);

  /// Let it finish what it was given, then end.
  void close();
}

/// Never on the web: the archive writes inline there.
Future<XprsArchiveWriterPort?> startArchiveWriter(String path, String? secret) async =>
    null;
