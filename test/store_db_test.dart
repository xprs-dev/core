// The store opener (lib/src/storage/store_db.dart): plain and encrypted
// profiles, a locked profile, the wrong key, and two isolates on one file.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xprs_core/src/profile/profile_crypto.dart';
import 'package:xprs_core/src/profile/profile_db_common.dart';
import 'package:xprs_core/src/storage/store_db.dart';

void main() {
  late Directory root;
  const id = 'P1';
  setUp(() {
    root = Directory.systemTemp.createTempSync('storedb');
    profileDbRootOverride = root.path;
    Directory('${root.path}/devices/$id/data').createSync(recursive: true);
  });
  tearDown(() {
    ProfileKeyring.instance.lockAll();
    profileDbRootOverride = null;
    root.deleteSync(recursive: true);
  });
  String store(String name) => '${root.path}/devices/$id/data/$name.zx';
  void encrypt([int seed = 7]) {
    File('${root.path}/devices/$id/$keyslotFileName').writeAsStringSync('{}');
    ProfileKeyring.instance.putKeys(
        id,
        UnlockedProfileKeys(
            pmk: Uint8List.fromList(List.filled(32, seed)), nsec: 'nsec1x'));
  }

  test('plain profile: a plain file', () {
    final db = openStoreDb(store('a'));
    db.execute('CREATE TABLE t (v TEXT)');
    db.execute("INSERT INTO t VALUES ('visible-marker')");
    db.dispose();
    expect(storeSecretFor(store('a')), isNull);
    expect(String.fromCharCodes(File(store('a')).readAsBytesSync())
        .contains('visible-marker'), isTrue);
  });

  test('encrypted profile: encrypted, fast, per-store secrets', () {
    encrypt();
    final sw = Stopwatch()..start();
    final db = openStoreDb(store('b'));
    db.execute('CREATE TABLE t (v TEXT)');
    db.execute("INSERT INTO t VALUES ('hidden-marker')");
    db.dispose();
    expect(sw.elapsedMilliseconds, lessThan(3000));
    expect(String.fromCharCodes(File(store('b')).readAsBytesSync())
        .contains('hidden-marker'), isFalse);
    expect(storeSecretFor(store('b')), isNot(storeSecretFor(store('c'))));
    expect(openStoreDb(store('b')).select('SELECT v FROM t').single['v'],
        'hidden-marker');
    // StoreKind.plain stays plain inside an encrypted profile
    final p = openStoreDb(store('plain'), kind: StoreKind.plain)
      ..execute('CREATE TABLE t (v TEXT)')
      ..execute("INSERT INTO t VALUES ('plain-marker')")
      ..dispose();
    expect(p, isNotNull);
    expect(String.fromCharCodes(File(store('plain')).readAsBytesSync())
        .contains('plain-marker'), isTrue);
  });

  test('locked profile throws; another master key is a wrong password', () {
    encrypt();
    openStoreDb(store('c'))
      ..execute('CREATE TABLE t (v)')
      ..dispose();
    ProfileKeyring.instance.lock(id);
    expect(() => openStoreDb(store('c')),
        throwsA(isA<ProfileLockedException>()));
    encrypt(9);
    expect(
        () => openStoreDb(store('c')),
        throwsA(isA<ZxDbException>()
            .having((e) => e.kind, 'kind', ZxDbError.wrongPassword)));
  });

  test('two isolates share an encrypted store through its secret', () async {
    encrypt();
    final path = store('shared');
    openStoreDb(path)
      ..execute('CREATE TABLE t (who TEXT, i INTEGER)')
      ..dispose();
    final secret = storeSecretFor(path);
    Future<void> writer(String who) => Isolate.run(() {
          final db = openStoreDbWithSecret(path, secret);
          for (var b = 0; b < 10; b++) {
            db.transaction(() {
              for (var i = 0; i < 50; i++) {
                db.execute('INSERT INTO t VALUES (?, ?)', [who, i]);
              }
            });
          }
          db.dispose();
        });
    await Future.wait([writer('a'), writer('b')]);
    final db = openStoreDb(path);
    expect(db.select('SELECT COUNT(*) c FROM t').single['c'], 1000);
    db.dispose();
  });
}
