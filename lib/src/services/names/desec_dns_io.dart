/*
 * NamesDns over deSEC's API (https://desec.readthedocs.io/): one bulk PUT
 * per change sets a label's A and AAAA RRsets exactly (an empty record list
 * deletes one). The token is held only here and never logged. A 429 becomes
 * NamesDnsBusy, which the keeper turns into "DNS pending" and retries from
 * its sweep.
 */
import 'dart:convert';
import 'dart:io';

import 'names_keeper.dart';

class DesecDns implements NamesDns {
  DesecDns({
    required this.zone,
    required String token,
    this.api = 'https://desec.io/api/v1',
    this.ttl = 900,
    HttpClient? client,
  })  : _token = token,
        _client = client ?? HttpClient();

  final String zone;
  final String api;

  /// deSEC's minimum for this zone is 900.
  final int ttl;
  final String _token;
  final HttpClient _client;

  Uri get _rrsets => Uri.parse('$api/domains/$zone/rrsets/');

  @override
  Future<void> set(String label, {String? v4, String? v6}) => _put([
        {
          'subname': label,
          'type': 'A',
          'ttl': ttl,
          'records': [if (v4 != null) v4],
        },
        {
          'subname': label,
          'type': 'AAAA',
          'ttl': ttl,
          'records': [if (v6 != null) v6],
        },
      ]);

  @override
  Future<void> remove(String label) => set(label);

  @override
  Future<void> ensureCaa() async {
    final have = await _get(Uri.parse('$api/domains/$zone/rrsets/@/CAA/'));
    if (have != null) return;
    await _put([
      {
        'subname': '',
        'type': 'CAA',
        'ttl': 3600,
        'records': ['0 issue "letsencrypt.org"'],
      }
    ]);
  }

  /// The RRset as JSON, or null when there is none (404).
  Future<Map<String, dynamic>?> _get(Uri u) async {
    final req = await _client.getUrl(u).timeout(const Duration(seconds: 30));
    req.headers.set(HttpHeaders.authorizationHeader, 'Token $_token');
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await utf8.decodeStream(res);
    if (res.statusCode == 404) return null;
    if (res.statusCode == 429) throw const NamesDnsBusy();
    if (res.statusCode != 200) throw _fail(u, res.statusCode, text);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> _put(List<Map<String, Object?>> rrsets) async {
    final req = await _client.putUrl(_rrsets).timeout(const Duration(seconds: 30));
    req.headers.set(HttpHeaders.authorizationHeader, 'Token $_token');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(rrsets));
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await utf8.decodeStream(res);
    if (res.statusCode == 429) throw const NamesDnsBusy();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw _fail(_rrsets, res.statusCode, text);
    }
  }

  /// The error without the token, which deSEC never echoes but the request
  /// headers would.
  static Exception _fail(Uri u, int status, String body) => Exception(
      'deSEC ${u.path} answered $status: ${body.length > 200 ? body.substring(0, 200) : body}');

  void close() => _client.close(force: true);
}
