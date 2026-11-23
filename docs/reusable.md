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

### A visitor heard through the API — the `viaApi` pattern

A browser on the station's web page is a station the core HEARS, not a
second kind of peer: the host hands its wire to `PacketGateway.receive`
on bearer `lan` with `viaApi: true, localLink: <on our network?>`, and
`XprsIngest.heard` carries the same two flags. Nothing new reaches the
wire. What the flag changes, in one place each: `XprsMonitor.offer`
marks the entry (`XprsStation.viaApi`, `lastRadioMs`) so
`heardDirectly(radioOnly: true)` excludes a page-only visitor (the
mailbox's `reachable` asks with it: a browser hears no re-air);
`XprsGossip.noteDirect(shortRange:)` writes the durable layer only for a
visitor on the station's own network (12.9.4); `onDirectHeard(..., viaApi:)`
lets the receiver report the hearing and skip the re-air. A visitor who
only proved a session is `XprsMonitor.noteVisitor` (a synthetic `lan`
sighting) and `MeshService.visitorHeard`. Reuse the flag for any lane
that delivers through something other than the air (a socket page, a
push channel) rather than inventing a bearer word.

### The station as a visitor's mailbox — `XprsArchive.noteServed` / `servesVisitor`

`served_visitors(call, since, last)` plus a RAM set: `noteServed` (the
offer), `touchServed` (seen again), `servesVisitor` (one lookup, safe on
the receive path), `servedVisitors`, `forgetServed`. The archive answers
for a served visitor as if it had declared this station: `holdersFor`
returns `[self]` until a real declaration, `hasActiveDecl` is true,
`caredFor` counts it toward `room:`. The funnel shelves their mail
`Tier.followed` (protected), `XprsForwarder` never forwards it away, and
`XprsMailbox.armDeposit(onBehalf: true)` deposits their outgoing mail
with the station's archivers (12.8.3 step 1 for somebody who has no
archiver). The seam that decides whether to offer is
`MeshService.offerMailbox` (public archiver with room, `_hasRoom`).

### `WebChatApi` visitor seams — `receiveFrom`, `onVisitor`, `holdersOf`, `offerMailbox`, `mailFor`

`receiveFrom(wire, {local})` replaces `receive` when a host can say where
the browser is; `onVisitor(call, {local})` fires on a proven session.
`/api/session` then answers `holders` (list), `offer` (this station, only
when nobody holds) and `mail` (count); `/api/services` says
`page.mailbox: true` when `holdersOf` and `mailFor` are wired. A
`t:mailbox` or `t:receipt` through `/api/xprs/send` must verify against a
key the station knows (409 `identity unknown`, 400 `forged`), because
both are acted on by whoever hears them. Both hosts (server `Station`,
app `ShareAppService`) wire the same five lines.

### `XprsDirectory` — who keeps what, between archivers (XPRS.md 12.9)

`services/xprs/xprs_directory.dart`: `XprsDirectory.compose/parse` (the
`XDIR1` listing, sorted, one line per callsign), `shaOf`, `refOf`,
`announces(p)`. `XprsDirectoryAnnouncer` publishes it from the minute
sweep every ten minutes, only when the digest changed, as a signed
`t:service … file:<ref>.xdir` aired and deposited; every side effect is a
seam (`entries`, `count`, `store`, `air`, `deposit`, …). `XprsDirectoryConsumer`
reads a named archiver's announcement once per (archiver, digest) through
an injected `fetchText` and keeps POINTERS in `XprsGossip.notePointers` /
`keepersOf` (`directory_ptr`, bounded by `directoryMaxRows`). The archive's
lines are `XprsArchive.directoryEntries`. `XprsHistoryServer.tryFor` is
the one composer of a 404's `m:try`: holders, keepers, then gossip.

### Replays: one on the radio, many on directed lanes

