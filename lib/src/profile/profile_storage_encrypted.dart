/*
 * Encrypted profile storage backend (docs/plan-encrypted-storage.md).
 *
 * Routes a profile's file tree between two stores:
 *
 *   - profile.zx (a zx store, encrypted with the profile's store secret):
 *     every loose user file — data/<wapp>/kv.json, hal_file_* files,
 *     avatar.png, chat JSON, … — in the KV store `files` (key: the
 *     profile-relative path; value: 8 bytes of modification time in ms,
 *     big-endian, a kind byte, then the content (kind 0) or, for a file
 *     copied in from outside (kind 1), its size (8 bytes) and the 16-byte
 *     id of its pieces in the KV store `parts` (key: id + 4-byte index,
 *     [pieceSize] each), streamed in and out so a big file is never whole
 *     on the heap there); the explicitly created directories are in the KV
 *     store `dirs`
 *   - filesystem passthrough: things that MUST be real files —
 *       * wapp packages (`wapps/…`, public software, scope decision)
 *       * every store (`*.zx`, encrypted by zx itself through openStoreDb;
 *         live handles of another store cannot run inside this one)
 *       * RNS runtime files bound by absolute path from RnsService
 *         (identity key + folder keystore are individually encrypted via
 *         SecureProfileFile; see _passthroughFiles)
 *       * the keyslot / seed markers / profile.zx itself
 *
 * The store opens on first use (synchronously, so the WASM HAL's sync calls
 * work from the start) while the profile is unlocked, and is closed when the
 * profile locks. Every write is one commit.
 */

import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';


import '../platform/fs.dart';
import '../storage/store_db.dart';
import 'profile_keyring.dart';
import 'profile_storage.dart';
import 'profile_storage_fs.dart';

/// Name of the per-profile store of loose files.
const String profileArchiveName = 'profile.zx';

class EncryptedProfileStorage extends ProfileStorage {
  final String profileId;
  final String _basePath; // absolute devices/<id>, no trailing slash
  final FilesystemProfileStorage _fs;

  EncryptedProfileStorage(this.profileId, String basePath)
      : _basePath = _stripTrailingSlash(basePath),
        _fs = FilesystemProfileStorage(basePath) {
    _registerLockHook();
  }

