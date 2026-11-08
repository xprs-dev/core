/*
 * The public-name service on the web: a page cannot listen on a port, so
 * there is nothing to name. Same API as public_name_io.dart.
 */
import 'public_name_api.dart';

class PublicName {
  PublicName({
    required this.options,
    required this.http,
    required this.newServer,
    void Function(String)? log,
    this.onUrl,
  });

  final PublicNameOptions options;
  final AcmeWebServer http;
  final AcmeWebServer Function() newServer;
  final void Function(String?)? onUrl;
  Future<List<String>> Function({String? v4, String? v6})? extraNames;
  String? get url => null;
  String? get publicIPv4 => null;
  List<String> get urls => const [];
  List<String> get pending => const [];

  Future<void> start() async {}
  Future<void> check() async {}
  Future<void> stop() async {}
}
