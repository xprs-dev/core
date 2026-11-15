// Visit a station as the app does, from a computer: through a gateway's
// WebSocket, with a throwaway visitor key. Prints what the station offers.
//
//   dart run tool/station_visit.dart wss://x3ptzm.xprs.dev/rns X3PTZM
//
// The calls are StationVisit's own (lib/src/services/station), so this is a
// check of the client against a real station, firmware or server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';
import 'package:xprs_core/src/services/station/station_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart' show xprsNowTs;

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args[0] : 'wss://x3ptzm.xprs.dev/rns';
  final call = (args.length > 1 ? args[1] : 'X3PTZM').toUpperCase();
  final sw = Stopwatch()..start();
  void say(String m) => stdout.writeln('${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s $m');
  final ws = await WebSocket.connect(url);
  final control = StreamController<Map<String, dynamic>>.broadcast();
  final gw = RnsGatewayClient((f) => ws.add(f));
  ws.listen((m) {
    if (m is List<int>) {
      gw.onFrame(Uint8List.fromList(m));
    } else if (m is String) {
      control.add(jsonDecode(m) as Map<String, dynamic>);
    }
  });
  Future<Map<String, dynamic>> ask(Map<String, Object?> j) {
    final f = control.stream.first;
    ws.add(jsonEncode(j));
    return f.timeout(const Duration(seconds: 15));
  }

  await ask({'op': 'hello'});
  final r = await ask({'op': 'resolve', 'call': call});
  final rns = r['rns'];
  if (rns is! String) {
    say('the gateway does not know $call');
    exit(1);
  }
  final link = gw.client(RnsIdentity.fromPublicKey(Uint8List.fromList(HEX.decode(rns))));
  if (!await link.open()) {
    say('no link');
    exit(1);
  }
  say('link open');
  const nonce = 'visitprobe0001';
  final linkHex = HEX.encode(link.linkId!);
  final fault = stationProofFault(await link.request('/xprs/prove', nonce), call, nonce, linkHex);
  say(fault == null ? 'proof holds: this is $call' : 'PROOF REFUSED: $fault');

  final rng = Random.secure();
  var d = BigInt.zero;
  for (var i = 0; i < 32; i++) {
    d = (d << 8) | BigInt.from(rng.nextInt(256));
  }
  final pubHex = HEX.encode(XprsCrypto.publicKeyXOnly(d));
  final me = 'X1${NostrCrypto.deriveCallsign(pubHex)}';
  String sign(String w) => xprsSign(XprsPacket.parse(w)!, d).encode();
  final v = StationVisit(call, stationLinkCarrier(link),
      visitor: StationVisitor(
        call: me,
        identityWire: () => sign('t:identity f:$me ts:${xprsNowTs()} k:${NostrCrypto.encodeNpub(pubHex)}'),
        sign: sign,
      ));
  final s = await v.services();
  say('services: serve ${s?['serve']} page ${(s?['page'] as Map?)?.keys.toList()} file ${s?['file']}');
  say('session as $me: ${await v.session() == null ? 'none' : 'held'}');
  final rooms = await v.rooms();
  if (rooms == null) {
    say('no rooms API');
  } else {
    for (final room in rooms) {
      say('room ${room.call} "${room.name}" ${room.kind} ${room.visibility} role ${room.role}');
      if (!room.isCollection) continue;
      final topics = await v.topics(room.call) ?? [];
      final c = await v.collection(room.call);
      for (final t in topics) {
        final items = c?.inFolder(t.id) ?? [];
        say('  folder "${t.title}": ${items.length} items');
        for (final it in items.take(3)) {
          say('    ${it.name.isEmpty ? it.caption : it.name} ${it.size} preview ${it.preview.isEmpty ? '-' : 'yes'} likes ${it.likes}');
        }
        if (items.isNotEmpty) {
          final it = items.first;
          final ref = it.preview.isNotEmpty ? it.preview : it.ref;
          final t0 = sw.elapsedMilliseconds;
          var got = 0, parts = 0;
          final st = await v.fileParts(it.ref.isNotEmpty ? it.ref : ref, (b, o, n) async {
            got += b.length;
            parts++;
          });
          say('    file ${it.ref}: $st $got bytes in $parts parts, ${sw.elapsedMilliseconds - t0} ms');
        }
      }
    }
  }
  say('calls ${StationVisit.calls}, unanswered ${StationVisit.unanswered}');
  gw.drop(link);
  await ws.close();
  exit(0);
}
