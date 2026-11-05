/*
 * A small ACME (RFC 8555) client for HTTP-01, enough for Let's Encrypt.
 *
 * The caller answers the challenges: [AcmeClient.obtain] hands each token and
 * key authorization to `publish`, which must make
 * http://<name>/.well-known/acme-challenge/<token> return the key
 * authorization (WebChatServer.acmeChallenges does), and calls `withdraw`
 * when done.
 *
 * Failures throw [AcmeException]; [AcmeException.unreachable] is true when the
 * CA could not connect to the name (the reachability verdict the server uses).
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ec_key.dart';

const letsEncryptProduction = 'https://acme-v02.api.letsencrypt.org/directory';
const letsEncryptStaging =
    'https://acme-staging-v02.api.letsencrypt.org/directory';

class AcmeException implements Exception {
  AcmeException(this.message, {this.type = '', this.unreachable = false});
  final String message;

  /// The ACME problem type (urn:ietf:params:acme:error:...), or empty.
  final String type;

  /// The CA could not reach the name (connection, timeout, DNS).
  final bool unreachable;

  @override
  String toString() => 'ACME: $message';
}

class AcmeClient {
  AcmeClient({
    required this.directoryUrl,
    required this.accountKey,
    this.contact,
    this.log,
  });

  final String directoryUrl;
  final EcKey accountKey;
  final String? contact; // e-mail, optional
  final void Function(String)? log;

  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  Map<String, dynamic>? _dir;
  String? _nonce;
  String? _kid;

  void close() => _http.close(force: true);

  /// Gets a certificate for [names]; returns the PEM chain.
  Future<String> obtain({
    required List<String> names,
    required EcKey certKey,
    required void Function(String token, String keyAuth) publish,
    required void Function(String token) withdraw,
  }) async {
    await _account();
    final order = await _post(_dir!['newOrder'] as String, {
      'identifiers': [
        for (final n in names) {'type': 'dns', 'value': n},
      ],
    });
    final orderUrl = order.location!;
    final tokens = <String>[];
    try {
      for (final authzUrl in (order.json['authorizations'] as List).cast<String>()) {
        final authz = (await _post(authzUrl, null)).json;
        if (authz['status'] == 'valid') continue;
        final ch = (authz['challenges'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((c) => c['type'] == 'http-01',
                orElse: () => throw AcmeException('no http-01 challenge'));
        final token = ch['token'] as String;
        publish(token, '$token.${accountKey.thumbprint}');
        tokens.add(token);
        await _post(ch['url'] as String, <String, dynamic>{});
        await _poll(authzUrl, done: 'valid', what:
            'authorization for ${(authz['identifier'] as Map)['value']}');
      }
      await _poll(orderUrl, done: 'ready', what: 'order');
      await _post(order.json['finalize'] as String,
          {'csr': b64url(certKey.csr(names))});
      final ready = await _poll(orderUrl, done: 'valid', what: 'order');
      final cert = await _post(ready['certificate'] as String, null);
      return cert.body;
    } finally {
      for (final t in tokens) {
        withdraw(t);
      }
    }
  }

  Future<void> _account() async {
    _dir ??= jsonDecode(await _get(directoryUrl)) as Map<String, dynamic>;
    if (_kid != null) return;
    final r = await _post(_dir!['newAccount'] as String, {
      'termsOfServiceAgreed': true,
      if (contact != null && contact!.isNotEmpty) 'contact': ['mailto:$contact'],
    }, useJwk: true);
    _kid = r.location;
  }

  Future<Map<String, dynamic>> _poll(String url,
      {required String done, required String what}) async {
    for (var i = 0; i < 40; i++) {
      final j = (await _post(url, null)).json;
      final st = j['status'];
      if (st == done || (done == 'ready' && st == 'valid')) return j;
      if (st == 'invalid') throw _problemOf(j, what);
      await Future<void>.delayed(Duration(seconds: i < 5 ? 2 : 5));
    }
    throw AcmeException('$what: timed out');
  }

  /// The error inside an invalid authorization or order.
  AcmeException _problemOf(Map<String, dynamic> j, String what) {
    Map<String, dynamic>? err = j['error'] as Map<String, dynamic>?;
    for (final c in (j['challenges'] as List? ?? const [])) {
      if (c is Map && c['error'] is Map) err = c['error'] as Map<String, dynamic>;
    }
    final type = (err?['type'] ?? '') as String;
    final detail = (err?['detail'] ?? 'invalid') as String;
    const unreach = ['connection', 'dns', 'unknownHost', 'incorrectResponse'];
    return AcmeException('$what: $detail',
        type: type, unreachable: unreach.any(type.endsWith));
  }

  Future<String> _get(String url) async {
    final req = await _http.getUrl(Uri.parse(url));
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    if (res.statusCode >= 300) {
      throw AcmeException('GET $url: HTTP ${res.statusCode}');
    }
    return body;
  }

  Future<String> _newNonce() async {
    final req = await _http.headUrl(Uri.parse(_dir!['newNonce'] as String));
    final res = await req.close();
    await res.drain<void>();
    final n = res.headers.value('replay-nonce');
    if (n == null) throw AcmeException('no nonce');
    return n;
  }

  /// A JWS POST; [payload] null is POST-as-GET.
  Future<_Reply> _post(String url, Object? payload,
      {bool useJwk = false, bool retried = false}) async {
    final nonce = _nonce ?? await _newNonce();
    _nonce = null;
    final protected = {
      'alg': 'ES256',
      'nonce': nonce,
      'url': url,
      if (useJwk) 'jwk': accountKey.jwk else 'kid': _kid,
    };
    final p64 = b64url(utf8.encode(jsonEncode(protected)));
    final b64 = payload == null ? '' : b64url(utf8.encode(jsonEncode(payload)));
    final sig = b64url(accountKey.signRaw(utf8.encode('$p64.$b64')));
    final req = await _http.postUrl(Uri.parse(url));
    req.headers.contentType = ContentType('application', 'jose+json');
    final bytes = utf8.encode(
        jsonEncode({'protected': p64, 'payload': b64, 'signature': sig}));
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    _nonce = res.headers.value('replay-nonce');
    if (res.statusCode >= 400) {
      Map<String, dynamic> j = {};
      try {
        j = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {}
      final type = (j['type'] ?? '') as String;
      if (type.endsWith(':badNonce') && !retried) {
        return _post(url, payload, useJwk: useJwk, retried: true);
      }
      throw AcmeException('${j['detail'] ?? 'HTTP ${res.statusCode}'}',
          type: type);
    }
    return _Reply(body, res.headers.value('location'));
  }
}

class _Reply {
  _Reply(this.body, this.location);
  final String body;
  final String? location;
  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
}

/// The first certificate's notAfter (UTC), from its DER; null if unreadable.
DateTime? certificateExpiry(String pemChain) {
  final m = RegExp(
          r'-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----')
      .firstMatch(pemChain);
  if (m == null) return null;
  try {
    final b = base64.decode(m.group(1)!.replaceAll(RegExp(r'\s'), ''));
    var p = 0;
    // Returns (tag, start of content, end of content) of the element at [at].
    (int, int, int) tlv(int at) {
      final tag = b[at];
      var len = b[at + 1];
      var s = at + 2;
      if (len & 0x80 != 0) {
        final n = len & 0x7f;
        len = 0;
        for (var i = 0; i < n; i++) {
          len = (len << 8) | b[s + i];
        }
        s += n;
      }
      return (tag, s, s + len);
    }

    p = tlv(0).$2; // Certificate -> tbsCertificate
    p = tlv(p).$2; // tbsCertificate contents
    var e = tlv(p);
    if (e.$1 == 0xa0) p = e.$3; // [0] version
    p = tlv(p).$3; // serialNumber
    p = tlv(p).$3; // signature algorithm
    p = tlv(p).$3; // issuer
    final validity = tlv(p);
    e = tlv(validity.$2); // notBefore
    e = tlv(e.$3); // notAfter
    var s = ascii.decode(b.sublist(e.$2, e.$3)).replaceAll('Z', '');
    if (e.$1 == 0x17) {
      final yy = int.parse(s.substring(0, 2));
      s = '${yy < 50 ? 20 : 19}$s';
    }
    return DateTime.utc(
      int.parse(s.substring(0, 4)),
      int.parse(s.substring(4, 6)),
      int.parse(s.substring(6, 8)),
      int.parse(s.substring(8, 10)),
      int.parse(s.substring(10, 12)),
      int.parse(s.substring(12, 14)),
    );
  } catch (_) {
    return null;
  }
}
