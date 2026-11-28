/*
 * DeviceIdentity -- the device's own X3, beside the people who use it.
 *
 * XPRS.md 3: `X1` is a person, `X3` a fixed station, relay or unattended
 * equipment. The ESP32 firmware has always been the second kind: it holds
 * its own key, wears `X3...`, and is OWNED by a person's `X1` (11.9). A
 * phone or a desktop running this app used to be only the first kind: the
 * user's `X1` did the station's work as well, so what the device offers to
 * others (its place, its archive, its files) was announced as facts about a
 * person.
 *
 * Now every install holds one device key, made on first start and kept for
 * the life of the install, shared by every profile on it:
 *
 *   - the callsign is derived from the key with the station prefix (`X3`),
 *     exactly as an X1 is, so it is self-certifying (XPRS.md 3);
 *   - its owners are the X1s of the profiles on this device, active first,
 *     at most four (11.9's `owner:` path);
 *   - it signs the device's own station packets: its observation (place,
 *     what it serves, who it hears -- its owner first), its key binding, its
 *     `t:service` announcement and its `s:policy` answer.
 *
 * The person's X1 keeps everything personal: identity, chat, LXMF address,
 * posts, mail. docs/architecture.md "The device and its people" has the split.
 *
 * Where the key lives: the public half in `station/device.json` under the
 * storage root (not under any profile, which is per person); the private half
 * in the OS keychain where the host has one (CoreHost.secureStore), else in
 * that file, protected by the data directory's permissions like the server's
 * own station key. A server whose active profile is already an X3 IS the
 * device: no second key is made.
 */
import 'dart:convert';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart' as reticulum;
import 'package:reticulum/reticulum.dart' show NostrCrypto, NostrKeyGenerator;

import '../platform/core_host.dart';
import '../services/log_service.dart';
import 'profile_service.dart';
import 'storage_paths.dart';

class DeviceIdentity {
  DeviceIdentity._();
  static final DeviceIdentity instance = DeviceIdentity._();

  static const String _file = 'station/device.json';
  static const String _secureKey = 'xprs.device.nsec';

  String _callsign = '';
  String _npub = '';
  String _nsec = '';
  BigInt? _scalar;

  /// The device's callsign (`X3...`), or empty before [ensure] ran.
  String get callsign => _callsign;
  String get npub => _npub;
  bool get ready => _callsign.isNotEmpty && _nsec.isNotEmpty;

  /// The private scalar the device signs with, or null before [ensure].
  BigInt? get scalar => _scalar;

  /// Is [call] (any suffix) this device?
  bool isDevice(String call) {
    if (_callsign.isEmpty) return false;
    return NostrCrypto.bareCallsign(call).trim().toUpperCase() == _callsign;
  }

  /// Owners added on the wire by an owner's `cmd:set owner:` (XPRS.md 11.9):
  /// the accounts that administer this device from somewhere else. Kept and
  /// restored by `XprsDeviceAdmin`.
  List<String> addedOwners = const [];

  /// The profiles on this device, active first: owners by holding the
  /// machine, whatever any command says. Their wire callsigns, so a licensed
  /// operator owns it under the name they air.
  List<String> localOwners() {
    final svc = ProfileService.instance;
    final active = svc.activeProfile;
    final out = <String>[];
    void add(String c) {
      final b = NostrCrypto.bareCallsign(c).trim().toUpperCase();
      if (b.isNotEmpty && b != _callsign && !out.contains(b)) out.add(b);
    }

    if (active != null) add(active.wireCallsign);
    for (final p in svc.profiles) {
      if (out.length >= 4) break;
      add(p.wireCallsign);
    }
    return out.length > 4 ? out.sublist(0, 4) : out;
  }

  /// The device's owners: the profiles on it, then the ones added on the
  /// wire, at most four (XPRS.md 11.9 `owner:` holds up to four).
  List<String> owners() {
    final out = localOwners();
    for (final c in addedOwners) {
      if (out.length >= 4) break;
      final b = c.trim().toUpperCase();
      if (b.isNotEmpty && b != _callsign && !out.contains(b)) out.add(b);
    }
    return out;
  }