  static String _stripTrailingSlash(String p) {
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  // ── the profile store ──────────────────────────────────────────────────

  static final Map<String, ZxSqlDb> _stores = {};
  static bool _hookRegistered = false;

  static void _registerLockHook() {
    if (_hookRegistered) return;
    _hookRegistered = true;
    ProfileKeyring.instance.onLock.add(closeArchive);
  }

  /// Close (and drop) the open profile store of [profileId]. Called
  /// automatically when the keyring locks a profile.
  static Future<void> closeArchive(String profileId) async {
    try {
      _stores.remove(profileId)?.dispose();
    } catch (_) {}
  }

  static Future<void> closeAllArchives() async {
    for (final id in _stores.keys.toList()) {
      await closeArchive(id);
    }
  }

  /// The open profile store; opens it on first use. Throws
  /// [ProfileLockedException] while the profile is locked.
  ZxSqlDb _store() {
    final cached = _stores[profileId];
    if (cached != null) return cached;
    if (ProfileKeyring.instance.keysFor(profileId) == null) {
      throw ProfileLockedException(profileId, _basePath);
    }
    final db = openStoreDb('$_basePath/$profileArchiveName');
    _stores[profileId] = db;
    return db;
  }

  ZxKvStore get _files => _store().kv('files');
  ZxKvStore get _dirs => _store().kv('dirs');

  static Uint8List _key(String p) => Uint8List.fromList(utf8.encode(p));

  ZxKvStore get _parts => _store().kv('parts');

  /// The size of one piece of a file copied in from outside.
  static const int pieceSize = 256 << 10;

  /// Pieces written per commit while copying a file in.
  static const int _piecesPerCommit = 16;

  static Uint8List _pack(Uint8List bytes) {
    final out = Uint8List(9 + bytes.length);
    ByteData.sublistView(out).setInt64(0, DateTime.now().millisecondsSinceEpoch);
    out.setRange(9, out.length, bytes);
    return out;
  }

  static Uint8List _packPieces(int size, Uint8List id) {
    final out = Uint8List(9 + 8 + 16);
    final d = ByteData.sublistView(out)
      ..setInt64(0, DateTime.now().millisecondsSinceEpoch)
      ..setInt64(9, size);
    d.setUint8(8, 1);
    out.setRange(17, 33, id);
    return out;
  }

  static bool _inPieces(Uint8List v) => v[8] == 1;
  static int _size(Uint8List v) =>
      _inPieces(v) ? ByteData.sublistView(v).getInt64(9) : v.length - 9;
  static Uint8List _piecesId(Uint8List v) => Uint8List.sublistView(v, 17, 33);

  static Uint8List _pieceKey(Uint8List id, int n) {
    final k = Uint8List(20)..setRange(0, 16, id);
    ByteData.sublistView(k).setUint32(16, n);
    return k;
  }

  /// The pieces of a kind-1 file, in order.
  Iterable<Uint8List> _piecesOf(Uint8List v) =>
      _parts.scan(prefix: _piecesId(v)).map((e) => e.value);

  /// The content of a stored value (a kind-1 file stitched together).
  Uint8List _content(Uint8List v) {
    if (!_inPieces(v)) return Uint8List.fromList(Uint8List.sublistView(v, 9));
    final out = BytesBuilder(copy: false);
    for (final piece in _piecesOf(v)) {
      out.add(piece);
    }
    return out.takeBytes();
  }

  /// Drops the pieces of [old] (a value being replaced or deleted).
  void _dropPieces(Uint8List? old) {
    if (old == null || !_inPieces(old)) return;
    final parts = _parts;
    final keys = [for (final e in parts.scan(prefix: _piecesId(old))) e.key];
    for (var i = 0; i < keys.length; i += 64) {
      final chunk = keys.sublist(i, (i + 64).clamp(0, keys.length));
      parts.batch((b) => chunk.forEach(b.delete));
    }
  }

  /// Stores [value] under [p], dropping the pieces of what it replaces.
  void _put(String p, Uint8List value) {
    final files = _files;
    final old = files.get(_key(p));
    files.put(_key(p), value);
    _dropPieces(old);
  }

  void _remove(String p) {
    final files = _files;
    final old = files.get(_key(p));
    if (old == null) return;
    files.delete(_key(p));
    _dropPieces(old);
  }
  static DateTime _modified(Uint8List v) => DateTime.fromMillisecondsSinceEpoch(
      ByteData.sublistView(v).getInt64(0));

  // ── absolute-path bridge (WASM HAL etc.) ───────────────────────────────

  /// For code that only has an absolute path: returns the encrypted storage
  /// + profile-relative path when [absPath] falls inside an encrypted
  /// profile AND is store-routed. Null → caller should use dart:io.
  static ({EncryptedProfileStorage storage, String rel})? routeAbsolutePath(
      String absPath) {
    final loc = locateProfileDb(absPath);
    if (loc == null) return null;
    if (!ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) return null;
    if (isPassthroughPath(loc.relPath)) return null;
    final root = '${profileStorageRoot()}/devices/${loc.profileId}';
    return (
      storage: EncryptedProfileStorage(loc.profileId, root),
      rel: loc.relPath,
    );
  }

  // ── routing ────────────────────────────────────────────────────────────

  /// Files that RnsService & friends bind by ABSOLUTE path and read/write
  /// with dart:io — they must stay real files. The secrets among them
  /// (rns_identity.key, folders.json) are individually encrypted via
  /// SecureProfileFile. If you add a new absolute-path file to
  /// rns_autostart, add it here too, or it will land in the archive and
  /// dart:io access will break for encrypted profiles.
  static const Set<String> _passthroughFiles = {
    'data/rns_identity.key',
    'data/folders.json',
    'data/call_peers.json',
    'data/disk_folders.json',
    'data/folder_subscriptions.json',
    'data/host_follows.json',
    'data/hero_inbox.json',
    'data/hero_media.json',
  };

  static const List<String> _passthroughPrefixes = [
    'wapps/', // wapp packages (public software) + their zx stores
    'data/partials/', // resumable-download chunks, dart:io dir scans
    'data/mesh/', // mesh bulk custody chunks (dart:io, MeshService)
    'data/share/', // MediaFileSource share dir (dart:io, reticulum)
  ];

  static bool isPassthroughPath(String relativePath) {
    final p = _normalizeRel(relativePath);
    if (p.isEmpty) return false;
    if (p == keyslotFileName || p == profileArchiveName) return true;
    if (p.startsWith('$profileArchiveName-')) return true; // -wal / -shm
    if (p.startsWith('.seeded')) return true;
    // zx stores encrypt themselves (store_db.dart); the lock file beside
    if (RegExp(r'\.zx(-lock)?$').hasMatch(p)) return true;
    if (_passthroughFiles.contains(p)) return true;
    for (final prefix in _passthroughPrefixes) {
      if (p.startsWith(prefix) || p == prefix.substring(0, prefix.length - 1)) {
        return true;
      }
    }
    return false;
  }

  static String _normalizeRel(String relativePath) {
    var p = relativePath.replaceAll('\\', '/');
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p.replaceAll(RegExp(r'/+'), '/');
  }

  // ── ProfileStorage interface ───────────────────────────────────────────

  @override
  String get basePath => _basePath;

  @override
  bool get isEncrypted => true;

  @override
  String getAbsolutePath(String relativePath) =>
      _fs.getAbsolutePath(relativePath);

  @override
  Future<String?> readString(String relativePath) async {
    final bytes = await readBytes(relativePath);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> readBytes(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.readBytes(p);
    return _readSync(p);
  }

  Uint8List? _readSync(String p) {
    final v = _files.get(_key(p));
    return v == null ? null : _content(v);
  }

  @override
  Future<void> writeString(String relativePath, String content) =>
      writeBytes(relativePath, Uint8List.fromList(utf8.encode(content)));

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.writeBytes(p, bytes);
    _put(p, _pack(bytes));
  }

  @override
  Future<void> appendString(String relativePath, String content) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.appendString(p, content);
    final existing = _readSync(p);
    final add = Uint8List.fromList(utf8.encode(content));
    if (existing == null) {
      return writeBytes(p, add);
    }
    final merged = Uint8List(existing.length + add.length)
      ..setRange(0, existing.length, existing)
      ..setRange(existing.length, existing.length + add.length, add);
    return writeBytes(p, merged);
  }

