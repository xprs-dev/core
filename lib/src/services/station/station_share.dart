/*
 * What this node's owner shares from it: files put into a room it hosts,
 * exactly as the web page puts them (portal chat_page.html, galUpload): the
 * preview where the kind shows one, the file itself, then the item
 * (`t:message r:<folder> file:<preview>`) and its `t:file` naming the
 * original. The room and the folder are made when they are not there.
 *
 * Everything goes through the node's own visitor API as its owner
 * (StationHost.own), so a share made here reads the same from a browser,
 * another phone or a firmware station's page. A file is hashed and filed as
 * it is read, never held whole (performance.md 8); only a picture is decoded
 * for its preview, on a worker.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../platform/fs.dart';
import '../background_service.dart';
import '../log_service.dart';
import '../media/media_preview.dart';
import '../receive/core_state.dart';
import '../xprs/xprs_vocab.dart' show xprsNowTs;
import '../web_chat_api.dart';
import 'station_api.dart';
import 'station_host.dart';

/// The page's `slugOf`: lower case, runs of anything else become one dash,
/// at most 40 characters.
String stationSlug(String t) {
  var s = t.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (s.length > 40) s = s.substring(0, 40);
  return s.replaceAll(RegExp(r'-+$'), '');
}

/// The page's `galSize`.
String stationSizeWord(int n) => n >= 1073741824
    ? '${(n / 1073741824).toStringAsFixed(1)}GB'
    : n >= 1048576
        ? '${(n / 1048576).toStringAsFixed(1)}MB'
        : '${(n / 1024).round() < 1 ? 1 : (n / 1024).round()}kB';

class StationShare {
  StationShare._();
  static final StationShare instance = StationShare._();

  /// The room a kind gets when its first files are shared.
  static const Map<String, String> roomNames = {
    'gallery': 'Photos',
    'music': 'Music',
    'library': 'Files',
  };

  bool busy = false;
  int done = 0, total = 0, failed = 0;
  String why = '';

  /// What is being shared now: `{busy, done, total, failed, why?}`.
  Map<String, dynamic> get state => {
        'busy': busy,
        'done': done,
        'total': total,
        'failed': failed,
        if (why.isNotEmpty) 'why': why,
      };

  String _ext(String path) {
    final m = RegExp(r'\.([A-Za-z0-9]{1,8})$').firstMatch(path);
    return m == null ? 'bin' : m[1]!.toLowerCase().replaceAll('jpeg', 'jpg');
  }

  static String _base(String path) {
    final n = path.replaceAll('\\', '/').split('/').last;
    return n.replaceFirst(RegExp(r'\.[^.]*$'), '');
  }

  Uint8List _json(Map<String, Object?> j) => Uint8List.fromList(utf8.encode(jsonEncode(j)));

  /// Put the files at [paths] into folder [folder] of this node's [kind]
  /// room (`gallery`, `music` or `library`), [private] or for everybody.
  /// One share at a time; progress is [state], told by `core.station`.
  Future<bool> add({
    required String kind,
    required String folder,
    required List<String> paths,
    bool private = false,
  }) async {
    if (busy || paths.isEmpty || !roomNames.containsKey(kind)) return false;
    busy = true;
    done = 0;
    failed = 0;
    total = paths.length;
    why = '';
    void tell() => CoreState.instance.changed(CoreState.station);
    tell();
    try {
      final v = StationHost.instance.own();
      final api = StationHost.instance.api;
      final s = await v?.session();
      if (v == null || api == null || s == null || !await StationHost.instance.ensureOwner()) {
        why = 'owner';
        return false;
      }
      final me = v.visitor!.call;
      // The room of this kind and audience, made when there is none.
      final want = private ? 'private' : 'public';
      var room = '';
      for (final r in await v.rooms() ?? const <StationRoom>[]) {
        if (r.kind == kind && r.visibility == want) {
          room = r.call;
          break;
        }
      }
      if (room.isEmpty) {
        final made = await v.call('POST', '/api/rooms', const {}, _json({
          'action': 'create', 'session': s, 'kind': kind,
          'name': private ? '${roomNames[kind]} (private)' : roomNames[kind],
          'visibility': want, 'posting': 'members',
        }));
        room = '${made?.json['room'] ?? ''}';
        if (made == null || !made.ok || room.isEmpty) {
          why = 'room';
          return false;
        }
      }
      // The folder, by its title.
      final title = stationSlug(folder).isEmpty ? 'shared' : stationSlug(folder);
      var folderId = '';
      for (final f in await v.topics(room) ?? const <StationTopic>[]) {
        if (stationSlug(f.title) == title) {
          folderId = f.id;
          break;
        }
      }
      if (folderId.isEmpty) {
        final r = await v.send('t:blog f:$me d:$room ts:${xprsNowTs()} title:$title m:${folder.trim().isEmpty ? title : folder.trim()}');
        folderId = '${r?.json['id'] ?? ''}';
        if (r == null || !r.ok || folderId.isEmpty) {
          why = 'folder';
          return false;
        }
      }
      for (final path in paths) {
        final ok = await _one(v, api, s, me, room, folderId, kind, path);
        ok ? done++ : failed++;
        tell();
      }
      LogService.instance.add('station: shared $done of $total file(s) as $kind${failed > 0 ? ', $failed failed' : ''}');
      return failed == 0;
    } catch (e) {
      why = 'failed';
      LogService.instance.add('station: sharing failed: ${e.runtimeType}');
      return false;
    } finally {
      busy = false;
      tell();
    }
  }

  Future<bool> _one(StationVisit v, WebChatApi api, String s, String me, String room,
      String folderId, String kind, String path) async {
    final f = fs.file(path);
    if (!await f.exists()) return false;
    final size = await f.length();
    final ext = _ext(path);
    // The reference first (the bytes are read twice, never held).
    final digest = await crypto.sha256.bind(f.openRead()).first;
    final oref = '${base64Url.encode(digest.bytes).replaceAll('=', '')}.$ext';
    final q = {'room': room, 'session': s};
    final up = api.beginFilePut(oref, q, 'self', size);
    if (up.reply == null) {
      await for (final chunk in f.openRead()) {
        up.add(chunk);
      }
    }
    final kept = up.finish();
    if (kept.status != 200) {
      LogService.instance.add('station: a file was not kept (${kept.status})');
      return false;
    }
    // A gallery shows a preview; a picture this build cannot read goes
    // without (the grid shows its name).
    var pref = '';
    if (kind == 'gallery' && size <= kPreviewSourceMax) {
      try {
        // arch-ignore: no-whole-file-read a picture decoded for its preview, at most kPreviewSourceMax
        final bytes = await f.readAsBytes();
        final small = await BackgroundService.runOffThread(() async => MediaPreviews.shrink(bytes));
        if (small != null) {
          final p = '${base64Url.encode(crypto.sha256.convert(small).bytes).replaceAll('=', '')}.jpg';
          final r = await v.call('POST', '/api/xprs/file/$p', {'preview': '1', ...q}, small);
          if (r != null && r.ok) pref = p;
        }
      } catch (_) {}
    }
    final cap = stationSlug(_base(path));
    final item = await v.send('t:message f:$me d:$room ts:${xprsNowTs()} r:$folderId'
        '${pref.isEmpty ? '' : ' file:$pref'}${cap.isEmpty ? '' : ' m:$cap'}');
    final pid = '${item?.json['id'] ?? ''}';
    if (item == null || !item.ok || pid.isEmpty) return false;
    final named = await v.send('t:file f:$me d:$room ts:${xprsNowTs()} r:$pid file:$oref '
        'size:${stationSizeWord(size)} name:${cap.isEmpty ? 'file' : cap}.$ext');
    return named != null && named.ok;
  }
}
