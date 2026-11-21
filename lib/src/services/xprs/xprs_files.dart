/*
 * xprs_files — `cmd:file`: the XPRS ask in front of the bulk lane.
 *
 * XPRS.md section 25.2.2 draws the whole transfer, and only the middle third of
 * it was ever built:
 *
 *   -- advert channel (XPRS) ------------------------------------------------
 *   ->  t:command ... cmd:file file:<ref> [off:<qty>] sig:...
 *   <-  t:result  ... code:202 sig:...
 *   -- bulk lane (binary, one ATT write per frame; 4D 01 = session magic) ----
 *       FILE_OFFER / FILE_ACCEPT / CHUNK / WIN_ACK / FILE_DONE / FILE_OK
 *   -- advert channel again -------------------------------------------------
 *   <-  t:result  ... code:200 sig:...
 *
 * The bulk lane is `mesh_session.dart` (MSP) over a short auto-paired GATT
 * session, spooled by `mesh_bulk_spool.dart` — built, and measured at 27 kB/s
 * phone to phone (docs/mesh.md M2). The advert channel is XPRS. What was
 * missing, in the specification's own words (section 37), is "the XPRS ask in
 * front of them". This file is that ask, both ends of it.
 *
 * Two things it deliberately does NOT do:
 *  - It never carries bytes. A `cmd:file` is 250 bytes like every other packet;
 *    the payload goes on the bulk lane and nowhere near an advertisement.
 *  - It never hashes or copies the file. The holder already knows the digest —
 *    that is what was asked for — and the spool serves it from disk.
 *
 * The final `200` is a statement about CONTENT, not transmission: it is aired
 * only after the receiving station verified the bytes itself and sent FILE_OK.
 */
import 'dart:async';

import 'package:xprs_core/src/platform/core_host.dart';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart';

import '../log_service.dart';
import '../mesh/mesh_bulk_spool.dart';
import '../media/media_ref_index.dart';
import 'xprs_id.dart';
import 'xprs_airtime.dart';
import 'xprs_monitor.dart';
import 'xprs_inline_file.dart';
import 'xprs_inline_sender.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';
import 'xprs_vocab.dart';
import '../../platform/fs.dart';

/// A file this station holds, as the answer to a `file:` reference.
class XprsHeldFile {
  /// Absolute path for a file on disk. The spool reads it with seek+read and
  /// never copies it. Empty when the bytes are a MediaArchive blob instead —
  /// then [archiveToken] names them. Exactly one of the two is set.
  final String path;

  /// `file:<b64u>.<ext>` token when the bytes live in the MediaArchive (a chat
  /// picture) rather than on disk. Served with `enqueueFromArchive`.
  final String? archiveToken;

  /// Lowercase hex SHA-256 — already known and trusted by the holder.
  final String shaHex;
  final int size;
  final String name;
  final String ext;

  const XprsHeldFile({
    this.path = '',
    this.archiveToken,
    required this.shaHex,
    required this.size,
    required this.name,
    required this.ext,
  });
}

/// The SHA-256 a `file:` value names, as lowercase hex.
///
/// Section 6.7 gives two forms and says a receiver accepts both: 43 base64url
/// characters, a dot and the type (what a sender emits), or the earlier 64
/// lowercase hex. The extension is advisory and never part of identity.
String? xprsFileSha(String? ref) {
  final v = (ref ?? '').trim();
  if (v.isEmpty) return null;
  final dot = v.lastIndexOf('.');
  final head = dot > 0 ? v.substring(0, dot) : v;
  if (head.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(head)) {
    return head.toLowerCase();
  }
  return MediaRef.b64uToHex(head);
}

/// The extension a `file:` value carries, or '' when it is a bare digest.
String xprsFileExt(String? ref) {
  final v = (ref ?? '').trim();
  final dot = v.lastIndexOf('.');
  if (dot <= 0 || dot == v.length - 1) return '';
  final e = v.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{1,18}$').hasMatch(e) ? e : '';
}

/// Serves `cmd:file` (section 25.2) for whatever the host says it holds.
class XprsFileServer {
  XprsFileServer._();
  static final XprsFileServer instance = XprsFileServer._();

  /// What do we hold for this digest? Null from all means "not held" — a `404`.
  ///
  /// Registered by whoever owns files worth serving: the update mirror its
  /// channel directories, the mesh its MediaArchive of chat media. Consulted in
  /// registration order after [_held]; the first non-null wins.
  final List<XprsHeldFile? Function(String shaHex)> _resolvers = [];

  /// Add a lookup consulted after the pinned files. Several owners coexist.
  void addResolver(XprsHeldFile? Function(String shaHex) fn) =>
      _resolvers.add(fn);

