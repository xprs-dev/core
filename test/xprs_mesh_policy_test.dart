// docs/plan-mesh-trust.md: what a station keeps from afar, and from whom.
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_mesh_policy.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart';

void main() {
  XprsPacket w(String s) => XprsPacket.parse(s)!;
  const self = 'X3HILL';
  XprsMeshVerdict v(String wire, String bearer, XprsMeshPolicy pol, {bool asked = false}) =>
      xprsMeshAdmits(w(wire), bearer: bearer, policy: pol, self: self, askedFor: asked);
  const alert = 't:warning f:X1ALIC kind:fire sev:watch ts:2026-11-06_10:00:00 m:smoke on the ridge';
  const post = 't:blog f:X1ALIC ts:2026-11-06_10:00:00 title:notes m:x';
  const chat = 't:message f:X1ALIC ts:2026-11-06_10:00:00 m:hello';

  test('the defaults: alerts and posts from local and regional bearers, chat from anywhere', () {
    const pol = XprsMeshPolicy();
    expect(v(alert, 'lora', pol), XprsMeshVerdict.keep);
    expect(v(alert, 'wifi', pol), XprsMeshVerdict.keep);
    expect(v(alert, 'rns', pol), XprsMeshVerdict.drop);
    expect(v(post, 'rns', pol), XprsMeshVerdict.drop);
    expect(v(chat, 'rns', pol), XprsMeshVerdict.keep);
  });

  test('the cap is the administrator\'s: local keeps only the building, global keeps all', () {
    expect(v(alert, 'lora', const XprsMeshPolicy(reachAlerts: XprsReach.local)), XprsMeshVerdict.drop);
    expect(v(alert, 'rns', const XprsMeshPolicy(reachAlerts: XprsReach.global)), XprsMeshVerdict.keep);
    expect(v(chat, 'lora', const XprsMeshPolicy(reachChat: XprsReach.local)), XprsMeshVerdict.drop);
  });

  test('never touched: our own words, mail, a room\'s post, a call for help, a record', () {
    const strict = XprsMeshPolicy(reachAlerts: XprsReach.local, reachPosts: XprsReach.local, reachChat: XprsReach.local);
    expect(v('t:warning f:X3HILL ts:2026-11-06_10:00:00 m:ours', 'rns', strict), XprsMeshVerdict.keep);
    expect(v('t:message f:X1ALIC d:X1BOBB ts:2026-11-06_10:00:00 m:mail', 'rns', strict), XprsMeshVerdict.keep);
    expect(v('t:blog f:X1ALIC d:X5F0RM ts:2026-11-06_10:00:00 title:t m:x', 'rns', strict), XprsMeshVerdict.keep);
    expect(v('t:sos f:X1ALIC ts:2026-11-06_10:00:00 m:help', 'rns', strict), XprsMeshVerdict.keep);
    expect(v('t:identity f:X1ALIC ts:2026-11-06_10:00:00 k:npub1x', 'rns', strict), XprsMeshVerdict.keep);
    expect(v('t:moderate f:X3OTHR d:X5F0RM ts:2026-11-06_10:00:00 grant:X1A role:mod', 'rns', strict), XprsMeshVerdict.keep);
  });

  test('a followed author and an answer to our own ask come from anywhere', () {
    const pol = XprsMeshPolicy(followed: {'X1ALIC'});
    expect(v(post, 'rns', pol), XprsMeshVerdict.keep);
    expect(v(post.replaceFirst('X1ALIC', 'X1BOBB'), 'rns', pol), XprsMeshVerdict.drop);
    expect(v(post.replaceFirst('X1ALIC', 'X1BOBB'), 'rns', pol, asked: true), XprsMeshVerdict.keep);
  });

  test('named mode: an alert or a post on the air is kept from a peer, through a peer, or not at all', () {
    const pol = XprsMeshPolicy(named: true, peers: {'X3TOWN'});
    expect(v(alert, 'lora', pol), XprsMeshVerdict.drop, reason: 'a stranger in LoRa range');
    String relayed(String via) => alert.replaceFirst(' m:', ' via:$via m:');
    expect(v(relayed('X3ROGU'), 'lora', pol), XprsMeshVerdict.drop);
    expect(v(relayed('X3ROGU,X3TOWN'), 'lora', pol), XprsMeshVerdict.keep, reason: 'relayed by a peer');
    expect(v(alert.replaceFirst('X1ALIC', 'X3TOWN'), 'lora', pol), XprsMeshVerdict.keep, reason: 'the peer\'s own');
    expect(v(chat, 'lora', pol), XprsMeshVerdict.keep, reason: 'chat is not a record');
    expect(v(alert, 'lora', const XprsMeshPolicy(named: true, peers: {'X3TOWN'}, followed: {'X1ALIC'})), XprsMeshVerdict.keep);
  });

  test('from settings', () {
    final pol = XprsMeshPolicy.fromSettings({
      'reach_alerts': 'global', 'reach_posts': 'local', 'reach_chat': 'nonsense',
      'peers_mode': 'named', 'peers': 'x3town X3HUB',
    }, followed: {'x1alic-7'});
    expect(pol.reachAlerts, XprsReach.global);
    expect(pol.reachPosts, XprsReach.local);
    expect(pol.reachChat, XprsReach.global, reason: 'an unknown word is the default');
    expect(pol.named, true);
    expect(pol.peers, {'X3TOWN', 'X3HUB'});
    expect(pol.followed, {'X1ALIC'});
    expect(xprsCallsignList(' x3a, X3B  x3c '), ['X3A', 'X3B', 'X3C']);
  });
}
