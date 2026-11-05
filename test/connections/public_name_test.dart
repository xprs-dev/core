import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/connections/internet/public_name/acme_io.dart';
import 'package:xprs_core/src/connections/internet/public_name/ec_key.dart';
import 'package:xprs_core/src/connections/internet/public_name/public_address_io.dart';

Future<String> _openssl(List<String> args, {String? input}) async {
  final p = await Process.start('openssl', args);
  if (input != null) p.stdin.write(input);
  await p.stdin.close();
  final out = await utf8.decodeStream(p.stdout);
  final err = await utf8.decodeStream(p.stderr);
  if (await p.exitCode != 0) throw StateError('openssl $args: $err');
  return out + err;
}

// Run on dev machines and CI with openssl on PATH; the checks that need it
// are skipped elsewhere.
final _hasOpenssl = () {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}();

void main() {
  group('nip.io names', () {
    test('IPv4 with dashes', () {
      expect(nipName(InternetAddress('178.202.105.29')),
          '178-202-105-29.nip.io');
    });
    test('IPv6 with dashes, :: as --', () {
      expect(nipName(InternetAddress('2a02:908:2616:da20:2ecf:67ff:fe14:d505')),
          '2a02-908-2616-da20-2ecf-67ff-fe14-d505.nip.io');
      expect(nipName(InternetAddress('2a01:4f8:c17:b8f::2')),
          '2a01-4f8-c17-b8f--2.nip.io');
      expect(nipName(InternetAddress('::1')), '0--1.nip.io');
    });
  });

  test('public, private and stable addresses', () {
    expect(isPublic(InternetAddress('178.202.105.29')), isTrue);
    for (final a in ['192.168.178.1', '10.1.2.3', '100.64.0.1', '172.20.0.1']) {
      expect(isPublic(InternetAddress(a)), isFalse, reason: a);
    }
    expect(isPublic(InternetAddress('2a02:908::1')), isTrue);
    expect(isPublic(InternetAddress('fd88:41d1:1224::1')), isFalse);
    expect(isEui64(InternetAddress('2a02:908:2616:da20:2ecf:67ff:fe14:d505')),
        isTrue);
  });

  group('EcKey', skip: _hasOpenssl ? false : 'needs openssl', () {
    final key = EcKey.generate();

    test('round-trips through JSON', () {
      final back = EcKey.fromJson(key.toJson());
      expect(back.jwk, key.jwk);
      expect(key.signRaw(utf8.encode('x')), hasLength(64));
    });

    test('SEC1 PEM loads in dart:io and openssl', () async {
      SecurityContext().usePrivateKeyBytes(utf8.encode(key.toSec1Pem()));
      final out = await _openssl(['ec', '-noout', '-check'],
          input: key.toSec1Pem());
      expect(out, contains('valid'));
    });

    test('CSR verifies and names the SANs', () async {
      final csr = pem('CERTIFICATE REQUEST',
          key.csr(['a-1.nip.io', 'b--2.nip.io']));
      final out = await _openssl(['req', '-verify', '-noout', '-text'],
          input: csr);
      expect(out, contains('verify OK'));
      expect(out, contains('DNS:a-1.nip.io'));
      expect(out, contains('DNS:b--2.nip.io'));
    });

    test('a self-signed cert from our key serves TLS and its expiry reads',
        () async {
      final dir = await Directory.systemTemp.createTemp('xprs_tls');
      try {
        final keyFile = File('${dir.path}/k.pem')
          ..writeAsStringSync(key.toSec1Pem());
        final certPem = await _openssl([
          'req', '-x509', '-key', keyFile.path, '-subj', '/CN=t',
          '-days', '10', '-outform', 'PEM',
        ]);
        final exp = certificateExpiry(certPem)!;
        final want = DateTime.now().toUtc().add(const Duration(days: 10));
        expect(exp.difference(want).inMinutes.abs(), lessThan(5));
        SecurityContext()
          ..useCertificateChainBytes(utf8.encode(certPem))
          ..usePrivateKeyBytes(utf8.encode(key.toSec1Pem()));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