  /// Legacy single-slot setter: REPLACES the chain (its old semantics), and
  /// `= null` clears it. Production code registers with [addResolver] so owners
  /// coexist; this stays for the tests and callers that owned the one slot.
  set resolver(XprsHeldFile? Function(String shaHex)? fn) {
    _resolvers.clear();
    if (fn != null) _resolvers.add(fn);
  }

  /// Decides whether [requester] may receive the BYTES for [shaHex]. Null means
  /// open — every held file public, the update-mirror default. Set to gate
  /// private chat media by the audience of the message that shared it (§11.2).
  /// [sigVerified] says whether the ask carried a signature that verified as
  /// [requester]; a private file is served only to a verified, authorised
  /// caller.
  bool Function(String shaHex, String requester, {required bool sigVerified})?
      authorize;

  /// Files pinned explicitly, by digest. Consulted before the resolvers, so an
  /// operator (or a bench run) can offer one file without displacing whatever
  /// service owns the dynamic lookup.
  final Map<String, XprsHeldFile> _held = {};

  /// Offer [f] to anyone who asks for its digest, until [drop].
  void hold(XprsHeldFile f) => _held[f.shaHex.toLowerCase()] = f;
  bool drop(String shaHex) => _held.remove(shaHex.toLowerCase()) != null;
  List<XprsHeldFile> get pinned => _held.values.toList(growable: false);

  XprsHeldFile? _lookUp(String shaHex) {
    final pinned = _held[shaHex];
    if (pinned != null) return pinned;
    for (final r in _resolvers) {
      final f = r(shaHex);
      if (f != null) return f;
    }
    return null;
  }

  /// Largest file this station will offer a peer. A transfer is minutes of
  /// somebody's radio and battery (section 31.2), so there has to be a number;
  /// above it the answer is a polite `403` naming the size.
  int maxServeBytes = 256 * 1024 * 1024;

  int served = 0;
  int refused = 0;
  int notHeld = 0;

  /// Asks answered with `202`, by the identifier of the ask, so the closing
  /// `200` can quote the same `r:` after the receiver's FILE_OK. Bounded: a
  /// transfer that never completes must not pin a record forever.
  final Map<String, _Served> _inFlight = {};
  static const int _inFlightMax = 32;

  /// Handle one `cmd:file`. Returns the code aired, for the caller's logs.
  ///
  /// The caller has already done the work every command shares: it is for us,
  /// it is not a duplicate, its signature is not forged, and the requester is
  /// within budget. This decides only the file question.
  int onCommand(
    XprsPacket p, {
    required String selfBase,
    required String from,
    required String cmdId,
    required void Function(int code, {String? m}) air,
    bool sigVerified = false,
  }) {
    final shaHex = xprsFileSha(p['file']);
    if (shaHex == null) {
      air(400, m: 'file: must be a digest');
      return 400;
    }
    final held = _lookUp(shaHex);
    if (held == null) {
      notHeld++;
      air(404);
      return 404;
    }
    // WHO MAY FETCH THE BYTES (§11.2): the hash is public, the bytes are not. A
    // private file is served only to a caller whose signed callsign is in the
    // file's audience. An unauthorised ask is refused like a too-large one, so
    // the asker learns not to retry. Null [authorize] = every file public.
    final gate = authorize;
    if (gate != null && !gate(shaHex, from, sigVerified: sigVerified)) {
      refused++;
      air(403, m: 'not authorized');
      return 403;
    }
    if (held.size > maxServeBytes) {
      refused++;
      // What `size:` on a description exists to prevent (section 6.7.1): say
      // why, so the asker does not simply try again.
      air(403, m: 'too large: ${held.size}B');
      return 403;
    }

    // `have:` (§7.7.6, §8.1): a packet-lane receiver saying what it holds of
    // this file. Re-send only what the map lacks, as datagrams, from the same
    // deterministic split; 200 when the map is already complete, 404 when we
    // no longer have the bytes so the asker stops. No spool, no bulk lane.
    final have = p['have'];
    if (have != null && have.isNotEmpty) {
      // Only a packet-lane file has a chunk map; anything larger lives on the
      // bulk lane, and reading it whole here is the shape performance.md 8.9
      // forbids. Say so, so the asker uses cmd:file without have:.
      if (held.size > kInlineMaxBytes) {
        refused++;
        air(403, m: 'not a packet-lane file: ${held.size}B');
        return 403;
      }
      final bytes = bytesOf?.call(shaHex);
      if (bytes == null) {
        notHeld++;
        air(404);
        return 404;
      }
      final ext = held.ext.isNotEmpty ? held.ext : xprsFileExt(p['file']);
      final n = XprsInlineSender.instance
          .onHave(bytes, from: selfBase, to: from, ext: ext, have: have);
      LogService.instance
          .add('XPRS: cmd:file have: from $from -> re-send $n chunk(s)');
      final code = n == 0 ? 200 : 202;
      air(code);
      return code;
    }

    // `off:` resumes (section 25.2). We do not act on it here: the spool keeps
    // the receiver's offset and MSP's FILE_ACCEPT carries it, which is the
    // same resume the spec describes, decided by the side that knows.
    //
    // Chat media is a MediaArchive blob with no path — served with
    // enqueueFromArchive; a file on disk (an update artifact) with enqueueFromFile.
    final ok = held.archiveToken != null
        ? MeshBulkSpool.instance
            .enqueueFromArchive(held.archiveToken!, from, selfBase)
        : MeshBulkSpool.instance.enqueueFromFile(
            held.path,
            held.shaHex,
            held.size,
            target: from,
            origin: selfBase,
            name: held.name,
            ext: held.ext.isNotEmpty ? held.ext : xprsFileExt(p['file']),
          );
    if (!ok) {
      // Already queued for this peer is success, not failure: the transfer it
      // is waiting for is the one it just asked for.
      final already = MeshBulkSpool.instance.holds(held.shaHex);
      if (!already) {
        refused++;
        air(403, m: 'cannot spool');
        return 403;
      }
    }
    served++;
    if (_inFlight.length >= _inFlightMax) {
      _inFlight.remove(_inFlight.keys.first);
    }
    // Per file AND asker: keyed by the file alone, a second asker replaced
    // the first, and then neither was sent its closing `200`.
    _inFlight['${held.shaHex}|${from.toUpperCase()}'] =
        _Served(cmdId, from, selfBase);
    LogService.instance
        .add('XPRS: cmd:file ${held.name} (${held.size}B) -> $from (202)');
    // A far requester fetches over a Reticulum link to us (the internet
    // middle, 11.2.2), which needs us announced through a hub: a phone on
    // battery brings one up for the transfer and drops it after.
    unawaited(CoreHost.requestHub('serve:${held.shaHex.substring(0, 8)}', const Duration(minutes: 15)));
    air(202);
    return 202;
  }

