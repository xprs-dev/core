/*
 * The server's public addresses and the nip.io names made from them.
 *
 * IPv4: the address the internet sees (behind NAT it is the router's), asked
 * of nip.io's own name servers: a TXT query for ip.nip.io returns the
 * querier's address (https://nip.io/experimental.html). One UDP exchange, no
 * HTTP, and the same service that serves the name.
 *
 * IPv6: an address of this machine (no NAT). A stable one is preferred, so
 * the name does not die with a temporary privacy address: an EUI-64 one
 * (ff:fe in the middle of the interface id), else the address the internet
 * sees, as for IPv4.
 */
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// nip.io's name servers (https://nip.io/, 2026-06): one IPv4 and one IPv6
/// address each.
const nipNameServersV4 = ['5.78.28.211', '167.172.4.236', '51.75.53.19'];
const nipNameServersV6 = [
  '2a01:4ff:1f2:10d::',
  '2400:6180:0:d2:0:2:e3e7:0',
  '2001:41d0:602:2313::1',
];

/// The name nip.io resolves to [ip]: dashes for both families
/// (178-202-105-29.nip.io, 2a02-908-...-d505.nip.io; `::` becomes `--`).
String nipName(InternetAddress ip, {String zone = 'nip.io'}) {
  if (ip.type == InternetAddressType.IPv4) {
    return '${ip.address.replaceAll('.', '-')}.$zone';
  }
  var s = _compressV6(ip.rawAddress);
  if (s.startsWith(':')) s = '0$s';
  if (s.endsWith(':')) s = '${s}0';
  return '${s.replaceAll(':', '-')}.$zone';
}

/// RFC 5952 text, lower case (InternetAddress.address is already, but this
/// keeps the name independent of the platform's formatting).
String _compressV6(Uint8List raw) {
  final g = [for (var i = 0; i < 16; i += 2) (raw[i] << 8) | raw[i + 1]];
  var bestAt = -1, bestLen = 0;
  for (var i = 0; i < 8;) {
    if (g[i] != 0) {
      i++;
      continue;
    }
    var j = i;
    while (j < 8 && g[j] == 0) {
      j++;
    }
    if (j - i > bestLen && j - i > 1) {
      bestAt = i;
      bestLen = j - i;
    }
    i = j;
  }
  String hex(Iterable<int> xs) => xs.map((x) => x.toRadixString(16)).join(':');
  if (bestAt < 0) return hex(g);
  return '${hex(g.take(bestAt))}::${hex(g.skip(bestAt + bestLen))}';
}

/// Whether [ip] is a public unicast address worth putting in a name.
bool isPublic(InternetAddress ip) {
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    if (b[0] == 10 || b[0] == 127 || b[0] == 0 || b[0] >= 224) return false;
    if (b[0] == 172 && b[1] >= 16 && b[1] < 32) return false;
    if (b[0] == 192 && b[1] == 168) return false;
    if (b[0] == 169 && b[1] == 254) return false;
    if (b[0] == 100 && b[1] >= 64 && b[1] < 128) return false; // CGNAT
    return true;
  }
  return (b[0] & 0xe0) == 0x20; // 2000::/3 global unicast
}

/// An EUI-64 interface id (ff:fe in bytes 11-12): stable across reboots.
bool isEui64(InternetAddress ip) =>
    ip.type == InternetAddressType.IPv6 &&
    ip.rawAddress[11] == 0xff &&
    ip.rawAddress[12] == 0xfe;

/// The address [server] sees our query come from (TXT ip.nip.io), or null.
Future<InternetAddress?> askPublicAddress(String server,
    {Duration timeout = const Duration(seconds: 4)}) async {
  final to = InternetAddress(server);
  RawDatagramSocket? s;
  try {
    s = await RawDatagramSocket.bind(
        to.type == InternetAddressType.IPv4
            ? InternetAddress.anyIPv4
            : InternetAddress.anyIPv6,
        0);
    final id = Random.secure().nextInt(0xffff);
    final q = BytesBuilder()
      ..add([id >> 8, id & 0xff, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
    for (final label in ['ip', 'nip', 'io']) {
      q
        ..addByte(label.length)
        ..add(label.codeUnits);
    }
    q.add([0, 0, 16, 0, 1]); // QTYPE TXT, QCLASS IN
    s.send(q.toBytes(), to, 53);
    final got = Completer<InternetAddress?>();
    s.listen((ev) {
      if (ev != RawSocketEvent.read || got.isCompleted) return;
      final d = s!.receive();
      if (d == null || d.data.length < 12) return;
      if (((d.data[0] << 8) | d.data[1]) != id) return;
      got.complete(_firstTxtAddress(d.data));
    });
    return await got.future.timeout(timeout, onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    s?.close();
  }
}

/// The first TXT string in a DNS reply that parses as an address.
InternetAddress? _firstTxtAddress(Uint8List m) {
  int skipName(int p) {
    while (p < m.length) {
      final l = m[p];
      if (l == 0) return p + 1;
      if (l & 0xc0 == 0xc0) return p + 2;
      p += 1 + l;
    }
    return p;
  }

  final qd = (m[4] << 8) | m[5];
  final an = (m[6] << 8) | m[7];
  var p = 12;
  for (var i = 0; i < qd; i++) {
    p = skipName(p) + 4;
  }
  for (var i = 0; i < an && p < m.length; i++) {
    p = skipName(p);
    final type = (m[p] << 8) | m[p + 1];
    final rdlen = (m[p + 8] << 8) | m[p + 9];
    final rd = p + 10;
    if (type == 16 && rdlen > 1) {
      final n = m[rd];
      final s = String.fromCharCodes(m.sublist(rd + 1, rd + 1 + n));
      final ip = InternetAddress.tryParse(s);
      if (ip != null) return ip;
    }
    p = rd + rdlen;
  }
  return null;
}

/// What the internet sees of this machine, and the IPv6 addresses it owns.
class PublicAddresses {
  PublicAddresses({this.v4, this.v6});
  final InternetAddress? v4;
  final InternetAddress? v6;

  bool get isEmpty => v4 == null && v6 == null;

  @override
  bool operator ==(Object other) =>
      other is PublicAddresses && other.v4?.address == v4?.address &&
      other.v6?.address == v6?.address;

  @override
  int get hashCode => Object.hash(v4?.address, v6?.address);

  @override
  String toString() =>
      '${v4?.address ?? 'no IPv4'}, ${v6?.address ?? 'no IPv6'}';
}

Future<InternetAddress?> _askAny(List<String> servers) async {
  for (final s in servers) {
    final ip = await askPublicAddress(s);
    if (ip != null) return ip;
  }
  return null;
}

/// Looks the public addresses up now.
Future<PublicAddresses> discoverPublicAddresses() async {
  final v4 = await _askAny(nipNameServersV4);
  InternetAddress? v6;
  final own = <InternetAddress>[];
  try {
    for (final nic in await NetworkInterface.list(
        type: InternetAddressType.IPv6)) {
      own.addAll(nic.addresses.where(isPublic));
    }
  } catch (_) {}
  if (own.isNotEmpty) {
    v6 = own.firstWhere(isEui64, orElse: () => own.first);
    // Without an EUI-64 address, use what the internet sees if it is ours
    // (it is the one outgoing connections use).
    if (!isEui64(v6)) {
      final seen = await _askAny(nipNameServersV6);
      if (seen != null && own.any((a) => a.address == seen.address)) {
        v6 = seen;
      }
    }
  }
  return PublicAddresses(
    v4: v4 != null && isPublic(v4) ? v4 : null,
    v6: v6,
  );
}
