/*
 * Does a station answer on its XPRS/Reticulum port from the internet?
 * (XPRS.md 13.4: one TCP port, 4242, speaks both.) The names keeper asks
 * this of every claimant, from outside, because a station cannot test its
 * own port from inside its own network.
 *
 * Not "is the port open": a `t:ping` to the station's callsign must come
 * back as a `t:pong` from that callsign, signed by the claimant's key. A port
 * forwarded to some other program, or to another station, does not pass.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hex/hex.dart';

import '../xprs/xprs_packet.dart';
import '../xprs/xprs_sig.dart';
import '../xprs/xprs_vocab.dart';

/// True when [address]:[port] answers a ping to [call] with a pong from
/// [call] signed by [keyHex]. [asker] is the keeper's own callsign.
Future<bool> xprsPortAnswers(
  String address,
  int port, {
  required String asker,
  required String call,
  required String keyHex,
  Duration timeout = const Duration(seconds: 6),
}) async {
  Socket? s;
  try {
    s = await Socket.connect(address, port, timeout: timeout);
    final ping = 't:ping f:$asker d:$call ts:${xprsFmtTs(DateTime.now().toUtc())}';
    s.add(utf8.encode('$ping\n'));
    await s.flush();
    final done = Completer<bool>();
    final buf = StringBuffer();
    final key = Uint8List.fromList(HEX.decode(keyHex));
    final sub = s.listen((data) {
      buf.write(utf8.decode(data, allowMalformed: true));
      final text = buf.toString();
      for (final line in text.split('\n')) {
        final p = XprsPacket.parse(line.trim());
        if (p == null || p.type != 'pong') continue;
        final from = (p['f'] ?? '').trim().toUpperCase().split('-').first;
        if (from == call.toUpperCase().split('-').first &&
            xprsVerify(p, key) == XprsSigState.verified) {
          if (!done.isCompleted) done.complete(true);
        }
      }
      if (buf.length > 8192 && !done.isCompleted) done.complete(false);
    }, onDone: () {
      if (!done.isCompleted) done.complete(false);
    }, onError: (_) {
      if (!done.isCompleted) done.complete(false);
    });
    final ok = await done.future.timeout(timeout, onTimeout: () => false);
    await sub.cancel();
    return ok;
  } catch (_) {
    return false;
  } finally {
    s?.destroy();
  }
}
