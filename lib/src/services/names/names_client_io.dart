/*
 * The station side of the names keeper (XPRS.md 13.0.3): claim
 * `<callsign>.<zone>` for this station's public addresses.
 *
 * One claim per address family, each over a connection of that family, so
 * the keeper sees the request come from the very address the claim names.
 * The keeper's host name is resolved to an A or AAAA record and the TLS
 * connection is made to that address with the host name for SNI and the
 * certificate check. Anything that fails is logged and skipped; the
 * public-name loop asks again next round.
 */
import 'dart:convert';
import 'dart:io';

import '../xprs/xprs_packet.dart';
import '../xprs/xprs_vocab.dart';

class NamesClientOptions {
  const NamesClientOptions({
    required this.keeper,
    required this.callsign,
    required this.npub,
    required this.sign,
  });

  /// `https://names.xprs.dev`.
  final String keeper;
  final String Function() callsign;
  final String Function() npub;

  /// Signs a packet as this station; null when it cannot (no key yet).
  final XprsPacket? Function(XprsPacket p) sign;
}

class NamesClient {
  NamesClient(this.options, {void Function(String)? log, DateTime Function()? now})
      : log = log ?? print,
        now = now ?? DateTime.now;

  final NamesClientOptions options;
  final void Function(String) log;
  final DateTime Function() now;

  /// Whether the keeper reached this station on its XPRS/Reticulum port
  /// (13.4) from outside at the last [claim]: true when any address family
  /// answered, false when the keeper tested and none did, null when no
  /// keeper reply said.
  bool? portOpen;

  /// Claims the name for each of [v4] and [v6] that is given; returns the
  /// names the keeper confirmed (one, or none).
  Future<List<String>> claim({String? v4, String? v6}) async {
    final out = <String>{};
    bool? open;
    for (final (addr, type) in [
      if (v4 != null) (v4, InternetAddressType.IPv4),
      if (v6 != null) (v6, InternetAddressType.IPv6),
    ]) {
      try {
        final (name, port) = await _claimOne(addr, type);
        if (name != null) out.add(name);
        if (port != null) open = (open ?? false) || port;
      } catch (e) {
        log('names: claim for $addr failed: $e');
      }
    }
    portOpen = open;
    return out.toList();
  }

  /// The name the keeper confirmed and whether it reached the port.
  Future<(String?, bool?)> _claimOne(String addr, InternetAddressType type) async {
    final base = Uri.parse(options.keeper);
    final host = base.host;
    final targets = await InternetAddress.lookup(host, type: type);
    if (targets.isEmpty) {
      log('names: $host has no ${type == InternetAddressType.IPv6 ? 'AAAA' : 'A'} record');
      return (null, null);
    }
    // IPv6 has no NAT: the claim must leave FROM the address it names, not
    // from a temporary privacy address the system would pick by default.
    // IPv4 goes out through the router's NAT, which shows the keeper the
    // public address; there the local source is left to the system.
    final source = type == InternetAddressType.IPv6 ? InternetAddress(addr) : null;
    final client = HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) {
        final port = uri.port == 0 ? (uri.scheme == 'https' ? 443 : 80) : uri.port;
        final plain = Socket.connect(targets.first, port,
            sourceAddress: source, timeout: const Duration(seconds: 30));
        // An address from lookup() carries the host name, which the TLS
        // handshake uses for SNI and the certificate check.
        final Future<Socket> s = uri.scheme == 'https'
            ? plain.then((raw) => SecureSocket.secure(raw, host: host))
            : plain;
        return Future.value(ConnectionTask.fromSocket(s, () {}));
      };
    try {
      final api = base.replace(path: '/api/names');
      final ch = await _json(client, await client.getUrl(api));
      if (ch == null || ch['ok'] != true) {
        log('names: $host gave no challenge');
        return (null, null);
      }
      final nonce = '${ch['nonce']}', station = '${ch['station']}';
      final seen = '${ch['you']}';
      if (_norm(seen) != _norm(addr)) {
        // The keeper sees another address (a NAT, a proxy): a claim for
        // this one would be refused, so it is not made.
        log('names: the keeper sees $seen, not $addr; no claim');
        return (null, null);
      }
      final p = options.sign(XprsPacket([
        const MapEntry('t', 'service'),
        MapEntry('f', options.callsign()),
        MapEntry('d', station),
        MapEntry('ts', xprsFmtTs(now().toUtc())),
        MapEntry('dial', addr),
        MapEntry('k', options.npub()),
        // m: is the free-text tail (XPRS.md 4): last, so k: survives.
        MapEntry('m', nonce),
      ]));
      if (p == null) {
        log('names: no key to sign the claim with');
        return (null, null);
      }
      final req = await client.postUrl(api);
      req.headers.contentType = ContentType.text;
      req.write(p.encode());
      final r = await _json(client, req);
      if (r == null) return (null, null);
      if (r['ok'] == true) {
        final rns = r['rns'];
        final port = rns == 'open' ? true : (rns == 'closed' ? false : null);
        if (port != null) {
          log('names: the keeper ${port ? 'reached' : 'could not reach'} '
              'this station on port ${r['rns_port'] ?? 4242} at $addr');
        }
        return ('${r['name']}', port);
      }
      log('names: ${r['error']}${r['until'] != null ? ' until ${r['until']}' : ''}');
      return (null, null);
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>?> _json(HttpClient c, HttpClientRequest req) async {
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await utf8.decodeStream(res);
    try {
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      log('names: ${req.uri.host} answered ${res.statusCode} without JSON');
      return null;
    }
  }

  static String _norm(String a) {
    var s = a.trim().toLowerCase();
    if (s.startsWith('::ffff:') && s.contains('.')) s = s.substring(7);
    return s;
  }
}
