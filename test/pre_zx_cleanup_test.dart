import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/storage/pre_zx_cleanup.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('pre_zx_'));
  tearDown(() => root.deleteSync(recursive: true));

  File touch(String rel) =>
      File('${root.path}/$rel')..createSync(recursive: true);

  test('removes the SQLite files and profile.ear once, nothing else', () async {
    final gone = [
      touch('devices/X1/data/mesh.sqlite3'),
      touch('devices/X1/data/mesh.sqlite3-wal'),
      touch('devices/X1/data/mesh.sqlite3-shm'),
      touch('devices/X1/wapps/chat/rooms/_hLOCAL.sqlite3'),
      touch('devices/X1/profile.ear'),
      touch('devices/X1/profile.ear-journal'),
    ];
    final kept = [
      touch('devices/X1/data/mesh.zx'),
      touch('devices/X1/profile.zx'),
      touch('devices/X1/keyslot.json'),
      touch('devices/X1/data/notes.sqlite3.txt'),
      touch('devices/X1/data/my.profile.ear.bak'),
    ];

    expect(await removePreZxFiles(root.path), gone.length);
    for (final f in gone) {
      expect(f.existsSync(), isFalse, reason: f.path);
    }
    for (final f in kept) {
      expect(f.existsSync(), isTrue, reason: f.path);
    }

    // once: a file appearing later is not the cleanup's business
    touch('devices/X1/data/late.sqlite3');
    expect(await removePreZxFiles(root.path), 0);
    expect(File('${root.path}/devices/X1/data/late.sqlite3').existsSync(),
        isTrue);
  });
}
