# core

The XPRS core: the code every XPRS program shares, in plain Dart.

The [app](https://github.com/xprs-dev/app) (phones and desktops, Flutter) and
the server edition (Linux, no GUI) run the same implementation of the protocol,
so a fix to a bearer rule, a callsign or the mesh session lands everywhere at
once. Nothing here imports Flutter: a `dart` program can use all of it.

```
  app (Flutter)          server (dart)
        \                  /
         xprs_core  (this repo)       XPRS packets, policy, mesh, folders, I2P
              |
         reticulum  (xprs-dev/reticulum-dart)   Reticulum, LXMF, NOSTR, DHT, files
```

## What is here

| Area | Files (`lib/src/…`) | What it does |
|---|---|---|
| XPRS packets | `services/xprs/xprs_packet`, `xprs_vocab`, `xprs_id`, `xprs_callsign` | the wire grammar and vocabulary (spec XPRS.md), packet ids, the shape of a callsign |
| Station policy | `xprs_station_policy`, `xprs_owned_stations`, `xprs_archive_policy`, `xprs_archiver_choice`, `xprs_cadence` | what a station keeps and for whom, which archiver it leans on, how often it asks |
| Relaying | `xprs_digipeat`, `xprs_gateway_dedup`, `xprs_airtime`, `xprs_presence`, `xprs_mailbox` | repeating what was heard, one message however many gateways carry it, one airtime budget across bearers, who is reachable, held mail |
| Mesh | `services/mesh/*` | the Mesh Session Protocol (MSP), frames, route beacons and bloom digests, neighbour table, custodian choice, xblob |
| Folders | `services/folders/*` | mutable folders as signed NOSTR events, their state reducer, peer discovery, ntorrent refs |
| I2P | `services/i2p/*` | a pure-Dart I2P node: NTCP2, tunnels, leasesets, datagrams, swarm |
| Identity seam | `services/nostr/nostr_signer` | "this program can sign as you" without holding the key |
| Utilities | `services/log_service`, `services/db_bytes`, `util/geohash`, `util/nostr_imeta`, `services/social/note_text` | log ring buffer, sqlite size, geohash, NIP-92 imeta, mentions |

Import everything through one barrel:

```dart
import 'package:xprs_core/xprs_core.dart';
```

## Use it

`core` is a path dependency, checked out next to its users, with
`reticulum-dart` next to it:

```
code/
  app/  or  xprs/       the Flutter app
  core/                 this repo
  reticulum-dart/       its dependency
```

```yaml
dependencies:
  xprs_core:
    path: ../core
```

## Develop

```sh
dart pub get
dart analyze
dart test
```

The app's architecture guard (`tool/arch_guard.dart` in the app repo) scans
this repo with the app's own rules, so code that moved here is held to the same
standard it was in the app. Run it from the app before committing here.

## Where it came from

These files moved out of the app's `lib/` unchanged, keeping the app's directory
layout under `lib/src/` so their relative imports still hold. The app keeps a
one-line export shim at each old path, so nothing in the app had to change but
the dependency. Their earlier history is in the app repository.

The rest of the XPRS core (the archive, ingest, the bridge, the LAN and TCP
bearers, the web chat API) still lives in the app: it depends on app services
(the profile, preferences, the mesh and Reticulum services) that have to become
interfaces first. That is the next stage; see `docs/reusable.md` for what is
already shareable.

## License

BSD-3-Clause, copyright Max Brito and XPRS contributors. See [LICENSE](LICENSE).
