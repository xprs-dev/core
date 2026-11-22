// The archivers' directory says who holds each issued callsign, as the
// archiver heard it (XPRS.md 6.4.2, 12.9): a line an older reader skips.
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_directory.dart';

void main() {
  const npub = 'npub1qz3n7fu9j9uenmyva7ha6x9eqwymytv2847ccv4vxdmn45y50q7h7k5f';
  final since = DateTime.utc(2026, 3, 1, 9, 30).millisecondsSinceEpoch;
  final last = DateTime.utc(2026, 11, 21, 17, 45, 12).millisecondsSinceEpoch;
  final t0 = DateTime.utc(2026, 11, 22, 10).millisecondsSinceEpoch;

  test('holder lines are written and read back', () {
    final text = XprsDirectory.compose(
        [XprsDirectoryEntry('X1BOA3', t0)],
        holders: [XprsHolderLine('CT1ABC', npub, since, last)]);
    expect(text, contains('XKEY1 CT1ABC $npub 2026-03-01_09:30:00 '));
    final h = XprsDirectory.holdersIn(text).single;
    expect(h.call, 'CT1ABC');
    expect(h.npub, npub);
    expect(h.sinceMs, since);
    expect(h.lastMs, DateTime.utc(2026, 11, 21).millisecondsSinceEpoch,
        reason: 'the last hearing is written to the day');
  });

  test('a holder speaking again the same day does not change the listing',
      () {
    String at(int lastMs) => XprsDirectory.compose(
        [XprsDirectoryEntry('X1BOA3', t0)],
        holders: [XprsHolderLine('CT1ABC', npub, since, lastMs)]);
    expect(XprsDirectory.shaOf(at(last)),
        XprsDirectory.shaOf(at(last + 3 * 60 * 60 * 1000)),
        reason: 'an unchanged directory has an unchanged hash (12.9)');
  });

  test('a reader that knows nothing of holders still reads the callsigns', () {
    final text = XprsDirectory.compose(
        [XprsDirectoryEntry('X1BOA3', t0), XprsDirectoryEntry('X1AAAA', t0)],
        holders: [XprsHolderLine('CT1ABC', npub, since, last)]);
    final calls = [for (final e in XprsDirectory.parse(text)!) e.call];
    expect(calls, ['X1AAAA', 'X1BOA3'],
        reason: 'the holder line is skipped, not read as a callsign');
  });

  test('a line that is not a holder line is not taken for one', () {
    const text = 'XDIR1\n'
        'XKEY1 CT1ABC not-a-key 2026-03-01_09:30:00 2026-11-21_00:00:00\n'
        'XKEY1 CT1ABC $npub yesterday today\n'
        'XKEY1 CT1ABC $npub 2026-03-01_09:30:00\n'
        'X1BOA3 2026-11-22_10:00:00\n';
    expect(XprsDirectory.holdersIn(text), isEmpty);
  });

  test('no holders: the listing is what it was before', () {
    final a = XprsDirectory.compose([XprsDirectoryEntry('X1BOA3', t0)]);
    expect(a, 'XDIR1\nX1BOA3 2026-11-22_10:00:00\n');
  });
}