  @override
  Future<bool> exists(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.exists(p);
    return _files.get(_key(p)) != null;
  }

  @override
  Future<void> delete(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.delete(p);
    _remove(p); // a missing file is a no-op, as on the fs
  }

  @override
  Future<void> copyFromExternal(String externalPath, String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.copyFromExternal(externalPath, p);
    // Streamed in pieces under a fresh id; the file's entry is written
    // last, so an interrupted copy leaves no half file behind.
    final id = Uint8List.fromList(
        List<int>.generate(16, (_) => _rand.nextInt(256)));
    final parts = _parts;
    var n = 0, size = 0;
    final pending = <(Uint8List, Uint8List)>[];
    void flush() {
      if (pending.isEmpty) return;
      final batch = List.of(pending);
      pending.clear();
      parts.batch((b) {
        for (final (k, v) in batch) {
          b.put(k, v);
        }
      });
    }

    final buf = BytesBuilder(copy: false);
    void cut(bool all) {
      while (buf.length >= pieceSize || (all && buf.length > 0)) {
        final bytes = buf.takeBytes();
        final take = bytes.length < pieceSize ? bytes.length : pieceSize;
        pending.add((_pieceKey(id, n++), Uint8List.sublistView(bytes, 0, take)));
        size += take;
        if (take < bytes.length) buf.add(Uint8List.sublistView(bytes, take));
        if (pending.length >= _piecesPerCommit) flush();
      }
    }

    await for (final chunk in fs.file(externalPath).openRead()) {
      buf.add(chunk);
      cut(false);
    }
    cut(true);
    flush();
    _put(p, _packPieces(size, id));
  }

  static final _rand = Random.secure();

