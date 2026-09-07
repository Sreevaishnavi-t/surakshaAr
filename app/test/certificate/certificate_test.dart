import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:surakshaar/certificate/base45.dart';
import 'package:surakshaar/certificate/certificate.dart';
import 'package:surakshaar/certificate/certificate_codec.dart';
import 'package:surakshaar/modules/catalogue.dart';

WorkerCertificate sampleCertificate({
  String keyId = 'org:jh-2026a',
  TrustTier tier = TrustTier.verified,
  DateTime? issuedAt,
  DateTime? expiresAt,
  String workerName = 'Sunita Murmu',
}) {
  final issued = issuedAt ?? DateTime.utc(2026, 3, 14);
  return WorkerCertificate(
    schemaVersion: WorkerCertificate.currentSchemaVersion,
    id: Uint8List.fromList(List<int>.generate(16, (i) => i * 11 % 256)),
    workerName: workerName,
    workerRef: 'JH/DHN/CT/1187',
    employerCode: 'JH-DHN-0042',
    modules: [
      ModuleAttainment(
        domain: SafetyDomain.fire,
        score: 87,
        completedAt: issued,
      ),
      ModuleAttainment(
        domain: SafetyDomain.gas,
        score: 91,
        completedAt: issued,
      ),
    ],
    issuedAt: issued,
    expiresAt: expiresAt ?? DateTime.utc(2027, 3, 14),
    keyId: keyId,
    trustTier: tier,
  );
}

