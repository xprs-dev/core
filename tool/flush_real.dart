// Time the archive's periodic write on REAL signed packets, and what it
// costs the isolate that would be drawing the screen:
//   dart tool/flush_real.dart <new-archive.zx> <history.json>...
// Each JSON is a station's /api/xprs/history answer (rows with `wire`).
// Keys come from the identity rows among them. The same packets are written
// twice into fresh files: once on this isolate (in slices, as before), once
// handed to the archive's writer thread. For each, the longest this
// isolate's event loop went without a turn (a 2 ms timer that notes how
// late it fires): that pause is what a person feels.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart' show NostrCrypto;
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

String _base(String f) => f.split('-').first.toUpperCase();

Future<void> main(List<String> a) async {
  final wires = <String>{};
  for (final f in a.skip(1)) {
    final j = jsonDecode(File(f).readAsStringSync()) as Map<String, dynamic>;
    for (final r in (j['rows'] as List? ?? const [])) {
      final w = (r as Map)['wire'];
      if (w is String) wires.add(w);
    }
  }
  final packets =
      [for (final w in wires) XprsPacket.parse(w)].whereType<XprsPacket>().toList();
  final keys = <String, Uint8List>{};
  for (final p in packets) {
    final k = p['k'] ?? '';
    if (p.type != 'identity' || !k.startsWith('npub1')) continue;
    try {
      keys[_base(p['f'] ?? '')] =
          Uint8List.fromList(HEX.decode(NostrCrypto.decodeNpub(k)));
    } catch (_) {}
  }
  final keyed = packets
      .where((p) => p.has('sig') && keys.containsKey(_base(p['f'] ?? '')))
      .length;
  print('${packets.length} packets, $keyed signed with a known key');

  for (final thread in [false, true]) {
    final path = '${a.first}.${thread ? 'thread' : 'inline'}';
    for (final f in [File(path), File('$path.lock')]) {
      if (f.existsSync()) f.deleteSync();
    }
    final x = XprsArchive.instance
      ..offThreadWrites = thread
      ..keyResolver = ((c) => keys[c.toUpperCase()])
      ..init(path);
    if (thread) {
      while (!x.writesOffThread) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    // The pause meter, running through the whole write. Pauses of 30 ms or
    // more are listed with when they began.
    final t = Stopwatch()..start();
    var worst = 0;
    final long = <String>[];
    var last = DateTime.now().microsecondsSinceEpoch;
    final meter = Timer.periodic(const Duration(milliseconds: 2), (_) {
      final now = DateTime.now().microsecondsSinceEpoch;
      final gap = now - last;
      if (gap > worst) worst = gap;
      if (gap >= 30000) {
        long.add('${gap ~/ 1000}ms at ${t.elapsedMilliseconds - gap ~/ 1000}ms');
      }
      last = now;
    });
    // Admitted in steps of 50 under the archive's own triggers, the way a
    // radio delivers them, each step one turn of the event loop.
    for (var i = 0; i < packets.length; i += 50) {
      for (final p in packets.skip(i).take(50)) {
        x.admit(p, bearer: 'lan');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!thread) await x.flushInSlices();
    }
    final admittedAt = t.elapsedMilliseconds;
    if (thread) {
      await x.flushNow();
    } else {
      await x.flushInSlices();
    }
    meter.cancel();
    print('  admitted by ${admittedAt}ms; pauses: ${long.join(', ')}');
    print('${thread ? 'writer thread' : 'this isolate '}: written in '
        '${t.elapsedMilliseconds} ms, longest pause here ${worst ~/ 1000} ms, '
        '${x.countOf()} rows');
    x.close();
  }
  exit(0);
}
