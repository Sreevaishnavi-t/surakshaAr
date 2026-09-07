import 'dart:typed_data';

import '../modules/catalogue.dart';
import 'canonical_cbor.dart';

/// Who vouches for a certificate.
///
/// A worker finishing a drill in a gallery with no signal still deserves proof
/// of what they did, so the phone signs it there and then. That signature is
/// real but only as trustworthy as the handset, so it is labelled honestly as
/// provisional until the training centre counter-signs it.
enum TrustTier {
  /// Signed by the per-device key created on first run. Verifiable by anyone
  /// holding that device's public key — in practice, the site dashboard the
  /// device enrolled with.
  provisional(0),

  /// Counter-signed with the organisation key at sync. The organisation
  /// **public** key is compiled into the app, so any fresh install verifies
  /// this offline — including an inspector's phone with no account and no
  /// network.
  verified(1);

  const TrustTier(this.code);

  final int code;

  static TrustTier fromCode(int code) =>
      code == verified.code ? verified : provisional;
}

/// One completed training domain, as recorded on a certificate.
class ModuleAttainment {
  const ModuleAttainment({
    required this.domain,
    required this.score,
    required this.completedAt,
  });

  final SafetyDomain domain;

  /// Composite score, 0..100: 60% assessment, 40% measured behaviour in the AR
  /// drill. Stored as an integer because a certificate is not the place for
  /// float encoding ambiguity between two languages.
  final int score;

  final DateTime completedAt;

  // CBOR keys. Part of the wire format — never renumber.
  static const int _kDomain = 1;
  static const int _kScore = 2;
  static const int _kCompletedAt = 3;

  Map<int, Object?> toCbor() => {
        _kDomain: domain.code,
        _kScore: score,
        _kCompletedAt: completedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      };

  static ModuleAttainment fromCbor(Map<Object?, Object?> map) {
    final domainCode = _requireInt(map, _kDomain, 'module domain');
    final domain = SafetyDomain.fromCode(domainCode);
    if (domain == null) {
      throw CertificateFormatError('Unknown safety domain code $domainCode');
    }
    final score = _requireInt(map, _kScore, 'module score');
    if (score < 0 || score > 100) {
      throw CertificateFormatError('Module score out of range: $score');
    }
    return ModuleAttainment(
      domain: domain,
      score: score,
      completedAt: DateTime.fromMillisecondsSinceEpoch(
        _requireInt(map, _kCompletedAt, 'module completedAt') * 1000,
        isUtc: true,
      ),
    );
  }
}

/// The signed body of a worker's safety certificate.
///
/// Kept deliberately small — a couple of hundred bytes — so the whole thing
/// fits in a QR code that a cracked phone camera can read in poor light. The
/// design follows India's own DIVOC/CoWIN approach: the QR *is* the
/// certificate, not a pointer to a server record, because a pointer is useless
/// at a pit head with no signal.
///
/// What it deliberately does **not** contain: date of birth, address, phone
/// number, Aadhaar, or any other identifier beyond what a safety officer needs
/// to confirm the holder trained. A certificate gets photographed, shared over
/// WhatsApp and pinned to noticeboards; it should carry as little about the
/// worker as the job allows.
class WorkerCertificate {
  const WorkerCertificate({
    required this.schemaVersion,
    required this.id,
    required this.workerName,
    required this.workerRef,
    required this.employerCode,
    required this.modules,
    required this.issuedAt,
    required this.expiresAt,
    required this.keyId,
    required this.trustTier,
    this.photoDigest,
  });

  /// Current schema version. Bump only for incompatible changes; a verifier
  /// that meets a newer version refuses rather than guessing.
  static const int currentSchemaVersion = 1;

  final int schemaVersion;

  /// 16-byte certificate identifier. Also the idempotency key for sync.
  final Uint8List id;

  final String workerName;

  /// Employer's own worker reference — a token number or contractor roll
  /// number. Not a national identifier.
  final String workerRef;

  /// Site or contractor code, e.g. a DGMS mine code.
  final String employerCode;

  final List<ModuleAttainment> modules;

  final DateTime issuedAt;

  /// Statutory expiry. The Factories Act 1948 and Mines Act 1952 both require
  /// periodic re-certification, so a certificate without an expiry would be
  /// misrepresenting compliance.
  final DateTime expiresAt;

  /// Identifies the key that signed this. Device keys are prefixed `dev:`,
  /// organisation keys `org:`.
  final String keyId;

  final TrustTier trustTier;

  /// Optional hash of the worker's enrolment photo, letting a verifier confirm
  /// the person presenting the certificate is its holder without the photo
  /// itself ever travelling in the QR.
  final Uint8List? photoDigest;

