/*
 * The operating system (OS predicates, paths, subprocesses, locale) without
 * Flutter. Import as `platform`: the names match the app's lib/platform.
 */
export 'os_web.dart' if (dart.library.io) 'os_io.dart';
