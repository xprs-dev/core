# Working in core

This is the XPRS core (`xprs_core`): what the app and the server edition both
run. `../xprs/docs/architecture.md` governs it (§2a is about this repo) and
`../xprs/docs/performance.md` governs its cost. Read both before writing code.

## Rules

1. **No Flutter, no app.** Nothing here imports `package:flutter`, a Flutter
   plugin, or anything from the app. `dart analyze` and `dart test` must pass
   with plain Dart. If the core needs something only a host has, it asks
   `CoreHost` (`lib/src/platform/core_host.dart`); add a seam only when there
   is no other way, keep it to the calls actually made, give it a headless
   default, and wire the app's answer in `../xprs/lib/boot/core_host_app.dart`.
2. **The core does not know a wapp.** No wapp name in code: not a comparison,
   not a storage folder, not a notification source. Raise a notification by
   topic (`core:nostr`) and let the host route it; offer a capability every
   wapp can use.
3. **Screens forward intent; the core decides.** Lanes, retries, custody,
   reachability verdicts and fetching are decided here, behind a method that
   takes the intent (`RnsService.react`, `RnsService.inReach`), never by the
   caller.
4. **The web build compiles this.** `dart:io`, `dart:ffi`, `dart:isolate` and
   FFI sqlite go in a `*_io.dart` behind a conditional export (`fs.dart`,
   `os.dart`, `off_thread.dart` are the pattern).
5. **Cost rules apply** (performance.md §8): no sub-minute poll, no whole
   file on the heap, no page fetched to count, nothing unbounded that grows per
   packet or per peer, a `perf:` counter for any worker, never a person's words
   in the log.

## Before committing

From the app repo (it scans this one with the app's rules):

```sh
cd ../xprs && dart tool/arch_guard.dart      # must say clean
```

Here:

```sh
dart analyze && dart test
```

A violation the guard reports is fixed, not baselined. Re-baselining is for
code that MOVED (the same rule and line reappearing under `../core/`), and the
commit says so.

## Moving code here from the app

Keep the app's path under `lib/src/`, leave a one-line export shim at the old
`lib/` path, move the tests that only touch moved files (`flutter_test` becomes
`test`), and check: the app's analyzer reports nothing new, the guard is clean,
both test suites pass. `docs/reusable.md` describes the pattern.

## Reusable code

Keep `docs/reusable.md` current: read it before writing something new, add to
it when you write something others should reuse, and ask when unsure whether
something belongs there.