  @override
  Future<void> copyToExternal(String relativePath, String externalPath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.copyToExternal(p, externalPath);
    final v = _files.get(_key(p));
    if (v == null) {
      throw StateError('$p is not in the profile store');
    }
    final dest = fs.file(externalPath);
    await dest.parent.create(recursive: true);
    final sink = dest.openWrite();
    try {
      if (_inPieces(v)) {
        for (final piece in _piecesOf(v)) {
          sink.add(piece);
        }
      } else {
        sink.add(Uint8List.sublistView(v, 9));
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  // ── directory ops ──────────────────────────────────────────────────────

  @override
  Future<List<StorageEntry>> listDirectory(String relativePath,
      {bool recursive = false}) async {
    final p = _normalizeRel(relativePath);

    // Merge: filesystem side (wapps/, stores, markers) + profile store side.
    final out = <String, StorageEntry>{};

    if (await _fs.directoryExists(p)) {
      for (final e in await _fs.listDirectory(p, recursive: recursive)) {
        // Hide the profile store + keyslot from listings of the root.
        if (e.path == profileArchiveName ||
            e.path.startsWith('$profileArchiveName-') ||
            e.path == keyslotFileName) {
          continue;
        }
        out[e.path] = e;
      }
    }

    final prefix = p.isEmpty ? '' : '$p/';
    void addDir(String dirPath) => out.putIfAbsent(
        dirPath,
        () => StorageEntry(
            name: dirPath.substring(dirPath.lastIndexOf('/') + 1),
            path: dirPath,
            isDirectory: true));

    // A path under the listed one: itself when it is a direct child (or
    // recursive), else its first segment as a directory.
    String? direct(String path) {
      final tail = path.substring(prefix.length);
      if (tail.isEmpty) return null;
      if (!recursive && tail.contains('/')) {
        addDir(prefix + tail.substring(0, tail.indexOf('/')));
        return null;
      }
      return path;
    }

    final pk = prefix.isEmpty ? null : _key(prefix);
    for (final e in _dirs.scan(prefix: pk)) {
      final d = direct(e.keyString);
      if (d != null) addDir(d);
    }
    for (final e in _files.scan(prefix: pk)) {
      final f = direct(e.keyString);
      if (f == null) continue;
      if (recursive) {
        // the directories on the way down
        var at = f.indexOf('/', prefix.length);
        while (at > 0) {
          addDir(f.substring(0, at));
          at = f.indexOf('/', at + 1);
        }
      }
      out[f] = StorageEntry(
        name: f.substring(f.lastIndexOf('/') + 1),
        path: f,
        isDirectory: false,
        size: _size(e.value),
        modified: _modified(e.value),
      );
    }
    return out.values.toList();
  }

  @override
  Future<void> createDirectory(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.createDirectory(p);
    // Real directory too: store files / passthrough children of this
    // directory need it to exist on disk.
    await _fs.createDirectory(p);
    if (p.isNotEmpty) _dirs.put(_key(p), Uint8List(0));
  }

  @override
  Future<bool> directoryExists(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (await _fs.directoryExists(p)) return true;
    if (isPassthroughPath(p)) return false;
    if (_dirs.get(_key(p)) != null) return true;
    final under = _key('$p/');
    return _files.scan(prefix: under, limit: 1).isNotEmpty ||
        _dirs.scan(prefix: under, limit: 1).isNotEmpty;
  }

  @override
  Future<void> deleteDirectory(String relativePath, {bool recursive = false}) async {
    final p = _normalizeRel(relativePath);
    if (await _fs.directoryExists(p)) {
      await _fs.deleteDirectory(p, recursive: recursive);
    }
    if (isPassthroughPath(p)) return;
    // One batch (one commit) per KV store.
    if (recursive) {
      final under = _key('$p/');
      final files = _files;
      final doomed = [for (final e in files.scan(prefix: under)) e];
      if (doomed.isNotEmpty) {
        files.batch((b) {
          for (final e in doomed) {
            b.delete(e.key);
          }
        });
        for (final e in doomed) {
          _dropPieces(e.value);
        }
      }
    }
    final dirs = _dirs;
    final doomedDirs = [
      if (recursive) for (final e in dirs.scan(prefix: _key('$p/'))) e.key,
      if (dirs.get(_key(p)) != null) _key(p),
    ];
    if (doomedDirs.isNotEmpty) dirs.batch((b) => doomedDirs.forEach(b.delete));
  }

  @override
  Future<void> renameDirectory(String fromRelative, String toRelative) async {
    final from = _normalizeRel(fromRelative);
    final to = _normalizeRel(toRelative);
    if (from.isEmpty || to.isEmpty || from == to) return;
    if (await directoryExists(to)) return;

    if (await _fs.directoryExists(from)) {
      await _fs.renameDirectory(from, to);
    }
    if (isPassthroughPath(from)) return;

    // One batch (one commit) per KV store: the files, then the directories.
    final under = _key('$from/');
    for (final kv in [_files, _dirs]) {
      final moved = [
        for (final e in kv.scan(prefix: under))
          (e.key, '$to/${e.keyString.substring(from.length + 1)}', e.value),
        if (kv.name == 'dirs' && kv.get(_key(from)) != null)
          (_key(from), to, Uint8List(0)),
      ];
      if (moved.isEmpty) continue;
      kv.batch((b) {
        for (final (old, now, v) in moved) {
          b.delete(old);
          b.put(_key(now), Uint8List.fromList(v));
        }
      });
    }
  }

  // ── sync variants (WASM HAL) ───────────────────────────────────────────

  @override
  Uint8List? readBytesSync(String relativePath) {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.readBytesSync(p);
    return _readSync(p);
  }

  @override
  void writeStringSync(String relativePath, String content) =>
      writeBytesSync(relativePath, Uint8List.fromList(utf8.encode(content)));

  @override
  void writeBytesSync(String relativePath, Uint8List bytes) {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) {
      _fs.writeBytesSync(p, bytes);
      return;
    }
    _put(p, _pack(bytes));
  }

  @override
  bool existsSync(String relativePath) {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.existsSync(p);
    return _files.get(_key(p)) != null;
  }
}
