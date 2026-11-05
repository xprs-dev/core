// XPRS.md 6.3.2 `url:`: where a station serves the web chat, carried as a
// decoration field (newest per field, `-` clears), never in the key binding.
import 'dart:convert';

import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_profiles.dart';
import 'package:xprs_core/src/services/xprs/xprs_publisher.dart';

final _d = BigInt.parse(
    '3f2a9c1d7e5b4a6c8d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e',
    radix: 16);

List<XprsPacket> _compose({String? url, String nick = 'XPRS server',
        String about = '', String ts = '2026-11-05_17:00:00'}) =>
    [
      for (final w in XprsPublisher.composeDecoration(
          call: 'X3PTZM',
          nick: nick,
          fileToken: '',
          about: about,
          ts: ts,
          signingKey: _d,
          url: url))
        XprsPacket.parse(w)!,
    ];

void main() {
  const v6 =
      'https://2a02-908-2616-da20-2ecf-67ff-fe14-d505.nip.io/';

  test('no url: the field is not stated (stations without a web chat)', () {
    expect(_compose().any((p) => p.has('url')), isFalse);
  });

  test('a url rides with the name when it fits, every packet fits BLE5', () {
    final ps = _compose(url: 'https://178-202-105-29.nip.io/');
    expect(ps.where((p) => p['url'] == 'https://178-202-105-29.nip.io/'),
        hasLength(1));
    for (final p in ps) {
      expect(utf8.encode(p.encode()).length,
          lessThanOrEqualTo(XprsPublisher.decorationFrameMax));
    }
  });

  test('a long url and a long description: split, nothing lost', () {
    final ps = _compose(
        url: v6, nick: 'a rather long station name', about: 'x' * 120);
    expect(ps.where((p) => p['url'] == v6), hasLength(1));
    expect(ps.where((p) => p.has('m')), hasLength(1));
    expect(ps.where((p) => p.has('nick')), hasLength(1));
    for (final p in ps) {
      expect(p.has('k'), isFalse, reason: 'never in the key binding');
      if (!p.has('m')) {
        expect(utf8.encode(p.encode()).length,
            lessThanOrEqualTo(XprsPublisher.decorationFrameMax));
      }
    }
  });

  test('"" states url:- (the station had one and has none now)', () {
    expect(_compose(url: '').single['url'], '-');
  });

  group('receiving', () {
    final profiles = XprsProfiles.instance;
    setUp(() {
      profiles.keyResolver = (_) => XprsCrypto.publicKeyXOnly(_d);
      profiles.identityRows = (_) => const [];
    });

    test('kept per field, newest wins, - clears, only http(s)', () {
      for (final p in _compose(url: v6, ts: '2026-11-05_17:00:00')) {
        profiles.offer('X3PTZM', p);
      }
      expect(profiles.urlFor('X3PTZM'), v6);
      // An older announcement does not displace it.
      for (final p in _compose(
          url: 'https://old.nip.io/', ts: '2026-11-05_16:00:00')) {
        profiles.offer('X3PTZM', p);
      }
      expect(profiles.urlFor('X3PTZM'), v6);
      // A newer one without url: keeps it (left out = unchanged).
      for (final p in _compose(ts: '2026-11-05_18:00:00')) {
        profiles.offer('X3PTZM', p);
      }
      expect(profiles.urlFor('X3PTZM'), v6);
      // Not a web address: ignored.
      for (final p in _compose(
          url: 'javascript:alert(1)', ts: '2026-11-05_19:00:00')) {
        profiles.offer('X3PTZM', p);
      }
      expect(profiles.urlFor('X3PTZM'), v6);
      // url:- clears.
      for (final p in _compose(url: '', ts: '2026-11-05_20:00:00')) {
        profiles.offer('X3PTZM', p);
      }
      expect(profiles.urlFor('X3PTZM'), isNull);
    });
  });
}
