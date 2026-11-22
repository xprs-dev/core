/*
 * This node as a station others visit (spec/API-HTTP.md): the one visitor
 * API, wired the same way whatever runs it, a server on a mast or a phone in
 * a pocket. Posts go in through the one receive door, reads come from the
 * archive, hosted rooms keep their keys in the group store and their traffic
 * filed and never aired.
 *
 * [stationWebChatApi] is that wiring; a host adds what only it has (where
 * settings are kept, its own network, the download page). [StationHost]
 * holds the API this node answers with, lets its owner use it as any visitor
 * does ([own], no link in between), makes the owner its administrator, and
 * answers it over Reticulum links while [serving].
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart' show NostrCrypto, Tier;

import '../../platform/key_value_store.dart';
import '../../profile/profile_service.dart';
import '../log_service.dart';
import '../mesh/mesh_service.dart';
import '../receive/packet_gateway.dart';
import '../reticulum/rns_service.dart';
import '../web_chat_api.dart';
import '../web_chat_rns.dart';
import '../xprs/xprs_group_index.dart';
import '../xprs/xprs_group_rank_rows.dart';
import '../xprs/xprs_archive.dart';
import '../xprs/xprs_group_keys.dart';
import '../xprs/xprs_groups.dart';
import '../xprs/xprs_history_server.dart';
import '../xprs/xprs_monitor.dart';
import '../xprs/xprs_packet.dart';
import '../xprs/xprs_publisher.dart';
import '../xprs/xprs_sig.dart';
import 'station_api.dart';
import 'station_visits.dart';

/// The key for a callsign: what the core heard, or this node's own. A node
/// never hears its own identity, so without the fallback it could not verify
/// the acts it signs itself (XPRS.md 10.10: appointing a moderator).
Uint8List? stationKeyFor(String call) {
  final heard = XprsArchive.instance.keyResolver?.call(call);
  if (heard != null) return heard;
  final me = MeshService.instance.tableCallsign.trim().toUpperCase().split('-').first;
  if (me.isEmpty || call.trim().toUpperCase().split('-').first != me) return null;
  final npub = ProfileService.instance.activeProfile?.npub ?? '';
  if (!npub.startsWith('npub1')) return null;
  try {
    return Uint8List.fromList(HEX.decode(NostrCrypto.decodeNpub(npub)));
  } catch (_) {
    return null;
  }
}

/// The visitor API of this node, with hosted rooms (galleries, music, files,
/// chat rooms, forums). [store] keeps the administrator and the settings
/// across restarts; [appPath] is the download page when this copy can be
/// handed on.
WebChatApi stationWebChatApi({
  required String? Function() appPath,
  KeyValueStore? store,
  Map<String, bool> hostSwitches = const {},
  bool Function(String peer)? isLocalPeer,
}) =>
    WebChatApi(
      devices: () => XprsMonitor.instance.devicesForApi(),
      publicRows: archivePublicRows,
      held: (t) => XprsArchive.instance.countOf(types: t, undirected: true),
      // A visitor's wire is heard on `lan`, through the API: the bearer is
      // the network it came in on, and that it came through the page is the
      // core's internal flag (XprsIngest.heard `viaApi`), never a wire word.
      receive: (w) => PacketGateway.instance.receive(
          Uint8List.fromList(utf8.encode(w)),
          bearer: 'lan', lane: RxLane.datagram, viaApi: true),
      receiveFrom: (w, {required local}) => PacketGateway.instance.receive(
          Uint8List.fromList(utf8.encode(w)),
          bearer: 'lan', lane: RxLane.datagram, viaApi: true, localLink: local),
      // A visitor who proved their key is at this node's ear (12.8.1), and
      // the node may be their mailbox (12.7, 13.0.2).
      onVisitor: (call, {required local}) =>
          MeshService.instance.visitorHeard(call, local: local),
      holdersOf: XprsArchive.instance.holdersFor,
      offerMailbox: MeshService.instance.offerMailbox,
      mailFor: MeshService.instance.mailFor,
      mayAir: XprsPublisher.instance.mayAir,
      selfCallsign: () => MeshService.instance.tableCallsign,
      keyOf: stationKeyFor,
      appPath: appPath,
      // Files by reference (API-HTTP.md): the mesh's own content store.
      fileStore: () => MeshService.instance.media,
      store: store,
      hostSwitches: hostSwitches,
      isLocalPeer: isLocalPeer,
      // XPRS.md 10.10: the node is the group of its own rooms. Its key signs
      // the administrator's acts, and they go out like any of its packets.
      groups: XprsGroups.instance,
      signAsStation: (canonical) {
        final p = XprsPacket.parse(canonical);
        final d = xprsProfileScalar();
        return p == null || d == null ? null : xprsSign(p, d);
      },
      publish: (w) => unawaited(XprsPublisher.instance.publishWire(w)),
      // Rooms the node hosts (XPRS.md 10.10.1): their keys in the group
      // store, their traffic filed here and never aired, read back by `d:`.
      roomKeys: WebChatRoomKeys(
        create: (nick) {
          final g = XprsGroupKeys.instance.create(nick: nick);
          if (g == null) return null;
          // Teach the callsign->key map the room before anything is signed
          // with it: a node does not hear itself (XprsGroupOps.create).
          try {
            RnsService.instance
                .recordCallsignPubkey(g.callsign, NostrCrypto.decodeNpub(g.npub));
          } catch (_) {}
          return g.callsign;
        },
        scalar: XprsGroupKeys.instance.scalarFor,
      ),
      keep: (w) {
        final p = XprsPacket.parse(w);
        if (p == null) return;
        XprsArchive.instance.admit(p, bearer: 'web', tier: Tier.self);
        // Visible to the next poll, not in twenty seconds.
        XprsArchive.instance.flush();
      },
      roomRows: ({required room, sinceMs, untilMs, required types, required limit}) =>
          XprsArchive.instance.query(
            sinceMs: sinceMs,
            untilMs: untilMs,
            types: types,
            to: [room],
            limit: limit,
          ),
      groupRank: (by) => xprsGroupRankRows(by),
      airVerbatim: (w) =>
          unawaited(XprsPublisher.instance.publishWire(w, verbatim: true, datagram: true)),
    )
      ..ownIdentity = XprsPublisher.instance.ownIdentityWire
      ..groupHolders = XprsGroupRanking.instance.holdersOf
      // A file kept over the station API is advertised, with its piece list
      // when it has one (RnsService.dhtPublish): this station is a holder
      // other stations can find, not only the one a visitor happened to ask.
      ..fileKept = (shaHex) {
        try {
          unawaited(RnsService.instance
              .dhtPublish(Uint8List.fromList(HEX.decode(shaHex))));
        } catch (e) {
          LogService.instance.add('station: advertising a kept file failed: $e');
        }
      };

class StationHost {
  StationHost._();
  static final StationHost instance = StationHost._();

  WebChatApi? _api;
  bool _wired = false;
  StationVisit? _own;

  /// Whether visitors are answered over Reticulum links now. The handlers
  /// stay registered either way: off, a visitor is told at once (nil proof,
  /// 404) rather than left to time out.
  bool serving = false;

  int answered = 0, refused = 0;

  /// The API this node answers with. The host builds it
  /// ([stationWebChatApi]) and hands it here once.
  WebChatApi? get api => _api;
  set api(WebChatApi? a) {
    _api = a;
    _own = null;
    if (a == null) return;
    // A hosted room's history goes only to whom the API says may read it.
    XprsHistoryServer.instance.hostedRoom = a.roomServable;
    XprsHistoryServer.instance.roomPeers = a.roomPeers;
  }

  /// This node's own API as its owner uses it: the calls any visitor makes,
  /// answered here with no link in between, from the node's own network.
  StationVisit? own() {
    final a = _api;
    if (a == null) return null;
    return _own ??= StationVisit(
      selfCall().toUpperCase().split('-').first,
      stationRequestCarrier((data) => webChatLinkAnswer(a, data, 'self')),
      visitor: visitor(),
    );
  }

  /// Test seams.
  String Function() selfCall = () => MeshService.instance.tableCallsign;
  StationVisitor? Function() visitor = () => StationVisits.instance.visitor();

  /// The owner is the administrator: claimed the first time, before anybody
  /// on the node's network could. True when the owner holds it.
  Future<bool> ensureOwner() async {
    final v = own();
    final s = await v?.session();
    if (v == null || s == null) return false;
    final st = await v.call('GET', '/api/admin', {'session': s});
    if (st?.json['you'] == true) return true;
    if (st?.json['claimable'] != true) {
      LogService.instance.add('station: another key administers this node (${st?.json['admin']})');
      return false;
    }
    final r = await v.call('POST', '/api/admin', const {},
        Uint8List.fromList(utf8.encode(jsonEncode({'action': 'claim', 'session': s}))));
    final ok = r != null && r.ok;
    LogService.instance.add(ok ? 'station: its owner administers it' : 'station: the owner could not claim it (${r?.status})');
    return ok;
  }

  /// Answer visitors over Reticulum links, or stop. Needs [api].
  Future<void> serve(bool on) async {
    if (on && _api != null) await ensureOwner();
    serving = on && _api != null;
    if (!_wired && _api != null) {
      _wired = true;
      final rns = RnsService.instance;
      rns.serveRequests(kXprsApiRequestPath, (data, link) async {
        final a = _api;
        if (!serving || a == null) {
          refused++;
          return {'s': 404, 't': 'application/json', 'b': utf8.encode('{"ok":false,"error":"not here"}')};
        }
        answered++;
        return webChatLinkAnswer(a, data, 'rns:${_hex(link.linkId)}');
      });
      rns.serveRequests(kXprsProveRequestPath, (data, link) async {
        final a = _api;
        if (!serving || a == null) return null;
        return webChatLinkProof(a, data, link.linkId);
      });
    }
    LogService.instance.add(serving
        ? 'station: answering visitors over Reticulum'
        : 'station: not answering visitors');
  }

  static String _hex(List<int>? b) =>
      (b ?? const <int>[]).take(8).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