  // CBOR keys. Part of the wire format — never renumber or reuse.
  static const int _kSchema = 1;
  static const int _kId = 2;
  static const int _kName = 3;
  static const int _kWorkerRef = 4;
  static const int _kEmployer = 5;
  static const int _kModules = 6;
  static const int _kIssued = 7;
  static const int _kExpires = 8;
  static const int _kKeyId = 9;
  static const int _kTrust = 10;
  static const int _kPhoto = 11;

  bool isExpiredAt(DateTime moment) => !moment.toUtc().isBefore(expiresAt.toUtc());

  /// Mean of the module scores, which is what a dashboard shows as an overall
  /// figure. Returns 0 for an empty certificate rather than dividing by zero.
  double get overallScore {
    if (modules.isEmpty) return 0;
    final total = modules.fold<int>(0, (sum, m) => sum + m.score);
    return total / modules.length;
  }

  /// The exact bytes that get signed.
  Uint8List toSignedBytes() => CanonicalCbor.encode(toCbor());

  Map<int, Object?> toCbor() {
    final map = <int, Object?>{
      _kSchema: schemaVersion,
      _kId: CborBytes(id),
      _kName: workerName,
      _kWorkerRef: workerRef,
      _kEmployer: employerCode,
      _kModules: modules.map((m) => m.toCbor()).toList(),
      _kIssued: issuedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      _kExpires: expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      _kKeyId: keyId,
      _kTrust: trustTier.code,
    };
    // Omitted entirely when absent rather than encoded as null: a present-but-
    // null key would still cost bytes and would have to be specified for the
    // TypeScript side to reproduce byte-for-byte.
    final photo = photoDigest;
    if (photo != null) map[_kPhoto] = CborBytes(photo);
    return map;
  }

  static WorkerCertificate fromCbor(Object? decoded) {
    if (decoded is! Map) {
      throw CertificateFormatError('Certificate body is not a CBOR map');
    }

    final schema = _requireInt(decoded, _kSchema, 'schema version');
    if (schema != currentSchemaVersion) {
      throw CertificateFormatError(
        'Unsupported certificate schema version $schema — this app reads '
        'version $currentSchemaVersion. Update the app to verify this code.',
      );
    }

    final rawModules = decoded[_kModules];
    if (rawModules is! List || rawModules.isEmpty) {
      throw CertificateFormatError('Certificate lists no completed modules');
    }

    final photo = decoded[_kPhoto];

    return WorkerCertificate(
      schemaVersion: schema,
      id: _requireBytes(decoded, _kId, 'certificate id', expectedLength: 16),
      workerName: _requireText(decoded, _kName, 'worker name'),
      workerRef: _requireText(decoded, _kWorkerRef, 'worker reference'),
      employerCode: _requireText(decoded, _kEmployer, 'employer code'),
      modules: rawModules.map((entry) {
        if (entry is! Map) {
          throw CertificateFormatError('Module entry is not a CBOR map');
        }
        return ModuleAttainment.fromCbor(entry);
      }).toList(growable: false),
      issuedAt: _epochSeconds(_requireInt(decoded, _kIssued, 'issued date')),
      expiresAt: _epochSeconds(_requireInt(decoded, _kExpires, 'expiry date')),
      keyId: _requireText(decoded, _kKeyId, 'key id'),
      trustTier: TrustTier.fromCode(_requireInt(decoded, _kTrust, 'trust tier')),
      photoDigest: photo is CborBytes ? Uint8List.fromList(photo.bytes) : null,
    );
  }

  WorkerCertificate copyWith({
    String? keyId,
    TrustTier? trustTier,
  }) {
    return WorkerCertificate(
      schemaVersion: schemaVersion,
      id: id,
      workerName: workerName,
      workerRef: workerRef,
      employerCode: employerCode,
      modules: modules,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      keyId: keyId ?? this.keyId,
      trustTier: trustTier ?? this.trustTier,
      photoDigest: photoDigest,
    );
  }
}

class CertificateFormatError implements Exception {
  CertificateFormatError(this.message);

  final String message;

  @override
  String toString() => message;
}

DateTime _epochSeconds(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

int _requireInt(Map<Object?, Object?> map, int key, String label) {
  final value = map[key];
  if (value is! int) {
    throw CertificateFormatError('Certificate is missing $label');
  }
  return value;
}

String _requireText(Map<Object?, Object?> map, int key, String label) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw CertificateFormatError('Certificate is missing $label');
  }
  return value;
}

Uint8List _requireBytes(
  Map<Object?, Object?> map,
  int key,
  String label, {
  int? expectedLength,
}) {
  final value = map[key];
  if (value is! CborBytes) {
    throw CertificateFormatError('Certificate is missing $label');
  }
  if (expectedLength != null && value.bytes.length != expectedLength) {
    throw CertificateFormatError(
      '$label should be $expectedLength bytes, found ${value.bytes.length}',
    );
  }
  return Uint8List.fromList(value.bytes);
}
