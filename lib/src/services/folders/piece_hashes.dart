/*
 * Copyright (c) Max Brito and XPRS contributors
 * License: BSD-3-Clause
 *
 * The piece-hash list of a file (docs/torrents.md §8 step 2).
 *
 * A publisher cuts each file into pieces, hashes every piece, and publishes the
 * LIST as its own content-addressed blob — naming that blob's sha256 in the
 * signed addFile op. Two things follow, and they are the whole reason the swarm
 * can be trusted:
 *
 *   * the list is authenticated by the owner's signature (the op names it), so
 *     once a downloader has bytes that hash to `ph`, every piece hash in it is
 *     the publisher's word;
 *   * therefore ONE piece from ONE stranger is verifiable on its own, before the
 *     rest of the file exists. Without this, bytes from an unknown peer can only
 *     be checked after the last byte of the whole file — which is why a naive
 *     multi-peer fetch is unsafe, not merely slow.
 *
 * The list is just 32 bytes per piece (a 4 GB file → 4096 pieces → 128 KB), and
 * it is fetched like any other blob, from anyone.
 */

import 'package:file/file.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:reticulum/reticulum.dart';

import 'folder_event.dart' show pieceSizeForFile;

/// The piece hashes of [file], read in bounded chunks so a 4 GB file costs one
/// piece of memory rather than four gigabytes. Yields between pieces, so a big
/// hash never freezes the isolate it runs on.
Future<List<Uint8List>> pieceHashesOfFile(File file, int pieceSize) async {
  final out = <Uint8List>[];
  final raf = await file.open();
  try {
    var buf = BytesBuilder(copy: false);
    var inPiece = 0;
    var sinceYield = 0;
    const chunkSize = 1 << 16; // 64 KiB
    while (true) {
      final want = pieceSize - inPiece;
      final chunk = await raf.read(want < chunkSize ? want : chunkSize);
      if (chunk.isEmpty) break;
      buf.add(chunk);
      inPiece += chunk.length;
      if (inPiece >= pieceSize) {
        out.add(Uint8List.fromList(
            crypto.sha256.convert(buf.takeBytes()).bytes));
        buf = BytesBuilder(copy: false);
        inPiece = 0;
      }
      if (++sinceYield >= 64) {
        sinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (inPiece > 0) {
      out.add(
          Uint8List.fromList(crypto.sha256.convert(buf.takeBytes()).bytes));
    }
  } finally {
    await raf.close();
  }
  return out;
}

/// The piece hashes of bytes already in memory.
List<Uint8List> pieceHashesOfBytes(Uint8List bytes, int pieceSize) {
  final out = <Uint8List>[];
  for (var o = 0; o < bytes.length; o += pieceSize) {
    final end =
        (o + pieceSize > bytes.length) ? bytes.length : o + pieceSize;
    out.add(Uint8List.fromList(
        crypto.sha256.convert(Uint8List.sublistView(bytes, o, end)).bytes));
  }
  return out;
}

/// The hashes packed for publication: one 32-byte hash after another. This blob
/// is what `ph` names, and what a downloader verifies before believing a hash in
/// it.
Uint8List packPieceHashes(List<Uint8List> hashes) {
  final out = Uint8List(hashes.length * 32);
  for (var i = 0; i < hashes.length; i++) {
    out.setRange(i * 32, i * 32 + 32, hashes[i]);
  }
  return out;
}

/// The inverse. Returns null when [blob] is not a whole number of hashes — a
/// list we cannot read is a list we must not guess at.
List<Uint8List>? unpackPieceHashes(Uint8List blob) {
  if (blob.isEmpty || blob.length % 32 != 0) return null;
  return [
    for (var i = 0; i < blob.length; i += 32)
      Uint8List.fromList(Uint8List.sublistView(blob, i, i + 32)),
  ];
}

/// The packed piece list (spec 7.7.2) of a file of [size] bytes that is read
/// a range at a time through [read], or null when the file is one piece (it
/// needs no list: its own hash verifies it) or a range could not be read.
///
/// For a file held as a blob rather than on disk. One piece is in memory at
/// a time, and the loop yields between pieces, so hashing a large file never
/// holds it whole or freezes the isolate it runs on.
Future<Uint8List?> pieceListOfRanged(
    int size, Uint8List? Function(int offset, int length) read) async {
  final pieceSize = pieceSizeForFile(size);
  if (size <= pieceSize) return null;
  final hashes = <Uint8List>[];
  for (var off = 0; off < size; off += pieceSize) {
    final len = off + pieceSize > size ? size - off : pieceSize;
    final piece = read(off, len);
    if (piece == null || piece.length != len) return null;
    hashes.add(Uint8List.fromList(crypto.sha256.convert(piece).bytes));
    await Future<void>.delayed(Duration.zero);
  }
  return packPieceHashes(hashes);
}

/// Fetch a file of exactly [size] bytes by pieces from [providers], given the
/// hash of its piece list ([manifest], what a provider record or a `ph:`
/// names): the list first, from whichever holder serves it, then the pieces
/// from all of them at once, each verified against the list, the whole
/// against [fileHash]. Null when no holder serves the list, the list does not
/// match the size, or the pieces cannot be completed; the caller then falls
/// back to a whole-file fetch.
///
/// The one place the three facts a piece fetch needs meet: the exact length
/// (a holder's `202` or `q:have` answer, spec 11.2, 8.1), the piece list
/// (7.7.2) and the holders.
Future<Uint8List?> fetchByPieces(
  FileTransferNode f, {
  required Uint8List fileHash,
  required int size,
  required List<RnsIdentity> providers,
  required Uint8List manifest,
  Duration timeout = const Duration(minutes: 20),
  void Function(String message)? log,
}) async {
  if (size <= 0 || providers.isEmpty) return null;
  // The list itself is a small blob every holder also serves; one whole-file
  // fetch of a few KB, from whichever provider answers first.
  Uint8List? blob;
  for (final p in providers) {
    blob = await f.fetch(manifest, p, timeout: const Duration(seconds: 45));
    if (blob != null && blob.isNotEmpty) break;
  }
  if (blob == null || blob.isEmpty) {
    log?.call('no holder served the piece list — whole-file path');
    return null;
  }
  final hashes = unpackPieceHashes(blob);
  final pieceSize = pieceSizeForFile(size);
  if (hashes == null || hashes.length != pieceCountFor(size, pieceSize)) {
    log?.call('piece list does not match its size — whole-file path');
    return null;
  }
  return f.fetchFilePieces(
    fileHash: fileHash,
    size: size,
    pieceSize: pieceSize,
    pieceHashes: hashes,
    providers: providers,
    timeout: timeout,
  );
}