  /// The bytes of a held file, for re-sending the chunks a packet-lane
  /// receiver says it lacks (§7.7.6, `cmd:file ... have:`). Set by the core to
  /// the media archive's blob read; a small file (the lane's cap) on the
  /// calling isolate is the same cost the store pays on arrival.
  Uint8List? Function(String shaHex)? bytesOf;

  /// Admission decision for a `cmd:put` deposit (§11.2, §34.3). Null = deposits
  /// off (every put refused `403 not an archiver`). mesh_service wires this to
  /// `admitToArchive` with the operator's policy and quota.
  ArchiveVerdict Function(String from, int bytes, ArrivedOver via)? admit;

  /// Peers to name in `m:try` when a deposit is refused for fullness (§12.11):
  /// other archivers the operator knows, which may have room. Null = none.
  List<String> Function()? depositAlternates;

  int deposits = 0;

  /// Handle one `cmd:put`: a peer offers to deposit a file for us to host. The
  /// XPRS ask authorises and picks the lane; the bytes then arrive on the
  /// per-bearer middle (MSP bulk / RNS Resource) and the closing `200` — a
  /// custody receipt for bytes — is aired when they land and verify. The
  /// preamble already did the shared work (for us, not a dup, not forged).
  int onPut(
    XprsPacket p, {
    required String selfBase,
    required String from,
    required String cmdId,
    required ArrivedOver via,
    required void Function(int code, {String? m}) air,
  }) {
    final shaHex = xprsFileSha(p['file']);
    if (shaHex == null) {
      air(400, m: 'file: must be a digest');
      return 400;
    }
    final size = _bytesOf(p['size']);
    if (size <= 0) {
      // §11.2: size: is mandatory — accepting bytes unseen is how a small
      // station is filled by a stranger.
      air(400, m: 'size: required');
      return 400;
    }
    if (size > maxServeBytes) {
      air(403, m: 'too large: ${size}B');
      return 403;
    }
    final decide = admit;
    final v = decide?.call(from, size, via) ??
        const ArchiveVerdict.no('not an archiver');
    if (!v.accept) {
      final full = v.reason == 'archive full';
      refused++;
      if (full) {
        // §12.11: full is refused OUT LOUD, and this store refuses rather than
        // evicting to fit a deposit, so declared/pinned content is never
        // dropped for a stranger's bytes. Name a peer with room when we can.
        final alts = depositAlternates?.call() ?? const <String>[];
        air(429, m: alts.isEmpty ? v.reason : 'try ${alts.join(',')}');
        return 429;
      }
      air(403, m: v.reason);
      return 403;
    }
    deposits++;
    LogService.instance
        .add('XPRS: cmd:put from $from (${size}B) accepted (202)');
    air(202);
    return 202;
  }

