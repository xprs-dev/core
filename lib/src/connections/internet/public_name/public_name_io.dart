/*
 * A public name and HTTPS for the server, with nobody doing anything.
 *
 * Every [checkEvery] the server:
 *   1. finds its public addresses (public_address_io.dart) and the nip.io names
 *      they give: 2a02-...-d505.nip.io (IPv6, preferred: it does not change
 *      with the ISP's NAT) and 178-202-105-29.nip.io (IPv4). Nothing to
 *      register: nip.io answers any such name.
 *   2. asks the router by UPnP to let ports 80 and 443 in (upnp_io.dart), where
 *      the router allows it.
 *   3. finds which names the internet can reach, on which port, using Let's
 *      Encrypt's STAGING CA as the outside tester (generous limits, nothing
 *      to trust): an order answered on port 80 shows port 80 is open; a
 *      second one whose port-80 answer redirects to https://name/ (the CA
 *      follows it and ignores the certificate there) shows port 443 is open.
 *      Untested names are retried with a backoff (15 min doubling to 6 h),
 *      from scratch when an address changes.
 *   4. for names open on 443: gets a real certificate (HTTP-01), serves
 *      HTTPS, sends visitors who come by name over HTTP to HTTPS, renews 30
 *      days before expiry. Names open only on 80 are published as http://.
 *
 * State lives in options.dir (account keys, key, chain, state.json).
 * Counters go to the `perf: public-name` line (CoreHost.perfSources).
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../platform/core_host.dart';
import '../../../services/log_service.dart';
import 'public_name_api.dart';
import 'acme_io.dart';
import 'ec_key.dart';
import 'public_address_io.dart';
import 'upnp_io.dart';

class PublicName {
  PublicName({
    required this.options,
    required this.http,
    required this.newServer,
    void Function(String)? log,
    this.onUrl,
  }) : log = log ?? LogService.instance.add {
    CoreHost.perfSources['public-name'] = () {
      final c = Map<String, int>.of(_perf);
      _perf.updateAll((_, _) => 0);
      return c;
    };
  }

  // checks: rounds run; probes: staging orders; issued: real certificates;
  // failed: orders that failed.
  final _perf = {'checks': 0, 'probes': 0, 'issued': 0, 'failed': 0};

  final PublicNameOptions options;

  /// The plain-HTTP web chat: answers challenges, redirects by name.
  final AcmeWebServer http;

  /// A fresh web chat server for HTTPS.
  final AcmeWebServer Function() newServer;
  final void Function(String) log;

  /// Called with the public URL whenever it changes (null: none).
  final void Function(String?)? onUrl;

  /// Names for this station beyond the nip.io ones, asked for its public
  /// addresses (the names keeper of XPRS.md 13.0.3: `x3ptzm.xprs.dev`, from
  /// the keeper's client, or from the keeper itself on the keeper's host).
  /// Asked when the addresses change and every [extraNamesEvery] otherwise,
  /// again each round while it returns nothing. They go first: the first
  /// reachable name is the one published as the station's URL.
  Future<List<String>> Function({String? v4, String? v6})? extraNames;
  static const Duration extraNamesEvery = Duration(days: 7);
  List<String> _extra = const [];
  DateTime? _extraAt;

  AcmeWebServer? _https;
  Timer? _timer;
  bool _busy = false;
  PublicAddresses? _last;
  DateTime _nextProbe = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _backoff = const Duration(minutes: 15);
  String? url;
  List<String> _names = const [];
  List<String> _served = const [];
  List<String> _httpOnly = const [];

  /// The public IPv4 last found (null before the first check, or none).
  String? get publicIPv4 => _last?.v4?.address;

  /// Where the internet reaches this web chat now: https://name/ for every
  /// name in the certificate being served, http://name/ for a name open on
  /// port 80 only. Empty until a test from outside succeeded.
  List<String> get urls => [
        if (_https != null) for (final n in _served) 'https://$n/',
        for (final n in _httpOnly)
          if (_https == null || !_served.contains(n)) 'http://$n/',
      ];

  /// Names this machine's addresses give that nobody can reach yet: the
  /// router has not let ports 80 and 443 in for that address, or the test
  /// has not run. Shown to the operator so they know what to open.
  List<String> get pending => [
        for (final n in _names)
          if (!(_https != null && _served.contains(n)) && !_httpOnly.contains(n)) n,
      ];

  String get _tls => options.dir;
  File get _stateFile => File('$_tls/state.json');
  File get _certFile => File('$_tls/cert.pem');
  File get _keyFile => File('$_tls/key.pem');

  Future<void> start() async {
    await Directory(_tls).create(recursive: true);
    await _chmod(_tls, '700');
    // Serve the certificate we already have straight away.
    final st = _state();
    if (st != null && _certFile.existsSync() && _keyFile.existsSync()) {
      final exp = DateTime.tryParse('${st['expires']}');
      if (exp != null && exp.isAfter(DateTime.now().toUtc())) {
        await _serve((st['names'] as List).cast<String>());
      }
    }
    _timer = Timer.periodic(options.checkEvery, (_) => unawaited(check()));
    unawaited(check());
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _https?.stop();
  }

  /// One round of the loop in the header. Never throws.
  Future<void> check() async {
    if (_busy) return;
    _busy = true;
    try {
      await _check();
    } catch (e) {
      log('public name: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _check() async {
    _perf['checks'] = _perf['checks']! + 1;
    final addrs = await discoverPublicAddresses();
    if (addrs.isEmpty) {
      log('public name: no public address found');
      return;
    }
    final changed = addrs != _last;
    if (changed) {
      log('public name: public addresses $addrs');
      _last = addrs;
      _nextProbe = DateTime.fromMillisecondsSinceEpoch(0);
      _backoff = const Duration(minutes: 15);
    }
    if (options.upnp) await _openPorts(addrs, quiet: !changed);

    if (extraNames != null &&
        (changed ||
            _extra.isEmpty ||
            _extraAt == null ||
            DateTime.now().difference(_extraAt!) > extraNamesEvery)) {
      try {
        final got = await extraNames!(v4: addrs.v4?.address, v6: addrs.v6?.address);
        _extraAt = DateTime.now();
        if (got.isNotEmpty && got.join(',') != _extra.join(',')) {
          log('public name: named ${got.join(', ')}');
          // A new name is tested at the next round, not after the backoff.
          _nextProbe = DateTime.fromMillisecondsSinceEpoch(0);
        }
        _extra = got;
      } catch (e) {
        log('public name: names: $e');
      }
    }
    final names = [
      ..._extra,
      if (addrs.v6 != null) nipName(addrs.v6!),
      if (addrs.v4 != null) nipName(addrs.v4!),
    ];
    _names = names;

    // An address changed and the name we published no longer points here:
    // withdraw it (the announcement then says url:-) and stop serving it.
    final current = url;
    if (current != null && !names.contains(Uri.parse(current).host)) {
      log('public name: $current no longer points here');
      await _https?.stop();
      _https = null;
      _served = const [];
      _httpOnly = const [];
      http.redirectHosts = {};
      url = null;
      onUrl?.call(null);
    }

    // The certificate we have, if its names are still ours.
    var have = <String>[];
    final st = _state();
    if (st != null) {
      final certNames = (st['names'] as List).cast<String>();
      final exp = DateTime.tryParse('${st['expires']}');
      if (certNames.isNotEmpty && certNames.every(names.contains)) {
        final fresh = exp != null &&
            exp.isAfter(DateTime.now().toUtc().add(const Duration(days: 30)));
        if (!fresh) {
          // Same names, already shown reachable: renew without a test.
          log('public name: renewing ${certNames.join(', ')}');
          await _issue(certNames);
          return;
        }
        have = certNames;
      }
    }
    var untested = names.where((n) => !have.contains(n)).toList();
    if (untested.isEmpty || DateTime.now().isBefore(_nextProbe)) return;
    // A name just written into DNS takes a minute to reach the world; a test
    // before that gets NXDOMAIN and the CA's resolvers remember it for an
    // hour. Such a name waits for the next round, outside the backoff.
    final waiting = <String>[];
    for (final n in untested.where(_extra.contains)) {
      if (!await _resolves(n)) waiting.add(n);
    }
    if (waiting.isNotEmpty) {
      log('public name: ${waiting.join(', ')} not in DNS yet; testing next round');
      untested = untested.where((n) => !waiting.contains(n)).toList();
      if (untested.isEmpty) return;
    }

    final open = await _probe(untested);
    final https = [for (final e in open.entries) if (e.value.$2) e.key];
    final httpOnly = [
      for (final e in open.entries) if (e.value.$1 && !e.value.$2) e.key,
    ];
    _httpOnly = httpOnly;
    if (https.isNotEmpty) await _issue([...have, ...https]);
    if (have.isEmpty && https.isEmpty && httpOnly.isNotEmpty) {
      _setUrl('http://${httpOnly.first}/');
      log('public name: port 443 is closed, so no HTTPS yet');
    }
    if (https.length < untested.length) _later();
  }

  static Future<bool> _resolves(String name) async {
    try {
      return (await InternetAddress.lookup(name)).isNotEmpty;
    } on SocketException {
      return false;
    }
  }

  void _later() {
    _nextProbe = DateTime.now().add(_backoff);
    log('public name: retrying the names not yet reachable '
        'in ${_backoff.inMinutes} min');
    final next = _backoff * 2;
    _backoff = next > const Duration(hours: 6) ? const Duration(hours: 6) : next;
  }

  Future<void> _openPorts(PublicAddresses a, {required bool quiet}) async {
    final gw = await UpnpGateway.discover();
    if (gw == null) {
      if (!quiet) log('public name: no UPnP router found');
      return;
    }
    for (final (ext, internal) in [
      (80, options.httpPort),
      (443, options.httpsPort),
    ]) {
      if (a.v4 != null && gw.canMapV4) {
        try {
          await gw.mapTcpV4(ext, internalPort: internal, description: 'XPRS server');
          if (!quiet) log('public name: router maps IPv4 port $ext');
        } on UpnpException catch (e) {
          if (!quiet) log('public name: router refused IPv4 port $ext: $e');
        }
      }
      if (a.v6 != null && gw.canPinholeV6) {
        try {
          await gw.pinholeTcpV6(a.v6!, internal);
          if (!quiet) log('public name: router opened IPv6 port $internal');
        } on UpnpException catch (e) {
          if (!quiet) log('public name: router refused IPv6 port $internal: $e');
        }
      }
    }
  }

  /// name -> (open on 80, open on 443), tested from outside by the staging
  /// CA (header, step 3).
  Future<Map<String, (bool, bool)>> _probe(List<String> names) async {
    final out = <String, (bool, bool)>{};
    final client = AcmeClient(
      directoryUrl: letsEncryptStaging,
      accountKey: await _accountKey('account-staging.json'),
      contact: options.email,
    );
    // Challenges are answered by the HTTP server, and by whichever HTTPS
    // server is up (ours, or a stand-in during the test).
    AcmeWebServer? standIn;
    void publish(String t, String ka) {
      http.acmeChallenges[t] = ka;
      (_https ?? standIn)?.acmeChallenges[t] = ka;
    }

    void withdraw(String t) {
      http.acmeChallenges.remove(t);
      _https?.acmeChallenges.remove(t);
      standIn?.acmeChallenges.remove(t);
    }

    try {
      for (final n in names) {
        // Port 80.
        _perf['probes'] = _perf['probes']! + 2;
        final key = EcKey.generate();
        String chain;
        try {
          chain = await client.obtain(
              names: [n], certKey: key, publish: publish, withdraw: withdraw);
        } on AcmeException catch (e) {
          log(e.unreachable
              ? 'public name: $n is not reachable on port 80: ${e.message}'
              : 'public name: testing $n failed: ${e.message}');
          out[n] = (false, false);
          continue;
        }
        log('public name: $n is reachable on port 80');
        // Port 443, through the redirect; the staging certificate just
        // issued is good enough for the CA, which does not check it.
        var ok443 = false;
        try {
          if (_https == null) {
            standIn = newServer();
            await standIn.startSecure(
              port: options.httpsPort,
              address: options.address,
              certificateChain: utf8.encode(chain),
              privateKey: utf8.encode(key.toSec1Pem()),
            );
          }
          http.challengesViaHttps = true;
          await client.obtain(
              names: [n],
              certKey: EcKey.generate(),
              publish: publish,
              withdraw: withdraw);
          ok443 = true;
          log('public name: $n is reachable on port 443');
        } on AcmeException catch (e) {
          log('public name: $n is not reachable on port 443: ${e.message}');
        } on SocketException catch (e) {
          log('public name: cannot listen on ${options.httpsPort}: $e');
        } finally {
          http.challengesViaHttps = false;
          await standIn?.stop();
          standIn = null;
        }
        out[n] = (true, ok443);
      }
    } finally {
      client.close();
    }
    return out;
  }

  Future<void> _issue(List<String> names) async {
    final client = AcmeClient(
      directoryUrl: options.staging ? letsEncryptStaging : letsEncryptProduction,
      accountKey: await _accountKey(
          options.staging ? 'account-staging.json' : 'account.json'),
      contact: options.email,
    );
    try {
      final key = EcKey.generate();
      final chain = await client.obtain(
        names: names,
        certKey: key,
        publish: (t, ka) => http.acmeChallenges[t] = ka,
        withdraw: http.acmeChallenges.remove,
      );
      await _write(_keyFile, key.toSec1Pem());
      await _write(_certFile, chain);
      final exp = certificateExpiry(chain);
      await _write(
          _stateFile,
          jsonEncode({
            'names': names,
            'expires': exp?.toIso8601String(),
            'issued': DateTime.now().toUtc().toIso8601String(),
            'staging': options.staging,
          }));
      _perf['issued'] = _perf['issued']! + 1;
      log('public name: certificate for ${names.join(', ')} '
          'until ${exp?.toIso8601String() ?? '?'}');
      await _serve(names);
    } on AcmeException catch (e) {
      _perf['failed'] = _perf['failed']! + 1;
      log('public name: certificate failed: ${e.message}');
    } finally {
      client.close();
    }
  }

  Future<void> _serve(List<String> names) async {
    // Our own PEM files, a few KB each, and SecurityContext takes bytes.
    // arch-ignore: no-whole-file-read bounded PEM written by this service
    final chain = await _certFile.readAsBytes();
    // arch-ignore: no-whole-file-read bounded PEM written by this service
    final key = await _keyFile.readAsBytes();
    await _https?.stop();
    final s = newServer();
    try {
      await s.startSecure(
          port: options.httpsPort,
          address: options.address,
          certificateChain: chain,
          privateKey: key);
    } catch (e) {
      log('public name: cannot serve HTTPS on ${options.httpsPort}: $e');
      _https = null;
      _served = const [];
      http.redirectHosts = {};
      return;
    }
    _https = s;
    _served = names;
    http
      ..httpsPort = options.httpsPort
      ..redirectHosts = names.toSet();
    // The CA only follows redirects to 443, so a reachable https name is
    // on 443 from outside even when the server listens elsewhere (UPnP maps).
    _setUrl('https://${names.first}/');
  }

  void _setUrl(String u) {
    if (u == url) return;
    url = u;
    log('public name: web chat at $u');
    onUrl?.call(u);
  }

  Future<EcKey> _accountKey(String file) async {
    final f = File('$_tls/$file');
    if (f.existsSync()) {
      return EcKey.fromJson(
          jsonDecode(await f.readAsString()) as Map<String, Object?>);
    }
    final k = EcKey.generate();
    await _write(f, jsonEncode(k.toJson()));
    return k;
  }

  Map<String, dynamic>? _state() {
    try {
      return jsonDecode(_stateFile.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Atomic replace, owner-only.
  Future<void> _write(File f, String text) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await _chmod(tmp.path, '600');
    await tmp.rename(f.path);
  }

  static Future<void> _chmod(String path, String mode) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', [mode, path]);
    } catch (_) {}
  }
}
