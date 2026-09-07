import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'base45.dart';
import 'canonical_cbor.dart';
import 'certificate.dart';

/// Ed25519 signature length in bytes. Fixed by the algorithm, and relied on
/// when splitting a decoded QR body back into payload and signature.
const int kSignatureLength = 64;

/// Ed25519 public key length in bytes.
const int kPublicKeyLength = 32;

/// Prefix identifying a SurakshaAR certificate and its wire version.
///
/// Present so a scanner can reject an unrelated QR code with a clear message
/// instead of failing deep inside base45 with something unreadable. Bumping the
/// digit signals an incompatible envelope change.
const String kQrPrefix = 'SJH1:';

/// Result of verifying a scanned certificate.
///
/// Verification failure is not one condition but several, and they mean very
/// different things to the person holding the phone. "Expired" means send the
/// worker for refresher training; "signature invalid" means the code is forged
/// or corrupt; "unknown key" means this verifier has not synced with the site
/// that issued it. Collapsing them into a single boolean would make the feature
/// useless in the field.
sealed class VerificationResult {
  const VerificationResult();
}

class VerificationValid extends VerificationResult {
  const VerificationValid({required this.certificate, required this.checkedAt});

  final WorkerCertificate certificate;
  final DateTime checkedAt;

  bool get isProvisional => certificate.trustTier == TrustTier.provisional;
}

class VerificationExpired extends VerificationResult {
  const VerificationExpired({required this.certificate, required this.checkedAt});

  /// The signature was good — this certificate is genuine but out of date.
  final WorkerCertificate certificate;
  final DateTime checkedAt;

  Duration get overdueBy => checkedAt.toUtc().difference(certificate.expiresAt);
}

class VerificationUnknownKey extends VerificationResult {
  const VerificationUnknownKey({required this.keyId});

  final String keyId;
}

class VerificationInvalid extends VerificationResult {
  const VerificationInvalid(this.reason);

  final String reason;
}

class VerificationMalformed extends VerificationResult {
  const VerificationMalformed(this.reason);

  final String reason;
}

/// Somewhere to look up the public key for a given key id.
///
/// Two implementations matter: the organisation key compiled into the app, and
/// the registry of device keys a dashboard has enrolled. Both are consulted
/// entirely offline.
abstract class PublicKeyResolver {
  /// Returns the 32-byte Ed25519 public key for [keyId], or null if unknown.
  Uint8List? resolve(String keyId);
}

/// Resolves keys from an in-memory map.
class MapKeyResolver implements PublicKeyResolver {
  MapKeyResolver(this._keys);

  final Map<String, Uint8List> _keys;

  @override
  Uint8List? resolve(String keyId) => _keys[keyId];

  /// Adds or replaces a key. Used as the device registry is synced.
  void register(String keyId, Uint8List publicKey) {
    if (publicKey.length != kPublicKeyLength) {
      throw ArgumentError('Ed25519 public key must be $kPublicKeyLength bytes');
    }
    _keys[keyId] = publicKey;
  }

  int get length => _keys.length;
}

/// Encodes, signs and verifies certificates.
///
/// Every operation here runs offline. Verification in particular needs no
/// server, no account and no prior contact with the issuing site as long as the
/// certificate was counter-signed with the organisation key — which is the
/// whole point, since the people who most need to check a certificate are
/// standing at a pit head.
class CertificateCodec {
  CertificateCodec({Ed25519? algorithm}) : _ed25519 = algorithm ?? Ed25519();

  final Ed25519 _ed25519;

  /// Signs [certificate] and returns the complete QR payload string.
  Future<String> encodeAndSign({
    required WorkerCertificate certificate,
    required KeyPair keyPair,
  }) async {
    final body = certificate.toSignedBytes();
    final signature = await _ed25519.sign(body, keyPair: keyPair);

    if (signature.bytes.length != kSignatureLength) {
      throw StateError(
        'Expected a $kSignatureLength-byte Ed25519 signature, '
        'got ${signature.bytes.length}',
      );
    }

    final envelope = Uint8List(body.length + kSignatureLength)
      ..setAll(0, body)
      ..setAll(body.length, signature.bytes);

    return '$kQrPrefix${Base45.encode(envelope)}';
  }

  /// Verifies a scanned QR string.
  ///
  /// Ordering is deliberate: structure, then signature, then expiry. A tampered
  /// certificate must never be reported as merely "expired", because that reads
  /// as a scheduling problem rather than a forgery.
  Future<VerificationResult> verify({
    required String qrData,
    required PublicKeyResolver keys,
    DateTime? now,
  }) async {
    final checkedAt = (now ?? DateTime.now()).toUtc();

    final trimmed = qrData.trim();
    if (!trimmed.startsWith(kQrPrefix)) {
      return const VerificationMalformed(
        'This is not a SurakshaAR certificate code.',
      );
    }

    Uint8List envelope;
    try {
      envelope = Base45.decode(trimmed.substring(kQrPrefix.length));
    } on Base45Error catch (e) {
      return VerificationMalformed('Certificate code is damaged: ${e.message}');
    }

    if (envelope.length <= kSignatureLength) {
      return const VerificationMalformed('Certificate code is truncated.');
    }

    final bodyLength = envelope.length - kSignatureLength;
    final body = Uint8List.sublistView(envelope, 0, bodyLength);
    final signatureBytes = Uint8List.sublistView(envelope, bodyLength);

    WorkerCertificate certificate;
    try {
      certificate = WorkerCertificate.fromCbor(
        CanonicalCbor.decode(Uint8List.fromList(body)),
      );
    } on CertificateFormatError catch (e) {
      return VerificationMalformed(e.message);
    } on CborError catch (e) {
      return VerificationMalformed('Certificate contents are damaged: ${e.message}');
    }

    final publicKey = keys.resolve(certificate.keyId);
    if (publicKey == null) {
      return VerificationUnknownKey(keyId: certificate.keyId);
    }

    final signatureValid = await _ed25519.verify(
      body,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );

    if (!signatureValid) {
      return const VerificationInvalid(
        'The signature does not match. This certificate has been altered or '
        'was not issued by this organisation.',
      );
    }

    if (certificate.isExpiredAt(checkedAt)) {
      return VerificationExpired(certificate: certificate, checkedAt: checkedAt);
    }

    return VerificationValid(certificate: certificate, checkedAt: checkedAt);
  }

  /// Re-signs an already-issued certificate with the organisation key.
  ///
  /// This is the provisional-to-verified promotion that happens when a phone
  /// syncs with the training centre. The body changes (the key id and trust
  /// tier are part of it), so this genuinely re-signs rather than appending a
  /// second signature — which keeps the envelope to exactly one signature and
  /// the QR small.
  Future<String> counterSign({
    required WorkerCertificate certificate,
    required KeyPair organisationKeyPair,
    required String organisationKeyId,
  }) {
    return encodeAndSign(
      certificate: certificate.copyWith(
        keyId: organisationKeyId,
        trustTier: TrustTier.verified,
      ),
      keyPair: organisationKeyPair,
    );
  }

  /// Generates a fresh Ed25519 key pair.
  Future<SimpleKeyPair> generateKeyPair() => _ed25519.newKeyPair();

  /// Extracts the raw 32-byte public key from a key pair.
  static Future<Uint8List> publicKeyBytes(KeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();
    if (publicKey is! SimplePublicKey) {
      throw ArgumentError('Expected a SimplePublicKey for Ed25519');
    }
    return Uint8List.fromList(publicKey.bytes);
  }
}