  /// A `size:` value in bytes: a bare integer, or a number with a `kB`/`MB`/`GB`
  /// suffix (§6.7.1 writes them that way). 0 on anything unparseable.
  static int _bytesOf(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return 0;
    final m = RegExp(r'^(\d+)\s*([kKmMgG]?)[bB]?$').firstMatch(s);
    if (m == null) return 0;
    final n = int.tryParse(m.group(1)!) ?? 0;
    switch (m.group(2)!.toLowerCase()) {
      case 'k':
        return n * 1024;
      case 'm':
        return n * 1024 * 1024;
      case 'g':
        return n * 1024 * 1024 * 1024;
      default:
        return n;
    }
  }

  /// Do we hold the bytes for this digest? (Pinned or any resolver.)
  bool holds(String shaHex) => _lookUp(shaHex.toLowerCase()) != null;

  /// The exact length in bytes of a file this station holds, or null. What a
  /// `202` and a `q:have` answer state as `size:`: a fetch by pieces needs
  /// the exact count, and a description's `size:` is rounded.
  int? sizeOf(String shaHex) => _lookUp(shaHex.toLowerCase())?.size;

  /// "Who else holds this hash" — the seeder index (§12.9.2, Phase E): the
  /// sources table and, on an archiver, the provider-record/DHT lookup. Returns
  /// callsigns to name in a `q:have` miss's `m:try`. Null = nothing indexed.
  List<String> Function(String shaHex)? holderIndex;

  int qHave = 0;

  /// Answer a `q:have` (§8.1): who holds the bytes for a `file:` reference. The
  /// hash is public, so this is not gated — it moves no bytes, it only says
  /// where they are. Held → `have:full`. A directed miss → `code:404` with
  /// `m:try` naming indexed holders. A broadcast we cannot answer stays silent
  /// (§8.1: a station holding nothing does not reply to the street).
  void onHave(
    XprsPacket p, {
    required String selfBase,
    required String from,
    required bool directed,
  }) {
    final shaHex = xprsFileSha(p['file']);
    if (shaHex == null) return;
    final id = xprsIdentifier(p);
    final size = sizeOf(shaHex);
    if (size != null) {
      qHave++;
      unawaited(XprsPublisher.instance.publishWire('t:result f:$selfBase '
          'd:$from ts:${xprsNowTs()} r:$id s:have have:full size:$size'));
      return;
    }
    if (!directed) return; // silent on a broadcast miss (§8.1)
    final tries = holderIndex?.call(shaHex) ?? const <String>[];
    final b = StringBuffer(
        't:result f:$selfBase d:$from ts:${xprsNowTs()} r:$id code:404');
    if (tries.isNotEmpty) b.write(' m:try ${tries.join(',')}');
    unawaited(XprsPublisher.instance.publishWire(b.toString()));
  }

  /// The peer verified the bytes and sent FILE_OK. Close the exchange with the
  /// `200` the spec makes conditional on exactly that.
  void noteHandedOver(String shaHex, String peer) {
    final s =
        _inFlight.remove('${shaHex.toLowerCase()}|${peer.toUpperCase()}');
    if (s == null) return;
    final wire = 't:result f:${s.self} d:${s.to} '
        'ts:${xprsNowTs()} r:${s.cmdId} code:200';
    unawaited(XprsPublisher.instance.publishWire(wire));
    LogService.instance.add('XPRS: cmd:file to ${s.to} complete (200)');
  }

  Map<String, dynamic> statusJson() => {
        'served': served,
        'refused': refused,
        'notHeld': notHeld,
        'inFlight': _inFlight.length,
        'maxServeBytes': maxServeBytes,
        'resolvers': _resolvers.length,
        'gated': authorize != null,
        'pinned': [
          for (final f in _held.values)
            {'sha': f.shaHex, 'name': f.name, 'size': f.size}
        ],
      };
}

class _Served {
  final String cmdId;
  final String to;
  final String self;
  _Served(this.cmdId, this.to, this.self);
}

/// The stations known to hold [shaHex], best first: those that said so
/// themselves (a `202`, kept as `callsign` sources of the archive), then the
/// one whose message named the file. What a `q:have` miss names in `m:try`
/// and what a fetch asks beside the sender (spec 8.1, 12.9.2).
List<String> xprsKnownHolders(MediaArchive archive, String shaHex,
    {int max = 4}) {
  final out = <String>[];
  void add(String? c) {
    final v = (c ?? '').trim().toUpperCase();
    if (v.isNotEmpty && !out.contains(v) && out.length < max) out.add(v);
  }

  for (final (kind, value) in archive.getSources(shaHex)) {
    if (kind == 'callsign') add(value);
  }
  add(MediaRefIndex.instance.describe(shaHex)?.from);
  return out;
}

