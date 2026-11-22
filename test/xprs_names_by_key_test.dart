// Search takes a person's key: an npub IS the person, their callsign is
// arithmetic on it, so somebody can be written to whom no station here has
// ever heard. Found on a phone, 2026-11-22: an npub typed into New chat
// found nobody and offered nothing.
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_names.dart';

void main() {
  const npub = 'npub1py6rgw9ldpd97a8xmua456nj2ehnfxfdxg3xfq8d555pzfkuuvmserx254';
  final learned = <String, String>{};

  setUp(() {
    learned.clear();
    XprsNames.learnKey = (call, hex) => learned[call] = hex;
  });
  tearDown(XprsNames.debugReset);

  test('an npub is one person, and their key is remembered for the callsign', () {
    final hex = NostrCrypto.decodeNpub(npub);
    final call = 'X1${NostrCrypto.deriveCallsign(hex)}';
    final rows = XprsNames.find(query: '  ${npub.toUpperCase()} ', self: 'X1ME');
    expect(rows, hasLength(1));
    expect(rows.single['call'], call);
    expect(rows.single['kind'], 'user');
    expect(learned, {call: hex});
  });

  test('asked for people only it is still found; for groups or stations it is not', () {
    expect(XprsNames.find(query: npub, kind: 'user'), hasLength(1));
    expect(XprsNames.find(query: npub, kind: 'group'), isEmpty);
    expect(XprsNames.find(query: npub, kind: 'station'), isEmpty);
  });

  test('something that only looks like a key is an ordinary search', () {
    expect(XprsNames.find(query: 'npub1notakey'), isEmpty);
    expect(XprsNames.find(query: '${npub.substring(0, 62)}x'), isEmpty);
    expect(learned, isEmpty);
  });

  test('one\'s own key finds nobody to write to', () {
    final hex = NostrCrypto.decodeNpub(npub);
    final me = 'X1${NostrCrypto.deriveCallsign(hex)}';
    expect(XprsNames.find(query: npub, self: me), isEmpty);
  });
}
