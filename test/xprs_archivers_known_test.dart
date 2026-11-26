// The archivers a station knows of (XPRS.md 13.0.5): what each offers on
// t:service and what keeps it going on its observation, read together and
// put in the order a station chooses in.
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive_policy.dart';
import 'package:xprs_core/src/services/xprs/xprs_archivers_known.dart';
import 'package:xprs_core/src/services/xprs/xprs_conditions.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart';

void main() {
  const ts = '2026-11-26_09:00:00';
  final at = xprsParseTs(ts)!;

  XprsPacket svc(String f, {String extra = ''}) => XprsPacket.parse(
      't:service f:$f serve:archive,files count:48211 $extra ts:$ts')!;
  XprsPacket obs(String f, String extra) => XprsPacket.parse(
      't:observation f:$f link:lan serve:archive $extra ts:$ts')!;

  test('size: and bw: are stepped down, and read back', () {
    expect(xprsStepBytes(0), '0B');
    expect(xprsStepBytes(999), '500B');
    expect(xprsStepBytes(1999999999), '1GB');
    expect(xprsStepBytes(53000000000), '50GB');
    expect(xprsStepBytes(2600000000000), '2TB');
    expect(xprsStepRate(0), isNull);
    expect(xprsStepRate(2400000), '2MB/s');
    expect(xprsParseBytes('50GB'), 50000000000);
    expect(xprsParseBytes('2MB/s'), 2000000);
    expect(xprsParseBytes('125kHz'), isNull, reason: 'a radio channel');
  });

  test('the offer and the conditions are read together, matched on f:', () {
    final k = XprsKnownArchiver.from(
        svc('X3ARC1', extra: 'room:yes size:50GB'),
        obs('X3ARC1',
            'source:solar backup:battery uplink:satellite plan:unlimited '
            'uptime:4day bw:2MB/s'),
        nowMs: at)!;
    expect(k.callsign, 'X3ARC1');
    expect(k.count, 48211);
    expect(k.room, isTrue);
    expect(k.sizeBytes, 50000000000);
    expect(k.source, 'solar');
    expect(k.uplink, 'satellite');
    expect(k.uptime, '4day');
    expect(k.bwBytesPerS, 2000000);
    expect(k.survivesOutage, isTrue);
    expect(k.stale, isFalse);

    // Another station's observation is not this archiver's.
    final other = XprsKnownArchiver.from(
        svc('X3ARC1'), obs('X3ARC2', 'source:solar'),
        nowMs: at)!;
    expect(other.source, isNull);
    // A service that does not archive is not an archiver.
    expect(
        XprsKnownArchiver.from(
            XprsPacket.parse('t:service f:X3RLY1 serve:relay ts:$ts')!, null,
            nowMs: at),
        isNull);
  });

  test('stale after three hours without an announcement', () {
    final k = XprsKnownArchiver.from(svc('X3ARC1'), null,
        nowMs: at + 3 * 3600000 + 1)!;
    expect(k.stale, isTrue);
  });

  test('the order: fresh, room, outage, uplink, plan, space, speed', () {
    XprsKnownArchiver k(String f, String o, {String s = '', int ago = 0}) =>
        XprsKnownArchiver.from(svc(f, extra: s), obs(f, o), nowMs: at + ago)!;
    final list = [
      k('X3STALE', 'source:solar uplink:satellite', ago: 4 * 3600000),
      k('X3FULL', 'source:solar uplink:satellite', s: 'room:no'),
      k('X3CELL', 'source:grid backup:ups uplink:cellular plan:unlimited'),
      k('X3GRID', 'source:grid backup:none uplink:satellite plan:unlimited'),
      k('X3SAT', 'source:grid backup:ups uplink:satellite plan:limited'),
      k('X3SATU', 'source:grid backup:ups uplink:satellite plan:unlimited',
          s: 'size:5GB'),
      k('X3BIG', 'source:grid backup:ups uplink:satellite plan:unlimited',
          s: 'size:50GB'),
    ]..sort(xprsCompareArchivers);
    expect(list.map((e) => e.callsign), [
      'X3BIG', 'X3SATU', 'X3SAT', 'X3CELL', 'X3GRID', 'X3FULL', 'X3STALE',
    ]);
  });

  test('an archiver\'s own observation is cached; anybody else\'s is not', () {
    expect(xprsIsArchiverObservation(obs('X3ARC1', 'source:solar')), isTrue);
    expect(
        xprsIsArchiverObservation(XprsPacket.parse(
            't:observation f:X3RLY1 link:lan serve:relay ts:$ts')!),
        isFalse);
    expect(
        xprsIsArchiverObservation(XprsPacket.parse(
            't:observation f:X3ARC1 d:X1ME serve:archive ts:$ts')!),
        isFalse,
        reason: 'one addressed to somebody is an answer, not an announcement');
    expect(kXprsCoreFollowedKinds, contains('service'));
  });
}