/// Asks another station for a file by digest, and waits for the bytes.
///
/// Follows the shape XprsCatchup already proved: a directed ask, correlation by
/// the section-5 identifier the responder echoes as `r:`, one ask in flight per
/// peer, and every reply code meaning what section 25.1 says it means.
class XprsFileFetch {
  XprsFileFetch._();
  static final XprsFileFetch instance = XprsFileFetch._();

  /// Asks outstanding, by the identifier of the ask.
  final Map<String, _Ask> _pending = {};

  /// Waiters by digest, completed when the bytes land and verify.
  final Map<String, Completer<String?>> _waiting = {};

  /// Digests a holder has already answered `202` for: the ask is done its job
  /// and re-airing it would only take rotation slots from the transfer.
  final Set<String> _accepted = {};

  /// How often an unanswered ask goes back on the air. Just under the
  /// advertising period (60 s), so a re-air lands in a different window rather
  /// than the same one.
  static const Duration askEvery = Duration(seconds: 45);

  /// Where a caller wants its file put, by digest. Set at [fetch] time and
  /// honoured by [claimInbound] so the artifact never becomes a zx blob.
  final Map<String, String> _destDir = {};

  /// The internet middle (§11.2.2): fetch the bytes over Reticulum/DHT/torrent
  /// when the archiver is reachable off-radio, racing the BLE bulk lane. Returns
  /// the local path once the bytes verify, or null. mesh_service wires it to
  /// `RnsService.fetchContentAddressed` and the shared-media resolve ladder.
  /// Null means no internet lane (a BLE-only build or bench).
  Future<String?> Function(
          String shaHex, String ext, String archiver, String? destDir)?
      internetFetch;

  /// A station said it holds a file (its `202` to our ask). The core keeps
  /// it as a source of that hash, which is what a `q:have` miss names in
  /// `m:try` (spec 8.1, 12.9.2) and what a later fetch asks first. Nothing
  /// recorded a holder before, so that index was always empty.
  void Function(String shaHex, String holder)? onHolder;

  /// How long to wait for the bytes once a peer said `202`.
  ///
  /// The bulk lane moves ~27 kB/s and MSP ends a session politely at 300 s,
  /// resuming in the next one — so a large file legitimately spans several
  /// sessions and a generous ceiling is the honest number, not an optimistic
  /// one. The caller may pass its own.
  static const Duration defaultTimeout = Duration(minutes: 90);

  /// What is still wanted, by digest: who asks, and who was asked. A fetch is
  /// ONE per file however many callers and holders it has: a second caller
  /// joins it, and every holder named for the file is one more source.
  final Map<String, _Want> _wants = {};

  /// How many holders one fetch asks at most. Each ask is airtime and a
  /// metered answer at the far end (section 30.2).
  static const int maxHolders = 6;

  /// Ask [archiver] for the file named by [shaHex]; complete with the local
  /// path once it has arrived and verified, or null when every holder asked
  /// refused, or on timeout.
  ///
  /// Asking again for a file already being fetched joins that fetch, and
  /// [archiver], when it was not asked yet, is asked as well. A holder that
  /// answers `404`/`429` with `m:try` names others (spec 8.1, 12.9, 30.2):
  /// they are asked, one hop and no further.
  Future<String?> fetch({
    required String archiver,
    required String shaHex,
    required String selfCallsign,
    String ext = '',
    int off = 0,
    String? destDir,
    Duration timeout = defaultTimeout,
    Duration? acceptWithin,
    int exactSize = 0,
  }) async {
    final sha = shaHex.toLowerCase();
    final existing = _waiting[sha];
    if (existing != null) {
      if (exactSize > 0) _wants[sha]?.exactSize = exactSize;
      _askHolder(sha, archiver);
      return existing.future;
    }
    if (MediaRef.hexToB64u(sha) == null) {
      LogService.instance.add('XPRS: cmd:file for a malformed digest — not sent');
      return null;
    }
    final done = Completer<String?>();
    _waiting[sha] = done;
    _wants[sha] = _Want(selfCallsign, ext, off)..exactSize = exactSize;
    if (destDir != null) _destDir[sha] = destDir;
    if (!_askHolder(sha, archiver)) {
      _end(sha, 'could not be asked for');
      return done.future;
    }

    Timer(timeout, () {
      if (identical(_waiting[sha], done)) _end(sha, 'timed out');
    });
    // A station that holds the file answers 202 within seconds; one that does
    // not answers 404 -- or, on a board that has never heard of the ref, says
    // nothing at all. [timeout] is sized for the TRANSFER (a 60 MB APK over
    // the bulk lane is an hour), so without this window an unanswered ask
    // held the caller for that whole hour. Measured on the C61: the updater
    // asked the ESP32 for a release it could not possibly hold and sat at 0%
    // re-airing the same wire every 45 s, and the HTTPS fallback that would
    // have worked in a minute was never reached. Once a 202 is in hand the
    // transfer timeout governs, exactly as before.
    if (acceptWithin != null) {
      Timer(acceptWithin, () {
        if (!identical(_waiting[sha], done) || _accepted.contains(sha)) return;
        _end(sha, 'unanswered after ${acceptWithin.inSeconds}s');
      });
    }
    return done.future;
  }

