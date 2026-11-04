/*
 * A value that tells its listeners when it changes: Flutter's ValueNotifier,
 * in plain Dart, for core state a screen watches (the active profile, the
 * translation revision). The app adapts one to a Flutter ValueListenable with
 * `.listenable` (lib/util/observable_listenable.dart) for ValueListenableBuilder.
 */

/// Holds a [value] and calls listeners when it is set to a different one.
class Observable<T> {
  Observable(this._value);

  T _value;
  final List<void Function()> _listeners = [];

  T get value => _value;

  /// Notifies only when the value actually changes (`!=`), as ValueNotifier.
  set value(T v) {
    if (v == _value) return;
    _value = v;
    notifyListeners();
  }

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  bool get hasListeners => _listeners.isNotEmpty;

  /// Call every listener, for a change the setter cannot see (a mutated
  /// object kept in [value]). A listener that throws does not stop the rest.
  void notifyListeners() {
    for (final l in List<void Function()>.of(_listeners)) {
      try {
        l();
      } catch (_) {}
    }
  }

  void dispose() => _listeners.clear();
}
