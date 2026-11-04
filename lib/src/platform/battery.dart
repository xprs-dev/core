/*
 * The battery, as the core reads it: level, condition, and when it changes.
 * The raw condition is passed through on purpose: the power tier, the mesh
 * beacon's cond byte and the capacity governor each decide "on mains" with
 * their own rule, and folding the states here would change one of them.
 * The app backs it with battery_plus; the default is a machine on mains with
 * no battery (a server, a desktop), which is also what battery_plus reports
 * there (`unknown`).
 */

enum BatteryCondition { charging, connectedNotCharging, discharging, full, unknown }

abstract interface class BatterySource {
  /// 0-100.
  Future<int> level();
  Future<BatteryCondition> condition();
  Stream<BatteryCondition> get changes;
}

class NoBattery implements BatterySource {
  const NoBattery();
  @override
  Future<int> level() async => 100;
  @override
  Future<BatteryCondition> condition() async => BatteryCondition.unknown;
  @override
  Stream<BatteryCondition> get changes => const Stream.empty();
}
