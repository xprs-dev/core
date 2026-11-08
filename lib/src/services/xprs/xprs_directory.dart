/*
 * xprs_directory — who keeps what, exchanged between archivers (XPRS.md 12.9).
 *
 * Archivers never exchange content; what they exchange is a DIRECTORY: which
 * callsigns each is archiving or receiving from, and when it last heard each.
 * A text listing in the 7.7.2 family, one line per callsign, sorted:
 *
 *   XDIR1
 *   CT1ABC-9 2026-08-17_13:40:11
 *   X1BOA3 2026-08-17_14:02:36
 *
 * It is an ordinary content-addressed file, named in the archiver's signed
 * `t:service … file:<ref>.xdir` announcement, fetched with `cmd:file` and
 * verified against its reference like anything else. An unchanged directory
 * has an unchanged hash, so a quiet peer costs nothing to poll; a consumer
 * keeps POINTERS (callsign, which archiver, how fresh), never the content.
 *
 * Three pieces, each with its sends injected so the whole thing runs on a
 * bench (the pattern of XprsMailbox and XprsForwarder):
 *
 *   XprsDirectory          compose / parse, pure.
 *   XprsDirectoryAnnouncer WHEN to publish: a public archiver, on the minute
 *                          sweep, every ten minutes, and only when the text
 *                          changed. Stores the bytes, holds the file, signs
 *                          and airs the announcement, deposits it with the
 *                          station's archivers (12.9: the announcement is one
 *                          of the four things that cross).
 *   XprsDirectoryConsumer  WHAT to do with one heard: from an archiver this
 *                          station named or adopted, fetch the file once per
 *                          (archiver, digest), parse it, keep the pointers.
 *
 * `count:` on the announcement stays what 13.0.1 made it: RECORDS held,
 * never callsigns; how many callsigns the directory lists is learned by
 * fetching it.
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:reticulum/reticulum.dart' show MediaRef;

import '../log_service.dart';
import 'xprs_gossip.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

/// One directory line: a callsign and when the archiver last heard it.
class XprsDirectoryEntry {
  const XprsDirectoryEntry(this.call, this.tsMs);
  final String call;
  final int tsMs;

  @override
  bool operator ==(Object other) =>
      other is XprsDirectoryEntry && other.call == call && other.tsMs == tsMs;
  @override
  int get hashCode => Object.hash(call, tsMs);
  @override
  String toString() => '$call ${xprsNowTs(tsMs)}';
}

class XprsDirectory {
  XprsDirectory._();

  static const String magic = 'XDIR1';
  static const String ext = 'xdir';

  /// The largest listing a consumer reads: ten thousand callsigns are about
  /// 280 kB (12.9), so a megabyte is a bound nobody honest reaches, and a
  /// file past it is not a directory.
  static const int maxBytes = 1 << 20;

  /// The listing: header, then one line per callsign, sorted by callsign;
  /// a callsign named twice keeps its freshest time. Lines end in `\n`.
  static String compose(Iterable<XprsDirectoryEntry> entries) {
    final best = <String, int>{};
    for (final e in entries) {
      final c = e.call.trim().toUpperCase();
      if (c.isEmpty || c.contains(' ')) continue;
      final was = best[c];
      if (was == null || e.tsMs > was) best[c] = e.tsMs;
    }
    final calls = best.keys.toList()..sort();
    final b = StringBuffer('$magic\n');
    for (final c in calls) {
      b.write('$c ${xprsNowTs(best[c]!)}\n');
    }
    return b.toString();
  }

  /// The entries of a listing, or null when the text is not one. A line
  /// that does not parse is skipped rather than failing the file: a
  /// directory line is a claim priced like a false `hears:`, one wasted
  /// redirect per reader (12.9).
  static List<XprsDirectoryEntry>? parse(String text) {
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty || lines.first.trim() != magic) return null;
    final out = <XprsDirectoryEntry>[];
    for (final raw in lines.skip(1)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final sp = line.indexOf(' ');
      if (sp <= 0) continue;
      final call = line.substring(0, sp).trim().toUpperCase();
      final ts = xprsParseTs(line.substring(sp + 1).trim());
      if (call.isEmpty || ts == null) continue;
      out.add(XprsDirectoryEntry(call, ts));
    }
    return out;
  }

  /// The SHA-256 of [text]'s UTF-8 bytes, lowercase hex: the file's identity.
  static String shaOf(String text) =>
      crypto.sha256.convert(utf8.encode(text)).toString();

  /// The `file:` value of a listing with digest [shaHex]: 43 base64url
  /// characters, a dot, `xdir` (7.7).
  static String? refOf(String shaHex) {
    final b64 = MediaRef.hexToB64u(shaHex);
    return b64 == null ? null : '$b64.$ext';
  }

  /// Does this announcement name a directory an archiver publishes?
  static bool announces(XprsPacket p) =>
      p.type == 'service' &&
      (p['serve'] ?? '').split(',').map((s) => s.trim()).contains('archive') &&
      (p['file'] ?? '').trim().endsWith('.$ext') &&
      shaOfRef(p['file']) != null;

  /// The SHA-256 (lowercase hex) a `file:` value names, in either of 7.7's
  /// two forms, or null. (The same reading as xprs_files' `xprsFileSha`,
  /// kept here so this leaf imports nothing of the file lanes.)
  static String? shaOfRef(String? ref) {
    final v = (ref ?? '').trim();
    if (v.isEmpty) return null;
    final dot = v.lastIndexOf('.');
    final head = dot > 0 ? v.substring(0, dot) : v;
    if (head.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(head)) {
      return head.toLowerCase();
    }
    return MediaRef.b64uToHex(head);
  }
}

/// Publishes this station's directory: every ten minutes, only when it
/// changed. Every side effect is a seam, so the decision runs without a
/// station.
class XprsDirectoryAnnouncer {
  XprsDirectoryAnnouncer._();
  static final XprsDirectoryAnnouncer instance = XprsDirectoryAnnouncer._();

  /// How often the listing is recomposed at most. The sweep that calls
  /// [tick] runs every minute; the gate is here so the cadence is one fact.
  static const Duration every = Duration(minutes: 10);

  // ── injected by the core (mesh_service) ───────────────────────────────────

  /// Whether this station is a public archiver right now (12: only one puts
  /// `serve:archive` on the air, and only one has a directory to offer).
  bool Function()? isPublic;

  /// The listing's lines: who was heard, when (XprsArchive.directoryEntries).
  List<XprsDirectoryEntry> Function()? entries;

  /// Records held (13.0.1), for `count:`.
  int Function()? count;

  String Function()? selfCallsign;
  BigInt? Function()? signingKey;

  /// The station's `serve:` claim (`archive`, `archive,files`), `dial:` and
  /// `room:` as the observation carries them (13.0.2). Null leaves one out.
  String Function()? serve;
  String? Function()? dial;
  String? Function()? room;

  /// Keep [bytes] in the file store under [shaHex] and offer them to anyone
  /// asking for that digest (XprsFileServer.hold). The previous listing's
  /// digest is given so the host can stop offering it.
  void Function(Uint8List bytes, String shaHex, String? previousSha)? store;

  /// Air a signed wire on the bearers, and leave a copy with the archivers.
  Future<void> Function(String wire)? air;
  void Function(String wire)? deposit;

  int _lastMs = 0;
  String? _lastSha;
  int published = 0, unchanged = 0;

  /// The digest of the listing last published, or null.
  String? get lastSha => _lastSha;

  /// Called from the minute sweep. Returns the wire aired, or null when
  /// nothing was due, nothing changed, or this station is not a public
  /// archiver.
  Future<String?> tick({int? nowMs, bool force = false}) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (!(isPublic?.call() ?? false)) return null;
    if (!force && _lastMs != 0 && now - _lastMs < every.inMilliseconds) {
      return null;
    }
    _lastMs = now;
    final self = (selfCallsign?.call() ?? '').trim().toUpperCase();
    if (self.isEmpty) return null;
    final text = XprsDirectory.compose(entries?.call() ?? const []);
    final sha = XprsDirectory.shaOf(text);
    if (sha == _lastSha) {
      unchanged++;
      return null; // an unchanged directory has an unchanged hash (12.9)
    }
    final ref = XprsDirectory.refOf(sha);
    if (ref == null) return null;
    store?.call(Uint8List.fromList(utf8.encode(text)), sha, _lastSha);
    _lastSha = sha;

    final b = StringBuffer('t:service f:$self serve:${serve?.call() ?? 'archive'}');
    final n = count?.call();
    if (n != null) b.write(' count:$n');
    b.write(' file:$ref');
    final d = dial?.call();
    if (d != null && d.isNotEmpty) b.write(' dial:$d');
    final r = room?.call();
    if (r != null && r.isNotEmpty) b.write(' room:$r');
    b.write(' ts:${xprsNowTs(now)}');
    var p = XprsPacket.parse(b.toString());
    if (p == null) return null;
    final key = signingKey?.call();
    if (key != null) p = xprsSign(p, key);
    if (!p.fits) return null;
    final wire = p.encode();
    published++;
    await air?.call(wire);
    deposit?.call(wire);
    LogService.instance.add(
        'XPRS: directory published (${text.split('\n').length - 2} '
        'callsign(s), ${sha.substring(0, 8)}) — 12.9');
    return wire;
  }

  void debugReset() {
    _lastMs = 0;
    _lastSha = null;
    published = unchanged = 0;
    isPublic = null;
    entries = null;
    count = null;
    selfCallsign = null;
    signingKey = null;
    serve = null;
    dial = null;
    room = null;
    store = null;
    air = null;
    deposit = null;
  }
}

/// Takes another archiver's directory announcement: fetched once per
/// (archiver, digest), parsed, kept as pointers in the gossip table.
class XprsDirectoryConsumer {
  XprsDirectoryConsumer._();
  static final XprsDirectoryConsumer instance = XprsDirectoryConsumer._();

  /// The archivers this station named or adopted (12.3): the only ones
  /// whose directory it reads. Another archiver's listing is a claim this
  /// station did not ask for.
  List<String> Function()? named;

  /// Fetch the listing's text from [archiver] over the cheap lane
  /// (XprsFileFetch), or null. Injected: the bench has no lane.
  Future<String?> Function(String archiver, String shaHex)? fetchText;

  /// Where the pointers go. Default: the gossip table.
  void Function(String archiver, List<XprsDirectoryEntry> entries)? store;

  /// (archiver, digest) pairs already fetched. Bounded; a restart forgets,
  /// which costs one re-fetch of an unchanged file per archiver.
  final Map<String, int> _seen = {};
  static const int _seenMax = 256;

  int fetched = 0, failed = 0, ignored = 0;

  /// A `t:service` heard on any lane. Cheap when it is not a directory
  /// announcement, or not from an archiver we lean on: two string checks
  /// and a set lookup, no I/O.
  void offer(XprsPacket p) {
    if (!XprsDirectory.announces(p)) return;
    final from = (p['f'] ?? '').trim().toUpperCase().split('-').first;
    if (from.isEmpty) return;
    final mine = (named?.call() ?? const <String>[])
        .map((c) => c.trim().toUpperCase().split('-').first);
    if (!mine.contains(from)) {
      ignored++;
      return;
    }
    final sha = XprsDirectory.shaOfRef(p['file']);
    if (sha == null) return;
    final key = '$from|$sha';
    if (_seen.containsKey(key)) return;
    if (_seen.length >= _seenMax) _seen.remove(_seen.keys.first);
    _seen[key] = DateTime.now().millisecondsSinceEpoch;
    final fetch = fetchText;
    if (fetch == null) return;
    unawaited(() async {
      try {
        final text = await fetch(from, sha);
        if (text == null) {
          failed++;
          _seen.remove(key); // the next announcement may try again
          return;
        }
        if (XprsDirectory.shaOf(text) != sha) {
          failed++;
          return; // not the bytes the announcement named
        }
        final entries = XprsDirectory.parse(text);
        if (entries == null) {
          failed++;
          return;
        }
        fetched++;
        (store ?? _defaultStore)(from, entries);
        LogService.instance.add(
            'XPRS: directory of $from read (${entries.length} callsign(s)) — 12.9');
      } catch (e) {
        failed++;
        LogService.instance.add('XPRS: directory of $from failed: $e');
      }
    }());
  }

  static void _defaultStore(String archiver, List<XprsDirectoryEntry> entries) =>
      XprsGossip.instance.notePointers(
          archiver, [for (final e in entries) (e.call, e.tsMs)]);

  void debugReset() {
    _seen.clear();
    fetched = failed = ignored = 0;
    named = null;
    fetchText = null;
    store = null;
  }
}
