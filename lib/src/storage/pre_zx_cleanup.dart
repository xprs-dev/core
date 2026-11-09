/*
 * One-time removal of the files the stores kept before they moved to zx:
 * SQLite databases (`*.sqlite3` and their -wal/-shm/-journal sidecars) and
 * the encrypted profile archive `profile.ear`. Nothing reads them any more
 * (the stores started again at an empty zx file; there was no data to
 * migrate), so they would only hold disk space and, in a plain profile,
 * readable copies of old messages.
 *
 * Runs once per storage root (a marker file records it), in the background,
 * walking the tree asynchronously.
 */

import '../platform/fs.dart';

const String _marker = '.pre-zx-removed';

final RegExp _preZx =
    RegExp(r'(\.sqlite3(-wal|-shm|-journal)?|/profile\.ear(-wal|-shm|-journal)?)$');

/// Deletes the pre-zx files under [root] once; returns how many it deleted
/// (0 when it ran before).
Future<int> removePreZxFiles(String root) async {
  final marker = fs.file('$root/$_marker');
  try {
    if (await marker.exists()) return 0;
    final dir = fs.directory(root);
    if (!await dir.exists()) return 0;
    var n = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      final path = e.path.replaceAll('\\', '/');
      if (!_preZx.hasMatch(path)) continue;
      try {
        if (await fs.isFile(e.path)) {
          await fs.file(e.path).delete();
          n++;
        }
      } catch (_) {
        // one file that will not go must not stop the rest
      }
    }
    await marker.writeAsString('removed $n file(s)\n');
    return n;
  } catch (_) {
    return 0;
  }
}
