# core — reusable components

What in this package is worth reaching for before writing something new. Every
entry is plain Dart: usable from the app, the server, a `tool/` script or a
test. Paths are under `lib/src/`; everything is also exported by
`package:xprs_core/xprs_core.dart`.

When you write code in the app or the server that would serve both, it belongs
here. Add it to this list when you move it.

## Packets and names

### `XprsPacket` + `xprs_vocab` — the wire, parsed and written once

`services/xprs/xprs_packet.dart` parses and builds the XPRS wire; `xprs_vocab.dart`
holds the vocabulary (types, keys) and the time format: `xprsParseTs` and its
inverse `xprsFmtTs`. Never hand-format a `ts:` or split a wire on spaces.

### `xprs_callsign` — the shape of a callsign, decided once

`xprsNormaliseCallsign`, `xprsIsCallsignShaped`, `xprsIsSelfGenerated`,
`xprsLooksIssued`, `xprsIssuedCallsignRefusal`, `xprsIsForeignNodeNumber`.
Anything that takes a callsign from a person or a packet asks these rather than
writing its own regex.

### `xprs_id` — packet identity

`xprsIdentifier(packet)`: XPRS.md §5, the first 6 hex characters of sha256 of
the packet with `sig:` and `via:` removed, so a message keeps one identity at
every hop. Dedup, replies, reactions and history replay all key on it.

## Relaying and delivery

### Injected sends — `XprsMailbox` (and the app's `XprsForwarder`)

A routine that decides WHERE a packet goes takes its sends and its evidence as
function fields with device defaults (`sendTo`, `reachable`, `held`,
`holdersOf`, `publish`), so the whole decision runs on a bench against a
virtual air. `debugReset()` clears state AND the seams. Reuse this shape for
anything whose failure only shows between machines. The app's
`test/support/mail_relay_sim.dart` is the simulation that runs it.

### `XprsGatewayDedup` — one message, however many gateways

XPRS.md 9.11.5: two gateways that translate one Meshtastic transmission across
a minute boundary produce two identifiers. This catches the second copy by the
foreign network's own message id (`zmid:`) plus the part number. It's checked
at the one receive door, bounded at 256 entries and ten minutes. A server
bridging several networks uses it the same way the phone does.

### `XprsDigipeater` — repeating what we heard, on the medium we heard it

The digipeat decision (what to repeat, where, how often), with no radio in it.

### `XprsAirtime` / `XprsRetryLedger` — one airtime budget across every bearer

XPRS.md §31.1. Ask it before airing; don't keep a second counter.

### `xprs_presence` — is this an XPRS device, who is it, can we reach it

`XprsCandidate` / `XprsDevice`: one place that turns a sighting on any bearer
into a device. Use it rather than reading advert bytes yourself.

### Station and archive policy

`XprsStationPolicy` (what a station airs about itself, each builder returning
the unsigned wire or null when it does not fit 250 bytes), `XprsArchivePolicy`
(what is kept and for whom), `XprsArchiverChoice` (which archiver to lean on),
`XprsCadence` (how often to ask it), `XprsOwnedStations` (stations an operator
owns).

## Mesh (BLE street mesh, docs/mesh.md in the app)

- `MeshSession` / MSP types — the Mesh Session Protocol v1 (Plane 2).
- `MeshFrame` — one view over the two frame formats in flight.
- `MeshBeacon`, `mesh_bloom` — the route beacon codec and its have-digest
  (the bloom fixture is shared with the C firmware).
- `MeshTable` — neighbour registry and distance-vector routes.
- `mesh_custodian` — who should carry mail we can't deliver.
- `XblobSession` — the blob transfer over a mesh session.

All are codecs and state machines with no radio: test them on the host.

## Folders

`FolderEvent` / `FolderState` (mutable folders as signed NOSTR events, and the
reducer to their current contents), `FolderMeta`, `FolderRelay` (discovery by
key, no indexer), `NtorrentRef`.

## I2P

`I2pNode` ties a pure-Dart I2P node together (NTCP2, tunnel build and data,
LeaseSet2, datagrams, reseed); `I2pWorker` runs it on its own isolate;
`SwarmStore` is the BitTorrent-style collective download over it.

## The host seams (`platform/`)

### `CoreHost` — the one place the core asks its host for anything

