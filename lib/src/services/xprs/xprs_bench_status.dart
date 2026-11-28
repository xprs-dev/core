/*
 * xprs_bench_status — what a station says of its own archiver and file
 * machinery, for a test or an operator on the machine itself.
 *
 * Read-only, numbers and names, the same on every host: the app's remote API
 * and the server edition both answer `/api/xprs/archiver` and
 * `/api/xprs/files` from here, so a conformance run reads one shape whatever
 * it is driving (app docs/plan-archiver-tests.md, section 8). The server had
 * neither, which left its archiver a black box to every test.
 *
 * Each host decides WHO may ask: the app's remote API is off by default and
 * bound to loopback; the server answers a caller on the machine only. Nothing
 * here is for a visitor, and nothing here carries a person's words.
 */
library;

import 'package:reticulum/reticulum.dart' show NostrCrypto;

import '../mesh/mesh_bulk_spool.dart';
import '../mesh/mesh_service.dart';
import '../preferences_service.dart';
import '../reticulum/rns_service.dart';
import 'xprs_archive.dart';
import 'xprs_archiver_push.dart';
import 'xprs_file_index.dart';
import 'xprs_catchup.dart';
import 'xprs_files.dart';
import 'xprs_forwarder.dart';
import 'xprs_gossip.dart';
import 'xprs_line_io.dart';
import 'xprs_publisher.dart';
import 'xprs_tcp.dart';

/// The paths answered here.
const String kXprsArchiverStatusPath = '/api/xprs/archiver';
const String kXprsFilesStatusPath = '/api/xprs/files';

/// The archiver as configured and as it stands: what it announces, whom it
/// leans on, what it holds, what it handed over.
Map<String, dynamic> xprsArchiverStatusMap() {
  final prefs = PreferencesService.instanceSync;
  final counts = XprsArchive.instance.countsByTier();
  return {
    // The callsign the archive answers and announces under: the device's X3
    // (DeviceIdentity) where the install has one.
    'archiver': XprsArchive.instance.archiverName,
    'public': prefs?.xprsPublicArchiver ?? false,
    'alwaysOn': prefs?.xprsAlwaysOn ?? false,
    'alwaysOnStored': prefs?.xprsAlwaysOnStored ?? false,
    'keepFollowed': prefs?.xprsKeepFollowed ?? true,
    'quotaMb': prefs?.xprsArchiveMaxMb ?? 500,
    'maxDays': prefs?.xprsArchiveMaxDays ?? 365,
    'archivers': prefs?.xprsNamedArchivers ?? const <String>[],
    'adopted': prefs?.xprsArchiverAdopted ?? '',
    'dial': prefs?.xprsDial ?? '',
    'room': prefs?.xprsRoom ?? true,
    'roomStations': prefs?.xprsRoomStations ?? 500,
    'caredFor': XprsArchive.instance.caredFor(),
    'dials': prefs?.xprsArchiverDials ?? const <String, String>{},
    'dialsByHand': prefs?.xprsArchiverDialsByHand ?? const <String, String>{},
    'line': {
      'dialled': XprsLineLane.instance.status,
      'peers': XprsLinePeers.instance.status,
    },
    'records': {
      'own': counts.own,
      'followed': counts.followed,
      'stranger': counts.stranger,
      'total': counts.total,
    },
    'followedCallsigns': XprsArchive.instance.followed.length,
    // What this station handed to ITS archivers (XPRS.md 12), and the ones
    // it could not, which is what a silent deposit looks like.
    'deposited': XprsPublisher.instance.deposited,
    'depositNoDest': XprsPublisher.instance.depositNoDest,
    'bytes': XprsArchive.instance.spoolBytes,
    // The asking side (12.10) and gossip (12.9.4), as counters.
    'catchup': {
      'followAsks': XprsCatchup.instance.followAsks,
      'followRows': XprsCatchup.instance.followRows,
      'followRefused': XprsCatchup.instance.followRefused,
      'directoryAsks': XprsCatchup.instance.directoryAsks,
    },
    'gossip': XprsGossip.instance.statusJson(),
    // 12.8.1: held mail moved toward where its recipient is.
    'forwarder': XprsForwarder.instance.json,
    // 12.9.8: what was handed to the other archivers as it arrived.
    'handedOn': XprsArchiverPush.instance.json,
  };
}

/// The file machinery, both ends: what is served, what is being fetched and
/// from which holders, and what the bulk lane holds.
Map<String, dynamic> xprsFilesStatusMap() => {
      'server': XprsFileServer.instance.statusJson(),
      'fetch': XprsFileFetch.instance.statusJson(),
      'spool': MeshBulkSpool.instance.statusJson(),
    };

