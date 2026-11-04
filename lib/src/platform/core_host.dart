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
}
