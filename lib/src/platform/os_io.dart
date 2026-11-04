/*
 * The operating system, as plain Dart sees it — native (dart:io) half.
 *
 * Moved from the app's lib/platform so the core can ask "am I on Android", find
 * the home directory or run a subprocess without importing dart:io directly
 * (which compiles on the web and then throws) and without the app's
 * Flutter-bound platform half (method channels, the root view). The app's
 * lib/platform/platform.dart re-exports this and adds those.
 */
import 'dart:async';
import 'dart:io';

import 'os_web.dart' show PlatformProcessResult;

export 'os_web.dart' show PlatformProcessResult;

String currentLocale() {
  try {
    final os = Platform.localeName;
    if (os.isNotEmpty) return os;
  } catch (_) {}
  return 'en';
}

String? homeDir() {
  try {
    return Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
  } catch (_) {
    return null;
  }
}

bool get supportsSubprocesses => true;

Future<PlatformProcessResult> runSubprocess(
    String executable, List<String> arguments,
    {String? workingDirectory}) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    return PlatformProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout?.toString() ?? '',
      stderr: result.stderr?.toString() ?? '',
    );
  } catch (e) {
    return PlatformProcessResult(exitCode: -1, stdout: '', stderr: '$e');
  }
}

String get pathSeparator => Platform.pathSeparator;

/// OS predicates, so a service can ask "am I on Android" without importing
/// dart:io (which compiles on web and then throws on every Platform call).
bool get isAndroid => Platform.isAndroid;
bool get isIOS => Platform.isIOS;
bool get isLinux => Platform.isLinux;
bool get isMacOS => Platform.isMacOS;
bool get isWindows => Platform.isWindows;
bool get isWeb => false;

/// Canonical OS name used for wapp `platforms` advertisement matching:
/// one of linux/macos/windows/android/ios/fuchsia/unknown (web returns
/// 'web' from the stub).
String platformName() {
  if (Platform.isLinux) return 'linux';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isFuchsia) return 'fuchsia';
  return 'unknown';
}

String currentDirectory() {
  try {
    return Directory.current.path;
  } catch (_) {
    return '';
  }
}

/// Directory holding the running executable. A desktop bundle keeps its
/// `data/` beside it. '' when it cannot be resolved.
String executableDirectory() {
  try {
    return File(Platform.resolvedExecutable).parent.path;
  } catch (_) {
    return '';
  }
}

Future<List<int>?> readArbitraryFileBytes(String path) async {
  try {
    final f = File(path);
    if (!await f.exists()) return null;
    return await f.readAsBytes();
  } catch (_) {
    return null;
  }
}

List<int>? readArbitraryFileBytesSync(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    return f.readAsBytesSync();
  } catch (_) {
    return null;
  }
}

bool arbitraryFileExistsSync(String path) {
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}

Future<void> openInFileManager(String path) async {
  try {
    if (Platform.isLinux) {
      await Process.run('xdg-open', [path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [path]);
    }
  } catch (_) {
    // Best-effort — caller has no way to recover anyway.
  }
}
