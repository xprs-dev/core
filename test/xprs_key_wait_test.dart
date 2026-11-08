/*
 * A direct message whose recipient's key is not known yet waits in the
 * outbox, the key is looked for, and the message leaves sealed when it
 * lands (XPRS.md 6.2, 6.4, 12.12.1). Every seam injected: no store, no radio.
 */
import 'package:test/test.dart';
import 'package:xprs_core/src/services/xprs/xprs_key_wait.dart';

void main() {
  final w = XprsKeyWait.instance;
  late Map<String, String> keys;
  late List<String> asked;
  late List<String> sealed;
  late List<String> reports;
  late int now;

  setUp(() {
    w.debugReset();
    keys = {};
    asked = [];
    sealed = [];
    reports = [];
    now = 1700000000000;
    w
      ..nowMs = (() => now)
      ..keyFor = ((c) => keys[c])
      ..ask = ((c) => asked.add(c))
      ..seal = ((dest, text) {
        if (keys[dest.split('-').first] == null) return '';
        sealed.add('$dest:$text');
        return 'abc123';
      })
      ..report = (held, peer, state, {String newId = ''}) =>
          reports.add('$held|$peer|$state|$newId');
  });

  test('holding names the message and goes looking for the key', () {
    final id = w.hold('x1boa3', 'meet at the bridge');
    expect(id, matches(RegExp(r'^[0-9a-f]{6}$')),
        reason: 'the same shape as a section 5 identifier');
    expect(w.isHeld(id), isTrue);
    expect(asked, ['X1BOA3']);
    expect(sealed, isEmpty, reason: 'nothing goes out unsealed, or at all');
  });

  test('the key arriving sends it sealed and reports the real identifier', () {
    final id = w.hold('X1BOA3', 'meet at the bridge');
    keys['X1BOA3'] = 'ff' * 32;
    w.keyLearned('X1BOA3');
    expect(sealed, ['X1BOA3:meet at the bridge']);
    expect(reports, ['$id|X1BOA3|sent|abc123']);
    expect(w.isHeld(id), isFalse);
  });

  test('a key from one of the person\'s devices releases mail to the person',
      () {
    w.hold('X1BOA3', 'hello');
    keys['X1BOA3'] = 'ff' * 32;
    w.keyLearned('X1BOA3-2');
    expect(sealed, hasLength(1));
  });

  test('a key for somebody else releases nothing', () {
    final id = w.hold('X1BOA3', 'hello');
    keys['X1RD89'] = 'ff' * 32;
    w.keyLearned('X1RD89');
    expect(sealed, isEmpty);
    expect(w.isHeld(id), isTrue);
  });

  test('two identical messages are two rows', () {
    final a = w.hold('X1BOA3', 'ok');
    final b = w.hold('X1BOA3', 'ok');
    expect(a, isNot(b));
    expect(w.rows, hasLength(2));
  });

  test('taking one back drops it without airing anything', () {
    final id = w.hold('X1BOA3', 'never mind');
    expect(w.release(id), isTrue);
    expect(w.isHeld(id), isFalse);
    expect(w.release(id), isFalse, reason: 'only once');
    keys['X1BOA3'] = 'ff' * 32;
    w.keyLearned('X1BOA3');
    expect(sealed, isEmpty);
  });

  test('a message nobody\'s key came for in a month is given up on', () {
    final id = w.hold('X1BOA3', 'hello');
    now += XprsKeyWait.maxAge.inMilliseconds + 1;
    w.sweep();
    expect(w.isHeld(id), isFalse);
    expect(reports, ['$id|X1BOA3|expired|']);
  });

  test('resume sends what a restored key allows and asks for the rest', () {
    w.hold('X1BOA3', 'one');
    w.hold('X1RD89', 'two');
    asked.clear();
    keys['X1BOA3'] = 'ff' * 32;
    w.resume();
    expect(sealed, ['X1BOA3:one']);
    expect(asked, ['X1RD89']);
  });

  test('the outbox is bounded and says which one it dropped', () {
    final first = w.hold('X1BOA3', 'm0');
    for (var i = 1; i < XprsKeyWait.maxRows; i++) {
      w.hold('X1BOA3', 'm$i');
    }
    expect(reports, isEmpty);
    w.hold('X1BOA3', 'one too many');
    expect(w.rows, hasLength(XprsKeyWait.maxRows));
    expect(reports.single, startsWith('$first|X1BOA3|expired'));
  });
}
