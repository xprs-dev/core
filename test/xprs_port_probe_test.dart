// The keeper's outside test of a station's port (xprs_port_probe_io.dart):
// a ping to the callsign must come back as a pong from it, signed by its key.
import 'dart:convert';
import 'dart:io';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/names/xprs_port_probe_io.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart';

void main() {
  final d = BigInt.parse('a1' * 32, radix: 16);
  final other = BigInt.parse('b2' * 32, radix: 16);
  final hex = HEX.encode(XprsCrypto.publicKeyXOnly(d));
  final call = 'X3${NostrCrypto.deriveCallsign(hex, length: 4)}';

  /// A station on a TCP port that answers pings as [signer], or says nothing.
  Future<ServerSocket> station(BigInt? signer, {String? as}) async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    s.listen((c) {
      c.listen((data) {
        if (signer == null) return;
        final ping = XprsPacket.parse(utf8.decode(data).trim())!;
        final pong = XprsPacket.parse('t:pong f:${as ?? call} d:${ping['f']} '
            'ts:${xprsFmtTs(DateTime.now().toUtc())} r:x')!;
        c.add(utf8.encode('${xprsSign(pong, signer).encode()}\n'));
      });
    });
    return s;
  }

  Future<bool> probe(ServerSocket s) => xprsPortAnswers('127.0.0.1', s.port,
      asker: 'X3KEEP', call: call, keyHex: hex,
      timeout: const Duration(seconds: 2));

  test('the station itself answers: open', () async {
    final s = await station(d);
    expect(await probe(s), isTrue);
    await s.close();
  });

  test('another key, another callsign, silence or a closed port: not open',
      () async {
    final wrongKey = await station(other);
    expect(await probe(wrongKey), isFalse);
    await wrongKey.close();
    final wrongCall = await station(d, as: 'X3OTHR');
    expect(await probe(wrongCall), isFalse);
    await wrongCall.close();
    final silent = await station(null);
    expect(await probe(silent), isFalse);
    await silent.close();
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    expect(
        await xprsPortAnswers('127.0.0.1', port,
            asker: 'X3KEEP', call: call, keyHex: hex,
            timeout: const Duration(seconds: 2)),
        isFalse);
  });
}