`platform/core_host.dart`. A static field per need (keep-alive, preferences,
keychain, assets, battery, radio, notifications, location, USB serial, ...),
each with a default that is right for a program that has none of it. Before
adding a field: is there already one that answers the question? Reuse it
(the flasher's directory and the media cache both ask `appSupportDir`). A new
one is the calls actually made and nothing more, with a headless default; the
app's answer goes in `xprs/lib/boot/`. README.md has the table.

### Interfaces with a stand-in, for tests and the server

- `KeyValueStore` / `MemoryKeyValueStore` — settings (a test seeds the map).
- `SecureStore` / `NoSecureStore`, `AssetSource` / `NoAssets`.
- `BatterySource` / `NoBattery` — passes the RAW condition through, so each
  reader keeps its own "on mains" rule; folding states in a seam would have
  silently changed one of three.
- `AdvertRadio` / `NoAdvertRadio`, `BleRnsRadio`, `UsbSerialHost`.

### Stand-ins for what Flutter used to provide

- `Observable<T>` (`util/observable.dart`) — ValueNotifier's API in plain
  Dart. A widget watches one through `.listenable`
  (`xprs/lib/util/observable_listenable.dart`, one cached adapter per value).
- `offThread(fn, arg)` (`platform/off_thread.dart`) — `compute`: Isolate.run
  natively, a microtask on the web. One-shot only; a stream of items wants a
  long-lived worker (performance.md 8.1).
- `kIsWeb`, `setEquals` (`util/compat.dart`).
- `platform/os.dart` — OS checks, paths, subprocesses, locale (import as
  `platform`); `platform/fs.dart` — the file system, native or browser.

### Host-registered counters — `CoreHost.perfSources`

A subsystem the core does not own (the USB flasher's session counters) adds
`name -> drain()` and TaskMonitorService prints it in its once-a-minute
`perf:` lines. Use it instead of teaching the core about the subsystem.

## Deciding for the caller

### Intent in, lanes chosen here — `RnsService.react`, `addNostrLane`

A screen asks for the effect ("like this post"); the core picks the lanes and
their order (Reticulum first, then every NOSTR lane a host registered with
`addNostrLane`, best-effort). Copy the shape for any "send this" whose lanes
used to be picked by the caller.

### One verdict, read by everyone — `RnsService.inReach`

The presence dot's verdict (heard on the air OR reachable over the internet)
is computed here once; screens read it. A second place that combines the same
sources is the bug "Who is on the mesh, decided once" (architecture.md) names.

### Notifications by topic — `XprsNotification.withSource`

The core raises `core:<topic>` (`core:nostr`, `core:archiver`); the host maps a
topic to the wapp that shows it (`routeCoreNotification`,
`xprs/lib/boot/core_host_app.dart`). Never `source: 'wapp:<name>'` here.

## Small utilities

- `NostrSigner` / `LocalSigner` — "this program can sign as you" without
  holding the key; take a signer, not an nsec.
- `LogService` — the in-memory ring behind `/api/log` (never a person's words).
- `db_bytes` — the size of a sqlite database, on every platform.
- `geohash`, `nostr_imeta` (NIP-92), `note_text` (`NoteMention`).
- `ActivityArchive` (`services/storage/`) — a time-ordered feed store; one
  SQLite file per owner.

## Moving code here from the app

1. Cut the edges first: a file moves when nothing it imports is Flutter, a
   plugin or the app's UI. Replace what it borrowed with a `CoreHost` seam or
   a stand-in above.
2. Move with the app's path kept under `lib/src/`, leaving
   `export 'package:xprs_core/src/<path>';` at the old path; imports between
   moved files stay relative, imports of a shim become the package it
   re-exports.
3. Move the tests that only touch moved files (`flutter_test` -> `test`).
4. Check: the app's analyzer reports nothing new; `dart tool/arch_guard.dart`
   is clean and the baseline only shrinks (a moved violation reappears under
   `../core/` with the same line: that is the one allowed re-baseline); both
   test suites pass.

The tooling used for the November 2026 move (import-closure scan, the move
script that rewrites imports and refuses a file importing app-only code, the
re-baseline that refuses to hide a new violation) is described in
`docs/audit-2026-11-04.md`, "How the move was done".

| `LogService.onLine` | `services/log_service.dart` | a host that prints the log as it is kept (the server edition writes it to stdout / the journal) |
