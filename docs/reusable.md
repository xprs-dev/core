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

### `web_chat_forum` — a room's posts as topics and comments

`forumPosts(rows)` turns `blog` history rows into posts with their parts
joined (7.6) and the whole's identifier, holed sets left out; `forumTopics`
folds them into the newest topics by last activity with a reply count
(18.5). Pure functions: the server's `/api/rooms?topics=` and any app screen
listing a forum share one fold. Events (26) replace by title the same way a
post does, so an events index would start here.

### `XprsGroupMirror` — one group kept in step with a peer station

A standing `cmd:history only:<X5> since:<mark>` to each (group, peer) pair
the host names, 12.9.3's neighbour ask narrowed to one group: pages
continued before the oldest row (11.2.1), the mark moved to the ask's own
time on 200/404, a minute after news and doubling to ten while quiet, 429
honoured; an act parked for want of its signer's key makes it ask the peers
for that identity (`XprsGroups.onUnknownSigner`). Every send and clock is a seam. The web chat API supplies the
pairs (`mirrorPairs`) and the serving gate the history server consults
(`roomServable`, via `XprsHistoryServer.hostedRoom`). Anything else that
should keep a bounded record in step between two stations, a category of
events, a place's notices, is the same shape with a different `only:`.

### `XprsArchive.maxGroupBytes` — a ceiling per group

10.9.3's fourth axis on eviction: every twentieth flush, a group whose rows
exceed the ceiling loses its oldest ones (never its acts, its identity or
this station's own words). Anything else that keeps a bounded record per
addressee would be the same query with a different prefix.

### Holding a split packet until it verifies — `WebChatApi._postPart`

A split plain packet is signed once, on its last part, over the whole
(9.1.1). The pattern: decide who may post from the envelope, offer each part
to an `XprsPartTable`, and when the set completes verify the reassembled
packet and file THAT, never the parts: a part's `sig:` reads as forged on its
own and the archive drops it at flush, and a reader wants the post, not its
fragments (`WappDelivery._whole` files a rejoined message the same way).
Anything that takes split packets from an untrusted sender through an API
wants the same shape.

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

## Visitors and the station's administrator (`services/web_chat_api.dart`)

- `isPrivateAddress` — whether a socket's peer is on a private network
  (RFC 1918, loopback, link-local, CGNAT, IPv6 ULA, `::ffff:` IPv4). Pure;
  a host widens it with its own IPv6 prefixes (server: `Station.isLocalPeer`).
- `WebChatApi` administration — an administrator proved by a session (a
  signed nonce, no password), claimable once from the station's network, and
  settings kept in a `KeyValueStore`; reuse the pattern for any setting a
  visitor-facing host lets its owner change from a browser.
- `WebChatApi` moderation (XPRS.md 10.10) — a station's own rooms moderated
  through `XprsGroups` with the station as the group: `signAsStation` +
  `publish` for the admin's acts, moderators' acts verified and fed to the
  replay, `XprsRoster.away` (who an open room sent away, and until when).
  Any host with open rooms (the app's share server) reuses it by passing
  `groups`, `signAsStation` and `publish`.
- The station API is a contract with a conformance suite: the webchat
  repo's `contract/conformance.py` drives `/api/services`, `/api/session`,
  `/api/admin`, `/api/rooms`, history and send from outside, and the ESP32's
  C engine (`firmware/common/xprs_webchat`) passes the same run. A rule
  added to `WebChatApi` goes into the suite, and the other engine follows.
- `WebChatApi` hosted rooms and alerts (XPRS.md 10.10.1, 10.10.2) — closed
  groups whose key the host holds (`WebChatRoomKeys` over `XprsGroupKeys`),
  filed with `keep` and read with `roomRows`, never aired; `who_may_alert`
  gates `t:warning`/`t:info` through the page. The server wires it in
  `Station._webChatApi`; the app's share server can pass the same three.

## A public name and HTTPS (`connections/internet/public_name/`)

- `PublicName` (`public_name.dart`, io + web stub) — the whole loop: public
  addresses, a nip.io name, UPnP ports, an outside reachability test (Let's
  Encrypt staging: port 80, then 443 through a redirect), a real certificate,
  HTTPS, renewal. A host hands it its web server as an `AcmeWebServer` (the
  server's `WebChatServer`; next, the app's share server on Android/desktop).
- `AcmeClient` (`acme_io.dart`) — RFC 8555 HTTP-01 against any ACME CA;
  `certificateExpiry` reads notAfter from a PEM with no X.509 library.
- `EcKey` (`ec_key.dart`, pure Dart) — P-256: JWK + thumbprint, ES256 (raw)
  and DER signatures, SEC1 PEM for `SecurityContext`, a PKCS#10 CSR with
  SANs; `der*` / `pem` are a minimal DER writer for any other ASN.1 shape.
- `discoverPublicAddresses`, `askPublicAddress`, `nipName`, `isPublic`,
  `isEui64` (`public_address_io.dart`) — what the internet sees of this
  machine, by one UDP DNS query (TXT ip.nip.io), no HTTP service.
- `XprsPublisher.setPublicUrl` / `XprsProfiles.urlFor` — a host announces
  where it serves the web chat (6.3.2 `url:`, a decoration field) and a screen
  reads another station's; `PublicName.onUrl` feeds the first.
- `UpnpGateway` (`upnp_io.dart`) — SSDP discovery, IPv4 port mappings
  (falls back to a permanent lease), IPv6 pinholes, the router's public IPv4.

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
| `HeartbeatKeepAlive` | `platform/heartbeat_keep_alive.dart` | the core's heartbeat on a host with no native one (server, desktop): a Dart tick at a period the host passes, running only while listened to; hold/release delegated |
