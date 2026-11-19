// The ranking of public groups as a list to show (XPRS.md 12.9.7): what the
// app's hal_xprs_group_rank and the web chat's /api/xprs/groups both answer.
import 'xprs_group_act.dart' show xprsGroupNickShown;
import 'xprs_group_index.dart';
import 'xprs_group_read.dart';
import 'xprs_groups.dart';
import 'xprs_profiles.dart';

/// Public groups ranked `by` `active`, `members` or `growing`, [max] rows at
/// most, each `{g, name, open, members?, posts, posters, joins?}`, and how
/// many archivers' indexes went into it. Asking also reads any index an
/// archiver named since (at most once a minute).
({int sources, List<Map<String, Object?>> rows}) xprsGroupRankRows(String by,
    {int max = 50}) {
  final r = XprsGroupRanking.instance..refresh();
  final rows = <Map<String, Object?>>[];
  // A group's name as read here; a folder (10.2) wears its group's name in
  // front, or two "Recipes" of two groups read alike.
  String nameOf(String g) {
    final nick = XprsProfiles.instance.nickFor(g) ?? '';
    return nick.isEmpty ? g : xprsGroupNickShown(nick);
  }

  final parents = XprsGroups.instance.parents();
  for (final g in r.ranked(by)) {
    if (rows.length >= max) break;
    // An archiver judged it public from the newest post IT holds; a station
    // that knows better (a member told it is private, 10.7.1) does not show
    // it (12.9.7: public groups only).
    if (!g.open && XprsGroupRead.instance.modeOf(g.group) == 'private') {
      continue;
    }
    final up = g.open ? null : parents[g.group];
    final name = g.open
        ? g.group
        : up == null
            ? nameOf(g.group)
            : '${nameOf(up)} › ${nameOf(g.group)}';
    rows.add({
      'g': g.group,
      'name': name,
      'open': g.open,
      if (g.members != null) 'members': g.members,
      'posts': g.posts,
      'posters': g.posters,
      if (!g.open) 'joins': g.joins,
    });
  }
  return (sources: r.sources, rows: rows);
}
