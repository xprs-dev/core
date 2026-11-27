// A removal in the public rooms by this station's own person (XPRS.md
// 10.10.3): the half of [XprsPublicModerators] that needs the profile's key
// and the transmitter. A wapp asks through the host (the Chat does, with the
// verbs it already uses for a closed group's moderators); what a removal
// looks like on a screen is the wapp's.
import 'dart:async';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart';

import 'xprs_archive.dart';
import 'xprs_packet.dart';
import 'xprs_public_moderators.dart';
import 'xprs_publisher.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart' show xprsNowTs;

class XprsPublicModOps {
  XprsPublicModOps._();

  static BigInt? _keyOf;
  static Uint8List? _key;

  /// This profile's key, worked out once per profile (a curve operation).
  static Uint8List? _mine() {
    final d = xprsProfileScalar();
    if (d == null) return null;
    if (_keyOf != d) {
      _key = XprsCrypto.publicKeyXOnly(d);
      _keyOf = d;
    }
    return _key;
  }

  /// True when this profile's key is on the published list now.
  static bool get listed {
    final k = _mine();
    return k != null && XprsPublicModerators.instance.lists(k);
  }

  /// Remove [messageId] from the public rooms. Null when done (the archive
  /// drops it, the act is aired); otherwise why not. An unlisted key signs
  /// nothing: the act would be ignored by everybody, this station included.
  static String? remove(String messageId, {int? nowMs}) {
    final id = messageId.trim().toLowerCase();
    final d = xprsProfileScalar();
    if (d == null) return 'no profile open';
    if (!listed) return 'not a moderator of the public rooms';
    final me = XprsArchive.instance.selfCallsign.trim().toUpperCase();
    final raw = XprsPacket.parse(
        't:moderate f:$me ts:${xprsNowTs(nowMs)} r:$id remove:message');
    if (me.isEmpty || raw == null || !XprsPublicModerators.shaped(raw)) {
      return 'not a message identifier';
    }
    final p = xprsSign(raw, d);
    // Our own archive and screens move now: the packet is not coming back.
    if (XprsArchive.instance.publicOutOfReach(id)) {
      return 'only a message in the public rooms';
    }
    if (!XprsPublicModerators.instance.offer(p, nowMs: nowMs)) {
      return 'not a moderator of the public rooms';
    }
    XprsArchive.instance.purgePublic(id);
    unawaited(XprsPublisher.instance.publishWire(p.encode(), verbatim: true));
    return null;
  }
}
