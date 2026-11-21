// A file of several pieces is fetched BY PIECES from two stations that hold
// it in their media archives: the proof that the parts of the piece path fit
// together (app docs/plan-archiver-tests.md, fault F1).
//
//   holder side   the file is a blob in a real MediaArchive, served through
//                 MediaFileSource; its piece list is cut with
//                 pieceListOfRanged and stored beside it, exactly as
//                 RnsService.dhtPublish does;
//   fetcher side  fetchByPieces: the list from a holder, checked against the
//                 exact length a holder states (spec 11.2), then the pieces
//                 from both holders, each verified.
//
// Three FileTransferNodes wired in-process, so the link handshake, the
// requests and the resources run as on the wire.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/folders/piece_hashes.dart';

class _Loop {
  late FileTransferNode node;
  final List<RnsPacket> _inbox = [];
  bool _pumping = false;
  int delivered = 0;

  void deliver(Uint8List raw) {
    final p = RnsPacket.parse(raw);
    if (p == null) return;
    _inbox.add(p);
    _pump();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    while (_inbox.isNotEmpty) {
      final p = _inbox.removeAt(0);
      delivered++;
      try {
        await node.handlePacket(p);
      } catch (_) {/* a wrong-peer packet is ignored, as on the wire */}
    }
    _pumping = false;
  }
}

Uint8List _bytes(int n, {int seed = 1}) {
  final out = Uint8List(n);
  var x = (seed * 2654435761) & 0xffffffff;
  for (var i = 0; i < n; i++) {
    x = (1103515245 * x + 12345) & 0x7fffffff;
    out[i] = (x >> 16) & 0xff;
  }
  return out;
}

Uint8List _sha(Uint8List b) =>
    Uint8List.fromList(crypto.sha256.convert(b).bytes);

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('xprspieces'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A station that holds [file] in its archive. With [withList], it cut the
  /// file's piece list and stores it too, as a holder that advertised it does.
  Future<({MediaArchive archive, Uint8List? list})> holder(
      String name, Uint8List file,
      {bool withList = true}) async {
    final archive = MediaArchive.forDirectory('${tmp.path}/$name');
    archive.putBytes(file, 'jpg');
    final hex = _hex(_sha(file));
    Uint8List? list;
    if (withList) {
      list = await pieceListOfRanged(
          file.length, (off, len) => archive.readRange(hex, off, len));
      if (list != null) archive.putBytes(list, 'pieces');
    }
    return (archive: archive, list: list);
  }

  /// One fetcher and the holders' nodes, wired in-process.
  Future<(FileTransferNode, List<RnsIdentity>, List<_Loop>)> wire(
      List<MediaArchive> archives) async {
    final loopFetcher = _Loop();
    final pubs = <RnsIdentity>[];
    final loops = <_Loop>[];
    for (final a in archives) {
      final id = await RnsIdentity.generate();
      final loop = _Loop();
      loop.node = FileTransferNode(
          identity: id,
          source: MediaFileSource(a),
          send: (raw) => loopFetcher.deliver(raw));
      loops.add(loop);
      pubs.add(RnsIdentity.fromPublicKey(id.getPublicKey()));
    }
    loopFetcher.node = FileTransferNode(
        identity: await RnsIdentity.generate(),
        source: const EmptyFileSource(),
        send: (raw) {
          for (final l in loops) {
            l.deliver(raw);
          }
        });
    return (loopFetcher.node, pubs, loops);
  }

  test('a five-piece file arrives by pieces from two holders', () async {
    final file = _bytes(300 * 1024, seed: 11); // 5 pieces of 64 KiB
    final a = await holder('a', file);
    final b = await holder('b', file);
    expect(a.list, isNotNull);
    expect(a.list!.length, 5 * 32);
    expect(a.list, b.list,
        reason: 'two holders of the same bytes cut the same list');

    final (fetcher, providers, loops) = await wire([a.archive, b.archive]);
    final logs = <String>[];
    final got = await fetchByPieces(fetcher,
        fileHash: _sha(file),
        size: file.length,
        providers: providers,
        manifest: _sha(a.list!),
        timeout: const Duration(seconds: 60),
        log: logs.add);
    expect(logs, isEmpty, reason: 'no fallback to the whole-file path');
    expect(got, isNotNull);
    expect(_hex(_sha(got!)), _hex(_sha(file)));
    // Both holders took part: neither served the file alone.
    expect(loops[0].delivered, greaterThan(0));
    expect(loops[1].delivered, greaterThan(0));
  });

  test('a holder without the list still serves pieces; the other has the list',
      () async {
    final file = _bytes(200 * 1024, seed: 5); // 4 pieces
    final plain = await holder('plain', file, withList: false);
    final full = await holder('full', file);
    final (fetcher, providers, _) =
        await wire([plain.archive, full.archive]);
    final got = await fetchByPieces(fetcher,
        fileHash: _sha(file),
        size: file.length,
        providers: providers,
        manifest: _sha(full.list!),
        timeout: const Duration(seconds: 60));
    expect(got, isNotNull);
    expect(got, file);
  });

  test('a length that is not exact is refused, never guessed', () async {
    final file = _bytes(300 * 1024, seed: 3);
    final a = await holder('a', file);
    final (fetcher, providers, _) = await wire([a.archive]);
    final logs = <String>[];
    // What a message's rounded `size:` would give: 1 MB, sixteen pieces.
    final got = await fetchByPieces(fetcher,
        fileHash: _sha(file),
        size: 1024 * 1024,
        providers: providers,
        manifest: _sha(a.list!),
        timeout: const Duration(seconds: 30),
        log: logs.add);
    expect(got, isNull);
    expect(logs.single, contains('does not match its size'));
  });

  test('a file of one piece has no list to fetch by', () async {
    final file = _bytes(20 * 1024, seed: 9);
    final a = await holder('a', file);
    expect(a.list, isNull);
  });
}
