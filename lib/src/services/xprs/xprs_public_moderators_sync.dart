// The public rooms' moderator list, kept current from xprs.dev (XPRS.md
// 10.10.3): the host half of [XprsPublicModerators], which has no socket and
// no store of its own.
import 'package:http/http.dart' as http;

import '../preferences_service.dart';
import '../receive/core_state.dart';
import 'xprs_archive.dart';
import 'xprs_public_moderators.dart';

/// Read the operator's switch and the list last kept, and ask xprs.dev for
/// the list when the last ask is twelve hours old. Call at start and when an
/// uplink comes up; it returns at once when there is nothing to do.
Future<void> xprsSyncPublicModerators() async {
  final prefs = PreferencesService.instanceSync;
  if (prefs == null) return;
  if (!_remembered) {
    _remembered = true;
    XprsPublicModerators.instance
        .remember(XprsArchive.instance.publicRemoved().reversed);
  }
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

/// The operator's switch, from a settings screen: kept, applied at once, and
/// said to the wapps showing those rooms. Turned on, the list is asked for
/// if it is due.
Future<void> xprsSetHonourPublicModerators(bool on) async {
  final prefs = PreferencesService.instanceSync;
  if (prefs == null) return;
  await prefs.setXprsHonourPublicModerators(on);
  XprsPublicModerators.instance.honoured = on;
  CoreState.instance.changed(CoreState.moderation);
  if (on) await xprsSyncPublicModerators();
}

/// The archive's record of earlier removals is handed over once per start.
bool _remembered = false;
