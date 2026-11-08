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

  /// Claims the name for each of [v4] and [v6] that is given; returns the
  /// names the keeper confirmed (one, or none).
  Future<List<String>> claim({String? v4, String? v6}) async {
    final out = <String>{};
    for (final (addr, type) in [
      if (v4 != null) (v4, InternetAddressType.IPv4),
      if (v6 != null) (v6, InternetAddressType.IPv6),
    ]) {
      try {
        final name = await _claimOne(addr, type);
        if (name != null) out.add(name);
      } catch (e) {
        log('names: claim for $addr failed: $e');
      }
    }
    return out.toList();
  }

  Future<String?> _claimOne(String addr, InternetAddressType type) async {
    final base = Uri.parse(options.keeper);
    final host = base.host;
    final targets = await InternetAddress.lookup(host, type: type);
    if (targets.isEmpty) {
      log('names: $host has no ${type == InternetAddressType.IPv6 ? 'AAAA' : 'A'} record');
      return null;
    }
    final client = HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) {
        final port = uri.port == 0 ? (uri.scheme == 'https' ? 443 : 80) : uri.port;
        // An address from lookup() carries the host name, which the TLS
        // handshake uses for SNI and the certificate check.
        return uri.scheme == 'https'
            ? SecureSocket.startConnect(targets.first, port)
            : Socket.startConnect(targets.first, port);
      };
    try {
      final api = base.replace(path: '/api/names');
      final ch = await _json(client, await client.getUrl(api));
      if (ch == null || ch['ok'] != true) {
        log('names: $host gave no challenge');
        return null;
      }
      final nonce = '${ch['nonce']}', station = '${ch['station']}';
      final seen = '${ch['you']}';
      if (_norm(seen) != _norm(addr)) {
        // The keeper sees another address (a NAT, a proxy): a claim for
        // this one would be refused, so it is not made.
        log('names: the keeper sees $seen, not $addr; no claim');
        return null;
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
        return null;
      }
      final req = await client.postUrl(api);
      req.headers.contentType = ContentType.text;
      req.write(p.encode());
      final r = await _json(client, req);
      if (r == null) return null;
      if (r['ok'] == true) return '${r['name']}';
      log('names: ${r['error']}${r['until'] != null ? ' until ${r['until']}' : ''}');
      return null;
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
