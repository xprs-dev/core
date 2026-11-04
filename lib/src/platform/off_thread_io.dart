import 'dart:async';
import 'dart:isolate';

/// Runs `fn(arg)` on a new isolate and returns its result.
Future<R> offThread<Q, R>(FutureOr<R> Function(Q) fn, Q arg,
        {String? debugLabel}) =>
    Isolate.run(() => fn(arg), debugName: debugLabel ?? 'offThread');
