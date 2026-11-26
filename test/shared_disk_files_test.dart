// Files shared from disk (docs/plan-file-sharing.md 2.1): a folder's hashes
// kept between runs, unfinished `.part` files and subfolders left out when
// asked, and a held disk file read by the visitor API in ranges.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';
import 'package:xprs_core/src/services/folders/disk_folder.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_files.dart';

String _ref(List<int> bytes, String ext) =>
    '${base64Url.encode(crypto.sha256.convert(bytes).bytes).replaceAll('=', '')}.$ext';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('shared_disk_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('top level only, no .part, hashes kept on disk and trusted while size and time hold', () {
    final share = Directory('${dir.path}/maps')..createSync();
    final a = File('${share.path}/world-z6.pmtiles')..writeAsBytesSync(List.filled(100, 1));
    File('${share.path}/planet.pmtiles.part').writeAsBytesSync([1, 2, 3]);
    Directory('${share.path}/bin').createSync();
    File('${share.path}/bin/tool.py').writeAsStringSync('x');
    final index = '${dir.path}/idx/maps.json';

    final s1 = DiskFolderSource(share.path, indexPath: index, recursive: false);
    final files = s1.scan();
    expect(files.map((f) => f.name), ['world-z6.pmtiles']);
    expect(files.single.sha, crypto.sha256.convert(List.filled(100, 1)).toString());
    expect(File(index).existsSync(), isTrue);

    // Same size and modified time, other bytes: a new source trusts the
    // index instead of re-reading 140 GB (the point of keeping it).
    final t = a.lastModifiedSync();
    a.writeAsBytesSync(List.filled(100, 2));
    a.setLastModifiedSync(t);
    expect(DiskFolderSource(share.path, indexPath: index, recursive: false).scan().single.sha,
        files.single.sha);
    // Without the index it is hashed again.
    expect(DiskFolderSource(share.path, recursive: false).scan().single.sha,
        crypto.sha256.convert(List.filled(100, 2)).toString());
  });

  test('readFileRange: bounded, clipped at the end, null past it', () {
    final f = File('${dir.path}/x')..writeAsBytesSync(List.generate(10, (i) => i));
    expect(readFileRange(f.path, 2, 3), [2, 3, 4]);
    expect(readFileRange(f.path, 8, 100), [8, 9]);
    expect(readFileRange(f.path, 10, 1), isNull);
    expect(readFileRange('${dir.path}/missing', 0, 1), isNull);
  });

  test('the visitor API reads a held disk file by range, and whole when small', () async {
    final data = Uint8List.fromList(List.generate(5000, (i) => i * 31 & 0xff));
    final f = File('${dir.path}/world-z8.pmtiles')..writeAsBytesSync(data);
    final sha = crypto.sha256.convert(data).toString();
    XprsFileServer.instance.hold(XprsHeldFile(
        path: f.path, shaHex: sha, size: data.length, name: 'world-z8.pmtiles', ext: 'pmtiles'));
    addTearDown(() => XprsFileServer.instance.drop(sha));
    WebChatApi api(int max) => WebChatApi(
          publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) => [],
          held: (t) => 0,
          receive: (_) {},
          mayAir: (_) => true,
          selfCallsign: () => 'X3PTZM',
          keyOf: (_) => null,
          appPath: () => null,
          fileStore: () => null,
          fileMax: max,
        );
    final ref = _ref(data, 'pmtiles');
    final o = api(100).openFile(ref);
    expect(o.reply, isNull);
    expect(o.size, 5000);
    expect(o.read(4990, 100), data.sublist(4990));
    expect(o.headers['ETag'], '"$sha"');
    expect((await api(100).handle('GET', '/api/xprs/file/$ref', {}, '')).status, 413);
    final whole = await api(10000).handle('GET', '/api/xprs/file/$ref', {}, '');
    expect(whole.status, 200);
    expect(whole.bytes, data);
    expect(api(100).openFile(_ref([9], 'pmtiles')).reply!.status, 404);
  });
}
