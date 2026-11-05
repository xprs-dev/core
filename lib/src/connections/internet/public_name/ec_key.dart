/*
 * P-256 keys for ACME and TLS, with the few ASN.1 DER shapes they need:
 * JWS ES256 signatures (raw r||s), a JWK and its thumbprint (RFC 7638), a
 * SEC1 "EC PRIVATE KEY" PEM that dart:io's SecurityContext loads, and a
 * PKCS#10 CSR for one or more DNS names.
 *
 * pointycastle only; no OpenSSL on the host is needed.
 */
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

final _domain = ECDomainParameters('secp256r1');

SecureRandom _random() {
  final r = Random.secure();
  return FortunaRandom()
    ..seed(KeyParameter(
        Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)))));
}

String b64url(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Uint8List b64urlDecode(String s) =>
    base64Url.decode(s.padRight((s.length + 3) & ~3, '='));

Uint8List _int32(BigInt v) {
  final out = Uint8List(32);
  var x = v;
  for (var i = 31; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x = x >> 8;
  }
  return out;
}

BigInt _toBig(List<int> b) =>
    b.fold(BigInt.zero, (a, x) => (a << 8) | BigInt.from(x));

class EcKey {
  EcKey._(this.d) : q = _domain.G * d;

  /// A new random key.
  factory EcKey.generate() {
    final g = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_domain), _random()));
    final pair = g.generateKeyPair();
    return EcKey._((pair.privateKey as ECPrivateKey).d!);
  }

  /// From [toJson].
  factory EcKey.fromJson(Map<String, Object?> j) =>
      EcKey._(_toBig(b64urlDecode(j['d'] as String)));

  final BigInt d;
  final ECPoint? q;

  Uint8List get x => _int32(q!.x!.toBigInteger()!);
  Uint8List get y => _int32(q!.y!.toBigInteger()!);

  /// The private key as a JWK (stored by the server, 0600).
  Map<String, String> toJson() => {...jwk, 'd': b64url(_int32(d))};

  /// The public JWK, members in RFC 7638 order.
  Map<String, String> get jwk =>
      {'crv': 'P-256', 'kty': 'EC', 'x': b64url(x), 'y': b64url(y)};

  /// RFC 7638 thumbprint, base64url.
  String get thumbprint =>
      b64url(crypto.sha256.convert(utf8.encode(jsonEncode(jwk))).bytes);

  ECSignature _sign(List<int> msg) {
    final s = ECDSASigner(SHA256Digest())
      ..init(
          true,
          ParametersWithRandom(
              PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(d, _domain)),
              _random()));
    return s.generateSignature(Uint8List.fromList(msg)) as ECSignature;
  }

  /// JWS ES256: r||s, 64 bytes.
  Uint8List signRaw(List<int> msg) {
    final sig = _sign(msg);
    return Uint8List.fromList([..._int32(sig.r), ..._int32(sig.s)]);
  }

  /// X.509 / PKCS#10: SEQUENCE { r, s }.
  Uint8List signDer(List<int> msg) {
    final sig = _sign(msg);
    return der(0x30, [...derInt(sig.r), ...derInt(sig.s)]);
  }

  Uint8List get _publicPoint => Uint8List.fromList([0x04, ...x, ...y]);

  /// SubjectPublicKeyInfo.
  Uint8List get spki => der(0x30, [
        ...der(0x30, [...derOid(_oidEcPublicKey), ...derOid(_oidP256)]),
        ...derBitString(_publicPoint),
      ]);

  /// SEC1 private key PEM ("EC PRIVATE KEY"), what SecurityContext reads.
  String toSec1Pem() {
    final body = der(0x30, [
      ...derInt(BigInt.one),
      ...der(0x04, _int32(d)),
      ...der(0xa0, derOid(_oidP256)),
      ...der(0xa1, derBitString(_publicPoint)),
    ]);
    return pem('EC PRIVATE KEY', body);
  }

  /// A PKCS#10 request for [names] (subjectAltName dNSName; CN = first).
  Uint8List csr(List<String> names) {
    final san = der(0x30, [
      for (final n in names) ...der(0x82, utf8.encode(n)),
    ]);
    final extReq = der(0x30, [
      ...derOid(_oidExtensionRequest),
      ...der(0x31, der(0x30, der(0x30, [
        ...derOid(_oidSubjectAltName),
        ...der(0x04, san),
      ]))),
    ]);
    final subject = der(0x30, der(0x31, der(0x30, [
      ...derOid(_oidCommonName),
      ...der(0x0c, utf8.encode(names.first)),
    ])));
    final info = der(0x30, [
      ...derInt(BigInt.zero),
      ...subject,
      ...spki,
      ...der(0xa0, extReq),
    ]);
    return der(0x30, [
      ...info,
      ...der(0x30, derOid(_oidEcdsaSha256)),
      ...derBitString(signDer(info)),
    ]);
  }
}

const _oidEcPublicKey = '1.2.840.10045.2.1';
const _oidP256 = '1.2.840.10045.3.1.7';
const _oidEcdsaSha256 = '1.2.840.10045.4.3.2';
const _oidExtensionRequest = '1.2.840.113549.1.9.14';
const _oidSubjectAltName = '2.5.29.17';
const _oidCommonName = '2.5.4.3';

// ---- minimal DER writer ----

Uint8List der(int tag, List<int> body) {
  final n = body.length;
  final len = n < 0x80
      ? [n]
      : () {
          final b = <int>[];
          for (var v = n; v > 0; v >>= 8) {
            b.insert(0, v & 0xff);
          }
          return [0x80 | b.length, ...b];
        }();
  return Uint8List.fromList([tag, ...len, ...body]);
}

Uint8List derInt(BigInt v) {
  final b = <int>[];
  var x = v;
  do {
    b.insert(0, (x & BigInt.from(0xff)).toInt());
    x = x >> 8;
  } while (x > BigInt.zero);
  if (b.first & 0x80 != 0) b.insert(0, 0);
  return der(0x02, b);
}

Uint8List derBitString(List<int> b) => der(0x03, [0, ...b]);

Uint8List derOid(String oid) {
  final p = oid.split('.').map(int.parse).toList();
  final out = <int>[p[0] * 40 + p[1]];
  for (final v in p.skip(2)) {
    final chunk = <int>[v & 0x7f];
    for (var x = v >> 7; x > 0; x >>= 7) {
      chunk.insert(0, 0x80 | (x & 0x7f));
    }
    out.addAll(chunk);
  }
  return der(0x06, out);
}

String pem(String label, List<int> body) {
  final b = base64.encode(body);
  final lines = [
    for (var i = 0; i < b.length; i += 64)
      b.substring(i, min(i + 64, b.length)),
  ];
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}
