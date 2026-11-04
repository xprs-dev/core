/*
 * Files shipped with the program (translations under assets/lang/). The app
 * reads them from its Flutter asset bundle; the server from a directory. The
 * default has none, so the core falls back to its English keys.
 */

abstract interface class AssetSource {
  /// Every asset path, e.g. `assets/lang/en/core.json`.
  Future<List<String>> list();

  /// One asset as text; throws when it does not exist.
  Future<String> loadString(String path);
}

class NoAssets implements AssetSource {
  const NoAssets();
  @override
  Future<List<String>> list() async => const [];
  @override
  Future<String> loadString(String path) async =>
      throw StateError('no asset $path');
}
