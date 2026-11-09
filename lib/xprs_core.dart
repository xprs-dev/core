/// The XPRS core shared by the app and the server: plain Dart, no Flutter.
///
/// See README.md. Files keep the app's layout under lib/src/ so code moved
/// out of the app keeps its relative imports.
library;

// ── folders ───────────────────────────────────────────────────────────────
export 'src/services/folders/folder_event.dart';
export 'src/services/folders/folder_meta.dart';
export 'src/services/folders/folder_relay.dart';
export 'src/services/folders/folder_state.dart';
export 'src/services/folders/ntorrent.dart';

// ── i2p ───────────────────────────────────────────────────────────────────
export 'src/services/i2p/i2p_crypto.dart';
export 'src/services/i2p/i2p_datagram.dart';
export 'src/services/i2p/i2p_i2np.dart';
export 'src/services/i2p/i2p_leaseset.dart';
export 'src/services/i2p/i2p_node.dart';
export 'src/services/i2p/i2p_ntcp2.dart';
export 'src/services/i2p/i2p_reseed.dart';
export 'src/services/i2p/i2p_router.dart';
export 'src/services/i2p/i2p_structures.dart';
export 'src/services/i2p/i2p_swarm.dart';
export 'src/services/i2p/i2p_tunnel_build.dart';
export 'src/services/i2p/i2p_tunnel_data.dart';
export 'src/services/i2p/i2p_worker.dart';

// ── log_service.dart ──────────────────────────────────────────────────────
export 'src/services/log_service.dart';

// ── mesh ──────────────────────────────────────────────────────────────────
export 'src/services/mesh/mesh_beacon.dart';
export 'src/services/mesh/mesh_bloom.dart';
export 'src/services/mesh/mesh_custodian.dart';
export 'src/services/mesh/mesh_frame.dart';
export 'src/services/mesh/mesh_session.dart';
export 'src/services/mesh/mesh_table.dart';
export 'src/services/mesh/xprs_blob.dart';

// ── nostr ─────────────────────────────────────────────────────────────────
export 'src/services/nostr/nostr_signer.dart';

// ── reticulum ─────────────────────────────────────────────────────────────
export 'src/services/reticulum/rns_iface_kind.dart';

// ── social ────────────────────────────────────────────────────────────────
export 'src/services/social/direct_follow_resolver.dart';
export 'src/services/social/note_text.dart';

// ── util ──────────────────────────────────────────────────────────────────
export 'src/util/geohash.dart';
export 'src/util/nostr_imeta.dart';

// ── xprs ──────────────────────────────────────────────────────────────────
export 'src/services/xprs/xprs_airtime.dart';
export 'src/services/xprs/xprs_archive_policy.dart';
export 'src/services/xprs/xprs_archiver_choice.dart';
export 'src/services/xprs/xprs_cadence.dart';
export 'src/services/xprs/xprs_callsign.dart';
export 'src/services/xprs/xprs_digipeat.dart';
export 'src/services/xprs/xprs_gateway_dedup.dart';
export 'src/services/xprs/xprs_id.dart';
export 'src/services/xprs/xprs_key_wait.dart';
export 'src/services/xprs/xprs_directory.dart';
export 'src/services/xprs/xprs_mailbox.dart';
export 'src/services/xprs/xprs_owned_stations.dart';
export 'src/services/xprs/xprs_packet.dart';
export 'src/services/xprs/xprs_presence.dart';
export 'src/services/xprs/xprs_station_policy.dart';
export 'src/services/xprs/xprs_vocab.dart';
