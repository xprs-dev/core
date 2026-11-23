/// See store_worker.dart. No isolates on the web: no worker.
library;

/// The store, as the worker sees it.
abstract class StoreWorkerTarget {
  /// One operation; what it returns goes back to a [StoreWorker.call].
  Object? handle(String op, Object? arg);
  void close();
}

/// Makes the target in the worker: top-level or static.
typedef StoreWorkerFactory = StoreWorkerTarget? Function(
    String path, String? secret);

abstract class StoreWorker {
  bool get alive;
  void post(String op, Object? arg);
  Future<Object?> call(String op, Object? arg);
  void close();
}

Future<StoreWorker?> startStoreWorker(
        String path, String? secret, StoreWorkerFactory factory,
        {String name = 'store-worker'}) async =>
    null;
