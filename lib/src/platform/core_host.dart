/*
 * CoreHost — what the core needs from the program it runs in.
 *
 * The core is plain Dart and runs in two editions: the app (Flutter, phones and
 * desktops) and the server (Linux, no screen). A few things only the host
 * program can provide: keeping the process alive on Android, a heartbeat that
 * survives a suspended phone, whether a person is looking at a screen, where
 * the shared media archive lives. Each is a field here with a default that is
 * right for a program with none of them (a test, the server); the app replaces
 * them at boot with its Flutter-backed implementations.
 *
 * The rule this file exists for (docs/architecture.md, "The core repository"):
 * core code never imports the app's platform, UI or wapp layers. When it needs
 * something only the host has, it asks here, and the host fills it in.
 */
import 'package:reticulum/src/util/media_archive.dart' show MediaArchive;

import '../services/notifications/notification.dart';
import 'advert_radio.dart';
import 'asset_source.dart';
import 'battery.dart';
import 'ble_rns_radio.dart';
import 'package:reticulum/src/services/reticulum/rns_ble_interface.dart' show RnsBleRadio;
import 'key_value_store.dart';
import 'secure_store.dart';

/// Keeping the process up, and the heartbeat that drives work while it is.
///
/// On Android this is the foreground service: `hold`/`release` are
/// ref-counted by reason, and tick listeners are called from the native
/// heartbeat, which keeps running when Dart timers are throttled in a pocket
/// (docs/performance.md 8.2). A program that is never suspended (the server,
/// a desktop) needs neither: the default holds nothing and never ticks, so
/// work that must also run in the foreground keeps its own timer.
abstract interface class KeepAlive {
  Future<void> hold(String reason);
  Future<void> release(String reason);
  void addTickListener(void Function() listener);
  void removeTickListener(void Function() listener);
}

class _NoKeepAlive implements KeepAlive {
  const _NoKeepAlive();
  @override
  Future<void> hold(String reason) async {}
  @override
  Future<void> release(String reason) async {}
  @override
  void addTickListener(void Function() listener) {}
  @override
  void removeTickListener(void Function() listener) {}
}

/// The host program's services to the core. Set once at boot by the host.
class CoreHost {
  CoreHost._();

  /// Process keep-alive and the native heartbeat. Default: none.
  static KeepAlive keepAlive = const _NoKeepAlive();

  /// Is anybody looking at a screen right now? Pacing that only matters to a
  /// person reading (a catch-up cadence) slows down when nobody is
  /// (docs/performance.md 6.5). Default: no — a headless program has no
  /// reader, so it takes the battery-friendly cadence.
  static bool Function() anyoneLooking = () => false;

  /// The device's shared, content-addressed media archive, or null while
  /// storage is not ready (or on the web). Default: none.
  static MediaArchive? Function() mediaArchive = () => null;

  /// Show a notification to the person; true when they were actually told
  /// (false for a suppressed duplicate). The app routes it to its backends
  /// (tray, in-app card); the default drops it, which is right for a test
  /// and for a server, which has nobody to show it to.
  static bool Function(XprsNotification n) notify = (_) => false;

  /// Open the settings store PreferencesService reads and writes. The app
  /// opens shared_preferences; the default keeps settings in memory.
  static Future<KeyValueStore> Function() openPreferences =
      () async => MemoryKeyValueStore();

  /// The OS keychain for a profile's device secrets. Default: none.
  static SecureStore secureStore = const NoSecureStore();

  /// Files shipped with the program (translations). Default: none.
  static AssetSource assets = const NoAssets();

  /// The per-application support directory (where profiles live when the
  /// person has not chosen a folder), or null to fall back to the home
  /// directory. The app asks path_provider.
  static Future<String?> Function() appSupportDir = () async => null;

  /// Does this process have a screen? An engine started at boot on Android
  /// has none until the person opens the app. Default: no.
  static bool Function() hasView = () => false;

  /// Load the SQLite build the program ships (SQLCipher on Android) before
  /// the first database opens. Default: the system library, nothing to do.
  static void Function() prepareSqlite = () {};

  /// May the program read and write anywhere on shared storage (Android's
  /// "all files access", needed to keep an identity backup outside the app's
  /// own folder)? Default: yes — a program with no such gate.
  static Future<bool> Function() hasAllFilesAccess = () async => true;

  /// The battery. Default: none, on mains.
  static BatterySource battery = const NoBattery();

  /// Tell the host the power tier changed (Android retunes its heartbeat and
  /// wake locks from it, docs/performance.md 8.11). Default: nobody to tell.
  static Future<void> Function(String tier) pushPowerTier = (_) async {};

  /// The BLE5 advert radio. Default: none.
  static AdvertRadio radio = const NoAdvertRadio();

  /// A new Reticulum radio over BLE5 adverts (chunking), or null when the
  /// program has no Bluetooth. Default: none.
  static BleRnsRadio? Function() newBle5RnsRadio = () => null;

  /// A new Reticulum radio over the BLE GATT service, or null. Default: none.
  static RnsBleRadio? Function() newGattRnsRadio = () => null;

  /// Hand a file, or a folder, to the system to open (a viewer, the file
  /// manager); true when something took it. Default: nothing to hand it to.
  static Future<bool> Function(String path) openFile = (_) async => false;
  static Future<bool> Function(String path) openFolder = (_) async => false;

  /// A position fix to answer a peer who asked where this station is
  /// (XPRS.md 15.1), or null with no location (the default, and the web).
  static Future<({double lat, double lon, double acc})?> Function(
      {Duration maxAge, Duration timeLimit}) locationFix = (
          {Duration maxAge = const Duration(minutes: 5),
          Duration timeLimit = const Duration(seconds: 20)}) async =>
      null;

  /// Counters the host keeps for work the core does not own (the USB
  /// flasher), drained into TaskMonitorService's `perf:` lines once a minute:
  /// name -> a function returning counters since the last drain. A worker or
  /// subsystem with no counter is one nobody can see burning
  /// (docs/performance.md 8.1).
  static final Map<String, Map<String, int> Function()> perfSources = {};
}
