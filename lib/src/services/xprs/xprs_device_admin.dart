/// A phone, a desktop or a Linux server as a station its owners administer
/// (`docs/XPRS.md` 11.9), the station side an ESP32 has had in its firmware.
///
/// The device's `X3` answered who owns it and obeyed nobody. Now an owner's
/// signed `cmd:set` is acted on, so a phone left at home as a station is run
/// from its owner's own phone, in the room or across the internet:
///
/// - `owner:` names who else may administer it. The profiles on the device
///   are its owners whatever a command says (whoever holds the machine holds
///   it, 11.9 on a cable); the callsigns added on the wire fill what is left
///   of the four.
/// - `serve:` is the archiver's switch: `archive` in the list lets other
///   people choose it for backups, its absence (or `none`) stops that.
/// - `use:` and `first:` are about bridging other people's packets onto a
///   radio, which this kind of station does not do: they are read, changed
///   by nothing, and the result states what is.
///
/// The gate is 11.4 and 11.9, in the firmware's order: never carried
/// (`via:`), the signature verified, an unowned station claimed only on a
/// local bearer, then the replay rule. Past the gate the lane does not
/// matter: an owner's command that arrived over Reticulum is as good as one
/// from the same room, which is what makes remote administration work.
///
/// Pure apart from persistence, which is injected; signing and airing the
/// result are the caller's.
library;

import '../../profile/device_identity.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_station_policy.dart';
import 'xprs_vocab.dart';

class XprsDeviceAdmin {
  XprsDeviceAdmin._();
  static final XprsDeviceAdmin instance = XprsDeviceAdmin._();

  /// Persistence, set at start: read once, written on every change.
  Map<String, dynamic>? Function() load = () => null;
  void Function(Map<String, dynamic>) save = (_) {};

  /// The archiver's switch, read and written through the core's preferences.
  String? Function()? serveClaim;
  void Function(bool public)? setPublicArchiver;

  /// Told when the owners changed (the device's own record of it is redone).
  void Function()? onOwnersChanged;

  /// Told once for each callsign a command ADDED: the station then says who
  /// owns it to that person (its signed `s:policy`), which is how their own
  /// phone learns it has a station to look after without ever standing
  /// next to it (`XprsOwnedStations` believes only the station's own word).
  void Function(String call)? onOwnerAdded;

  String? _ts;
  bool _loaded = false;

  int accepted = 0, refused = 0, asked = 0;

  void _ensure() {
    if (_loaded) return;
    _loaded = true;
    final j = load();
    if (j == null) return;
    _ts = j['ts'] as String?;
    DeviceIdentity.instance.addedOwners = [
      for (final c in (j['owners'] as List? ?? const []))
        c.toString().trim().toUpperCase()
    ];
  }

  /// Read what was kept, so [DeviceIdentity.owners] is whole from the start.
  void restore() => _ensure();

  /// What the station's policy IS.
  XprsStationPolicy policy() {
    _ensure();
    final claim = serveClaim?.call();
    return XprsStationPolicy(
      owners: DeviceIdentity.instance.owners(),
      serve: claim == null
          ? const []
          : claim.split(',').map((w) => w.trim()).toList(),
      ts: _ts,
    );
  }

  /// How the station is doing, as wire keys every station already uses
  /// (15.5, 13.0): `uptime:`, `count:` records held, `size:` room left,
  /// `mail:` held for others. Answered to an owner's `cmd:zdiag`, the ask
  /// the firmware answers with its own diagnostics, so an owner reads a
  /// station that announces nothing publicly, from wherever they are.
  String Function()? status;

  /// Is [cmd] the owner asking how the station is doing?
  static bool isStatusAsk(XprsPacket cmd) =>
      cmd.type == 'command' && cmd['cmd'] == 'zdiag';

  /// Is [cmd] one this class answers: a policy `cmd:set` (11.9), or the
  /// owner's status ask?
  static bool handles(XprsPacket cmd) =>
      xprsIsPolicyCommand(cmd) || isStatusAsk(cmd);

  /// Decide [cmd] and act on it. Returns the unsigned `t:result` to air, or
  /// null when the command is dropped without an answer (carried, forged or
  /// unverifiable: 11.4 answers none of those).
  ///
  /// [verified] is the caller's signature verdict; [bearer] is the lane the
  /// command arrived on.
  String? onCommand(XprsPacket cmd,
      {required bool verified, required String bearer, String? nowTs}) {
    _ensure();
    final dev = DeviceIdentity.instance;
    final from = (cmd['f'] ?? '').trim().toUpperCase();
    if (!dev.ready || from.isEmpty || !handles(cmd)) return null;
    if (xprsVia(cmd).isNotEmpty) return null;
    final before = policy();
    final id = xprsIdentifier(cmd);
    if (isStatusAsk(cmd)) {
      // Reading changes nothing, so there is no replay rule (an owner asks
      // as often as they look) and a refusal is said out loud even to a
      // signer we cannot check: an asker left waiting learns nothing.
      final ok = verified && before.isOwner(from);
      final said = ok ? (status?.call() ?? '') : '';
      if (ok) {
        asked++;
      } else {
        refused++;
      }
      final w = 't:result f:${dev.callsign} d:$from '
          'ts:${nowTs ?? xprsNowTs()} r:$id code:${ok ? 200 : 403}'
          '${said.isEmpty ? '' : ' $said'}';
      final sp = XprsPacket.parse(w);
      return (sp == null || !sp.fits) ? null : w;
    }
    if (!verified) return null;
    // An unowned station (a headless server nobody claimed) is taken by
    // somebody standing next to it, never from across the country.
    if (!before.owned && xprsBearerReach(bearer) != XprsReach.local) {
      return null;
    }
    final code = xprsPolicyCode(cmd, policy: before, verified: true);
    if (code == 200) {
      _apply(cmd, before);
      accepted++;
    } else {
      refused++;
    }
    final wire = 't:result f:${dev.callsign} d:$from '
        'ts:${nowTs ?? xprsNowTs()} r:$id code:$code ${policy().toKeys()}';
    final p = XprsPacket.parse(wire);
    return (p == null || !p.fits) ? null : wire;
  }

  void _apply(XprsPacket cmd, XprsStationPolicy before) {
    final dev = DeviceIdentity.instance;
    if (cmd.has('owner')) {
      final local = dev.localOwners();
      final named = XprsStationPolicy.fromPacket(cmd).owners;
      final room = kXprsOwnersMax - local.length;
      final added = <String>[];
      for (final c in named) {
        if (added.length >= room) break;
        if (c == dev.callsign || local.contains(c) || added.contains(c)) {
          continue;
        }
        added.add(c);
      }
      dev.addedOwners = added;
      onOwnersChanged?.call();
      for (final c in added) {
        if (!before.owners.contains(c)) onOwnerAdded?.call(c);
      }
    }
    if (cmd.has('serve')) {
      final words = XprsStationPolicy.fromPacket(cmd).serve;
      final want = words.contains('archive');
      if (want != before.serve.contains('archive')) {
        setPublicArchiver?.call(want);
      }
    }
    _ts = cmd['ts'];
    save({'owners': dev.addedOwners, 'ts': _ts});
  }

  /// Tests: forget everything.
  void debugReset() {
    _ts = null;
    _loaded = false;
    accepted = 0;
    refused = 0;
    asked = 0;
    DeviceIdentity.instance.addedOwners = const [];
  }
}