  /// The holders asked for a file being fetched, and how many of them said
  /// they hold it; null when no fetch of it is in flight. For a progress
  /// reading: local state, no traffic.
  ({int asked, int accepted})? holdersOf(String shaHex) {
    final want = _wants[shaHex.toLowerCase()];
    if (want == null) return null;
    return (asked: want.asked.length, accepted: want.accepted.length);
  }

  /// The exact length of a file being fetched, when its caller stated one,
  /// else 0. The internet lane needs it to fetch by pieces from several
  /// holders ([RnsService.fetchContentAddressed]); without it the lane can
  /// only take the whole file from one.
  int exactSizeOf(String shaHex) => _wants[shaHex.toLowerCase()]?.exactSize ?? 0;

  /// Ask one more holder for a file already wanted. False when it was asked
  /// before, the fetch is over, or the bound on holders is reached.
  bool _askHolder(String sha, String holder, {bool redirected = false}) {
    final want = _wants[sha];
    final h = holder.trim().toUpperCase();
    if (want == null || h.isEmpty) return false;
    if (want.asked.contains(h) || want.asked.length >= maxHolders) return false;
    final b = StringBuffer('t:command f:${want.self} d:$h '
        'ts:${xprsNowTs()} cmd:file file:${MediaRef.hexToB64u(sha)}');
    if (want.ext.isNotEmpty) b.write('.${want.ext}');
    if (want.off > 0) b.write(' off:${want.off}');
    final wire = b.toString();
    final p = XprsPacket.parse(wire);
    if (p == null || !p.fits) {
      LogService.instance.add('XPRS: cmd:file ask does not fit — not sent');
      return false;
    }
    final id = xprsIdentifier(p); // before signing, like every other ask
    want.asked.add(h);
    _pending[id] = _Ask(h, sha, redirected: redirected);
    LogService.instance.add('XPRS: asking $h for ${sha.substring(0, 8)}'
        '${redirected ? ' (named by another holder)' : ''}');
    unawaited(XprsPublisher.instance.publishWire(wire));

    // Race the internet middle. The XPRS bracket stays authoritative for
    // control, but the bytes take whichever lane delivers a verified copy
    // first: over the internet a Reticulum resource or a swarm usually beats
    // the ~27 kB/s bulk lane, and on a foreign network it is the only lane.
    // The completer guards against a double-complete, so the loser is a no-op.
    // The internet lane, once per holder. With the length known it starts
    // now. Without it, it waits a moment for the holder's `202`, which
    // states the length (spec 11.2): started at once it took the whole file
    // from one holder, and when the `202` then made pieces possible a second
    // fetch of the same bytes ran beside it on the same link.
    if (want.exactSize > 0) {
      _runInternet(sha, h);
    } else {
      want.timers.add(Timer(internetGrace, () => _runInternet(sha, h)));
    }

    // Re-air the ask until it is answered.
    //
    // The advert channel is fire-and-forget on a half-duplex radio: "a frame
    // transmitted once may not be observed at all" (docs/ble5.md section 1), and
    // the transmit window is five seconds a minute shared by every registered
    // frame. Asked once, a cmd:file is simply lost some of the time — measured
    // on the bench, the holder's `served` counter stayed at 0 for a whole
    // six-minute attempt. XprsCatchup re-asks on a cadence for the same reason.
    //
    // The SAME wire is re-published each time, so `ts:` and therefore the
    // section-5 identifier stay put and the answer still correlates; the advert
    // key is refreshed rather than a second frame added.
    want.timers.add(Timer.periodic(askEvery, (t) {
      if (!_pending.containsKey(id)) {
        t.cancel();
        return;
      }
      if (_accepted.contains(sha)) return; // 202 in hand; bytes are coming
      // §31.1: a retry is not a new packet, and this is the same wire — same
      // `ts:`, same §5 identifier — so it charges the same budget as the first
      // ask. The 45 s above is this subsystem's CADENCE; whether the air can
      // afford it is the ledger's answer, shared with every other re-airing
      // path so eleven timers cannot each decide they are the only one.
      //
      // §13.7.2 gates it on evidence: re-asking a holder we can no longer hear
      // teaches us nothing and costs a duty cycle everyone shares.
      final reachable = XprsMonitor.instance.stations[h] != null;
      if (!XprsRetryLedger.instance.may(id, reachable: reachable)) return;
      XprsRetryLedger.instance.spend(id);
      unawaited(XprsPublisher.instance.publishWire(wire));
    }));
    return true;
  }

