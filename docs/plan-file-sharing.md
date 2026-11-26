# Plan: large files over Reticulum (2026-11-26)

The goal: an archiver holds large files (the Protomaps planet, 140 GB; world
maps of 45 MB to 4 GB; release artifacts), says so, other archivers mirror
them, and a browser or a phone reads byte ranges of them over Reticulum.
Every download resumes where it broke, after a dropped link or a restart.

The first files are the maps the Pi keeps in `/srv/maps`
(`server/tool/maps_monthly.sh`, monthly, resumable).

## 1. What exists and is reused

| Piece | Where | Today | Reused as |
|---|---|---|---|
| Ranged reads over a link (`Range`, 206, 256 KB parts) | `web_chat_rns.dart` `_filePart`, `web_chat_api.dart` `openFile`, `station_api.dart` `fileParts` | works, but only for files in the zx media store | the read path for browsers and phones, once it reaches files on disk |
| `GET_RANGE` / `GET_HAVE` link ops | reticulum-dart `files/file_transfer.dart` | works, bounded reads | the primitive the piece fetcher uses |
| Piece swarm: 4 holders, rarest first, verified | reticulum-dart `file_node.dart` `fetchFilePieces` | works, measured | the scheduler. Its output into one `Uint8List(size)` is replaced (§2.2) |
| Piece lists (§7.7.2) and piece hashing in bounded reads | `folders/piece_hashes.dart`, `DiskFolderManager` | works | how pieces are verified, unchanged |
| Disk folders served from disk, ranged | `folders/disk_folder.dart` `readRange` | works | where large files live (a path, not zx: performance.md §8.9) |
| Finding holders: DHT provider records, archivers' pointer sync | reticulum-dart `files/dht/*`, `social/pointer_sync_service.dart` | live | discovery, unchanged |
| `q:have` answered `full`, `bitfield` or `n/m` | `xprs/xprs_files.dart` | answered, never asked | asking a holder what it has, a partial holder included |
| XFL1 folder snapshots, `t:file kind:folder` (§7.7.3) | `xprs/xprs_folder.dart` | published, never read for sync | THE listing archivers mirror from (XPRS words, nothing new) |
| HTTPS to disk to seed (update mirror) | app `update_mirror_service.dart` | validated, 456 MB | the pattern of the maps job; the server gains it too |

Not reused for large files:
- `GET_FILE`: the whole file in one Resource, stalls on large files.
- `fetchContentAddressed`'s whole-file path, and copying into the zx store (both hold the file on the heap).
- `PartialStore`: whole-file segments, capped at about 64 GiB.
- The NOSTR op-log folders: they stay for collaborative folders in the app, but archivers sync with XFL1.

## 2. What is built

### 2.1 Files on disk are served like any held file
`openFile` finds a sha in the disk folders as well as in the media store, so
`/api/xprs/file/<sha>.pmtiles` answers ranges for `/srv/maps` over HTTP
and over the link. The server gets a setting to share a directory read-only
(`ServerConfig`, one place). The folder's hashes and piece lists are kept on
disk (an index beside the folder), so a restart does not re-hash 140 GB. A
file is hashed once, in bounded reads, off the main isolate.

### 2.2 A resumable piece fetcher
`fetchFilePieces`' scheduler, with a different sink: each verified piece is
written at its offset into `<sha>.part`, and a bitmap of verified pieces
(`<sha>.have`) is saved as it fills.
- After a dropped link, a restart or a reboot, the fetch carries on from the
  bitmap. Nothing verified is fetched twice.
- Several holders at once. A holder that sends a bad piece is dropped (as today).
- While the file is partial, the node answers `q:have` with its bitfield and
  serves the pieces it has (§7.7.2 allows it).
- When the last piece is verified, `.part` is renamed into place, never copied.

`fetchContentAddressed` uses it for any file above a threshold (one piece
list's worth). Small files keep today's path.

### 2.3 Archivers mirror each other's folders
An archiver follows a folder by its XFL1 snapshot: it compares the newest
snapshot with what it holds and fetches the missing files with §2.2.
- It is opt-in per folder, with a size budget.
- It is newest first. A file dropped from the snapshot is dropped after a grace period.
- This is §12.9.2 ("the archiver is the seeder") made real for files. Partial
  holders seed as they fill.

The maps are the first folder: the Pi publishes `/srv/maps` as a snapshot
after each monthly run, and other archivers follow it within their budget.

### 2.4 Readers
- **Browser (portal):** a PMTiles `Source` whose reads are ranged requests to
  `/api/xprs/file/<sha>.pmtiles`.
  - On a station's own page, by HTTP.
  - On xprs.dev/in, through the shell's `ask` over the gateway.
  - It tries the station in use, then other archivers in reach, then xprs.dev's world file.
  - protomaps-leaflet draws it with `flavor:'black'`.
- **Phone:** the same ranged reads for browsing. "Keep this area" fetches a
  regional file with §2.2, for use with no internet.

## 3. Steps

1. **Maps on the Pi, readable** (§2.1).
   - The disk folder is shared.
   - The hash index is kept.
   - `openFile` reaches disk files.
   - The portal draws world-z8 from the Pi over HTTP and over Reticulum.
   - Checks: core tests, then a browser screenshot at several zooms.
2. **The resumable fetcher** (§2.2).
   - Test: two server processes and a 1 GB file. The reader is killed halfway,
     restarted, finishes, and the sha is verified (`portal/test/interop_archivers.py`).
   - Then the same with two holders, one of them lying.
3. **Folder mirroring between archivers** (§2.3), with a budget, from XFL1
   snapshots. Test: a second server follows the Pi's maps folder.
4. **The app.**
   - Map regions kept offline, drawn with the black theme.
   - The update mirror moves onto §2.2, so the server can be a release mirror too.
5. **Spec and housekeeping.**
   - Update §37's status lines.
   - Make the code use `xpl` for piece lists, as the spec does.
   - Fix the old "25.2" references in `xprs_files.dart`.
   - No new wire words: a map is a file with the `pmtiles` extension.

## 4. Known faults this touches
- Two links between the same pair break the files handshake (folders.md §6): step 2 must hold up against it.
- The whole-file Resource stall (torrents.md §16.4) is avoided for large files, not fixed.
- `cmd:file` over Bluetooth stays capped at 256 MB (`maxServeBytes`). A 140 GB file does not cross a radio; regional cuts do.
- `q:have` is answered but never asked (F3): step 2 asks it.
