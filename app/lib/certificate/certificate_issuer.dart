import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show KeyPair;

import '../data/repositories.dart';
import '../modules/catalogue.dart';
import 'certificate.dart';
import 'certificate_codec.dart';

/// A certificate that has been issued, together with the QR string to show.
class IssuedCertificate {
  const IssuedCertificate({required this.certificate, required this.qrPayload});

  final WorkerCertificate certificate;
  final String qrPayload;
}

/// Why a certificate could not be issued.
class NotCertifiable implements Exception {
  const NotCertifiable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Builds and signs certificates from what a worker has actually completed.
///
/// A domain only counts when the worker has passed **both** the AR drill and
/// the assessment. Requiring both is the whole argument of the platform:
/// passing the quiz alone is the classroom outcome whose retention is under
/// 20% after a week, and passing the drill alone leaves the reasoning behind
/// the actions untested.
class CertificateIssuer {
  CertificateIssuer({
    required this.attempts,
    required this.certificates,
    required this.codec,
    this.validity = const Duration(days: 365),
  });

  final AttemptRepository attempts;
  final CertificateRepository certificates;
  final CertificateCodec codec;

  /// How long a certificate remains valid.
  ///
  /// The Factories Act 1948 and Mines Act 1952 both require periodic
  /// re-certification, so an unbounded certificate would misrepresent
  /// compliance. One year is the common refresher interval; a deployment can
  /// shorten it per site without any change to the wire format.
  final Duration validity;

  /// Issues a provisional certificate signed by this handset.
  ///
  /// Provisional because a phone can only vouch for itself. The training centre
  /// upgrades it to verified at sync, using a key the handset never holds.
  Future<IssuedCertificate> issueProvisional({
    required WorkerRecord worker,
    required String deviceKeyId,
    required KeyPair deviceKeyPair,
    DateTime? now,
    math.Random? random,
  }) async {
    final scores = await attempts.certifiableDomains(worker.id);
    if (scores.isEmpty) {
      throw const NotCertifiable(
        'No module is complete yet. Finish both the AR drill and the '
        'assessment for at least one module to be certified.',
      );
    }

    final issuedAt = (now ?? DateTime.now()).toUtc();
    final rng = random ?? math.Random.secure();

    final modules = <ModuleAttainment>[
      for (final entry in _sortedByDomain(scores))
        ModuleAttainment(
          domain: entry.key,
          score: entry.value.round(),
          completedAt: issuedAt,
        ),
    ];

    final certificate = WorkerCertificate(
      schemaVersion: WorkerCertificate.currentSchemaVersion,
      id: _randomId(rng),
      workerName: worker.name,
      workerRef: worker.workerRef,
      employerCode: worker.employerCode,
      modules: modules,
      issuedAt: issuedAt,
      expiresAt: issuedAt.add(validity),
      keyId: deviceKeyId,
      trustTier: TrustTier.provisional,
      photoDigest: worker.photoDigest,
    );

    final qrPayload = await codec.encodeAndSign(
      certificate: certificate,
      keyPair: deviceKeyPair,
    );

    await certificates.store(
      certificateId: _hex(certificate.id),
      workerId: worker.id,
      qrPayload: qrPayload,
      trustTier: certificate.trustTier.code,
      keyId: certificate.keyId,
      overall: certificate.overallScore,
      issuedAt: certificate.issuedAt,
      expiresAt: certificate.expiresAt,
    );

    return IssuedCertificate(certificate: certificate, qrPayload: qrPayload);
  }

  /// Domains in catalogue order, so a reissued certificate for the same
  /// achievements produces the same bytes rather than depending on map
  /// iteration order.
  static List<MapEntry<SafetyDomain, double>> _sortedByDomain(
    Map<SafetyDomain, double> scores,
  ) {
    final entries = scores.entries.toList();
    entries.sort((a, b) => a.key.code.compareTo(b.key.code));
    return entries;
  }

  static Uint8List _randomId(math.Random rng) {
    return Uint8List.fromList(
      List<int>.generate(16, (_) => rng.nextInt(256)),
    );
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
