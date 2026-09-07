import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../certificate/certificate_codec.dart';

/// This installation's signing identity.
///
/// Every handset mints an Ed25519 key pair on first run. That key signs the
/// provisional certificates a worker earns while out of contact, and the
/// dashboard records its public half at enrolment so those certificates can be
/// checked before they are counter-signed.
///
/// The private key is held in [FlutterSecureStorage], which on Android is
/// encrypted with a key held in the hardware-backed Keystore. That matters more
/// here than it might elsewhere: a readable private key means a worker who can
/// reach app storage can mint certificates saying they completed training they
/// never did, and the whole compliance record becomes worthless.
///
/// Note the honest limit — a rooted phone can still defeat this. That is
/// precisely why device-signed certificates are labelled *provisional* and only
/// become *verified* once the training centre counter-signs them with a key the
/// worker's handset never holds. The threat model is written up in
/// `docs/threat-model.md`.
class DeviceIdentity {
  DeviceIdentity._({
    required this.keyId,
    required this.publicKey,
    required SimpleKeyPair keyPair,
    // ignore: prefer_initializing_formals
  }) : _keyPair = keyPair;

  /// Identifier written into certificates this device signs, e.g. `dev:3f9a…`.
  final String keyId;

  final Uint8List publicKey;

  final SimpleKeyPair _keyPair;

  SimpleKeyPair get keyPair => _keyPair;

  static const _storageKeySeed = 'surakshaar.device.seed.v1';
  static const _storageKeyId = 'surakshaar.device.keyid.v1';

  /// Android Keystore-backed encryption. `encryptedSharedPreferences` is what
  /// moves this from "a file in app storage" to "encrypted with a key the OS
  /// holds".
  static const FlutterSecureStorage _defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Loads the existing identity, creating one on first run.
  static Future<DeviceIdentity> loadOrCreate({
    FlutterSecureStorage? storage,
    Ed25519? algorithm,
  }) async {
    final store = storage ?? _defaultStorage;
    final ed25519 = algorithm ?? Ed25519();

    final existingSeed = await store.read(key: _storageKeySeed);
    final existingId = await store.read(key: _storageKeyId);

    if (existingSeed != null && existingId != null) {
      try {
        final seed = base64Decode(existingSeed);
        final keyPair = await ed25519.newKeyPairFromSeed(seed);
        return DeviceIdentity._(
          keyId: existingId,
          publicKey: await CertificateCodec.publicKeyBytes(keyPair),
          keyPair: keyPair,
        );
      } catch (e) {
        // A corrupted seed must not brick the app. Mint a fresh identity and
        // carry on — previously issued provisional certificates stop verifying
        // against this device, which is the correct outcome for a key we can no
        // longer prove we hold.
        debugPrint('DeviceIdentity: stored seed unusable, regenerating: $e');
      }
    }

    final keyPair = await ed25519.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    final publicKey = await CertificateCodec.publicKeyBytes(keyPair);

    // Key id is derived from the public key, so it is stable, collision-
    // resistant and carries no device serial or other hardware identifier.
    final digest = await Sha256().hash(publicKey);
    final keyId = 'dev:${_hex(digest.bytes.take(8).toList())}';

    await store.write(key: _storageKeySeed, value: base64Encode(seed));
    await store.write(key: _storageKeyId, value: keyId);

    return DeviceIdentity._(
      keyId: keyId,
      publicKey: publicKey,
      keyPair: keyPair,
    );
  }

  /// Short form for showing on an enrolment screen, so a supervisor can match
  /// the handset in front of them to the row in the dashboard.
  String get shortFingerprint {
    final withoutPrefix = keyId.replaceFirst('dev:', '');
    return withoutPrefix
        .toUpperCase()
        .replaceAllMapped(RegExp(r'.{4}'), (m) => '${m.group(0)} ')
        .trim();
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// The organisation's public key, compiled into the app.
///
/// This is what lets a certificate be verified with no network, no account and
/// no prior contact with the issuing site — an inspector installs the APK and
/// can immediately check any counter-signed certificate in the state.
///
/// The matching private key lives only on the dashboard host and is generated
/// by `tools/keygen.mjs`. The value below is a **development** root; a real
/// deployment replaces it with a key held under the issuing authority's
/// control, ideally in an HSM. That substitution is a deliberate, documented
/// step rather than something to be forgotten — see `docs/threat-model.md`.
class OrganisationKey {
  const OrganisationKey._();

  static const String keyId = 'org:dev-root-2026a';

  /// Base64 of the **raw 32-byte** Ed25519 public key — not DER/SPKI-wrapped.
  /// Generated by `tools/keygen.mjs`, whose matching private half is in
  /// `keys/org-private.json` and is gitignored.
  static const String publicKeyBase64 =
      'mMIcFa0+wwQHTPjoi4OEv1NeF/ZIQj7H2HTBDNRA4Pg=';

  /// The decoded key, for handing to a [PublicKeyResolver].
  static Uint8List get publicKeyBytes {
    final decoded = base64Decode(publicKeyBase64);
    if (decoded.length != kPublicKeyLength) {
      // A malformed compiled-in key would mean nothing verifies, which is worth
      // failing loudly at startup rather than discovering at a pit head.
      throw StateError(
        'Organisation public key must be $kPublicKeyLength raw bytes, '
        'found ${decoded.length}. It should be the raw Ed25519 key, not a '
        'DER/SPKI wrapper.',
      );
    }
    return Uint8List.fromList(decoded);
  }

  /// True when the app is still trusting the development root. The UI surfaces
  /// this so a demo is never mistaken for a deployment.
  static bool get isDevelopmentRoot => keyId.startsWith('org:dev-');
}
