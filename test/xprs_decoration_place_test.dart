// XPRS.md 6.3.2 and 15.1: where a station says it is, `pos:` and `acc:` as a
// decoration field (newest per field, `-` clears), set by its administrator.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_publisher.dart';

final _d = BigInt.parse(
    '3f2a9c1d7e5b4a6c8d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e',
    radix: 16);

List<XprsPacket> _compose({String? url, String? place, String about = ''}) => [
      for (final w in XprsPublisher.composeDecoration(
          call: 'X3PTZM',
          nick: 'XPRS-server',
          fileToken: '',
          about: about,
          ts: '2026-11-14_09:00:00',
          signingKey: _d,
          url: url,
          place: place))
        XprsPacket.parse(w)!,
    ];

void main() {
  test('no place: the field is not stated', () {
    expect(_compose().any((p) => p.has('pos')), isFalse);
  });

  test('a country: its centre with no decimals and its radius, with the name', () {
    final ps = _compose(place: '40,-8 acc:171000');
    final at = ps.where((p) => p.has('pos')).toList();
    expect(at, hasLength(1));
    expect(at.single['pos'], '40,-8');
    expect(at.single['acc'], '171000');
    expect(at.single['nick'], 'XPRS-server');
  });

  test('cleared: pos:- so the removal travels', () {
    expect(_compose(place: '').where((p) => p['pos'] == '-'), hasLength(1));
  });

  test('with a long address and description: split, every packet fits, nothing lost', () {
    const v6 = 'https://2a02-908-2616-da20-2ecf-67ff-fe14-d505.nip.io/';
    final ps = _compose(url: v6, place: '-33.86882,151.20929', about: 'x' * 120);
    expect(ps.where((p) => p['pos'] == '-33.86882,151.20929'), hasLength(1));
    expect(ps.where((p) => p['url'] == v6), hasLength(1));
    for (final p in ps) {
      expect(utf8.encode(p.encode()).length, lessThanOrEqualTo(XprsPacket.maxBytes));
    }
  });
}
