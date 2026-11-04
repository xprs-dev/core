/*
 * Where the core keeps its settings: the operations PreferencesService uses,
 * as an interface. The app backs it with shared_preferences; the server with a
 * JSON file; a test with [MemoryKeyValueStore]. Reads are synchronous (the
 * store is loaded when opened), writes return when persisted.
 */

abstract interface class KeyValueStore {
  bool? getBool(String key);
  int? getInt(String key);
  double? getDouble(String key);
  String? getString(String key);
  List<String>? getStringList(String key);
  bool containsKey(String key);
  Set<String> getKeys();

  Future<bool> setBool(String key, bool value);
  Future<bool> setInt(String key, int value);
  Future<bool> setDouble(String key, double value);
  Future<bool> setString(String key, String value);
  Future<bool> setStringList(String key, List<String> value);
  Future<bool> remove(String key);
}

/// Settings held in memory only: the default for a test or a fresh server.
class MemoryKeyValueStore implements KeyValueStore {
  MemoryKeyValueStore([Map<String, Object>? initial])
      : values = {...?initial};

  /// The stored values, for a host that persists them itself.
  final Map<String, Object> values;

  T? _get<T>(String k) {
    final v = values[k];
    return v is T ? v : null;
  }

  @override
  bool? getBool(String key) => _get<bool>(key);
  @override
  int? getInt(String key) => _get<int>(key);
  @override
  double? getDouble(String key) => _get<double>(key);
  @override
  String? getString(String key) => _get<String>(key);
  @override
  List<String>? getStringList(String key) {
    final v = values[key];
    return v is List ? List<String>.from(v) : null;
  }

  @override
  bool containsKey(String key) => values.containsKey(key);
  @override
  Set<String> getKeys() => values.keys.toSet();

  Future<bool> _set(String k, Object v) async {
    values[k] = v;
    return true;
  }

  @override
  Future<bool> setBool(String key, bool value) => _set(key, value);
  @override
  Future<bool> setInt(String key, int value) => _set(key, value);
  @override
  Future<bool> setDouble(String key, double value) => _set(key, value);
  @override
  Future<bool> setString(String key, String value) => _set(key, value);
  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _set(key, List<String>.of(value));
  @override
  Future<bool> remove(String key) async => values.remove(key) != null;
}
