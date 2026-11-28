// A phone, a desktop or a server as a station its owners administer
// (XPRS.md 11.9, XprsDeviceAdmin): who may change it, from where, and what
// an accepted command changes.
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/profile/device_identity.dart';
import 'package:xprs_core/src/services/xprs/xprs_device_admin.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';

void main() {
  final keys = NostrKeyGenerator.generateKeyPair();
  final admin = XprsDeviceAdmin.instance;
  late String dev;
  Map<String, dynamic>? kept;
  bool? public;
  var serving = false;

  XprsPacket cmd(String from, String keysText, {String ts = '2026-11-28_10:00:00'}) =>
      XprsPacket.parse('t:command f:$from d:$dev ts:$ts cmd:set $keysText')!;

  setUp(() {
    DeviceIdentity.instance
      ..resetForTest()
      ..adoptForTest(keys.nsec);
    dev = DeviceIdentity.instance.callsign;
    kept = null;
    public = null;
    serving = false;
    admin
      ..debugReset()
      ..load = (() => kept)
      ..save = ((j) => kept = j)
      ..serveClaim = (() => serving ? 'archive' : null)
      ..setPublicArchiver = ((on) {
        public = on;
        serving = on;
      });
  });
  tearDown(() {
    admin.debugReset();
    DeviceIdentity.instance.resetForTest();
  });

  test('an unowned station is claimed in the room, never from afar', () {
    expect(admin.policy().owned, isFalse);
    expect(
        admin.onCommand(cmd('X1OWNR', 'owner:X1OWNR'),
            verified: true, bearer: 'rns'),
        isNull);
    expect(admin.policy().owned, isFalse);
    final r = admin.onCommand(cmd('X1OWNR', 'owner:X1OWNR'),
        verified: true, bearer: 'lan')!;
    final p = XprsPacket.parse(r)!;
    expect(p.type, 'result');
    expect(p['f'], dev);
    expect(p['d'], 'X1OWNR');
    expect(p['code'], '200');
    expect(p['owner'], 'X1OWNR');
    expect(kept!['owners'], ['X1OWNR']);
  });

  test('an owner administers it over Reticulum as in the room', () {
    admin.onCommand(cmd('X1OWNR', 'owner:X1OWNR'),
        verified: true, bearer: 'ble5');
    // From the other side of the internet: add a second administrator.
    final r = XprsPacket.parse(admin.onCommand(
        cmd('X1OWNR', 'owner:X1OWNR,X1HOME', ts: '2026-11-28_10:05:00'),
        verified: true,
        bearer: 'rns')!)!;
    expect(r['code'], '200');
    expect(r['owner'], 'X1OWNR,X1HOME');
    // And the one just added may act too.
    final r2 = XprsPacket.parse(admin.onCommand(
        cmd('X1HOME', 'serve:archive', ts: '2026-11-28_10:06:00'),
        verified: true,
        bearer: 'rns')!)!;
    expect(r2['code'], '200');
    expect(public, isTrue);
    expect(r2['serve'], 'archive');
    final r3 = XprsPacket.parse(admin.onCommand(
        cmd('X1HOME', 'serve:none', ts: '2026-11-28_10:07:00'),
        verified: true,
        bearer: 'rns')!)!;
    expect(public, isFalse);
    expect(r3['serve'], 'none');
  });

  test('a stranger is refused out loud and changes nothing', () {
    admin.onCommand(cmd('X1OWNR', 'owner:X1OWNR'),
        verified: true, bearer: 'lan');
    final r = XprsPacket.parse(admin.onCommand(
        cmd('X1EVIL', 'owner:X1EVIL', ts: '2026-11-28_11:00:00'),
        verified: true,
        bearer: 'lan')!)!;
    expect(r['code'], '403');
    expect(r['owner'], 'X1OWNR');
    final r2 = XprsPacket.parse(admin.onCommand(
        cmd('X1EVIL', 'serve:archive', ts: '2026-11-28_11:00:01'),
        verified: true,
        bearer: 'lan')!)!;
    expect(r2['code'], '403');
    expect(public, isNull);
    expect(admin.refused, 2);
  });

  test('carried, unsigned and replayed commands do nothing', () {
    admin.onCommand(cmd('X1OWNR', 'owner:X1OWNR'),
        verified: true, bearer: 'lan');
    // Not verified: no answer at all (11.4).
    expect(
        admin.onCommand(cmd('X1OWNR', 'owner:X1EVIL', ts: '2026-11-28_12:00:00'),
            verified: false, bearer: 'lan'),
        isNull);
    // Carried by somebody: dropped.
    expect(
        admin.onCommand(
            XprsPacket.parse('t:command f:X1OWNR d:$dev '
                'ts:2026-11-28_12:00:01 cmd:set owner:X1EVIL via:X3RLY7')!,
            verified: true,
            bearer: 'lan'),
        isNull);
    // An old recording of the owner's own command: 408, whatever the clock.
    final r = XprsPacket.parse(admin.onCommand(
        cmd('X1OWNR', 'owner:X1SOLD', ts: '2026-11-28_09:00:00'),
        verified: true,
        bearer: 'lan')!)!;
    expect(r['code'], '408');
    expect(admin.policy().owners, ['X1OWNR']);
  });

  test('who was added survives a restart', () {
    admin.onCommand(cmd('X1OWNR', 'owner:X1OWNR,X1HOME'),
        verified: true, bearer: 'lan');
    admin.debugReset();
    expect(DeviceIdentity.instance.owners(), isEmpty);
    admin.restore();
    expect(DeviceIdentity.instance.owners(), ['X1OWNR', 'X1HOME']);
    // And the replay rule kept its stamp.
    final r = XprsPacket.parse(admin.onCommand(
        cmd('X1OWNR', 'owner:X1OWNR', ts: '2026-11-28_10:00:00'),
        verified: true,
        bearer: 'lan')!)!;
    expect(r['code'], '408');
  });

  test('an owner reads how it is doing; nobody else does', () {
    admin.status = () => 'uptime:26h count:1200 size:3GB mail:4';
    admin.onCommand(cmd('X1OWNR', 'owner:X1OWNR'),
        verified: true, bearer: 'lan');
    XprsPacket ask(String from) => XprsPacket.parse(
        't:command f:$from d:$dev ts:2026-11-28_13:00:00 cmd:zdiag')!;
    final r = XprsPacket.parse(
        admin.onCommand(ask('X1OWNR'), verified: true, bearer: 'rns')!)!;
    expect(r['code'], '200');
    expect(r['count'], '1200');
    expect(r['size'], '3GB');
    expect(r['mail'], '4');
    expect(r['uptime'], '26h');
    // Asked again with the same stamp: reading has no replay rule.
    expect(
        XprsPacket.parse(admin.onCommand(ask('X1OWNR'),
            verified: true, bearer: 'rns')!)!['code'],
        '200');
    final no = XprsPacket.parse(
        admin.onCommand(ask('X1EVIL'), verified: true, bearer: 'lan')!)!;
    expect(no['code'], '403');
    expect(no.has('count'), isFalse);
    // A signer we cannot check is told no as well, not left waiting.
    final unknown = XprsPacket.parse(
        admin.onCommand(ask('X1OWNR'), verified: false, bearer: 'lan')!)!;
    expect(unknown['code'], '403');
    admin.status = null;
  });

  test('a command that is not a policy one is not ours', () {
    final other = XprsPacket.parse(
        't:command f:X1OWNR d:$dev ts:2026-11-28_10:00:00 cmd:history')!;
    expect(XprsDeviceAdmin.handles(other), isFalse);
    expect(admin.onCommand(other, verified: true, bearer: 'lan'), isNull);
  });
}
