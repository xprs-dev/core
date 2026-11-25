// What GET /api/xprs/history hands a visitor by packet type (spec/API-HTTP.md):
// conversation by default, and a station's `t:service` announcements only
// when asked for by name, which is how a browser with no station of its own
// finds archivers to keep its mail (XPRS.md 12.9).
import 'package:test/test.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';

void main() {
  late List<List<String>> asked;

  WebChatApi make() => WebChatApi(
        publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) {
          asked.add(List.of(types));
          return <Map<String, dynamic>>[];
        },
        held: (_) => 0,
        receive: (_) {},
        mayAir: (_) => true,
        selfCallsign: () => 'X3PTZM',
        keyOf: (_) => null,
        appPath: () => null,
      );

  setUp(() => asked = []);

  Future<List<String>> typesFor(String? kind) async {
    asked = [];
    final r = await make().handle('GET', '/api/xprs/history', {if (kind != null) 'kind': kind}, '');
    expect(r.status, 200);
    return asked.single;
  }

  test('service announcements come when named', () async {
    expect(await typesFor('service'), ['service']);
    expect(await typesFor('identity,service'), ['identity', 'service']);
  });

  test('and never in the default listing', () async {
    final none = await typesFor(null);
    expect(none, isNot(contains('service')));
    expect(none, contains('message'));
    expect(await typesFor('command'), isNot(contains('command')));
  });
}