  /// Load the device key, making it on the first start. Idempotent.
  Future<void> ensure() async {
    if (ready) return;
    // A headless station (the server) already IS an X3: its profile.
    final active = ProfileService.instance.activeProfile;
    if (active != null &&
        active.callsign.startsWith('X3') &&
        active.nsec.isNotEmpty) {
      _adopt(active.callsign, active.npub, active.nsec);
      _isProfile = true;
      return;
    }
    final root = xprsRootStorage();
    Map<String, dynamic>? stored;
    try {
      stored = await root.readJson(_file);
    } catch (_) {
      stored = null;
    }
    final call = (stored?['callsign'] as String? ?? '').trim();
    final npub = (stored?['npub'] as String? ?? '').trim();
    var nsec = (stored?['nsec'] as String? ?? '').trim();
    if (call.isNotEmpty && npub.isNotEmpty) {
      if (nsec.isEmpty) {
        try {
          nsec = (await CoreHost.secureStore.read(_secureKey) ?? '').trim();
        } catch (_) {}
      }
      if (nsec.isNotEmpty && NostrKeyGenerator.derivePublicKey(nsec) == npub) {
        _adopt(call, npub, nsec);
        return;
      }
      LogService.instance.add(
          'device: key for $call is missing or does not match; making a new one');
    }
    await _create();
  }

  Future<void> _create() async {
    final c = candidate();
    await _store(c.callsign, c.npub, c.nsec);
    LogService.instance.add('device: new station identity ${c.callsign}');
  }

  /// Whether the station key is the active profile's own (a headless server
  /// whose profile IS the X3): then it is changed with the profile, never here.
  bool get isProfileKey => _isProfile;
  bool _isProfile = false;

  /// A fresh station key and the callsign it derives, for a person choosing
  /// one they like (XPRS.md 3: the callsign comes from the key, so a new
  /// callsign IS a new key). Nothing is stored; [replace] keeps the one picked.
  static ({String callsign, String npub, String nsec}) candidate() {
    final keys = NostrKeyGenerator.generateKeyPair(
        callsignLength: reticulum.NostrCrypto.kDefaultCallsignLength);
    final call = NostrKeyGenerator.deriveStationCallsign(keys.npub,
        length: reticulum.NostrCrypto.kDefaultCallsignLength);
    return (callsign: call.trim().toUpperCase(), npub: keys.npub, nsec: keys.nsec);
  }

  /// Wear the station key [nsec] from now on, in place of the one made on the
  /// first start: kept where that one was (the keychain, else the file) and
  /// used at once by everything that reads [callsign]. Peers learn the new
  /// callsign from the station's next announcements; whoever saved the old
  /// one by hand has to be told. Returns the new callsign.
  Future<String> replace(String nsec) async {
    if (_isProfile) {
      throw StateError('the station key is the active profile; change it there');
    }
    final npub = NostrKeyGenerator.derivePublicKey(nsec) ?? '';
    if (npub.isEmpty) throw ArgumentError('not a station key');
    final call = NostrKeyGenerator.deriveStationCallsign(npub,
            length: reticulum.NostrCrypto.kDefaultCallsignLength)
        .trim()
        .toUpperCase();
    final old = _callsign;
    await _store(call, npub, nsec);
    LogService.instance.add('device: station identity $old is now $call');
    return call;
  }

  /// Keep a station key: the private half in the keychain where there is one,
  /// the file where there is not (a write to NoSecureStore is dropped, which
  /// the read-back catches); the public half in the file. Then wear it.
  Future<void> _store(String call, String npub, String nsec) async {
    var inKeychain = false;
    try {
      await CoreHost.secureStore.write(_secureKey, nsec);
      inKeychain = await CoreHost.secureStore.read(_secureKey) == nsec;
    } catch (_) {
      inKeychain = false;
    }
    final doc = <String, dynamic>{
      'callsign': call,
      'npub': npub,
      if (!inKeychain) 'nsec': nsec,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };
    await xprsRootStorage().writeString(_file, jsonEncode(doc));
    _adopt(call, npub, nsec);
  }

  void _adopt(String call, String npub, String nsec) {
    _callsign = call.trim().toUpperCase();
    _npub = npub;
    _nsec = nsec;
    try {
      var d = BigInt.zero;
      for (final b in HEX.decode(NostrCrypto.decodeNsec(nsec))) {
        d = (d << 8) | BigInt.from(b);
      }
      _scalar = d;
    } catch (_) {
      _scalar = null;
    }
  }

  /// For tests: forget the loaded key.
  void resetForTest() {
    _isProfile = false;
    _callsign = '';
    _npub = '';
    _nsec = '';
    _scalar = null;
  }

  /// For tests: wear [nsec] as the device key without touching storage.
  void adoptForTest(String nsec) {
    final npub = NostrKeyGenerator.derivePublicKey(nsec) ?? '';
    _adopt(NostrKeyGenerator.deriveStationCallsign(npub), npub, nsec);
  }
}
