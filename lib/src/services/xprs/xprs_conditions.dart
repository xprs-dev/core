/*
 * xprs_conditions — what keeps this station going, as XPRS says it
 * (XPRS.md 13.0.4): `source:`, `backup:`, `uplink:`, `plan:`.
 *
 * The owner states them in Settings > Hardware; what was never stated takes
 * the default a reader would guess anyway (the grid; a phone runs on its own
 * battery between charges; the uplink this device can see). They ride the
 * station's own `t:observation` and an archiver's `t:service`, which is what
 * a map of stations and a station choosing its archivers read.
 *
 * Pure: the words in, the keys out, so it is tested without a device.
 */
library;

/// 14.3's energy words the settings offer, in the order shown.
const List<String> kXprsSourceChoices = [
  'grid', 'solar', 'wind', 'hydro', 'generator',
];

/// `backup:` choices the settings offer.
const List<String> kXprsBackupChoices = ['battery', 'ups', 'none'];

/// `uplink:` choices the settings offer.
const List<String> kXprsUplinkChoices = [
  'wifi', 'lan', 'cellular', 'satellite', 'none',
];

const List<String> kXprsPlanChoices = ['limited', 'unlimited'];

/// Every word 13.0.4 defines for each key, for a reader.
const Set<String> kXprsBackupWords = {'battery', 'ups', 'none'};
const Set<String> kXprsUplinkWords = {
  'lan', 'wifi', 'cellular', 'satellite', 'other', 'none',
};
const Set<String> kXprsPlanWords = {'limited', 'unlimited'};

/// The default backup: a phone runs on its own battery, anything else is
/// assumed to have none until its owner says otherwise.
String xprsDefaultBackup(String platform) =>
    platform == 'android' || platform == 'ios' ? 'battery' : 'none';

/// The uplink this device can see, as a 13.0.4 word: what is shown and aired
/// until the owner states one. A satellite link looks like any other network
/// from here, so it is only ever stated.
String xprsSeenUplink(String netKind) => switch (netKind) {
      'ethernet' => 'lan',
      'wifi' => 'wifi',
      'cellular' => 'cellular',
      'none' => 'none',
      _ => 'other',
    };

/// A mobile plan is assumed capped and anything else not, until stated.
String xprsDefaultPlan(String uplink) =>
    uplink == 'cellular' ? 'limited' : 'unlimited';

/// The four keys in wire order, for the announcement. [uplink] null follows
/// [seenUplink]; [planFor] is the plan the owner stated for that uplink, if
/// any, so the plan changes with the link: Wi-Fi unlimited, the phone's
/// mobile plan limited, each as stated or defaulted. `plan:` is left out
/// beside `uplink:none`, where it means nothing (13.0.4).
List<MapEntry<String, String>> xprsConditions({
  required String platform,
  required String seenUplink,
  String? source,
  String? backup,
  String? uplink,
  String? Function(String uplink)? planFor,
}) {
  final up = uplink ?? seenUplink;
  final plan = planFor?.call(up);
  return [
    MapEntry('source', source ?? 'grid'),
    MapEntry('backup', backup ?? xprsDefaultBackup(platform)),
    MapEntry('uplink', up),
    if (up != 'none') MapEntry('plan', plan ?? xprsDefaultPlan(up)),
  ];
}

/// [bytes] rounded DOWN to a step of 1, 2 or 5 times a power of ten, as
/// `size:` says it (13.0.5): `500MB`, `1GB`, `2GB`, `50GB`. Never more than
/// there is, and steady while an archiver fills, so it is not re-announced
/// on every megabyte. Zero or less is `0B`.
String xprsStepBytes(int bytes) {
  if (bytes <= 0) return '0B';
  var p = 1;
  while (p * 10 <= bytes) {
    p *= 10;
  }
  final lead = bytes ~/ p;
  final step = (lead >= 5 ? 5 : lead >= 2 ? 2 : 1) * p;
  const units = ['B', 'kB', 'MB', 'GB', 'TB', 'PB'];
  var u = 0;
  var v = step;
  while (v >= 1000 && v % 1000 == 0 && u < units.length - 1) {
    v ~/= 1000;
    u++;
  }
  return '$v${units[u]}';
}

/// A measured rate in bytes per second as `bw:` says it (13.0.5): the same
/// steps, per second. Null when nothing was measured.
String? xprsStepRate(int bytesPerSecond) =>
    bytesPerSecond <= 0 ? null : '${xprsStepBytes(bytesPerSecond)}/s';

/// `size:` or `bw:` read back into bytes (or bytes per second): `50GB` is
/// 50e9, `2MB/s` is 2e6. Null for anything else, a radio's `125kHz` among
/// them.
int? xprsParseBytes(String? v) {
  final m = RegExp(r'^(\d+(?:\.\d+)?)(B|kB|MB|GB|TB|PB)(/s)?$')
      .firstMatch((v ?? '').trim());
  if (m == null) return null;
  const mult = {
    'B': 1, 'kB': 1000, 'MB': 1000000, 'GB': 1000000000,
    'TB': 1000000000000, 'PB': 1000000000000000,
  };
  return (double.parse(m[1]!) * mult[m[2]]!).round();
}
