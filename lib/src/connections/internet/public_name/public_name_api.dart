/*
 * The parts of the public-name service that do not need dart:io: the web
 * server a host lends it, and its options. public_name.dart exports these
 * with the real service (io) or the web's stand-in.
 */

/// What the public-name service needs from a host's web server (the
/// server's WebChatServer, the app's share server): answer ACME HTTP-01
/// challenges, send visitors to HTTPS, and serve HTTPS.
abstract class AcmeWebServer {
  /// token -> key authorization, answered at /.well-known/acme-challenge/.
  Map<String, String> get acmeChallenges;

  /// Plain HTTP answers a known challenge with a redirect to the same path
  /// on https://host/ (the CA follows it: that tests port 443).
  bool challengesViaHttps = false;

  /// Host names whose plain-HTTP visitors go to https://host[:httpsPort].
  Set<String> redirectHosts = {};
  int httpsPort = 443;

  /// Starts serving HTTPS with a PEM chain and a PEM private key.
  Future<void> startSecure({
    required int port,
    required String address,
    required List<int> certificateChain,
    required List<int> privateKey,
  });

  Future<void> stop();
}

class PublicNameOptions {
  const PublicNameOptions({
    required this.dir,
    this.httpPort = 80,
    this.httpsPort = 443,
    this.address = '::',
    this.upnp = true,
    this.staging = false,
    this.email,
    this.checkEvery = const Duration(minutes: 15),
  });

  /// Where keys, certificate and state are kept (created 0700).
  final String dir;
  final int httpPort;
  final int httpsPort;
  final String address;

  /// Ask the router (UPnP) to let ports 80 and 443 in.
  final bool upnp;

  /// Real certificates from the staging CA too (testing: untrusted certs).
  final bool staging;
  final String? email;
  final Duration checkEvery;
}
