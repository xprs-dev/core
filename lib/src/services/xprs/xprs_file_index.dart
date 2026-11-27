// Which archiver holds which file, known across the archivers (XPRS.md
// 12.9.2, "finding the bytes across the network").
//
// A station knew a file's holders only from what it had been told about
// that one file: the author of the message that named it, and whoever
// answered a fetch with 202. An archiver asked for a hash it had never met
// answered 404 and named nobody, though the archiver next to it held the
// bytes.
//
// So an always-on public archiver says what it holds: for each file that
// lands in its store, one signed `t:file f:<itself> file:<ref> size:<n>`,
// the statement a shared folder already makes about its files (7.7.7). It
// is a publication like any other: kept, handed to the other archivers as
// it is made (12.9.8), and asked for with `kind:file` by the ones that
// missed it. An archiver that takes such a record notes the holder against
// the hash, and from then on answers `q:have` with a name in `m:try` and
// fetches the file without being told where from.
//
// The record names a hash and a holder, nothing else: no bytes move, and a
// file that is not public is still refused by its holder when asked
// (XprsFileServer.authorize). A false record costs one wasted ask, as a
// false `hears:` does (15.6.3).
//
// The class decides and counts. The store, the signer and the key check
// are injected (MeshService), so it runs in a test as in a station.
import 'dart:collection';

import 'xprs_files.dart' show xprsFileSha;
import 'xprs_folder.dart' show xprsFileRefOf;
import 'xprs_packet.dart';
import 'xprs_vocab.dart';

class XprsFileIndex {
  XprsFileIndex._();
  static final XprsFileIndex instance = XprsFileIndex._();

  /// Records this station makes in one minute, at most: a library dropped
  /// into the store in one go is not announced file by file at once. What
  /// was not said is found by asking (`q:have`), as before.
  static const int perMinute = 20;

  /// Holders noted per file.
  static const int maxHolders = 8;
  static const int _remembered = 4096;

  /// Holders noted in all, and how often the store is told to keep to it.
  static const int maxNoted = 200000;
  static const int pruneEvery = 2000;

  /// True when this station is an always-on public archiver now.
  bool Function()? enabled;

  /// This station's callsign, base form.
  String Function()? self;

  /// Sign and publish one canonical packet as this station's own.
  void Function(String canonical)? publish;

  /// Keep that [holder] holds [shaHex]; and read who is noted.
  void Function(String shaHex, String holder)? keep;
  List<String> Function(String shaHex)? holdersOf;

  /// Drop the oldest notes beyond [maxRows].
  void Function(int maxRows)? prune;

  /// True when [p]'s signature verifies under its author's key.
  bool Function(XprsPacket p)? verified;

  int said = 0, heldBack = 0, noted = 0;
  final LinkedHashSet<String> _saidOf = LinkedHashSet<String>();
  int _windowMs = 0, _inWindow = 0;

  /// A file of [size] bytes landed in this station's store.
  void landed(String shaHex, int size, String ext, {int? nowMs}) {
    final pub = publish;
    final me = (self?.call() ?? '').trim().toUpperCase();
    if (pub == null || me.isEmpty || !(enabled?.call() ?? false)) return;
    // The store names a file by the 43-character form; a caller may hand
    // either (7.7).
    final sha = xprsFileSha(shaHex) ?? '';
    if (sha.length != 64 || size <= 0 || _saidOf.contains(sha)) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (now - _windowMs >= 60000 || now < _windowMs) {
      _windowMs = now;
      _inWindow = 0;
    }
    if (_inWindow >= perMinute) {
      heldBack++;
      return;
    }
    _inWindow++;
    if (_saidOf.length >= _remembered) _saidOf.remove(_saidOf.first);
    _saidOf.add(sha);
    said++;
    pub('t:file f:$me ts:${xprsNowTs(now)} '
        'file:${xprsFileRefOf(sha, ext.isEmpty ? 'bin' : ext)} size:$size');
  }

  /// The hash [p] says its author holds, when [p] is such a record: a
  /// `t:file` for everybody that carries a reference and no bytes. Null
  /// otherwise. Cheap; says nothing about the signature.
  static String? recordOf(XprsPacket p) {
    if (p.type != 'file') return null;
    if ((p['d'] ?? '').trim().isNotEmpty) return null;
    if (p.has('off') || p.has('b')) return null;
    return xprsFileSha(p['file']);
  }

  /// Feed one packet the funnel accepted. True when a holder was noted.
  bool offer(XprsPacket p) {
    final sha = recordOf(p);
    final k = keep;
    if (sha == null || k == null) return false;
    final from = (p['f'] ?? '').split('-').first.trim().toUpperCase();
    final me = (self?.call() ?? '').trim().toUpperCase();
    if (from.isEmpty || from == me) return false;
    final held = holdersOf?.call(sha) ?? const <String>[];
    if (held.contains(from) || held.length >= maxHolders) return false;
    if (!(verified?.call(p) ?? false)) {
      // Its author's key may still be on its way: the archivers' hand-on
      // keeps the record and offers it again (XprsArchiverPush.keyLearned).
      return false;
    }
    k(sha, from);
    noted++;
    // What others say they hold has no end; the store keeps the newest.
    if (noted % pruneEvery == 0) prune?.call(maxNoted);
    return true;
  }

  Map<String, dynamic> get json =>
      {'said': said, 'heldBack': heldBack, 'noted': noted};

  /// For tests.
  void reset() {
    _saidOf.clear();
    said = heldBack = noted = 0;
    _windowMs = _inWindow = 0;
  }
}
