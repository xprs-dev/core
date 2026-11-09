/*
 * xprs_outbox — what this station sent, and what became of it.
 *
 * Nothing in the core could name a message it had sent. `sendLxmf` returns a
 * bool, the LXMF hash is computed and discarded, and `_lxmfRetries` deletes
 * its row at the exact moment the answer becomes interesting -- so
 * "delivered" and "gave up" were indistinguishable from outside, and
 * `lxmfPendingFor(dest) == 0` meant either. A receipt could arrive naming a
 * message and there was nothing to apply it to.
 *
 * So the tick a person sees was asserted by the WAPP: chat invented `am:`, a
 * second identifier competing with §5, and a private `?ACK <am> d|r` wire
 * that appears nowhere in the specification. This is what replaces it.
 *
 * Keyed on the §5 identifier, which is derived from the packet and never
 * transmitted, so the copy that went out over Reticulum and the copy that
 * went out over BLE are one row -- and a `t:receipt r:<id>` names it exactly
 * (§13.7.1).
 *
 * Deliberately small: an id, who it was for, a state and a timestamp. It is
 * not a message store. The words are the wapp's; this is only their fate.
 */

import 'dart:convert';

import '../../storage/store_db.dart';
import '../log_service.dart';
import '../receive/wapp_delivery.dart';

/// §13.7's states, plus the two local ones that precede any answer.
class TxState {
  /// Handed to the bearers; no answer yet.
  static const sent = 'sent';

  /// `s:ack` — it reached a device.
  static const delivered = 'delivered';

  /// `s:read` — it was opened.
  static const read = 'read';

  /// Ordered, so a late `ack` cannot walk `read` backwards.
  static const _rank = {sent: 0, delivered: 1, read: 2};
  static bool advances(String from, String to) =>
      (_rank[to] ?? -1) > (_rank[from] ?? -1);
}

class TxRecord {
  TxRecord(this.id, this.peer, this.state, this.ms);
  final String id;
  final String peer;
  String state;
  int ms;
}

class XprsOutbox {
  XprsOutbox._();
  static final XprsOutbox instance = XprsOutbox._();

  /// Bounded: a pocket, not a ledger. Oldest goes first, and losing the
  /// oldest row costs a tick on a message from hours ago.
  static const int maxRows = 500;

  final Map<String, TxRecord> _rows = {};

  static int recorded = 0;
  static int advanced = 0;
  static int unknown = 0;
  static int restored = 0;

  /// The same rows on disk.
  ///
  /// This pocket used to be session-lived, and the bench showed what that
  /// costs: a station that sends a message, is closed, and comes back to an
  /// archiver handing it the receipt has no row to advance — it logs "status
  /// only, no outbox row". Two things then go wrong. `stateOf` answers null
  /// for a message that IS delivered, so the mailbox deposits another copy of
  /// it with an archiver, and the retry ladder has nothing to stop it early.
  /// A tick is small; re-sending a delivered message to a mailbox is airtime.
  ///
  /// Profile database (SQLCipher) like [XprsFileAcl]: what this station sent
  /// is this station's business. Every write is one primary-key upsert and
  /// every read a primary-key lookup, so it is safe on the caller's isolate
  /// (docs/architecture.md §2).
  ZxSqlDb? _db;
  ZxKvStore? _kv; // KV `sent`: the message id as key, {peer, state, ts}

  /// Rows kept on disk. Larger than [maxRows] — memory holds the hot end, the
  /// file holds enough history that a receipt for yesterday's message still
  /// finds its row.
  static const int keepRows = 4000;

