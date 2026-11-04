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

## Seams and small utilities

- `NostrSigner` / `LocalSigner` — "this program can sign as you" without
  holding the key; take a signer, not an nsec.
- `LogService` — the in-memory ring buffer behind `/api/log`.
- `db_bytes` — the size of a sqlite database, on every platform.
- `geohash`, `nostr_imeta` (NIP-92), `note_text` (`NoteMention`).

## Moving code here from the app

The pattern used for the first 47 files, to repeat for the rest:

1. Move only a set closed under its own imports, with no Flutter or app
   service in it. Keep the app's path under `lib/src/` so relative imports
   hold.
2. Leave a one-line export shim at the old app path:
   `export 'package:xprs_core/src/<path>';`
3. Move the tests that only touch moved files; `flutter_test` becomes `test`.
4. Re-run the app's analyzer (no new errors) and `dart tool/arch_guard.dart`
   (it scans this repo with the app's rules).

What blocks the next files is listed in the README. It's mostly
`xprs_sig.dart`'s reach into the app's `ProfileService`, which wants a
`NostrSigner`-style seam.
