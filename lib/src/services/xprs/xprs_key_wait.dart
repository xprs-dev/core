/*
 * xprs_key_wait — messages that wait in the outbox for a key.
 *
 * A direct message is sealed by default (XPRS.md 6.4), and sealing needs the
 * recipient's public key, which comes from their `t:identity` (6.3). Until
 * that binding has been heard, a sealed message cannot be made. The old answer
 * was to refuse the send and tell the person to try again, which made them
 * do the core's waiting for it. Two things are true instead:
 *
 *   - a refusal to seal is still never a quiet downgrade to plain text
 *     (plaintext is a disclosure), so nothing here goes out unsealed; and
 *   - the words are not lost either. They wait HERE, in the profile's
 *     encrypted store, and leave sealed the moment the key lands.
 *
 * While a message waits the core goes looking for the key: `q:identity` to the
 * station itself (section 8) and `cmd:history kind:identity only:X` to the
 * chosen archivers (12.12.1, through XprsFetch), which keep `t:identity` as a
 * publication (12.1). The key arrives through the ordinary receive door,
 * `XprsIngest` verifies its self-signature and binds it, and
 * `RnsService.recordCallsignPubkey` calls [keyLearned].
 *
 * A waiting message has no section 5 identifier yet: the identifier covers
 * `x:`, and there is no `x:` until it is sealed. So it is named by a held id
 * of the same shape (6 hex), which the wapp keys its bubble on; when the
 * message finally goes, `xprs.status.tx` says `sent` for the held id and
 * carries `newId`, the real identifier, so the bubble moves to it and a
 * receipt naming the real one finds it.
 *
 * The wapp is not told how the key is found, and does not ask. It can only do
 * the two things that are the person's to decide: wait, or take the message
 * back (`hal_xprs_withdraw` on a held id, which drops it here without airing
 * anything) and send it again in the open.
 *
 * Every send, clock and lookup is injected, so the whole wait runs in a unit
 * test (test/xprs_key_wait_test.dart).
 */
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../storage/store_db.dart';
import '../log_service.dart';

/// One message waiting for its recipient's key.
class KeyWaitRow {
  KeyWaitRow(this.id, this.dest, this.text, this.ms);

  /// The held id the wapp keys its bubble on (6 hex, the §5 shape).
  final String id;

  /// The recipient, as the sender addressed it.
  final String dest;

  /// The words. Never logged.
  final String text;

  /// When it was handed to the core.
  final int ms;
}

class XprsKeyWait {
  XprsKeyWait._();
  static final XprsKeyWait instance = XprsKeyWait._();

  /// Bounded: an outbox, not a mail store. Past it the oldest goes, and the
  /// wapp is told that one `expired`.
  static const int maxRows = 200;

  /// A message nobody's key arrived for in this long is given up on, and the
  /// wapp says so on the bubble. A month is longer than any station stays
  /// silent while still being somebody's correspondent.
  static const Duration maxAge = Duration(days: 30);

  // ── seams, wired by the core (mesh_service); null does nothing ─────────

  /// The recipient's key as hex, or null while it is unknown.
  String? Function(String call)? keyFor;

  /// Go and find [call]'s key: the station itself, and the archivers.
  void Function(String call)? ask;

  /// Seal and send now that the key is known. Returns the §5 identifier of
  /// what went out, or '' when it still could not be sealed.
  String Function(String dest, String text)? seal;

  /// What became of a held message: `sent` with the real [newId], or
  /// `expired`. The wapp's bubble follows this.
  void Function(String heldId, String peer, String state, {String newId})?
      report;

  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  final Map<String, KeyWaitRow> _rows = {};
  ZxSqlDb? _db;
  ZxKvStore? _kv;
  int _seq = 0;

  static int heldTotal = 0, released = 0, withdrawn = 0, expired = 0;

  /// Open the store, bring back what was waiting when the app last closed,
  /// and look for the keys again: a restart is not a reason to stop.
  void init(String path) {
    close();
    try {
      // KV `wait`: the held id as key, {dest, text, ts} as JSON.
      final db = openStoreDb(path);
      _db = db;
      final kv = _kv = db.kv('wait');
      final rows = <KeyWaitRow>[];
      for (final e in kv.scan()) {
        final m = jsonDecode(e.valueString) as Map;
        rows.add(KeyWaitRow(e.keyString, m['dest'] as String,
            m['text'] as String, m['ts'] as int));
      }
      rows.sort((a, b) => a.ms.compareTo(b.ms));
      for (final row in rows.take(maxRows)) {
        _rows[row.id] = row;
      }
      if (_rows.isNotEmpty) {
        LogService.instance.add(
            'XPRS: ${_rows.length} message(s) still waiting for a key');
      }
    } catch (e) {
      _db = null;
      _kv = null;
      LogService.instance.add('XPRS: key-wait store unavailable ($e)');
    }
  }

