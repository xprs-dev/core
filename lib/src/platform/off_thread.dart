/*
 * Run a pure function off the calling isolate: the core's `compute`.
 *
 * Flutter's `compute` is what the core used for one-shot heavy work (a folder
 * walk, a passphrase unlock, a feed decode). It lives in package:flutter, so a
 * core that must also run under plain `dart` (the server edition, tests) uses
 * this instead. Natively it is `Isolate.run`; on the web, where there are no
 * isolates, it runs the function in a microtask, which is what `compute` does
 * there too.
 *
 * For a STREAM of items on a hot path, do not call this per item: use a
 * long-lived worker with a bounded queue (docs/performance.md 8.1).
 */
export 'off_thread_web.dart' if (dart.library.io) 'off_thread_io.dart';
