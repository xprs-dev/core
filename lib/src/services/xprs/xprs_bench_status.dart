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
import 'xprs_archive.dart';
import 'xprs_catchup.dart';
import 'xprs_files.dart';
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
Map<String, dynamic>? xprsBenchStatus(String path) => switch (path) {
      kXprsArchiverStatusPath => xprsArchiverStatusMap(),
      kXprsFilesStatusPath => xprsFilesStatusMap(),
      _ => null,
    };

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
  if (from.isEmpty || sha.length != 64) {
    return {'ok': false, 'error': 'from and sha256 (64 hex) are required'};
  }
  if (self.isEmpty) return {'ok': false, 'error': 'no callsign yet'};
  final secs = int.tryParse('${body['timeoutSeconds'] ?? ''}') ?? 120;
  final sw = Stopwatch()..start();
  final path = await XprsFileFetch.instance.fetch(
    archiver: from,
    shaHex: sha,
    selfCallsign: self,
    ext: ext,
    timeout: Duration(seconds: secs.clamp(5, 3600)),
  );
  return {
    'ok': path != null,
    if (path != null) 'path': path,
    if (path == null) 'error': 'not fetched (refused, unanswered or timed out)',
    'elapsedMs': sw.elapsedMilliseconds,
  };
}
