/*
 * The topic index of a forum room (spec/API-HTTP.md `/api/rooms?topics=`).
 *
 * A forum room is a hosted room (XPRS.md 10.10.1) whose posts are `t:blog`
 * (18): a titled post is a topic, replaced by a later one of the same title
 * from the same author (18.1); an untitled post carrying `r:` is a comment on
 * the post it names (18.5), `root:` the topic it hangs from. The archive files
 * a split post's parts as it heard them (7.6), so this fold joins them, keyed
 * on (f, ts), and never counts a set with a hole.
 *
 * Pure: rows in, topics out, so the server and the app share it and a test
 * needs no archive.
 */
import 'xprs/xprs_id.dart';
import 'xprs/xprs_packet.dart';
import 'xprs/xprs_parts.dart' show xprsSetKey;

/// One post of a forum room, parts joined: the packet the parts reassemble
/// into (7.6), its identifier, and the row's own time.
class ForumPost {
  const ForumPost(this.packet, this.id, this.ts, this.rowIds);
  final XprsPacket packet;

  /// The archive rows this post came from: one, or one per part.
  final List<String> rowIds;

  /// The section 5 identifier of [packet], which is what a comment names: a
  /// reply names the whole, never an individual part.
  final String id;

  /// Epoch seconds, the row's.
  final int ts;

  String get from => _base(packet['f'] ?? '');
  String? get title => packet['title'];
  bool get isComment => title == null && packet.has('r') && !packet.has('remove');
  bool get isTopic => title != null && !packet.has('remove');

  /// The topic a comment belongs to: `root:` when it says, else the post it
  /// answers (a first-level comment's parent IS the topic, 7.4).
  String? get thread => packet['root'] ?? packet['r'];
}

String _base(String c) => c.trim().toUpperCase().split('-').first;

/// History rows of type `blog` -> posts, parts joined, incomplete sets left
/// out, removed identifiers and sent-away authors dropped. Order as given.
List<ForumPost> forumPosts(List<Map<String, dynamic>> rows,
    {Set<String> removed = const {}, Set<String> away = const {}}) {
  final out = <ForumPost>[];
  // (f, ts) -> parts seen so far: total, index -> text, the first part, ts.
  final sets = <String, ({int total, Map<int, String> parts, XprsPacket? first, int ts, List<String> rows})>{};
  final order = <String>[];
  for (final r in rows) {
    final p = XprsPacket.parse('${r['wire'] ?? ''}');
    if (p == null || p.type != 'blog') continue;
    if (away.contains(_base(p['f'] ?? ''))) continue;
    final ts = (r['ts'] as num?)?.toInt() ?? 0;
    final n = p['n'];
    if (n == null) {
      final id = xprsIdentifier(p);
      if (removed.contains(id) || removed.contains('${r['id']}')) continue;
      out.add(ForumPost(p, id, ts, ['${r['id']}']));
      continue;
    }
    final m = RegExp(r'^([1-9])/([1-9])$').firstMatch(n);
    final key = xprsSetKey(p);
    if (m == null || key == null) continue;
    final i = int.parse(m[1]!), total = int.parse(m[2]!);
    if (i > total) continue;
    var s = sets[key];
    if (s == null || s.total != total) {
      s = (total: total, parts: <int, String>{}, first: null, ts: ts, rows: <String>[]);
      sets[key] = s;
      order.add(key);
    }
    if (!s.parts.containsKey(i)) {
      s.parts[i] = p['m'] ?? '';
      s.rows.add('${r['id']}');
    }
    if (i == 1) sets[key] = (total: total, parts: s.parts, first: p, ts: ts, rows: s.rows);
  }
  // A set is a post only when every part is here (7.6: never a partial).
  for (final key in order) {
    final s = sets[key]!;
    if (s.first == null || s.parts.length < s.total) continue;
    final joined = [for (var k = 1; k <= s.total; k++) s.parts[k]!].join(' ');
    final whole = s.first!.without({'n', 'sig', 'x', 'm'}).with_('m', joined);
    final id = xprsIdentifier(whole);
    if (removed.contains(id)) continue;
    out.add(ForumPost(whole, id, s.ts, List.unmodifiable(s.rows)));
  }
  return out;
}

/// The newest [max] topics of a room by last activity, each with its reply
/// count: the shape `/api/rooms?topics=` answers. [rows] is the room's `blog`
/// history, any order.
List<Map<String, dynamic>> forumTopics(List<Map<String, dynamic>> rows,
    {Set<String> removed = const {}, Set<String> away = const {}, int max = 100}) {
  final posts = forumPosts(rows, removed: removed, away: away);
  // Editions of one topic: author|title -> every edition, newest shown.
  final editions = <String, List<ForumPost>>{};
  final topicOf = <String, String>{}; // edition id -> author|title
  for (final p in posts) {
    if (!p.isTopic) continue;
    final k = '${p.from}|${p.title}';
    editions.putIfAbsent(k, () => []).add(p);
    topicOf[p.id] = k;
  }
  final replies = <String, int>{};
  final last = <String, int>{};
  for (final p in posts) {
    if (!p.isComment) continue;
    final k = topicOf[p.thread ?? ''];
    if (k == null) continue;
    replies[k] = (replies[k] ?? 0) + 1;
    if (p.ts > (last[k] ?? 0)) last[k] = p.ts;
  }
  final out = <Map<String, dynamic>>[];
  for (final e in editions.entries) {
    final shown = e.value.reduce((a, b) => b.ts >= a.ts ? b : a);
    out.add({
      'id': shown.id,
      'title': shown.title,
      'from': shown.from,
      'ts': shown.ts,
      'replies': replies[e.key] ?? 0,
      'last': [shown.ts, last[e.key] ?? 0].reduce((a, b) => a > b ? a : b),
      'edited': e.value.length > 1,
      if (shown.packet.has('tag')) 'tags': shown.packet['tag'],
    });
  }
  out.sort((a, b) => (b['last'] as int).compareTo(a['last'] as int));
  return out.length > max ? out.sublist(0, max) : out;
}