void main() {
  late CertificateCodec codec;
  late SimpleKeyPair orgKeys;
  late Uint8List orgPublicKey;
  late MapKeyResolver resolver;

  setUp(() async {
    codec = CertificateCodec();
    orgKeys = await codec.generateKeyPair();
    orgPublicKey = await CertificateCodec.publicKeyBytes(orgKeys);
    resolver = MapKeyResolver({'org:jh-2026a': orgPublicKey});
  });

  group('round trip', () {
    test('a signed certificate verifies and survives intact', () async {
      final original = sampleCertificate();
      final qr = await codec.encodeAndSign(
        certificate: original,
        keyPair: orgKeys,
      );

      expect(qr, startsWith(kQrPrefix));

      final result = await codec.verify(
        qrData: qr,
        keys: resolver,
        now: DateTime.utc(2026, 6, 1),
      );

      expect(result, isA<VerificationValid>());
      final valid = result as VerificationValid;
      expect(valid.certificate.workerName, 'Sunita Murmu');
      expect(valid.certificate.employerCode, 'JH-DHN-0042');
      expect(valid.certificate.modules.length, 2);
      expect(valid.certificate.modules.first.domain, SafetyDomain.fire);
      expect(valid.certificate.modules.first.score, 87);
      expect(valid.certificate.overallScore, closeTo(89, 0.001));
      expect(valid.isProvisional, isFalse);
    });

    test('preserves a Hindi and a Santali name exactly', () async {
      // Multi-byte scripts through CBOR text, base45 and back. A mangled name
      // on a certificate is a real failure: it is the field a supervisor reads
      // to decide whether this is the right person.
      for (final name in ['सुनीता मुर्मू', 'ᱥᱩᱱᱤᱛᱟ ᱢᱩᱨᱢᱩ']) {
        final qr = await codec.encodeAndSign(
          certificate: sampleCertificate(workerName: name),
          keyPair: orgKeys,
        );
        final result = await codec.verify(
          qrData: qr,
          keys: resolver,
          now: DateTime.utc(2026, 6, 1),
        );

        expect(result, isA<VerificationValid>(), reason: name);
        expect((result as VerificationValid).certificate.workerName, name);
      }
    });

    test('stays comfortably inside QR alphanumeric capacity', () async {
      final qr = await codec.encodeAndSign(
        certificate: sampleCertificate(workerName: 'ᱥᱩᱱᱤᱛᱟ ᱢᱩᱨᱢᱩ'),
        keyPair: orgKeys,
      );

      // Even at the highest error correction level a QR holds 1,852
      // alphanumeric characters. Staying well under keeps the symbol small
      // enough for a cracked camera in a dim gallery.
      expect(qr.length, lessThan(400));

      // And every character must actually be in the QR alphanumeric set,
      // otherwise the encoder silently falls back to byte mode.
      for (final char in qr.substring(kQrPrefix.length).split('')) {
        expect(Base45.alphabet.contains(char), isTrue, reason: 'char "$char"');
      }
    });

    test('signing is deterministic for identical input', () async {
      // Ed25519 signatures are deterministic by design, so the same
      // certificate signed with the same key must yield an identical QR. This
      // is what lets a re-issued certificate be compared byte-for-byte.
      final certificate = sampleCertificate();
      final first = await codec.encodeAndSign(
        certificate: certificate,
        keyPair: orgKeys,
      );
      final second = await codec.encodeAndSign(
        certificate: certificate,
        keyPair: orgKeys,
      );

      expect(first, second);
    });
  });

  group('tamper detection', () {
    test('rejects a certificate signed by a different key', () async {
      final attackerKeys = await codec.generateKeyPair();
      final qr = await codec.encodeAndSign(
        certificate: sampleCertificate(),
        keyPair: attackerKeys,
      );

      // The key id still claims to be the organisation's, but the signature
      // was made with someone else's private key.
      final result = await codec.verify(
        qrData: qr,
        keys: resolver,
        now: DateTime.utc(2026, 6, 1),
      );

      expect(result, isA<VerificationInvalid>());
    });

    test('rejects an altered score', () async {
      final qr = await codec.encodeAndSign(
        certificate: sampleCertificate(),
        keyPair: orgKeys,
      );

      // Flip a byte in the payload region and re-encode. Whatever it lands on,
      // the signature must stop matching.
      final envelope = Base45.decode(qr.substring(kQrPrefix.length));
      final bodyLength = envelope.length - kSignatureLength;
      var mutations = 0;

      for (var i = 0; i < bodyLength; i += 7) {
        final tampered = Uint8List.fromList(envelope);
        tampered[i] = tampered[i] ^ 0xFF;

        final result = await codec.verify(
          qrData: '$kQrPrefix${Base45.encode(tampered)}',
          keys: resolver,
          now: DateTime.utc(2026, 6, 1),
        );

        // Either the structure no longer parses or the signature fails. Both
        // are refusals; what must never happen is a VerificationValid.
        expect(
          result,
          anyOf(isA<VerificationInvalid>(), isA<VerificationMalformed>()),
          reason: 'byte $i was mutated and still verified',
        );
        mutations++;
      }

      expect(mutations, greaterThan(4));
    });

    test('rejects a tampered signature', () async {
      final qr = await codec.encodeAndSign(
        certificate: sampleCertificate(),
        keyPair: orgKeys,
      );

      final envelope = Base45.decode(qr.substring(kQrPrefix.length));
      envelope[envelope.length - 1] ^= 0x01;

      final result = await codec.verify(
        qrData: '$kQrPrefix${Base45.encode(envelope)}',
        keys: resolver,
        now: DateTime.utc(2026, 6, 1),
      );

      expect(result, isA<VerificationInvalid>());
    });

    test('reports an unknown key rather than claiming forgery', () async {
      final deviceKeys = await codec.generateKeyPair();
      final qr = await codec.encodeAndSign(
        certificate: sampleCertificate(
          keyId: 'dev:a91f',
          tier: TrustTier.provisional,
        ),
        keyPair: deviceKeys,
      );

      final result = await codec.verify(qrData: qr, keys: resolver);

      // The distinction matters in the field: this verifier simply has not
      // synced with the issuing site, which is a different problem from a
      // forged certificate and needs a different response.
      expect(result, isA<VerificationUnknownKey>());
      expect((result as VerificationUnknownKey).keyId, 'dev:a91f');
    });
  });

  group('expiry', () {
    test('a genuine but out-of-date certificate reports as expired', () async {
      final qr = await codec.encodeAndSign(
        certificate: sampleCertificate(),
        keyPair: orgKeys,
      );

      final result = await codec.verify(
        qrData: qr,
        keys: resolver,
        now: DateTime.utc(2027, 4, 1),
      );

      expect(result, isA<VerificationExpired>());
      final expired = result as VerificationExpired;
      expect(expired.certificate.workerName, 'Sunita Murmu');
      expect(expired.overdueBy.inDays, 18);
    });

    test('expiry is checked only after the signature passes', () async {
      // A forged certificate that is also out of date must be reported as
      // invalid, never as expired — "expired" reads as a scheduling problem
      // and would let a forgery through as a paperwork issue.
      final attackerKeys = await codec.generateKeyPair();
      final qr = await codec.encodeAndSign(
        certificate: sampleCertificate(),
        keyPair: attackerKeys,
      );

      final result = await codec.verify(
        qrData: qr,
        keys: resolver,
        now: DateTime.utc(2030, 1, 1),
      );

      expect(result, isA<VerificationInvalid>());
    });

    test('a certificate is valid right up to its expiry instant', () async {
      final expires = DateTime.utc(2027, 3, 14);
      final qr = await codec.encodeAndSign(
        certificate: sampleCertificate(expiresAt: expires),
        keyPair: orgKeys,
      );

      final justBefore = await codec.verify(
        qrData: qr,
        keys: resolver,
        now: expires.subtract(const Duration(seconds: 1)),
      );
      final atExpiry = await codec.verify(
        qrData: qr,
        keys: resolver,
        now: expires,
      );

      expect(justBefore, isA<VerificationValid>());
      expect(atExpiry, isA<VerificationExpired>());
    });
  });

  group('malformed input', () {
    test('rejects a QR that is not a SurakshaAR certificate', () async {
      for (final junk in [
        'https://example.com',
        '',
        'SJH2:BB8',
        'BB8',
      ]) {
        final result = await codec.verify(qrData: junk, keys: resolver);
        expect(result, isA<VerificationMalformed>(), reason: junk);
      }
    });

    test('rejects a truncated envelope', () async {
      final result = await codec.verify(
        qrData: '${kQrPrefix}BB8',
        keys: resolver,
      );
      expect(result, isA<VerificationMalformed>());
    });
  });

  group('counter-signing', () {
    test('promotes a provisional certificate to verified', () async {
      final deviceKeys = await codec.generateKeyPair();
      final devicePublicKey = await CertificateCodec.publicKeyBytes(deviceKeys);

      final provisional = sampleCertificate(
        keyId: 'dev:a91f',
        tier: TrustTier.provisional,
      );
      final provisionalQr = await codec.encodeAndSign(
        certificate: provisional,
        keyPair: deviceKeys,
      );

      // Before sync, only a verifier holding this device's key can check it.
      resolver.register('dev:a91f', devicePublicKey);
      final beforeSync = await codec.verify(
        qrData: provisionalQr,
        keys: resolver,
        now: DateTime.utc(2026, 6, 1),
      );
      expect(beforeSync, isA<VerificationValid>());
      expect((beforeSync as VerificationValid).isProvisional, isTrue);

      // After counter-signing, it verifies against the organisation key that
      // is compiled into every install — so any inspector's phone works.
      final verifiedQr = await codec.counterSign(
        certificate: provisional,
        organisationKeyPair: orgKeys,
        organisationKeyId: 'org:jh-2026a',
      );

      final freshResolver = MapKeyResolver({'org:jh-2026a': orgPublicKey});
      final afterSync = await codec.verify(
        qrData: verifiedQr,
        keys: freshResolver,
        now: DateTime.utc(2026, 6, 1),
      );

      expect(afterSync, isA<VerificationValid>());
      final valid = afterSync as VerificationValid;
      expect(valid.isProvisional, isFalse);
      expect(valid.certificate.trustTier, TrustTier.verified);
      // The substance is unchanged — only the attestation was upgraded.
      expect(valid.certificate.workerName, provisional.workerName);
      expect(valid.certificate.modules.length, provisional.modules.length);
      expect(valid.certificate.id, provisional.id);
    });
  });

  group('schema guards', () {
    test('a future schema version is refused, not guessed at', () {
      expect(
        () => WorkerCertificate.fromCbor({
          1: 99,
          2: null,
        }),
        throwsA(isA<CertificateFormatError>()),
      );
    });

    test('a certificate with no modules is refused', () {
      expect(
        () => WorkerCertificate.fromCbor({
          1: WorkerCertificate.currentSchemaVersion,
          6: <Object?>[],
        }),
        throwsA(isA<CertificateFormatError>()),
      );
    });
  });
}