  void init(String path) {
    close();
    try {
      final db = openStoreDb(path);
      _db = db;
      _kv = db.kv('sent');
      _restore();
    } catch (e) {
      _db = null;
      _kv = null;
      LogService.instance.add('XPRS: outbox store unavailable ($e)');
    }
  }

  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
    _kv = null;
  }

  TxRecord _decode(String id, String json) {
    final m = jsonDecode(json) as Map;
    return TxRecord(id, m['peer'] as String, m['state'] as String, m['ts'] as int);
  }

  /// Every row on disk, oldest first (at most [keepRows]: cheap to scan).
  List<TxRecord> _all() {
    final kv = _kv;
    if (kv == null) return const [];
    final out = [for (final e in kv.scan()) _decode(e.keyString, e.valueString)];
    out.sort((a, b) => a.ms.compareTo(b.ms));
    return out;
  }

  /// Load the newest rows back into the pocket, so the common lookups stay a
  /// map read and only a receipt for something older touches the file.
  void _restore() {
    if (_kv == null) return;
    try {
      final all = _all();
      for (final r in all.skip(all.length > maxRows ? all.length - maxRows : 0)) {
        _rows[r.id] = r;
      }
      restored = _rows.length;
      if (restored > 0) {
        LogService.instance
            .add('XPRS: outbox restored $restored sent message(s)');
      }
    } catch (_) {}
  }

  void _persist(TxRecord row) {
    final kv = _kv;
    if (kv == null) return;
    try {
      kv.putString(row.id,
          jsonEncode({'peer': row.peer, 'state': row.state, 'ts': row.ms}));
      // Bound the file: every 200 records, the oldest beyond keepRows go.
      if (recorded % 200 == 0) {
        final all = _all();
        if (all.length > keepRows) {
          kv.batch((b) {
            for (final r in all.take(all.length - keepRows)) {
              b.deleteString(r.id);
            }
          });
        }
      }
    } catch (_) {}
  }

  /// What the file says about [id] when the pocket has forgotten it.
  TxRecord? _load(String id) {
    final v = _kv?.getString(id);
    if (v == null) return null;
    try {
      return _decode(id, v);
    } catch (_) {
      return null;
    }
  }

  /// Remember that we sent [id] to [peer].
  void noteSent(String id, String peer) {
    if (id.isEmpty) return;
    if (_rows.containsKey(id)) return;
    if (_rows.length >= maxRows) _rows.remove(_rows.keys.first);
    final row = TxRecord(id, peer.toUpperCase(),
        TxState.sent, DateTime.now().millisecondsSinceEpoch);
    _rows[id] = row;
    recorded++;
    _persist(row);
  }

  /// A verified receipt arrived for [id]. [state] is `ack` or `read`.
  ///
  /// Publishes the change so the wapp that drew the bubble can draw a tick on
  /// it, instead of asserting a state the core never confirmed.
  void noteReceipt(String id, {required String state, String? peer}) {
    final to = state == 'read' ? TxState.read : TxState.delivered;
    // The pocket first, then the file: a receipt for a message this station
    // sent BEFORE it was last closed is exactly the case an archiver in the
    // middle creates, and it is the one the pocket cannot answer.
    var row = _rows[id];
    if (row == null) {
      row = _load(id);
      if (row != null) _rows[id] = row;
    }
    if (row == null) {
      // No local record of sending it: the row aged out of this pocket, or the
      // outbox is empty because the app restarted (it is session-lived). The
      // tick a person SEES lives in the wapp's persistent per-message status,
      // not here, so a VERIFIED receipt must still reach it -- otherwise a read
      // receipt for an older message updates nothing and the bubble is stuck on
      // one check forever. The wapp ranks the status monotonically, so a late
      // `ack` arriving after a `read` cannot walk the bubble backwards.
      unknown++;
      if (peer != null && peer.isNotEmpty) {
        LogService.instance
            .add('XPRS: $id is $to ($peer) — status only, no outbox row');
        WappDelivery.instance.deliverStatus(id: id, peer: peer, state: to);
      }
      return;
    }
    if (!TxState.advances(row.state, to)) return;
    row.state = to;
    row.ms = DateTime.now().millisecondsSinceEpoch;
    advanced++;
    _persist(row);
    LogService.instance.add('XPRS: $id is $to (${row.peer})');
    WappDelivery.instance.deliverStatus(id: id, peer: row.peer, state: to);
  }

  String? stateOf(String id) => (_rows[id] ?? _load(id))?.state;

  int get length => _rows.length;

  static void debugReset() {
    instance._rows.clear();
    instance.close();
    recorded = advanced = unknown = restored = 0;
  }
}