/// The reading for [path], or null when it is not one of these.
///
/// `?sha256=<64 hex>` on the files reading adds `holders_of`: the stations
/// this one knows to hold that file (12.9.2). `?call=` on the archiver
/// reading adds where that callsign is believed to be.
Map<String, dynamic>? xprsBenchStatus(String path,
        {Map<String, String> query = const {}}) =>
    switch (path) {
      kXprsArchiverStatusPath => {
          ...xprsArchiverStatusMap(),
          // `?call=X1ABCD`: where this station believes that callsign is:
          // the archivers it declared its mailbox (12.9.5) and the stations
          // that said they hear it (12.9.4).
          if ((query['call'] ?? '').trim().isNotEmpty) ..._whereIs(query['call']!),
        },
      kXprsFilesStatusPath => {
          ...xprsFilesStatusMap(),
          'index': XprsFileIndex.instance.json,
          if ((query['sha256'] ?? '').length == 64)
            'holders_of': xprsBenchHoldersOf(query['sha256']!),
        },
      _ => null,
    };

/// The stations this one knows to hold the file [shaHex], best first: what
/// it would name in `m:try` and ask on a fetch. For a test of the file index.
List<String> xprsBenchHoldersOf(String shaHex) {
  final media = MeshService.instance.media;
  if (media == null) return const [];
  return xprsKnownHolders(media, shaHex.toLowerCase(),
      max: XprsFileIndex.maxHolders);
}

/// The path of the fetch action below (the app's remote API has the same).
const String kXprsFileFetchPath = '/api/xprs/file';

/// Ask a station for a file and wait for it: `{"from": "X3HOLD", "sha256":
/// "<64 hex>", "ext": "jpg", "timeoutSeconds": 120}`. Answers when the bytes
/// have arrived and verified, or with why they did not. For a test that
/// needs to make a station fetch; the fetch is the one every other caller
/// uses (XprsFileFetch), so what it proves is the real path.
Future<Map<String, dynamic>> xprsBenchFetchFile(
    Map<String, dynamic> body) async {
  final from = (body['from'] ?? '').toString().trim().toUpperCase();
  final sha = (body['sha256'] ?? '').toString().trim().toLowerCase();
  final ext = (body['ext'] ?? '').toString().trim();
  final self = NostrCrypto.bareCallsign(MeshService.instance.tableCallsign);
  if (sha.length != 64) {
    return {'ok': false, 'error': 'sha256 (64 hex) is required'};
  }
  // Without `from`: whoever this station knows to hold it (12.9.2).
  final holders = from.isNotEmpty ? [from] : xprsBenchHoldersOf(sha);
  if (holders.isEmpty) {
    return {'ok': false, 'error': 'no holder known for that file'};
  }
  if (self.isEmpty) return {'ok': false, 'error': 'no callsign yet'};
  final secs = int.tryParse('${body['timeoutSeconds'] ?? ''}') ?? 120;
  final sw = Stopwatch()..start();
  final path = await XprsFileFetch.instance.fetch(
    archiver: holders.first,
    shaHex: sha,
    selfCallsign: self,
    ext: ext,
    timeout: Duration(seconds: secs.clamp(5, 3600)),
  );
  return {
    'ok': path != null,
    if (path != null) 'path': path,
    'from': holders.first,
    if (path == null) 'error': 'not fetched (refused, unanswered or timed out)',
    'elapsedMs': sw.elapsedMilliseconds,
  };
}

Map<String, dynamic> _whereIs(String call) {
  final c = NostrCrypto.bareCallsign(call).toUpperCase();
  return {
    'call': c,
    'holders_of': XprsArchive.instance.holdersFor(c),
    // The lanes a wire to it could take now (XprsPublisher.handTo).
    'lanes': {
      'linePeer': XprsLinePeers.instance.isConnected(c),
      'lineLane': XprsLineLane.instance.connectedTo(c),
      'station': RnsService.instance.isWappStation(c),
      'stationRoute': RnsService.instance.stationInReach(c),
      'lxmf': RnsService.instance.lxmfDestForCallsign(c).isNotEmpty,
      'lxmfRoute': RnsService.instance.reachableByCallsign(c),
    },
    'heard_by': [
      for (final s in XprsGossip.instance.whereIs(c))
        {'gateway': s.gateway, 'bearer': s.bearer, 'ts': s.tsMs, 'live': s.live},
    ],
  };
}
