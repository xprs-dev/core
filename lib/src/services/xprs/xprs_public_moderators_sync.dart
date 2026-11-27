// The public rooms' moderator list, kept current from xprs.dev (XPRS.md
// 10.10.3): the host half of [XprsPublicModerators], which has no socket and
// no store of its own.
import 'package:http/http.dart' as http;

import '../preferences_service.dart';
import 'xprs_public_moderators.dart';

/// Read the operator's switch and the list last kept, and ask xprs.dev for
/// the list when the last ask is twelve hours old. Call at start and when an
/// uplink comes up; it returns at once when there is nothing to do.
Future<void> xprsSyncPublicModerators() async {
  final prefs = PreferencesService.instanceSync;
  if (prefs == null) return;
  await XprsPublicModerators.instance.sync(
    honour: () => prefs.xprsHonourPublicModerators,
    kept: () => prefs.xprsPublicModeratorsJson,
    askedMs: () => prefs.xprsPublicModeratorsAskedMs,
    keep: prefs.setXprsPublicModerators,
    fetch: (url) async {
      final r = await http.get(url).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      if (r.bodyBytes.length > XprsPublicModerators.maxBytes) return null;
      return r.body;
    },
  );
}