`XprsHistoryServer` decides who is answered and on what (XPRS.md 12.9.4
"concurrent"): `_radio` is the one replay on the broadcast bearers; an
always-on archiver runs up to `directedMax` more in `_directed`, sent only by
`_sendDirected` (the LXMF destination for the callsign) at
`directedInterPacket`, `perAskerMax` questions per asker (`_question`:
kinds + `only:`). Tests drive it through `directedPathOverride` /
`directedTxOverride` beside `txOverride`. Anything else that answers many
askers (a future `cmd:file` index, `q:have`) should reuse this split rather
than add a second "busy" rule.

### `XprsKeyWait` — a send held until the key it needs arrives

`services/xprs/xprs_key_wait.dart`: a direct message that cannot be sealed yet
waits under a held id (6 hex, the §5 shape), persisted in the profile store,
bounded and expiring; the core looks for the key (`ask`: `q:identity` and
`XprsFetch.requestKey`), and `keyLearned` (called from
`RnsService.recordCallsignPubkey`) seals and sends it, reporting the real id
(`report`, which becomes `xprs.status.tx` with `newId`). Every seam injected
(`test/xprs_key_wait_test.dart`). The pattern for any send blocked on a fact
the core learns later.

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

### Files go where their publications go (XPRS.md 12.9.2)

`XprsPublisher.depositArchivers` hands a copy of each of this station's own
publications to its chosen archivers, and now also the BYTES behind a `file:`
the publication references (`_placeFile`): once per archiver and file, retried
on the next airing when refused, files up to `XprsPublisher.archiverFileMax`.
The deposit itself is the injectable `depositFileTo(archiver, fileValue)`,
wired by `MeshService` to `RnsService.depositFileToCallsign`; the archiver
stores the file and advertises itself on the DHT, so the hash is found while
the author sleeps. A wapp that wants its picture fetchable later describes it
in a `t:file` publication and does nothing else. `publishWire` also
advertises any `file:` a caller-composed wire carries (hash only, never a
push to `d:`), as the conversation paths always did.

## Mesh (BLE street mesh, docs/mesh.md in the app)

- `MeshSession` / MSP types — the Mesh Session Protocol v1 (Plane 2).
- `MeshFrame` — one view over the two frame formats in flight.
- `MeshBeacon`, `mesh_bloom` — the route beacon codec and its have-digest
  (the bloom fixture is shared with the C firmware).
- `MeshTable` — neighbour registry and distance-vector routes.
- `mesh_custodian` — who should carry mail we can't deliver.
- `XblobSession` — the blob transfer over a mesh session.

All are codecs and state machines with no radio: test them on the host.

## People (who a key is, how its holder is reached)

### `XprsPeople` — `services/people/xprs_people.dart`
One record per npub, with every identity learned under it: derived and issued
callsigns, Reticulum identities, LXMF addresses, static Bluetooth and WLAN
addresses, a node on another mesh, an e-mail address. Each with its evidence
(`XprsIdEvidence`: relayed, observed, noted, signed, derived), first and last
seen, and the scope its holder allows. **Any "who is this" or "how do I reach
this callsign" lookup goes here**, not into a new map: `note` / `noteForCall`
to file something, `of` / `valuesOf` for a holder's identities, `holders` /
`personWith` for who has a value, `reachCall(callsign, type)` for another
identity of whoever goes by a callsign, `claim` when a key proves a keyless
record is its own. Kept in `people.zx`, bounded, writes batched.
`RnsService.identityForCallsign` is the first reader (app
`docs/plan-people.md` lists the tables still to be moved onto it).

## Storage (zx stores)

