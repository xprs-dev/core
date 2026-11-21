// The piece list of a file held as a blob (spec 7.7.2): the same bytes
// `pieceHashesOfBytes` gives, read a range at a time, and none at all for a
// file of one piece. Every holder of a multi-piece file names this list in
// its provider record, which is what lets a downloader take pieces from
// several holders (RnsService.dhtPublish).
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/folders/folder_event.dart'
    show pieceSizeForFile;
import 'package:xprs_core/src/services/folders/piece_hashes.dart';

Uint8List _blob(int n) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) & 0xFF));

void main() {
  Uint8List? Function(int, int) reader(Uint8List data, {List<int>? reads}) =>
      (off, len) {
        reads?.add(len);
        return Uint8List.sublistView(data, off, off + len);
      };

  test('a file of one piece has no piece list', () async {
    expect(await pieceListOfRanged(5000, reader(_blob(5000))), isNull);
    expect(await pieceListOfRanged(65536, reader(_blob(65536))), isNull);
  });

  test('a 240 kB file is four hashes, the same as hashing it whole', () async {
    final data = _blob(240640);
    final reads = <int>[];
    final list = await pieceListOfRanged(
        data.length, reader(data, reads: reads));
    expect(list, isNotNull);
    expect(list!.length, 4 * 32);
    expect(list,
        packPieceHashes(pieceHashesOfBytes(data, pieceSizeForFile(data.length))));
    // One piece in memory at a time, the last one short.
    expect(reads, [65536, 65536, 65536, 240640 - 3 * 65536]);
  });

  test('the piece size follows the file size (64 kB, 256 kB from 4 MB)',
      () async {
    final data = _blob(4 * 1024 * 1024 + 10);
    final reads = <int>[];
    final list = await pieceListOfRanged(
        data.length, reader(data, reads: reads));
    expect(reads.first, 262144);
    expect(list!.length ~/ 32, 17, reason: '16 full pieces and 10 bytes');
    expect(unpackPieceHashes(list), hasLength(17));
  });

  test('a range that cannot be read gives no list, never a wrong one',
      () async {
    final data = _blob(200000);
    var n = 0;
    final list = await pieceListOfRanged(data.length, (off, len) {
      if (++n == 2) return null;
      return Uint8List.sublistView(data, off, off + len);
    });
    expect(list, isNull);
  });
}
