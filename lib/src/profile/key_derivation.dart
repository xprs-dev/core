/*
 * Synchronous key derivation and AES-256-GCM for the profile key hierarchy
 * (profile_crypto.dart) and the individually encrypted files beside the
 * stores (secure_file.dart). Sync because WASM HAL callbacks cannot await.
 *
 * Moved here from the encrypted_archive package when the profile's loose
 * files went into profile.zx (zx encrypts its own stores): the same HKDF
 * and GCM, byte for byte, so existing key slots and secure files still
 * decrypt.
 */

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/api.dart' as pc;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';

/// A failure to encrypt or decrypt (a wrong key, a damaged file).
class ProfileCryptoException implements Exception {
  const ProfileCryptoException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => 'ProfileCryptoException: $message';
}

/// AES-GCM output: the ciphertext and its 16-byte tag.
class EncryptedData {
  const EncryptedData({required this.ciphertext, required this.authTag});
  final Uint8List ciphertext;
  final Uint8List authTag;
}

class KeyDerivation {
  KeyDerivation._();

  static const int authTagSize = 16;

  /// RFC 5869 HKDF-SHA256 (an empty [salt] is HashLen zero bytes).
  static Uint8List hkdfSha256(
      Uint8List ikm, Uint8List salt, Uint8List info, int length) {
    final effectiveSalt = salt.isEmpty ? Uint8List(32) : salt;
    final prk = crypto.Hmac(crypto.sha256, effectiveSalt).convert(ikm).bytes;
    final out = BytesBuilder(copy: false);
    var previous = <int>[];
    var counter = 1;
    while (out.length < length) {
      final block =
          crypto.Hmac(crypto.sha256, prk).convert([...previous, ...info, counter]).bytes;
      out.add(block);
      previous = block;
      counter++;
    }
    return Uint8List.fromList(out.toBytes().sublist(0, length));
  }

  static GCMBlockCipher _gcm(bool encrypt, Uint8List key, Uint8List nonce) =>
      GCMBlockCipher(AESEngine())
        ..init(
            encrypt,
            pc.AEADParameters(
                pc.KeyParameter(key), authTagSize * 8, nonce, Uint8List(0)));

  /// AES-256-GCM encryption with no associated data.
  static EncryptedData encryptSync(
      Uint8List plaintext, Uint8List keyBytes, Uint8List nonce) {
    try {
      final output = _gcm(true, keyBytes, nonce).process(plaintext);
      return EncryptedData(
        ciphertext:
            Uint8List.sublistView(output, 0, output.length - authTagSize),
        authTag: Uint8List.sublistView(output, output.length - authTagSize),
      );
    } catch (e) {
      throw ProfileCryptoException('Encryption failed: $e', e);
    }
  }

  /// AES-256-GCM decryption; throws [ProfileCryptoException] when the tag
  /// does not verify.
  static Uint8List decryptSync(Uint8List ciphertext, Uint8List authTag,
      Uint8List keyBytes, Uint8List nonce) {
    try {
      final input = Uint8List(ciphertext.length + authTag.length)
        ..setRange(0, ciphertext.length, ciphertext)
        ..setRange(ciphertext.length, ciphertext.length + authTag.length,
            authTag);
      return _gcm(false, keyBytes, nonce).process(input);
    } catch (e) {
      throw ProfileCryptoException('Decryption failed: $e', e);
    }
  }
}