  /// Ask again for every recipient still owed a key, and send what can go.
  /// Called once the identity replays are restored, so a key already on disk
  /// releases its mail at once instead of after the next announcement.
  void resume() {
    sweep();
    for (final d in {for (final r in _rows.values) _base(r.dest)}) {
      if (keyFor?.call(d) != null) {
        keyLearned(d);
      } else {
        ask?.call(d);
      }
    }
  }

  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
    _kv = null;
  }

  /// Keep [text] for [dest] until its key arrives, and start looking for the
  /// key. Returns the held id.
  String hold(String dest, String text) {
    sweep();
    final d = dest.trim().toUpperCase();
    final now = nowMs();
    final id = _newId(d, text, now);
    while (_rows.length >= maxRows) {
      final oldest = _rows.values.first;
      _drop(oldest.id);
      expired++;
      report?.call(oldest.id, oldest.dest, 'expired');
    }
    final row = KeyWaitRow(id, d, text, now);
    _rows[id] = row;
    heldTotal++;
    try {
      _kv?.putString(id, jsonEncode({'dest': d, 'text': text, 'ts': now}));
    } catch (_) {}
    LogService.instance.add('XPRS: message to $d waits for its key');
    ask?.call(_base(d));
    return id;
  }

  /// Is [id] a message waiting here?
  bool isHeld(String id) => _rows.containsKey(id.trim().toLowerCase());

  /// The person took it back, to send in the open or not at all. Nothing was
  /// aired, so there is nothing to withdraw on the wire. True when it was here.
  bool release(String id) {
    final k = id.trim().toLowerCase();
    if (!_rows.containsKey(k)) return false;
    _drop(k);
    withdrawn++;
    return true;
  }

  /// A key was bound for [call]: everything waiting for that person goes now,
  /// sealed. The bare callsign is the person (3.1), so a key heard from one of
  /// their devices releases mail addressed to any of them.
  void keyLearned(String call) {
    if (_rows.isEmpty) return;
    final b = _base(call);
    final send = seal;
    if (b.isEmpty || send == null) return;
    for (final r in List.of(_rows.values)) {
      if (_base(r.dest) != b) continue;
      final newId = send(r.dest, r.text);
      if (newId.isEmpty) continue; // still not sealable; keep it
      _drop(r.id);
      released++;
      LogService.instance.add('XPRS: key for $b arrived, waiting message sent');
      report?.call(r.id, r.dest, 'sent', newId: newId);
    }
  }

  /// Give up on what has waited past [maxAge].
  void sweep() {
    final cut = nowMs() - maxAge.inMilliseconds;
    for (final r in List.of(_rows.values)) {
      if (r.ms >= cut) continue;
      _drop(r.id);
      expired++;
      report?.call(r.id, r.dest, 'expired');
    }
  }

  /// Waiting messages, oldest first: for the remote API and tests.
  List<KeyWaitRow> get rows => List.unmodifiable(_rows.values);

  Map<String, dynamic> get json => {
        'waiting': _rows.length,
        'for': {for (final r in _rows.values) _base(r.dest)}.toList(),
        'held': heldTotal,
        'released': released,
        'withdrawn': withdrawn,
        'expired': expired,
      };

  void _drop(String id) {
    _rows.remove(id);
    try {
      _kv?.deleteString(id);
    } catch (_) {}
  }

  /// A held id: 6 hex like a §5 identifier, from who, what, when and a
  /// counter, so two identical messages a second apart are two rows.
  String _newId(String dest, String text, int now) {
    while (true) {
      final h = sha256
          .convert(utf8.encode('keywait|$dest|$now|${_seq++}|$text'))
          .toString()
          .substring(0, 6);
      if (!_rows.containsKey(h)) return h;
    }
  }

  static String _base(String c) => c.trim().toUpperCase().split('-').first;

  /// Tests: forget everything, seams included.
  void debugReset() {
    close();
    _rows.clear();
    _seq = 0;
    heldTotal = released = withdrawn = expired = 0;
    keyFor = null;
    ask = null;
    seal = null;
    report = null;
    nowMs = () => DateTime.now().millisecondsSinceEpoch;
  }
}
