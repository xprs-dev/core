/*
 * The few package:flutter/foundation.dart helpers the core used, in plain
 * Dart, so core code compiles without Flutter (the server edition, `dart test`).
 */

/// True when compiled for the web (dart2js / dart2wasm): the classic test,
/// since `0` and `0.0` are the same object only under JavaScript numbers.
const bool kIsWeb = identical(0, 0.0);

/// Whether two sets hold the same elements (Flutter's `setEquals`).
bool setEquals<T>(Set<T>? a, Set<T>? b) {
  if (a == null) return b == null;
  if (b == null || a.length != b.length) return false;
  if (identical(a, b)) return true;
  for (final x in a) {
    if (!b.contains(x)) return false;
  }
  return true;
}