### `openStoreDb` / `openStoreDbWithSecret` / `openMemoryStoreDb` — `storage/store_db.dart`
Every store file is a zx store opened here: inside an encrypted profile it
gets its secret (`storeSecretFor(path)`: HKDF of the profile master key and
the store's relative path), a plain profile opens it unencrypted, a locked
one throws `ProfileLockedException`. An isolate without the keyring gets the
secret looked up beforehand and opens with `openStoreDbWithSecret` (the
Nostr engine, the file export worker). No store imports zx directly.

### Batching writes
Each autocommit is a generation (KBs of file, ms of time): a store written
often wraps bursts in `db.transaction` (SQL) or `kv.batch` (KV; KV writes do
not join an SQL transaction). `XprsGossip`'s write buffer and reticulum's
`ServeStats` are the buffered pattern.

### The profile store — `EncryptedProfileStorage` (`profile.zx`)
Loose files of an encrypted profile: KV `files` (path → mtime, kind,
content), `dirs`, and `parts` for files copied in from outside, which stream
in and out in 256 KiB pieces. The same pieces pattern serves any large value
a KV store must hold without putting it whole on the heap.

### `KeyDerivation` — `profile/key_derivation.dart`
Sync HKDF-SHA256 and AES-256-GCM for code that cannot await (the WASM HAL):
the profile key hierarchy and `SecureProfileFile`.

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
- `xprsProfileScalar()` / `xprsProfilePubXonly()` (`services/xprs/xprs_sig.dart`)
  — the active profile's signing scalar and its 32-byte public key (derived
  once per profile). A station never hears its own packets, so any check of
  an act this device signed itself (its acceptance of a group's offer) uses
  the second; the group key resolver in `RnsService` falls back to it for
  `XprsSelf.isMine` callsigns.
- `XprsGroupRead` (`services/xprs/xprs_group_read.dart`) — a closed group's
  reading keys (XPRS.md 10.7.1): `currentPubHex(group)` to seal a post to,
  `open(packet, senderPub)` to read one (newest key first), `learn` /
  `takeKeyMessage` on the member's side, `tend()` on the admin's (mint, renew
  on a departure, hand each member what they lack). `XprsSend.message` to an
  `X5` uses it, and `WappDelivery` opens sealed group posts with it.
- `XprsGroupRead.modeOf/isPublic/setPrivate` — a closed group public
  (anyone reads, members post; members told `nsec:-`) or private (sealed to
  the reading key). `XprsSend.message(..., joinRequest: true)` sends a
  non-member's request to join; `WappDelivery.mayAcceptFor(group)` says
  whether this station (admin or moderator) sees and answers requests;
  `XprsGroupOps.grant/revoke` sign as a moderator when this station is one.
- `XprsGroupOps.grant(g, [c], role: 'mod')` appoints (an offer answered
  with `accept:mod`; the member keeps posting meanwhile), a plain grant to a
  moderator takes the role back; `XprsRoster.offerRoles` says which offer
  waits. Wapps: `hal_xprs_group_appoint`.
- `xprsGroupNickShown(wire)` (`xprs_group_act.dart`) — a group's `nick:` as
  people read it (`_` is a space, 10.1). Use it wherever a group's name is shown.
- `XprsGroupRead.noteSeen(group, sealed:, tsMs:)` — a station outside a
  group learns its mode from what it reads (newest post decides); the admin's
  own say is never overridden.
- `xprsCommandExpired(p)` (`xprs_vocab.dart`) — 11.4's 300 s window; nothing
  relays or holds a command past it.
- `WappDelivery.groupAuthorMayPost(dest, author, tsMs:)` — a group post judged
  by its author's role when it was written (10.4).
- `RnsService.followGroup(name, on)` / `XprsArchive.followedGroups` — an open
  group (7.3) followed by name: its talk is kept as a room's
  (`XprsIngest._isRoomTalk`), fetched by `XprsCatchup` (`only:<NAME>`) and
  served to anyone by `XprsHistoryServer` (`_fellowMember`). Wapps reach it
  with `hal_xprs_follow("PICNIC", 1)`.
- `openStoreDb(..., pageCacheBytes:)` — every store's decoded-page budget
  (`storePageCacheBytes`, 4 MB; blocks 1 MB). Ask for more only for a store
  read hard, as the packet archive does (8 MB).
- `XprsProfiles.instance.nickFor(call)` — the name a callsign gave itself in
  its verified `t:identity`. `XprsMonitor.stationsJson` rows carry it as
  `nick` for a person (`kind:user`), so a picker can say "Bea (X13SUZ)".
- `geohash`, `nostr_imeta` (NIP-92), `note_text` (`NoteMention`).
- `ActivityArchive` (`services/storage/`) — a time-ordered feed store; one
  zx store per owner.

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
- `PublicName.urls` / `PublicName.pending` + `WebChatApi.addresses` — what
  works now and which names still wait for the router, for the page's
  Station view (`/api/services` `urls`, `urls_pending`); any host that
  serves the web chat on the internet wires the two in one line.
- `XprsPublisher.setPublicUrl` / `XprsProfiles.urlFor` — a host announces
  where it serves the web chat (6.3.2 `url:`, a decoration field) and a screen
  reads another station's; `PublicName.onUrl` feeds the first.
- `UpnpGateway` (`upnp_io.dart`) — SSDP discovery, IPv4 port mappings
  (falls back to a permanent lease), IPv6 pinholes, the router's public IPv4.

## Names for stations (`services/names/`)

- `NamesKeeper` (`names_keeper.dart`, pure Dart) — `<callsign>.<zone>` for
  any station that proves its key (XPRS.md 13.0.3): the challenge, the
  signed `t:service dial:` claim checked in order (shape, signature, key
  derives the callsign, nonce, timestamp, source address), the six-month
  lock per label, rate limits, reserved labels, the sweep and the operator's
  release. Storage (`NamesStore`, with `MemoryNamesStore`) and DNS
  (`NamesDns`) are seams, so a test drives it with fakes and a host picks
  its store. `isClaimableAddress` / `normalizeAddress` are the public-address
  rules for any service that takes an address from a client.
- `DesecDns` (`desec_dns_io.dart`) — `NamesDns` over deSEC's bulk RRset
  API, 429 as `NamesDnsBusy`; the token never leaves it.
- `NamesClient` (`names_client_io.dart`) — the station side: one claim per
  address family over a connection of that family (`HttpClient.connectionFactory`
  pinned to a looked-up address), which is how any client proves it can
  send from the address it names.
- `xprsPortAnswers` (`xprs_port_probe_io.dart`) — "does that station really
  answer on its port": a `t:ping` that must come back as a `t:pong` signed by
  the expected key. Use it wherever "the port is open" is not enough.
- `unmappedAddress` (reticulum-dart, `rns_tcp_server_interface.dart`) — an
  IPv4 peer on a dual-stack socket as the IPv4 address it is; every private
  range or label check on such a socket goes through it.
- `PublicName.extraNames` — the hook by which a host adds names it got
  elsewhere to the ones tested and certified; they go first, so the first
  reachable becomes the station's URL.

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
| `WebChatApi.hostSwitches` + `WebChatApi.settingsKey` | `services/web_chat_api.dart` | a true/false the HOST owns (the server's `auto_update`) set from Administration like any setting, stored with the station's and reported in `settings`; the host reads it back from its KeyValueStore under `settingsKey` even when the API is not running (the server's `update` command does, from a timer). Add a host's own switch here instead of a new endpoint |

### The trusted stations — `WebChatApi.trustedSet()` / `syncSet()`

One answer to "whom does this station trust": the administrator's list in
`named` mode, a mesh group's roster in `mesh` mode, nobody in `open` mode,
cached for 30 seconds. `syncSet()` is the few of them this station asks
(`syncFanout`, rotated weekly). Whatever needs the trusted stations (serving,
the mirror's pairs, the mesh policy's snapshot) asks these two, never the
settings directly.


- **Files by reference over HTTP** (`WebChatApi`, `/api/xprs/file/<ref>`):
  GET serves the bytes of a held public file from the injected `fileStore`
  (the mesh's `MeshService.instance.media`, the store every file lane ends
  in), gated by `XprsFileServer.instance.authorize` as an unsigned caller;
  POST keeps bytes that hash to the reference as a stranger's deposit
  (`putHosted`, tier 2). `WebChatReply.bytes` is the non-JSON reply both
  socket halves write. The app's share server and the server edition read
  the request body the same way, so that reading (raw bytes for the file
  route, text otherwise, one cap each) is a candidate to move here as one
  `*_io.dart` helper.

- **`CoreHost.requestHub(reason, hold)`**: ask for a public hub for a while,
  from the core, without knowing who provides it. A phone on battery holds
  none (the normal profile, app docs/performance.md 8.20); the app wires this
  to `RnsSession`, and the default does nothing (a server's hubs are always
  up). Call it at the moment a transfer or a directed wire needs the shared
  transport (`cmd:file` answered 202, an internet fetch, a wire for the
  Reticulum bearer), idempotently, never checking first.
- **`CoreHost.radioAllowed()` + `RnsService.radioGranted()`**: whether the
  host may use Bluetooth right now (an Android runtime permission the person
  can refuse). While false, no BLE interface is built (`start(mode:'ble5'|
  'ble')` throws "Bluetooth not granted", the edge bridge is skipped), so the
  node never reports itself up on a radio it cannot use. The host calls
  `radioGranted()` when it turns true; a node up on a hub adds its BLE side
  then. Default: allowed (the server edition never asks).
- **The line lane** (`xprs_dial.dart`, `xprs_line.dart` with its `_io`/`_stub`
  halves): one idle socket from a phone to its archiver (XPRS.md 13.0.2), the
  conditional export keeping `dart:io` off the web build. Moved here from the
  app with the battery work.


## The visitor API over Reticulum (`services/web_chat_rns.dart`)

`serveWebChatOverRns(api)` serves `WebChatApi.handle` over Reticulum links to
the station's xprs/wapp destination (`/xprs/api`) and lets a client check the
station (`/xprs/prove`): spec/API-HTTP.md, "The same API over a Reticulum
link". `RnsService.serveRequests(path, handler)` is the general hook for any
request handler on that destination; `attachFrameClient` attaches a gateway
client; `stationIdentity(call)` and `ownWappAnnounce()` serve resolution.
The app can call `serveWebChatOverRns` for its share server the same way.

## Visiting a station's API (`services/station/`)

The visitor's side of spec/API-HTTP.md: what the portal page does in
JavaScript, in Dart, one client for every deployment that serves the API
(firmware, server, phone).

- `StationVisits.instance.to(call)` opens the Reticulum link, checks the
  station's proof (`stationProofFault`) and returns a `StationVisit`; unused
  visits close after five minutes. `faultOf(call)` says why there is none.
- `stationWebChatApi(...)` (services/station/station_host.dart) is THE wiring of
  the visitor API, hosted rooms included: the server and the app both build
  theirs from it and add only what a host has (settings store, its network,
  the download page). Never wire a `WebChatApi` by hand again.
- `StationHost.instance`: this node as a station. `api` (set once by the
  host), `own()` (the owner's `StationVisit` on its own API, no link),
  `ensureOwner()` (the owner is the administrator before a guest can claim),
  `serve(on)` (answer visitors over Reticulum; off answers "not here" at
  once). `StationVisits.to(<own callsign>)` returns `own()`.
- `StationShare.instance.add(kind:, folder:, paths:, private:)` files what the
  owner picked in a room of that kind, as the page uploads (preview, file,
  item, `t:file`), streamed from disk. `stationSlug`, `stationSizeWord` are
  the page's `slugOf` and `galSize`.
- `webChatLinkProof(api, data, linkId)`: the `/xprs/prove` answer, for any
  host of the API.
- `RnsService.offersApi(call)` / `stationRequests(call)`: whether a station can be
  visited, and the link to it. They resolve the station's identity from its API
  announce, its beacon's `lx:`, or a named announce kept across restarts: ask
  these, never wait for one particular announce.
- `StationVisit`: `services()`, `session()` (posts the profile's identity on
  a 409, as the page does), `rooms()`, `topics(room)`, `collection(room)`
  (the page's `galTree` as `StationCollection`, read a page at a time with
  `into:`), `file(ref)`, `fileParts(ref, onPart, from:)` for a file of any
  size (`Range` over the link, resumable), `send(wire)` signed as the visitor.
- `StationCarrier` is the only thing that knows the transport.
  `stationLinkCarrier(RnsRequestClient)` for a link; `stationRequestCarrier`
  over anything that takes the `/xprs/api` request map, which is how
  `test/station_api_test.dart` runs every call against a real `WebChatApi`
  through `webChatLinkAnswer`. Write new client features against that test.
- `tool/station_visit.dart <gateway> <call>` runs the same client against a
  live station from a computer.

## DeviceIdentity (lib/src/profile/device_identity.dart)

The install's own `X3`: `ensure()` loads or makes it (public half in
`station/device.json`, private half in `CoreHost.secureStore` when there is a
keychain), `callsign`, `npub`, `scalar` to sign with, `isDevice(call)`,
`owners()` (the profiles on this device, active first, max four). Use it
whenever a packet states a fact about the machine rather than the person.

### Who may fetch a file — `WebChatApi._mayFetch`, `XprsFileAcl.groupOf` / `isOpen` / `openGroup`

XPRS.md 11.2 for the visitor API: a file posted in a hosted room
(`_bindRoomFiles` after `keep`, or `?room=` on an upload via `_uploadRoom` /
`_bindUpload`) is bound to that room in `XprsFileAcl` as a `group`, and every
GET (`_fileGet`, `openFile(session:)`) asks `_mayRead(room, session)` at that
moment, so a room's visibility is read live. `isOpen(sha)` is the one answer
for "anyone may have it" (unbound, public, or a group the host says is open
through `openGroup`); the mesh's `cmd:file` gate in `MeshService` uses it.
Anything that serves bytes by hash should ask `_mayFetch`/`isOpen`, never
`scopeOf` alone.

### Choosing a key by its callsign — `XprsGroupKeys.candidates` / `create(callsign:)`

A callsign derives from its key (XPRS.md 26.1), so "let the person pick the
callsign" means minting several keys and keeping the picked one.
`candidates(n)` mints n keys held in memory only (never stored, replaced by
the next call, spent by `create`) and returns their callsigns;
`create(nick:, callsign:)` / `XprsGroupOps.create(callsign:)` keeps the one
picked and mints fresh for anything else. About 45 ms per key on the Pi.

### Who is there by name — `XprsArchive.names`, `XprsNames.find`, `XprsCatchup.askNames`

The archive keeps a `names` table (callsign, newest nick, last announced,
a folded match key) beside the identities themselves, refreshed where
`_collapseIdentities` runs and only from VERIFIED rows, so a name search
never scans the spool. `XprsNames.find(query:, kind:, self:, ask:)` reads it
sorted into `user` / `station` / `group` and is what `hal_xprs_names` returns.
It is filled by what this station hears AND by `XprsCatchup`'s names pull:
`cmd:history kind:identity since:<mark>` to the named and always-on
archivers, a persisted mark per archiver (`names@<call>` in the catch-up
marks), a year back the first time, every 30 min, or now on `askNames()`
(XprsNames bounds that to once a minute). `CoreState.names` fires when an
identity is stored. Anything that lists people, stations or groups reads
this, never only the heard table.

### The archiver's name: `XprsArchive.archiverName` and `DeviceIdentity`

- `XprsArchive.instance.archiverName` is the callsign the archive answers,
  announces and holds mail under: the device's X3 where the install has one,
  the profile otherwise. Use it for anything the archiver says about itself
  (`hold:` offers, holders, status) rather than `tableCallsign`.
- `XprsHistoryServer._keyFor(self)` picks the signing key by the `f:` being
  written: the device scalar for the X3, `signingKey` (the person) otherwise.
  The publisher does the same for any non-verbatim wire `f:<X3>`, so a
  caller writing as the X3 needs no key of its own.
- `MeshService._archiverFields()` is the one source of `serve:`/`dial:`/
  `room:`/`mail:` for both observations; only one of the two carries them.
- `RnsService._lxmfAlias` holds a station's second name on an LXMF address
  shared with its person; `lxmfDestForCallsign` consults it after the
  observed table. `_noteStationSender` fills it from a station's own signed
  wire that arrived over LXMF (signature checked only on a change).
- Archiver dials: `PreferencesService.xprsArchiverDials` is the effective
  map (heard, overlaid by hand); `rememberArchiverDial` writes only what was
  heard, `setArchiverDialByHand` only what the person typed (null clears).
  A setting the operator made must outrank one learned from the air; reuse
  this two-map pattern for any other learned-but-overridable value.
- `MeshService.redialArchivers()` applies a list/dial change now instead of
  on the minute tick. `XprsLineLane.nudge()` makes clients in a backoff dial
  at once (at most once a minute each); `RnsService.onUplinkUp` fires it when
  an internet uplink rises, i.e. the network is back.

## Choosing the station's callsign (`DeviceIdentity.candidate` / `replace`)

The X3 comes from its key (XPRS.md 3), so a new callsign is a new key:
`DeviceIdentity.candidate()` makes one (nothing stored), `replace(nsec)` keeps
it where the first key was (keychain, else `station/device.json`) and wears it
at once. Refused when the station key is the active profile (`isProfileKey`, a
headless server). Tests point storage at a temp folder with
`setStorageRootForTest(dir)` (storage_paths.dart) instead of the real data dir.

### Archivers known from Reticulum — `RnsService.announcedArchivers()`

`lib/src/services/reticulum/rns_service.dart`. A view over the existing
relay directory (`relayDirectory.archivers()`, fed by
`_observeRelayAnnouncement` from the dedicated `xprs/relay` announce and the
relay announcement riding the chat announce after a NUL): the archivers that
are stations (X2, X3) and announced a callsign, freshest first, with uptime.
Use it wherever a station needs an archiver it cannot hear on the air:
`MeshService._reconsiderArchiver` offers them to `XprsArchiverChoice` as
`rns` offers. Never hard-code an archiver, and never keep a second list of
them: the relay directory is the one record of who archives.

### An archiver's directory over the internet — `cmd:history kind:service only:<archiver>`

`XprsCatchup._askDirectories`. An archiver's `t:service` (which names its
directory and groups index) rides its radio and LAN only; a chosen archiver
not heard on the air is asked for its own announcements of the last hour,
at most every 30 minutes. The replay enters through the receive door and
`XprsDirectoryConsumer.offer` reads it like a heard one. The same shape
(one type, one station, a short window) fits any "latest record of X from
its holder" need.

## Found on the phone, 2026-11-22

- `XprsPeople.disown(callsign, type, value)`: take an identity off a callsign's
  record when proof contradicts it. `RnsService.stationIsNot(call, identity)`
  uses it after a visit proof names another station, and `StationVisits`
  then tries the next address (`stationProofOther` is how that fault begins).
  Reuse the pattern wherever a claimed address can be tested: the test
  decides, and the wrong claim is removed instead of being asked again.
- `XprsIdType.normalise` takes an address or node number the way people write
  it (`aabbccddeeff`, `aa-bb-..`, `!a1b2c3d4`). Validate typed identities
  through it; do not add a second parser in a screen.
- `RnsService._dmDecoded`: a result keyed by a content hash is computed once
  (verify, decrypt), including the failure. Same rule for anything polled:
  the poll may repeat, the work on an unchanged item may not.
- `rnsArrivedLocally(via, wireHops)` and `rnsIfaceBearer(via, wireHops:)`
  (`rns_iface_kind.dart`): whether something came from nearby is the
  interface AND the hop count. Never name a bearer or call a node local from
  the interface label alone.
- `MeshCourier.keyLearned` / `XprsIngest.onKeyLearned`: the one hook for
  "this callsign's key is known now", fired from the identity packet and from
  `RnsService.recordCallsignPubkey`. Anything that waits for a key listens
  there instead of polling.
- `XprsGroupDeposit` (`xprs_group_deposit.dart`): a group's record handed to
  this station's archivers (10.9.2), one group and one archiver a turn, each
  pair once a week, due again after a new act. The pattern for anything that
  must reach a station that is not an addressee: injected seams, driven from
  the minute sweep, a per-pair mark in the key-value store.
- `XprsArchive.query` keeps the answer to a standing question (the newest
  undirected rows of some types, in a room or not) and patches it with what
  was filed since (`_rooms`, `roomHits`/`roomScans`). The archive engine
  scans for these whatever index exists: do not add another polled query
  that filters on `wire` or on several types without going through it.
  `tool/room_time.dart <archive.zx>` times the page's questions on a real file.
- `XprsFetch.requestKey(call, first: [...])`: ask named stations before the
  archivers. The carriers in a packet's `via:` are in reach by construction;
  use this whenever the thing needed is likely to be where the packet came
  from.
- A placeholder is not a delivery (`MeshCourier.deliverXprs(notice: true)`):
  nothing that stands in for content may acknowledge it, or the holders
  release what nobody read.
- `XprsArchive.flushInSlices()`: periodic database work goes a few rows at a
  time with the event loop given a turn between (the screen and the touches
  share this isolate). `flush()` stays for a caller that needs it written
  now. `tool/flush_time.dart <archive.zx>` measures a flush on a real file.
- `XprsOutbox.noteKept` / `keptAt`: where a message this station sent is kept
  (`held`: a station said so, `handed`: a copy was sent to an archiver).
  `XprsIngest.noteHeld` takes a station's signed `t:observation s:held r:<id>`.

## A periodic job that names its own slow step

`mesh_service.dart` (the minute sweep: `lap('held')`) and
`xprs_archive.dart` (`_laps`, read by `flushInSlices`): a stopwatch and a
`lap(name)` after each step, collected only when a step costs 50 ms or more
and logged as one `perf: <job> took Nms (step=Nms ...)` line only when the
whole turn is felt (250 ms). Silent otherwise. Use it for any new periodic
job on the one isolate instead of guessing which step is slow; the app's
`docs/performance.md` 8.26 and 8.27 are two stalls it named.

## A store written on its own thread, read where it is

`XprsArchive` + `xprs_archive_writer_io.dart`: a long-lived isolate opens
the same zx file and runs the class's own write code (`openWriter`,
`writeBatch`), fed batches of plain data by the main isolate and answering
with what the main isolate must update (counters, caches, hooks). Reads stay
synchronous on the main isolate: zx shows each isolate the other's commits
on the next statement. Counters both sides write are stored as additions
(`_countsDelta`). Reuse this shape for any other store whose periodic write
shows up as a stall; the web build keeps an inline path behind a
conditional export (`xprs_archive_writer.dart`).

## StoreWorker: a store's writes on a thread of their own

`lib/src/storage/store_worker.dart` (`startStoreWorker(path, secret,
factory)`): a long-lived isolate opens the same zx file through a static
factory that returns a `StoreWorkerTarget`, and runs named operations in
order (`post` without waiting, `call` with an answer). The main isolate
keeps reading the file directly. First users: the observed-node cache
(`ObservedStore.openForWorker`); the archive writer predates it and has
the same shape. Reach for it whenever a store's periodic write shows up in
`perf: main isolate held ... by timer from ...`.

## StallWatch: name what holds an isolate

`lib/src/platform/stall_watch.dart`: a zone that times every callback and
logs any that holds the isolate 250 ms or more, naming a timer by where it
was created. On in the app and the server. Read its lines before changing
anything for a pause.

## HttpTransport.request maxBytes

`HttpTransport.shared.request(..., maxBytes: n)` reads at most n bytes of
the answer and drops the rest of the download. For any answer whose size is
not known to be small.