  /// How long the internet lane waits for a holder's `202` (and the length
  /// it states) before starting without it.
  static Duration internetGrace = const Duration(seconds: 3);

  /// Start the internet lane for [sha] from holder [h], once; a no-op
  /// without one.
  void _runInternet(String sha, String h) {
    final net = internetFetch;
    final want = _wants[sha];
    if (net == null || want == null) return;
    if (!want.netStarted.add(h)) return;
    // The internet middle needs a hub; a phone on battery holds one up
    // for the fetch (RnsSession) and lets it go when the bytes are in.
    unawaited(CoreHost.requestHub(
        'fetch:${sha.substring(0, 8)}', const Duration(minutes: 15)));
    unawaited(net(sha, want.ext, h, _destDir[sha]).then((path) {
      if (path != null) {
        _completeFromInternet(sha, path);
      } else {
        _retryInternet(sha, h, want);
      }
    }).catchError((Object e) {
      LogService.instance.add('XPRS: internet lane for '
          '${sha.substring(0, 8)} from $h failed: $e');
      _retryInternet(sha, h, want);
      return null;
    }));
  }

  /// The first wait before the internet lane is tried again for a holder; it
  /// doubles each time, [internetRetries] times at most.
  static Duration internetRetry = const Duration(seconds: 60);
  static const int internetRetries = 3;

  /// The internet lane brought nothing from [h] and the file is still wanted:
  /// try again later, a few times. A device that asks in its first seconds
  /// has no Reticulum path to the holder yet; the one run failed on that and
  /// the fetch then waited out its whole timeout with the holder a hop away.
  void _retryInternet(String sha, String h, _Want want) {
    if (!identical(_wants[sha], want)) return; // arrived, or given up
    final n = want.netTries[h] ?? 0;
    if (n >= internetRetries) return;
    want.netTries[h] = n + 1;
    want.timers.add(Timer(internetRetry * (1 << n), () {
      if (!identical(_wants[sha], want)) return;
      LogService.instance.add('XPRS: internet lane for '
          '${sha.substring(0, 8)} from $h: trying again (${n + 1})');
      want.netStarted.remove(h);
      _runInternet(sha, h);
    }));
  }

  /// The fetch of [sha] is over: with [path] when the bytes are in hand, with
  /// null and [why] when they are not coming.
  void _end(String sha, String? why, {String? path}) {
    final want = _wants.remove(sha);
    for (final t in want?.timers ?? const <Timer>[]) {
      t.cancel();
    }
    _pending.removeWhere((_, a) => a.sha == sha);
    _destDir.remove(sha);
    _accepted.remove(sha);
    final w = _waiting.remove(sha);
    if (w == null || w.isCompleted) return;
    if (why != null) {
      LogService.instance.add('XPRS: cmd:file ${sha.substring(0, 8)} $why');
    }
    w.complete(path);
  }

