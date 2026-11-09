// Files by reference through the visitor API (spec/API-HTTP.md
// /api/xprs/file/<ref>, XPRS.md 7.7): stored only when the bytes hash to the
// reference, read back by anyone while public, refused when private.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:reticulum/reticulum.dart';
import 'package:test/test.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_files.dart';

String _ref(List<int> bytes, String ext) =>
    '${base64Url.encode(crypto.sha256.convert(bytes).bytes).replaceAll('=', '')}.$ext';

void main() {

  late Directory dir;
  late MediaArchive store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('web_chat_file_');
    store = MediaArchive.forDirectory(dir.path);
  });
  tearDown(() {
    XprsFileServer.instance.authorize = null;
    dir.deleteSync(recursive: true);
  });

  WebChatApi make({bool files = true, int max = 1000}) => WebChatApi(
        publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) => [],
        held: (t) => 0,
        receive: (_) {},
        mayAir: (_) => true,
        selfCallsign: () => 'X3PTZM',
        keyOf: (_) => null,
        appPath: () => null,
        fileStore: files ? () => store : null,
        fileMax: max,
      );

  final png = Uint8List.fromList(List.generate(300, (i) => i * 13 & 0xff));

  test('services says what files it serves, and a host without a store says nothing', () async {
    final sv = (await make().handle('GET', '/api/services', {}, '')).json;
    expect(sv['file'], {'get': true, 'put': true, 'max': 1000});
    expect((await make(files: false).handle('GET', '/api/services', {}, '')).json['file'], isNull);
    final r = await make(files: false).handle('GET', '/api/xprs/file/${_ref(png, 'png')}', {}, '');
    expect(r.status, 404);
  });

  test('stored when the bytes match, then served with its type', () async {
    final api = make();
    final ref = _ref(png, 'png');
    expect((await api.handle('GET', '/api/xprs/file/$ref', {}, '')).status, 404);
    final put = await api.handle('POST', '/api/xprs/file/$ref', {}, '', peer: 'a', raw: png);
    expect(put.status, 200);
    expect(put.json['size'], 300);
    final got = await api.handle('GET', '/api/xprs/file/$ref', {}, '');
    expect(got.status, 200);
    expect(got.bytes, png);
    expect(got.contentType, 'image/png');
    expect(got.headers['Cache-Control'], contains('immutable'));
    // The 64-hex form names the same file.
    final hex = crypto.sha256.convert(png).toString();
    expect((await api.handle('GET', '/api/xprs/file/$hex.png', {}, '')).bytes, png);
  });

  test('refused: wrong bytes, too large, not a reference, no bytes', () async {
    final api = make();
    final other = Uint8List.fromList([1, 2, 3]);
    expect((await api.handle('POST', '/api/xprs/file/${_ref(png, 'png')}', {}, '', peer: 'a', raw: other)).status, 400);
    final big = Uint8List(1001);
    expect((await api.handle('POST', '/api/xprs/file/${_ref(big, 'bin')}', {}, '', peer: 'a', raw: big)).status, 413);
    expect((await api.handle('POST', '/api/xprs/file/hello.png', {}, '', peer: 'a', raw: png)).status, 400);
    expect((await api.handle('POST', '/api/xprs/file/${_ref(png, 'png')}', {}, '', peer: 'a')).status, 400);
    expect((await api.handle('GET', '/api/xprs/file/${_ref(png, 'png')}.', {}, '')).status, 400);
  });

  test('a private file is not served to a visitor who proved nothing', () async {
    final api = make();
    final ref = _ref(png, 'png');
    await api.handle('POST', '/api/xprs/file/$ref', {}, '', peer: 'a', raw: png);
    XprsFileServer.instance.authorize = (sha, who, {required bool sigVerified}) => sigVerified;
    expect((await api.handle('GET', '/api/xprs/file/$ref', {}, '')).status, 403);
  });
}
