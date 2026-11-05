/*
 * UPnP IGD: ask the home router to let the internet in, so an operator never
 * opens ports by hand. IPv4 port mappings (WANIPConnection / WANPPPConnection)
 * and IPv6 pinholes (WANIPv6FirewallControl). Routers that refuse (UPnP off,
 * pinholes not allowed) just say no; the caller logs it and carries on.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class UpnpGateway {
  UpnpGateway._(this.base, this._services);

  /// http://router:port of the description that was found.
  final Uri base;
  final Map<String, Uri> _services; // serviceType -> control URL

  static const _ipConn = [
    'urn:schemas-upnp-org:service:WANIPConnection:2',
    'urn:schemas-upnp-org:service:WANIPConnection:1',
    'urn:schemas-upnp-org:service:WANPPPConnection:1',
  ];
  static const _v6fw = 'urn:schemas-upnp-org:service:WANIPv6FirewallControl:1';

  bool get canMapV4 => _ipConn.any(_services.containsKey);
  bool get canPinholeV6 => _services.containsKey(_v6fw);

  /// Finds the router by SSDP (multicast on the LAN), or null.
  static Future<UpnpGateway?> discover(
      {Duration wait = const Duration(seconds: 3)}) async {
    final locations = <Uri>{};
    RawDatagramSocket? s;
    try {
      s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      for (final st in [
        'urn:schemas-upnp-org:device:InternetGatewayDevice:2',
        'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
      ]) {
        s.send(
            utf8.encode('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
                'MAN: "ssdp:discover"\r\nMX: 2\r\nST: $st\r\n\r\n'),
            InternetAddress('239.255.255.250'),
            1900);
      }
      final sub = s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = s!.receive();
        if (d == null) return;
        final m = RegExp(r'^location:\s*(\S+)', caseSensitive: false, multiLine: true)
            .firstMatch(utf8.decode(d.data, allowMalformed: true));
        final u = m == null ? null : Uri.tryParse(m.group(1)!);
        if (u != null) locations.add(u);
      });
      await Future<void>.delayed(wait);
      await sub.cancel();
    } catch (_) {
      return null;
    } finally {
      s?.close();
    }
    // Merge every description the router offers (a FRITZ!Box puts IPv4
    // mapping and the IPv6 firewall in different ones).
    final services = <String, Uri>{};
    Uri? base;
    for (final loc in locations) {
      try {
        final xml = await _fetch(loc);
        for (final m in RegExp(r'<service>([\s\S]*?)</service>').allMatches(xml)) {
          final t = _tag(m.group(1)!, 'serviceType');
          final c = _tag(m.group(1)!, 'controlURL');
          if (t != null && c != null) services.putIfAbsent(t, () => loc.resolve(c));
        }
        base ??= loc.replace(path: '/');
      } catch (_) {}
    }
    if (base == null || services.isEmpty) return null;
    return UpnpGateway._(base, services);
  }

  /// The router's public IPv4, or null.
  Future<InternetAddress?> externalIPv4() async {
    final st = _ipConn.firstWhere(_services.containsKey, orElse: () => '');
    if (st.isEmpty) return null;
    final r = await _soap(st, 'GetExternalIPAddress', {});
    final ip = _tag(r, 'NewExternalIPAddress');
    return ip == null ? null : InternetAddress.tryParse(ip);
  }

  /// This machine's LAN IPv4 on the router's network.
  Future<InternetAddress?> lanAddress() async {
    final router = InternetAddress.tryParse(base.host) ??
        (await InternetAddress.lookup(base.host)).first;
    InternetAddress? any;
    for (final nic in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in nic.addresses) {
        if (a.isLoopback) continue;
        any ??= a;
        final r = router.rawAddress, b = a.rawAddress;
        if (r[0] == b[0] && r[1] == b[1] && r[2] == b[2]) return a;
      }
    }
    return any;
  }

  /// Maps TCP [port] on the public IPv4 to [internalPort] (default: the
  /// same) here. Throws [UpnpException] with the router's reason on refusal.
  Future<void> mapTcpV4(int port,
      {int? internalPort, required String description, int lease = 7200}) async {
    final st = _ipConn.firstWhere(_services.containsKey,
        orElse: () => throw UpnpException('no IPv4 mapping service'));
    final lan = await lanAddress();
    if (lan == null) throw UpnpException('no LAN IPv4 address');
    Future<void> add(int l) => _soap(st, 'AddPortMapping', {
          'NewRemoteHost': '',
          'NewExternalPort': '$port',
          'NewProtocol': 'TCP',
          'NewInternalPort': '${internalPort ?? port}',
          'NewInternalClient': lan.address,
          'NewEnabled': '1',
          'NewPortMappingDescription': description,
          'NewLeaseDuration': '$l',
        });
    try {
      await add(lease);
    } on UpnpException catch (e) {
      if (e.code != 725) rethrow; // OnlyPermanentLeasesSupported
      await add(0);
    }
  }

  /// Opens the IPv6 firewall for TCP [port] to [address]; returns its id.
  Future<String> pinholeTcpV6(InternetAddress address, int port,
      {int lease = 7200}) async {
    if (!canPinholeV6) throw UpnpException('no IPv6 firewall service');
    final r = await _soap(_v6fw, 'AddPinhole', {
      'RemoteHost': '',
      'RemotePort': '0',
      'InternalClient': address.address,
      'InternalPort': '$port',
      'Protocol': '6',
      'LeaseTime': '$lease',
    });
    return _tag(r, 'UniqueID') ?? '';
  }

  Future<String> _soap(String service, String action, Map<String, String> args) async {
    final body = '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        '<u:$action xmlns:u="$service">'
        '${args.entries.map((e) => '<${e.key}>${_esc(e.value)}</${e.key}>').join()}'
        '</u:$action></s:Body></s:Envelope>';
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await http.postUrl(_services[service]!);
      req.headers
        ..set('Content-Type', 'text/xml; charset="utf-8"')
        ..set('SOAPAction', '"$service#$action"');
      final bytes = utf8.encode(body);
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(const Duration(seconds: 8));
      final text = await utf8.decodeStream(res);
      if (res.statusCode != 200) {
        final code = int.tryParse(_tag(text, 'errorCode') ?? '') ?? res.statusCode;
        throw UpnpException(
            '$action: ${_tag(text, 'errorDescription') ?? 'HTTP ${res.statusCode}'}',
            code: code);
      }
      return text;
    } on UpnpException {
      rethrow;
    } catch (e) {
      throw UpnpException('$action: $e');
    } finally {
      http.close(force: true);
    }
  }

  static Future<String> _fetch(Uri u) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final res = await (await http.getUrl(u)).close();
      return await utf8.decodeStream(res);
    } finally {
      http.close(force: true);
    }
  }

  static String? _tag(String xml, String tag) =>
      RegExp('<(?:\\w+:)?$tag>([^<]*)</').firstMatch(xml)?.group(1)?.trim();

  static String _esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

class UpnpException implements Exception {
  UpnpException(this.message, {this.code = 0});
  final String message;
  final int code;
  @override
  String toString() => 'UPnP: $message${code != 0 ? ' ($code)' : ''}';
}
