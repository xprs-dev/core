## 0.1.0

First release: the part of the XPRS core that was already free of Flutter and
app services, moved out of the app (`xprs-dev/app`) unchanged.

- 47 files: XPRS packet grammar and vocabulary, callsigns, station and archive
  policy, digipeating, gateway dedup, airtime, presence, mailbox; the mesh
  session protocol and its frames, beacons and tables; folders; the I2P node;
  the NOSTR signer seam; log ring buffer and small utilities.
- 35 test files moved with them; they run under `dart test`.
- One barrel: `package:xprs_core/xprs_core.dart`.
