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
