import 'dart:async';

/// The web has no isolates: run `fn(arg)` asynchronously on this one.
Future<R> offThread<Q, R>(FutureOr<R> Function(Q) fn, Q arg,
        {String? debugLabel}) =>
    Future<R>(() => fn(arg));