  /// A `t:result` arrived. Chained after XprsCatchup's own handler.
  void onResult(XprsPacket p) {
    final ask = _pending[p['r'] ?? ''];
    if (ask == null) return;
    final code = int.tryParse(p['code'] ?? '') ?? 0;
    switch (code) {
      case 202:
        // Accepted; the bytes are coming on the bulk lane. Keep waiting — the
        // completion is FILE_OK on that lane, not this packet. Stop re-airing.
        _accepted.add(ask.sha);
        LogService.instance.add('XPRS: ${ask.station} accepted (202)');
        // "I hold it", from the holder itself: worth remembering whether or
        // not its bytes are the ones that arrive (spec 12.9.2).
        try {
          _wants[ask.sha]?.accepted.add(ask.station);
          onHolder?.call(ask.sha, ask.station);
        } catch (e) {
          LogService.instance.add('XPRS: noting a holder failed: $e');
        }
        // The holder states the exact length (spec 11.2). A file of more
        // than one piece can then be fetched by pieces from every holder,
        // which the internet lane could not do while it knew no size: it
        // started as a whole-file fetch from one, so it is started again.
        final said = int.tryParse(p['size'] ?? '') ?? 0;
        final want = _wants[ask.sha];
        if (want != null) {
          if (said > 0 && want.exactSize == 0) want.exactSize = said;
          // It holds the file: the internet lane need not wait any longer.
          _runInternet(ask.sha, ask.station);
        }
        return;
      case 200:
        // The holder's closing receipt. The bytes themselves are what complete
        // the wait, via [noteInboundComplete]; if they already did, this is
        // just confirmation.
        _pending.remove(p['r']);
        return;
      case 404:
      case 403:
      case 429:
      case 400:
      case 500:
        _pending.remove(p['r']);
        LogService.instance.add(
            'XPRS: ${ask.station} refused ${ask.sha.substring(0, 8)} ($code)'
            '${p.has('m') ? ' — ${p['m']}' : ''}');
        // It may have said who does hold it (`m:try`, spec 8.1, 12.9, 30.2).
        // One hop: a holder we were sent to is not asked where to go next.
        if (!ask.redirected) {
          final self =
              NostrCrypto.bareCallsign(_wants[ask.sha]?.self ?? '');
          for (final c in xprsTryCallsigns(p['m'])) {
            if (NostrCrypto.bareCallsign(c) == self) continue;
            _askHolder(ask.sha, c, redirected: true);
          }
        }
        // Over only when nobody asked is still to answer.
        if (!_pending.values.any((a) => a.sha == ask.sha)) {
          _end(ask.sha, 'refused by every holder asked');
        }
        return;
      default:
        return;
    }
  }

  /// Claim an arriving file we asked for, before the spool archives it.
  ///
  /// Archiving reads the whole file into memory and stores it as a zx
  /// blob. For a 56 MB artifact that is the wrong answer on both counts, so a
  /// caller that named a destination gets a rename instead — same volume, no
  /// bytes moved (docs/performance.md 8.7).
  String? claimInbound(
      String shaHex, String partPath, Map<String, dynamic> meta) {
    final sha = shaHex.toLowerCase();
    final dir = _destDir[sha];
    if (dir == null || !_waiting.containsKey(sha)) return null;
    try {
      fs.directory(dir).createSync(recursive: true);
      final name = (meta['name'] as String?)?.trim();
      final base = (name == null || name.isEmpty) ? sha : name;
      final dest = '$dir$pathSeparator$base';
      fs.file(partPath).renameSync(dest);
      return dest;
    } catch (e) {
      LogService.instance.add('XPRS: claim of ${sha.substring(0, 8)} failed: $e');
      return null; // fall back to the archive path rather than lose the file
    }
  }

  /// The internet middle delivered and verified the bytes first (§11.2.2).
  /// Completes the same waiter the bulk lane would; a later bulk arrival for
  /// the same digest finds the waiter gone and is a no-op.
  void _completeFromInternet(String shaHex, String path) {
    final sha = shaHex.toLowerCase();
    if (!_waiting.containsKey(sha)) return;
    LogService.instance
        .add('XPRS: ${sha.substring(0, 8)} arrived over the internet');
    _end(sha, null, path: path);
  }

  /// The bulk lane finished and the file verified against its digest.
  void noteInboundComplete(String shaHex, String path) {
    final sha = shaHex.toLowerCase();
    if (!_waiting.containsKey(sha)) return;
    LogService.instance
        .add('XPRS: ${sha.substring(0, 8)} arrived over the bulk lane');
    _end(sha, null, path: path);
  }

  bool get busy => _waiting.isNotEmpty;

  Map<String, dynamic> statusJson() => {
        'pending': _pending.length,
        'waiting': [for (final s in _waiting.keys) s.substring(0, 8)],
        'holders': {
          for (final e in _wants.entries) e.key.substring(0, 8): e.value.asked
        },
      };
}

class _Ask {
  final String station;
  final String sha;

  /// Asked because another holder named it in `m:try`.
  final bool redirected;
  _Ask(this.station, this.sha, {this.redirected = false});
}

/// One file being fetched: who wants it and which holders were asked.
class _Want {
  _Want(this.self, this.ext, this.off);
  final String self;
  final String ext;
  final int off;
  final List<String> asked = [];

  /// Those of [asked] that answered `202`.
  final Set<String> accepted = {};

  /// Holders the internet lane was started for.
  final Set<String> netStarted = {};

  /// How many times it was tried again, per holder.
  final Map<String, int> netTries = {};
  final List<Timer> timers = [];

  /// The file's length in bytes when the caller knows it EXACTLY (a release
  /// feed, a station's listing), else 0. A message's `size:` is rounded and
  /// is not this.
  int exactSize = 0;
}
