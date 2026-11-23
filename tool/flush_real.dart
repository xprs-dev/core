// Time the archive's periodic write on REAL signed packets:
//   dart tool/flush_real.dart <new-archive.zx> <history.json>...
// Each JSON is a station's /api/xprs/history answer (rows with `wire`).
// Keys come from the identity rows among them. Prints one line per slice
// with where the time went, and what a first signature check costs here.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart' show NostrCrypto;
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';

Future<void> main(List<String> a) async {
  final wires = <String>{};
  for (final f in a.skip(1)) {
    final j = jsonDecode(File(f).readAsStringSync()) as Map<String, dynamic>;
    for (final r in (j['rows'] as List? ?? const [])) {
      final w = (r as Map)['wire'];
      if (w is String) wires.add(w);
    }
  }
  final packets = [for (final w in wires) XprsPacket.parse(w)].whereType<XprsPacket>().toList();
  final keys = <String, Uint8List>{};
  for (final p in packets) {
    final k = p['k'] ?? '';
    if (p.type != 'identity' || !k.startsWith('npub1')) continue;
    try {
      keys[(p['f'] ?? '').split('-').first.toUpperCase()] =
          Uint8List.fromList(HEX.decode(NostrCrypto.decodeNpub(k)));
    } catch (_) {}
  }
  final signed = packets.where((p) => p.has('sig')).length;
  final keyed = packets.where((p) => p.has('sig') && keys.containsKey((p['f'] ?? '').split('-').first.toUpperCase())).length;
  print('${packets.length} packets, $signed signed, $keyed with a known key, ${keys.length} keys');

  // What one first check costs on this machine.
  final probe = packets.firstWhere((p) => p.has('sig') && !p.has('n') && keys.containsKey((p['f'] ?? '').split('-').first.toUpperCase()));
  final sw = Stopwatch()..start();
  final v = xprsVerify(probe, keys[(probe['f'] ?? '').split('-').first.toUpperCase()]);
  print('one first signature check: ${sw.elapsedMilliseconds} ms ($v)');

  final x = XprsArchive.instance
    ..init(a.first)
    ..keyResolver = (c) => keys[c.toUpperCase()];
  for (final warm in [false, true]) {
    for (final p in packets) {
      x.admit(p, bearer: 'lan');
    }
    final t = Stopwatch()..start();
    if (warm) {
      await x.flushInSlices();
    } else {
      x.flush();
    }
    print('${warm ? "second time (all verdicts known, rows exist)" : "first time (whole, verdicts unknown)"}: ${t.elapsedMilliseconds} ms');
  }
  x.close();
}
