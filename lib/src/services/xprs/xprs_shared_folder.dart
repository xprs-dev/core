/*
 * xprs_shared_folder — a directory on this machine, shared read-only as an
 * XPRS folder (XPRS.md 7.7.2, 7.7.3).
 *
 * Every file in it is hashed (once: the hashes are kept beside the station's
 * data, so 140 GB is not re-read at each start), held for `cmd:file` and for
 * `/api/xprs/file/<ref>` (ranges over HTTP and over a Reticulum link, read
 * from disk where the file lies), served on the files lane, and described in
 * a signed folder listing deposited with the archivers. A listing that has
 * not changed is not published again.
 *
 * The station's maps (`/srv/maps`, server/tool/maps_monthly.sh) are the
 * first such folder; docs/plan-file-sharing.md 2.1.
 */
library;

import 'dart:async';

import '../../platform/fs.dart';
import '../../profile/profile_service.dart';
import '../folders/disk_folder.dart';
import '../log_service.dart';
import '../mesh/mesh_service.dart';
import '../reticulum/rns_service.dart';
import 'xprs_files.dart';
import 'xprs_folder.dart';
import 'xprs_publisher.dart';
import 'xprs_sig.dart';

class XprsSharedFolder {
  XprsSharedFolder(this.dir, {required this.indexDir, String? name})
      : name = name ?? _lastSegment(dir),
        source = DiskFolderSource(dir,
            indexPath: '$indexDir/${_safe(dir)}.json', recursive: false);

  /// The directory shared.
  final String dir;

  /// Where the hash index and the last published listing are kept.
  final String indexDir;

  /// The folder's name in its listing (`maps`).
  final String name;

  final DiskFolderSource source;
  bool _served = false;
  final Set<String> _held = {};
  bool _busy = false;

  String get _publishedPath => '$indexDir/${_safe(dir)}.published';

  /// Hash what changed, hold every file, and publish the listing when it
  /// differs from the last one published. Safe to call on a timer.
  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    try {
      final files = await source.scanAsync();
      if (!_served) {
        RnsService.instance.addFileSource(source);
        _served = true;
      }
      final now = <String>{};
      final entries = <XprsFolderEntry>[];
      for (final f in files) {
        now.add(f.sha);
        entries.add(XprsFolderEntry(shaHex: f.sha, size: f.size, name: f.name));
        XprsFileServer.instance.hold(XprsHeldFile(
            path: f.path, shaHex: f.sha, size: f.size, name: f.name, ext: f.ext));
      }
      for (final gone in _held.difference(now)) {
        XprsFileServer.instance.drop(gone);
      }
      _held
        ..clear()
        ..addAll(now);
      await _publish(entries);
    } catch (e) {
      LogService.instance.add('shared folder $dir: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _publish(List<XprsFolderEntry> entries) async {
    final arch = MeshService.instance.media;
    final key = xprsProfileScalar();
    if (arch == null || key == null || entries.isEmpty) return;
    final listing = xprsListingBuild(entries);
    String last = '';
    try {
      last = fs.file(_publishedPath).readAsStringSync();
    } catch (_) {}
    if (last == listing) return;
    final profile = ProfileService.instance.activeProfile;
    final pub = XprsFolderPublisher(
      self: profile?.callsign ?? MeshService.instance.tableCallsign, // derived-callsign: the station's own name signs it
      key: key,
      store: (bytes, ext, fname) {
        final token = arch.putBytes(bytes, ext, name: fname);
        return xprsFileShaOf(token.substring(5)) ?? '';
      },
      air: (w) => XprsPublisher.instance.publishWire(w, verbatim: true),
      deposit: (ws) => XprsPublisher.instance.depositArchivers(ws, what: 'folder'),
    );
    final sha = await pub.publish(name, entries);
    if (sha == null) return;
    try {
      final f = fs.file(_publishedPath);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(listing);
    } catch (_) {}
    LogService.instance.add('shared folder $name: ${entries.length} files published (listing $sha)');
  }

  static String _lastSegment(String p) {
    final parts = p.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? 'folder' : parts.last;
  }

  static String _safe(String p) =>
      p.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
}
