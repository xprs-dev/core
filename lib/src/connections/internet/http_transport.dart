/*
 * The one HTTP client for the whole host.
 *
 * Before this existed, host HTTP was duplicated three ways: package:http in
 * the installer and wapp_page, and raw dart:io HttpClient in the CLI. They
 * all funnel through here now. package:http works on desktop, web and the
 * Dart CLI, so this single implementation covers every entry point.
 *
 * A GET and a POST that return bytes + status.
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Result of an HTTP request.
class HttpResult {
  final int statusCode;
  final Uint8List bodyBytes;

  HttpResult(this.statusCode, this.bodyBytes);

  /// True for 2xx.
  bool get isOk => statusCode >= 200 && statusCode < 300;

  /// Body decoded as UTF-8 (lossy on invalid bytes).
  String get bodyString => utf8.decode(bodyBytes, allowMalformed: true);
}

/// Host-side HTTP over the internet transport. Stateless; construct one or
/// reuse [HttpTransport.shared].
class HttpTransport {
  const HttpTransport();

  /// Shared default instance.
  static const HttpTransport shared = HttpTransport();

  /// GET [url]. Applies [timeout] when given (mirrors the previous
  /// per-call-site deadlines). Throws on network failure or timeout — the
  /// caller decides how to handle it.
  Future<HttpResult> get(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    var future = http.get(url, headers: headers);
    if (timeout != null) future = future.timeout(timeout);
    final res = await future;
    return HttpResult(res.statusCode, res.bodyBytes);
  }

  /// POST [url] with an optional string [body]. Non-streaming — awaits the
  /// whole response. Throws on network failure / timeout.
  Future<HttpResult> post(
    Uri url, {
    Map<String, String>? headers,
    String? body,
    Duration? timeout,
  }) async {
    var future = http.post(url, headers: headers, body: body);
    if (timeout != null) future = future.timeout(timeout);
    final res = await future;
    return HttpResult(res.statusCode, res.bodyBytes);
  }

  /// Any method, raw body bytes, the caller's headers. The one general
  /// request: a wapp's `hal_http_request2` (an API that wants a key in a
  /// header, a PUT or a DELETE) goes through here. Throws on network
  /// failure or timeout, like [get] and [post].
  Future<HttpResult> request(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
    Duration? timeout,
  }) async {
    final req = http.Request(method.toUpperCase(), url);
    if (headers != null) req.headers.addAll(headers);
    if (body != null) req.bodyBytes = body;
    // The deadline covers connecting as well as reading the answer.
    var future = req.send().then(http.Response.fromStream);
    if (timeout != null) future = future.timeout(timeout);
    final res = await future;
    return HttpResult(res.statusCode, res.bodyBytes);
  }
}
