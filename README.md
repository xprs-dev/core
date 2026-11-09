# core

The XPRS core: the code every XPRS program runs, in plain Dart.

The [app](https://github.com/xprs-dev/app) (phones and desktops, Flutter) and
the server edition (Linux, no screen) run this one implementation of the
protocol, so a fix to a bearer rule, a callsign or the courier lands everywhere
at once. Nothing here imports Flutter: a `dart` program can use all of it.

```
  app (Flutter)            server (dart)          tests (dart test)
        \                       |                       /
         \__ CoreHost answers __|__ CoreHost answers __/
                                |
                    xprs_core  (this repo)
          identity, transports, delivery, storage, the receive door
                                |
              reticulum  (xprs-dev/reticulum-dart)
          Reticulum, LXMF, NOSTR, DHT, files, XprsCrypto
```

## What is here

Everything `docs/architecture.md` (in the app repo) calls the core:

| Area | Where (`lib/src/…`) |
|---|---|
| **Identity and keys** | `profile/` (ProfileService, the profile database, encryption, the device key store, identity backup), `services/xprs/xprs_sig.dart`, `xprs_self.dart` |
| **Settings and words** | `services/preferences_service.dart`, `services/i18n/` (CoreI18n, `tr()`) |
| **The receive door** | `services/receive/` (PacketGateway, CoreState, WappDelivery) |
| **Transports** | `services/reticulum/rns_service.dart` (the Reticulum node, LXMF, NOSTR, folders, hub role, station lane), `services/mesh/` (BLE street mesh), `services/xprs/xprs_lan.dart`, `xprs_tcp.dart`, `services/i2p/`, `services/flash/` (the USB cable) |
| **Delivery** | MeshCourier and custody, XprsPublisher, XprsSend, XprsMailbox, XprsForwarder, XprsCommandCourier, XprsCatchup, XprsFetch, the inline file lane |
| **Storage** | XprsArchive (the packet spool), XprsGossip, the mesh store and bulk spool, ObservedStore, WappMailbox, `services/storage/activity_archive.dart`, folders, the profile store (`profile.zx`, `profile/profile_storage_encrypted.dart`) |
| **Policy** | station and archive policy, digipeat, gateway dedup, airtime, presence, PowerState and the power tier, the capacity governor |
| **Plumbing** | BackgroundService, TaskMonitorService, the event bus and topic broker, LogService |

One barrel exports the first files that moved: `package:xprs_core/xprs_core.dart`.
The rest is imported by path (`package:xprs_core/src/…`), the way the app
imports `package:reticulum/src/…`.

## What the host provides: `CoreHost`

The core never imports its host. What only the host program can provide is
one registry, `lib/src/platform/core_host.dart`, each entry with a default
right for a program that has none of it:

| seam | the app's answer | default |
|---|---|---|
| `keepAlive` | Android foreground service, native heartbeat (`ticks`) | none, never ticks (desktop and server: `HeartbeatKeepAlive`, 2 s) |
| `anyoneLooking`, `hasView` | launcher visibility, Flutter's views | no |
| `notify` | NotificationService (routes `core:<topic>` to a wapp) | dropped |
| `openPreferences` | shared_preferences | memory (`MemoryKeyValueStore`) |
| `secureStore` | flutter_secure_storage | none |
| `assets` | the Flutter asset bundle | none |
| `appSupportDir` | path_provider | home directory |
| `prepareSqlite` | SQLCipher on Android | system SQLite |
| `hasAllFilesAccess` | Android all-files permission | yes |
| `mediaArchive` | the shared media store | none |
| `battery`, `pushPowerTier` | battery_plus; the native service | on mains |
| `radio` | Ble5Bus + BleService (`AdvertRadio`) | no radio |
| `newBle5RnsRadio`, `newGattRnsRadio` | the BLE radios Reticulum runs over | none |
| `openFile`, `openFolder` | the system viewer / file manager | nothing |
| `locationFix` | the GPS fix for a peer who asks | none |
| `usbSerial` | Android's USB host (`UsbSerialHost`) | none (Linux opens ttys itself) |
| `perfSources` | the host's own `perf:` counters | empty |

Plain-Dart stand-ins for what the core used to borrow from Flutter:
`util/observable.dart` (`Observable<T>`, Flutter's `ValueNotifier`),
`platform/off_thread.dart` (`offThread`, Flutter's `compute`),
`util/compat.dart` (`kIsWeb`, `setEquals`), `platform/os.dart` (OS checks,
paths, subprocesses, locale), `platform/fs.dart` (the file system, native or
in the browser).

## Use it

`core` is a path dependency, checked out next to its users, with
`reticulum-dart` next to it:

```
code/
  xprs/ (the app)    core/ (this repo)    reticulum-dart/
```

```yaml
dependencies:
  xprs_core:
    path: ../core
```

A host wires `CoreHost` once at start, before any core service runs (the
app: `lib/boot/core_host_app.dart`).

## Develop

```sh
dart pub get
dart analyze
dart test
```

Read `CLAUDE.md` before changing anything: the rules for this repo are short
and they are enforced. The app's architecture guard (`dart tool/arch_guard.dart`
in the app repo) scans this repo with the app's rules.

## Where it came from

All of it was moved out of the app's `lib/` in November 2026, keeping the
app's directory layout under `lib/src/` so relative imports held; the app
keeps an export shim at each old path. Earlier history is in the app repo.
`docs/audit-2026-11-04.md` is the audit that started it and what is left.

## License

BSD-3-Clause, copyright Max Brito and XPRS contributors. See [LICENSE](LICENSE).
