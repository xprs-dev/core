/*
 * A public name (nip.io) and HTTPS (Let's Encrypt) for a host that serves
 * the web chat: the server edition now, the app on Android and desktop later.
 * See public_name_io.dart; the web has no sockets to serve from.
 */
export 'public_name_api.dart';
export 'public_name_web.dart' if (dart.library.io) 'public_name_io.dart';
